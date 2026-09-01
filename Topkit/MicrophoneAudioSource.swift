import Foundation
import AVFoundation

/// One shared microphone tap for a recording session, fanned out to every
/// consumer (speech engine, movie audio track). Buffers arrive on the audio
/// tap thread — consumers hop queues themselves.
final class MicrophoneAudioSource {

    enum SourceError: LocalizedError {
        case noInputDevice
        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone input available"
            }
        }
    }

    private let engine = AVAudioEngine()
    private(set) var format: AVAudioFormat?
    private var running = false

    /// Called on the audio tap thread for every captured buffer.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Starts the engine and installs the tap. Throws when there is no usable
    /// input device (no mic, or the sandbox denied the device).
    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SourceError.noInputDevice
        }
        self.format = format
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, when in
            self?.onBuffer?(buffer, when)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        onBuffer = nil
    }
}
