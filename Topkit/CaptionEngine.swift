import Foundation
import AVFoundation
import Speech

/// A speech-to-text backend for live captions. Buffers go in on the audio tap
/// thread; events come out on the main thread.
enum CaptionSpeechEvent {
    case volatile(String)   // hypothesis, will be revised
    case final(String)      // finalized phrase
    case failed(String)     // engine gave up (captions stop updating)
}

protocol CaptionSpeechEngine: AnyObject {
    /// Main thread.
    var onEvent: ((CaptionSpeechEvent) -> Void)? { get set }
    /// Call once, with the mic tap format, before appending buffers.
    func start(format: AVAudioFormat)
    /// Audio tap thread. Safe to call before start has finished spinning up —
    /// early buffers are dropped.
    func append(_ buffer: AVAudioPCMBuffer)
    func stop()
}

enum CaptionEngineFactory {
    /// The macOS 26 SpeechAnalyzer stack when its model supports a locale on
    /// this machine, otherwise the legacy SFSpeechRecognizer path (macOS 14/15).
    static func make() -> CaptionSpeechEngine {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            return ModernSpeechCaptionEngine()
        }
        return LegacySpeechCaptionEngine()
    }

    /// Whether the chosen backend needs the Speech Recognition TCC grant.
    /// The SpeechAnalyzer stack is fully on-device and only needs the mic.
    static var needsSpeechRecognitionPermission: Bool {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable { return false }
        return true
    }
}

// MARK: - macOS 26: SpeechAnalyzer / SpeechTranscriber

@available(macOS 26.0, *)
final class ModernSpeechCaptionEngine: CaptionSpeechEngine {

    var onEvent: ((CaptionSpeechEvent) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var stopped = false

    // Written once during async setup, read on the audio tap thread.
    private let conversionLock = NSLock()
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var ready = false

    /// Kick the model asset download early (app launch / pref toggle) so the
    /// first recording doesn't caption late. Safe to call repeatedly.
    static func preflightAssets() {
        Task.detached(priority: .utility) {
            guard SpeechTranscriber.isAvailable else { return }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let status = await AssetInventory.status(forModules: [transcriber])
            guard status == .supported || status == .downloading else { return }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                    debugLog("🎤 SpeechTranscriber assets installed")
                }
            } catch {
                debugLog("🎤 SpeechTranscriber asset preflight failed: \(error.localizedDescription)")
            }
        }
    }

    func start(format: AVAudioFormat) {
        Task { [weak self] in
            do {
                try await self?.startAnalyzer(tapFormat: format)
            } catch {
                debugLog("🎤 SpeechAnalyzer start failed: \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    self?.onEvent?(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func startAnalyzer(tapFormat: AVAudioFormat) async throws {
        var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if resolved == nil {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        }
        guard let locale = resolved else {
            throw NSError(domain: "Topkit.Captions", code: 1, userInfo: [NSLocalizedDescriptionKey: "No supported caption language"])
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        // Assets are normally preinstalled by preflightAssets; this catches the
        // first-ever run. downloadAndInstall is a no-op when already installed.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: tapFormat)
        conversionLock.lock()
        if let best, best != tapFormat {
            converter = AVAudioConverter(from: tapFormat, to: best)
        }
        analyzerFormat = best ?? tapFormat
        conversionLock.unlock()

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run { [weak self] in
                        guard let self, !self.stopped else { return }
                        self.onEvent?(isFinal ? .final(text) : .volatile(text))
                    }
                }
            } catch {
                debugLog("🎤 SpeechTranscriber results ended: \(error.localizedDescription)")
            }
        }

        try await analyzer.start(inputSequence: stream)
        conversionLock.lock()
        ready = true
        conversionLock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        conversionLock.lock()
        let ready = self.ready
        let converter = self.converter
        let analyzerFormat = self.analyzerFormat
        conversionLock.unlock()
        guard ready, !stopped else { return }

        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }
            inputContinuation?.yield(AnalyzerInput(buffer: out))
        } else {
            inputContinuation?.yield(AnalyzerInput(buffer: buffer))
        }
    }

    func stop() {
        stopped = true
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task {
            await analyzer?.cancelAndFinishNow()
        }
        resultsTask?.cancel()
        resultsTask = nil
    }
}

// MARK: - macOS 14/15 fallback: SFSpeechRecognizer

final class LegacySpeechCaptionEngine: NSObject, CaptionSpeechEngine {

    var onEvent: ((CaptionSpeechEvent) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private let requestLock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopped = false
    private var restartAttempts = 0

    func start(format: AVAudioFormat) {
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            onEvent?(.failed(String(localized: "Speech recognition is not available")))
            return
        }
        // Never use Apple's server speech path — keeps App Privacy as
        // "Data Not Collected" and matches the store privacy claim.
        guard recognizer.supportsOnDeviceRecognition else {
            onEvent?(.failed(String(localized: "On-device speech recognition is not available")))
            return
        }
        self.recognizer = recognizer
        startRequest()
    }

    private func startRequest() {
        guard !stopped, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = true
        requestLock.lock()
        self.request = request
        requestLock.unlock()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result: result, error: error) }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard !stopped else { return }
        if let result {
            restartAttempts = 0
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                onEvent?(.final(text))
                // On-device sessions can still end at utterance boundaries —
                // start a fresh request so dictation keeps going.
                startRequest()
            } else {
                onEvent?(.volatile(text))
            }
            return
        }
        if error != nil {
            requestLock.lock()
            request = nil
            requestLock.unlock()
            task = nil
            restartAttempts += 1
            guard restartAttempts <= 5 else {
                onEvent?(.failed(String(localized: "Speech recognition stopped")))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startRequest()
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        let request = self.request
        requestLock.unlock()
        request?.append(buffer)
    }

    func stop() {
        stopped = true
        requestLock.lock()
        let request = self.request
        self.request = nil
        requestLock.unlock()
        request?.endAudio()
        task?.cancel()
        task = nil
    }
}

// MARK: - Session coordinator

/// Owns one recording's caption pipeline: engine events → rolling transcript →
/// display text pushed to the overlay and the burn-in renderer. Main thread,
/// except `append`.
final class CaptionSession {

    private let engine: CaptionSpeechEngine
    private var transcript = CaptionTranscript()
    private var lingerTimer: Timer?
    private var active = false

    /// Seconds a finished phrase stays on screen with no new speech.
    static let lingerSeconds: TimeInterval = 1.25

    /// Main thread. nil text = hide the caption.
    var onDisplayTextChanged: ((String?) -> Void)?

    init(engine: CaptionSpeechEngine = CaptionEngineFactory.make()) {
        self.engine = engine
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start(format: AVAudioFormat) {
        active = true
        engine.start(format: format)
    }

    /// Audio tap thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        engine.append(buffer)
    }

    func stop() {
        active = false
        lingerTimer?.invalidate()
        lingerTimer = nil
        engine.stop()
        onDisplayTextChanged?(nil)
    }

    private func handle(_ event: CaptionSpeechEvent) {
        guard active else { return }
        switch event {
        case .volatile(let text):
            lingerTimer?.invalidate()
            lingerTimer = nil
            transcript.updateVolatile(text)
            push()
        case .final(let text):
            // appendFinal drops the volatile hypothesis the final supersedes:
            // legacy finals cover their whole request, modern ones their phrase.
            transcript.appendFinal(text)
            push()
            scheduleLingerClear()
        case .failed:
            transcript.clear()
            onDisplayTextChanged?(nil)
        }
    }

    private func push() {
        let text = transcript.displayText
        onDisplayTextChanged?(text.isEmpty ? nil : text)
    }

    private func scheduleLingerClear() {
        lingerTimer?.invalidate()
        lingerTimer = Timer.scheduledTimer(withTimeInterval: Self.lingerSeconds, repeats: false) { [weak self] _ in
            guard let self, self.active else { return }
            self.transcript.clear()
            self.onDisplayTextChanged?(nil)
        }
    }
}
