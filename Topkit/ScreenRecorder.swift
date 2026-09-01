import Foundation
import AVFoundation
import ScreenCaptureKit

/// One-shot SCStream → AVAssetWriter (H.264/.mov) recording engine.
/// macOS 14-compatible (SCRecordingOutput needs 15+). Create, start, stop, discard.
///
/// Optional extras, decided at init:
///  - a compressed AAC microphone track (`micFormat` non-nil);
///  - burned-in live captions (`burnsInCaptions`) — frames are then routed
///    through a pixel-buffer adaptor so the caption pill can be stamped onto
///    the pixels, and a low-rate refresh timer re-appends the last frame when
///    the caption changes while the screen is static (SCK only delivers
///    frames when pixels change).
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    enum RecorderError: LocalizedError {
        case writerSetupFailed(String)
        case noFramesCaptured
        var errorDescription: String? {
            switch self {
            case .writerSetupFailed(let reason): return "Recording writer failed: \(reason)"
            case .noFramesCaptured: return "Recording captured no frames"
            }
        }
    }

    let outputURL: URL
    /// Fires on main if the stream dies without stop() being called
    /// (display disconnect, recorded window closed, permission revoked).
    var onStreamStoppedUnexpectedly: ((Error?) -> Void)?

    private let micFormat: AVAudioFormat?
    private let burnsInCaptions: Bool

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var sessionStartTime = CMTime.zero
    private var stopping = false
    private let sampleQueue = DispatchQueue(label: "topkit.recording.samples")

    // Caption state — sampleQueue only.
    private var currentCaption: CaptionBurnImage?
    private var captionGeneration = 0
    private var appendedCaptionGeneration = 0
    private var lastFramePixelBuffer: CVPixelBuffer?
    private var lastVideoPTS = CMTime.invalid
    private var captionRefreshTimer: DispatchSourceTimer?

    init(outputURL: URL, micFormat: AVAudioFormat? = nil, burnsInCaptions: Bool = false) {
        self.outputURL = outputURL
        self.micFormat = micFormat
        self.burnsInCaptions = burnsInCaptions
    }

    func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        pixelWidth: Int,
        pixelHeight: Int,
        completion: @escaping (Error?) -> Void
    ) {
        do {
            try? FileManager.default.removeItem(at: outputURL)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let settings = RecordingEncoding.videoSettings(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.writerSetupFailed("cannot add video input")
            }
            writer.add(input)

            if burnsInCaptions {
                pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: pixelWidth,
                        kCVPixelBufferHeightKey as String: pixelHeight,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                    ]
                )
            }

            if let micFormat {
                let audioSettings = RecordingEncoding.audioSettings(
                    sampleRate: micFormat.sampleRate,
                    channels: Int(micFormat.channelCount)
                )
                let audioInput = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: audioSettings,
                    sourceFormatHint: micFormat.formatDescription
                )
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    self.audioInput = audioInput
                } else {
                    debugLog("❌ Recording: cannot add audio input, continuing video-only")
                }
            }

            guard writer.startWriting() else {
                throw RecorderError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
            }
            self.writer = writer
            self.input = input
        } catch {
            completion(error)
            return
        }

        if burnsInCaptions { startCaptionRefreshTimer() }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            completion(error)
            return
        }
        stream.startCapture { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// Stops capture and finalises the file. Completion on main; nil error
    /// means outputURL holds a playable movie.
    func stop(completion: @escaping (Error?) -> Void) {
        stopping = true
        let finalizeWriter: (Error?) -> Void = { [weak self] stopError in
            guard let self, let writer = self.writer, let input = self.input else {
                DispatchQueue.main.async { completion(stopError) }
                return
            }
            // Hop to the sample queue so no append races finishWriting.
            self.sampleQueue.async {
                self.captionRefreshTimer?.cancel()
                self.captionRefreshTimer = nil
                self.lastFramePixelBuffer = nil
                guard self.sessionStarted, writer.status == .writing else {
                    writer.cancelWriting()
                    DispatchQueue.main.async { completion(stopError ?? RecorderError.noFramesCaptured) }
                    return
                }
                input.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    let error: Error? = writer.status == .completed ? nil : (writer.error ?? stopError)
                    DispatchQueue.main.async { completion(error) }
                }
            }
        }
        if let stream {
            stream.stopCapture { error in finalizeWriter(error) }
        } else {
            finalizeWriter(nil)
        }
    }

    // MARK: - Captions (image rendered on main, state owned by sampleQueue)

    /// Swap the caption stamped onto subsequent frames. nil clears it. The
    /// refresh timer guarantees the change reaches the file even when the
    /// screen content itself is static.
    func updateCaption(_ caption: CaptionBurnImage?) {
        guard burnsInCaptions else { return }
        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.currentCaption = caption
            self.captionGeneration &+= 1
        }
    }

    private func startCaptionRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.sessionStarted, !self.stopping,
                  self.captionGeneration != self.appendedCaptionGeneration,
                  let base = self.lastFramePixelBuffer else { return }
            // Re-append the last frame with the fresh caption at "now" so
            // caption changes show up during static screen content.
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            guard self.lastVideoPTS.isValid, now > self.lastVideoPTS else { return }
            self.appendVideo(pixelBuffer: base, at: now)
        }
        timer.resume()
        captionRefreshTimer = timer
    }

    /// sampleQueue. Appends through the adaptor, burning the current caption.
    private func appendVideo(pixelBuffer: CVPixelBuffer, at pts: CMTime) {
        guard let writer, writer.status == .writing,
              let input, input.isReadyForMoreMediaData,
              let adaptor = pixelAdaptor else { return }

        var appended = false
        if let caption = currentCaption {
            if let pool = adaptor.pixelBufferPool {
                var dest: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dest)
                if let dest, CaptionPixelCompositor.copyAndBurn(source: pixelBuffer, into: dest, caption: caption) {
                    appended = adaptor.append(dest, withPresentationTime: pts)
                }
            }
        }
        if !appended {
            // No caption (or compositing unavailable): pass the frame through.
            appended = adaptor.append(pixelBuffer, withPresentationTime: pts)
        }
        if appended {
            lastVideoPTS = pts
            appendedCaptionGeneration = captionGeneration
        }
    }

    // MARK: - Microphone audio

    /// Audio tap thread: converts immediately (copying the tap's reusable
    /// buffer), then appends on the sample queue.
    func appendMicrophoneBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard audioInput != nil else { return }
        guard let sample = Self.makeAudioSampleBuffer(from: buffer, at: when) else { return }
        sampleQueue.async { [weak self] in
            guard let self, self.sessionStarted, !self.stopping,
                  let writer = self.writer, writer.status == .writing,
                  let audioInput = self.audioInput, audioInput.isReadyForMoreMediaData else { return }
            // Audio from before the first video frame would land ahead of the
            // writer session and error.
            guard CMSampleBufferGetPresentationTimeStamp(sample) >= self.sessionStartTime else { return }
            audioInput.append(sample)
        }
    }

    /// Wraps a PCM tap buffer in a CMSampleBuffer stamped on the host clock —
    /// the same timeline SCK uses for video PTS, so A/V stay in sync.
    private static func makeAudioSampleBuffer(from pcm: AVAudioPCMBuffer, at when: AVAudioTime) -> CMSampleBuffer? {
        let frames = CMItemCount(pcm.frameLength)
        guard frames > 0 else { return nil }

        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: pcm.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard let formatDesc else { return nil }

        let pts = when.isHostTimeValid
            ? CMClockMakeHostTimeFromSystemUnits(when.hostTime)
            : CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sample: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        guard createStatus == noErr, let sample else { return nil }

        // Copies the audio data into the sample buffer's own block buffer.
        let fillStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        guard fillStatus == noErr else { return nil }
        return sample
    }

    // MARK: - SCStreamOutput (called on sampleQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let writer, let input, writer.status == .writing else { return }
        // Only .complete frames carry displayable pixels (SCK also delivers
        // .idle/.blank status frames).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStartTime = pts
            sessionStarted = true
        }
        if burnsInCaptions {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            // Retaining one SCK buffer (queueDepth 8) for the refresh timer.
            lastFramePixelBuffer = pixelBuffer
            appendVideo(pixelBuffer: pixelBuffer, at: pts)
        } else if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            lastVideoPTS = pts
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopping else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onStreamStoppedUnexpectedly?(error)
        }
    }
}
