import Foundation
import AVFoundation

/// One shared microphone tap for a recording session, fanned out to every
/// consumer (speech engine, movie audio track). Buffers arrive on the audio
/// tap thread — consumers hop queues themselves.
///
/// Noise suppression (TEC-295) is always on: the input node runs Apple's voice
/// processing (noise suppression, echo cancellation, AGC). If the device can't
/// do voice processing the source falls back to the raw mic, as before.
final class MicrophoneAudioSource {

    enum SourceError: LocalizedError {
        case noInputDevice
        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone input available"
            }
        }
    }

    private var engine = AVAudioEngine()
    /// Format of the buffers handed to `onBuffer` (mono when voice processing is on).
    private(set) var format: AVAudioFormat?
    private(set) var isVoiceProcessingActive = false
    private var running = false

    /// Called on the audio tap thread for every captured buffer.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Starts the engine and installs the tap. Throws when there is no usable
    /// input device (no mic, or the sandbox denied the device).
    func start() throws {
        guard !running else { return }
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            debugLog("⚠️ Mic voice processing unavailable (\(error.localizedDescription)) — using raw microphone")
            tearDownEngine()
            engine = AVAudioEngine()
            try startEngine(voiceProcessing: false)
        }
        debugLog("🎤 Mic started — voice processing \(isVoiceProcessingActive ? "on" : "off"), \(format.map { "\($0.sampleRate) Hz × \($0.channelCount)" } ?? "?")")
        running = true
    }

    func stop() {
        guard running else { return }
        tearDownEngine()
        running = false
        onBuffer = nil
    }

    private func startEngine(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if voiceProcessing {
            // Must happen while the engine is stopped, before reading the
            // format: voice processing changes the node's format.
            try input.setVoiceProcessingEnabled(true)
            MicrophoneVoiceProcessing.configure(input)
        }
        isVoiceProcessingActive = voiceProcessing
        let nodeFormat = input.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0 else {
            throw SourceError.noInputDevice
        }
        // Voice processing yields one processed voice channel; on macOS the
        // node can still report extra channels, so keep channel 0 only.
        let reducer = voiceProcessing ? MicrophoneMonoReducer(inputFormat: nodeFormat) : nil
        if voiceProcessing, nodeFormat.channelCount > 1, reducer == nil {
            throw SourceError.noInputDevice
        }
        format = reducer?.outputFormat ?? nodeFormat
        input.installTap(onBus: 0, bufferSize: 2048, format: nodeFormat) { [weak self] buffer, when in
            guard let self else { return }
            if let reducer {
                guard let mono = reducer.reduce(buffer) else { return }
                self.onBuffer?(mono, when)
            } else {
                self.onBuffer?(buffer, when)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func tearDownEngine() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        if input.isVoiceProcessingEnabled {
            // Releases the voice-processing IO (and its ducking of other audio)
            // right away instead of whenever the engine deallocates.
            try? input.setVoiceProcessingEnabled(false)
        }
        isVoiceProcessingActive = false
    }
}

/// Voice-processing settings for screen recordings.
enum MicrophoneVoiceProcessing {
    /// Voice processing ducks other apps' audio by default (voice-chat
    /// behaviour). Recording a voice-over shouldn't make the user's music or
    /// the demo they're narrating quieter, so duck as little as possible.
    static let otherAudioDucking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: false,
        duckingLevel: .min
    )

    /// Automatic gain control keeps quiet and loud talkers at a usable level.
    /// Flip to false if recordings pump (noise floor rising in pauses).
    static let automaticGainControl = true

    static func configure(_ input: AVAudioInputNode) {
        input.voiceProcessingOtherAudioDuckingConfiguration = otherAudioDucking
        input.isVoiceProcessingAGCEnabled = automaticGainControl
        input.isVoiceProcessingBypassed = false
        input.isVoiceProcessingInputMuted = false
    }
}

/// Copies channel 0 of a multichannel PCM buffer into a mono Float32 buffer at
/// the same sample rate. Frame count (and so timing) is unchanged. Nil from
/// `init` when the input is already mono (pass buffers through untouched).
/// Not thread-safe: use from one thread (the audio tap thread).
final class MicrophoneMonoReducer {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.channelCount > 1, inputFormat.sampleRate > 0,
              let mono = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: inputFormat.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: mono) else { return nil }
        converter.channelMap = [0]
        self.inputFormat = inputFormat
        self.outputFormat = mono
        self.converter = converter
    }

    func reduce(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: buffer.frameLength) else { return nil }
        do {
            try converter.convert(to: out, from: buffer)
        } catch {
            return nil
        }
        return out.frameLength == buffer.frameLength ? out : nil
    }
}
