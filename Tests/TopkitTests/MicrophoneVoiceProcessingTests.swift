import XCTest
import AVFoundation
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class MicrophoneVoiceProcessingTests: XCTestCase {

    // MARK: Voice processing settings

    func testOtherAudioIsDuckedAsLittleAsPossible() {
        let ducking = MicrophoneVoiceProcessing.otherAudioDucking
        XCTAssertFalse(ducking.enableAdvancedDucking.boolValue)
        XCTAssertEqual(ducking.duckingLevel, .min)
    }

    // MARK: MicrophoneMonoReducer

    private func makeBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, value: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        if format.isInterleaved {
            let data = buffer.floatChannelData![0]
            for frame in 0..<Int(frames) {
                for channel in 0..<channels {
                    data[frame * channels + channel] = value(channel, frame)
                }
            }
        } else {
            for channel in 0..<channels {
                let data = buffer.floatChannelData![channel]
                for frame in 0..<Int(frames) { data[frame] = value(channel, frame) }
            }
        }
        return buffer
    }

    /// Distinct, recognisable sample per channel/frame.
    private func sample(_ channel: Int, _ frame: Int) -> Float {
        Float(channel) + Float(frame) / 10_000
    }

    /// Formats over two channels need an explicit layout (as the input node's
    /// voice-processing format carries one).
    private func multichannel(_ rate: Double, _ channels: UInt32) -> AVAudioFormat {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }

    func testMonoInputNeedsNoReducer() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        XCTAssertNil(MicrophoneMonoReducer(inputFormat: mono))
    }

    func testReducerOutputIsMonoFloatAtSameRate() throws {
        let input = multichannel(44_100, 3)
        let reducer = try XCTUnwrap(MicrophoneMonoReducer(inputFormat: input))
        XCTAssertEqual(reducer.outputFormat.channelCount, 1)
        XCTAssertEqual(reducer.outputFormat.sampleRate, 44_100)
        XCTAssertEqual(reducer.outputFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(reducer.outputFormat.isInterleaved)
    }

    func testReducerKeepsChannelZeroAndFrameCount() throws {
        // macOS voice processing can report a multichannel node format; the
        // processed voice is channel 0.
        let input = multichannel(48_000, 5)
        let reducer = try XCTUnwrap(MicrophoneMonoReducer(inputFormat: input))
        let frames: AVAudioFrameCount = 2048
        let buffer = makeBuffer(format: input, frames: frames, value: sample)

        let mono = try XCTUnwrap(reducer.reduce(buffer))
        XCTAssertEqual(mono.frameLength, frames, "frame count must match so audio timing is unchanged")
        let out = mono.floatChannelData![0]
        for frame in 0..<Int(frames) {
            XCTAssertEqual(out[frame], sample(0, frame), accuracy: 1e-6)
        }
    }

    func testReducerHandlesInterleavedStereo() throws {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let reducer = try XCTUnwrap(MicrophoneMonoReducer(inputFormat: input))
        let buffer = makeBuffer(format: input, frames: 512, value: sample)

        let mono = try XCTUnwrap(reducer.reduce(buffer))
        XCTAssertEqual(mono.frameLength, 512)
        let out = mono.floatChannelData![0]
        for frame in 0..<512 {
            XCTAssertEqual(out[frame], sample(0, frame), accuracy: 1e-6)
        }
    }

    func testReducerIsReusableAcrossBuffers() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let reducer = try XCTUnwrap(MicrophoneMonoReducer(inputFormat: input))
        for round in 0..<4 {
            let buffer = makeBuffer(format: input, frames: 480) { channel, frame in
                Float(round) + self.sample(channel, frame)
            }
            let mono = try XCTUnwrap(reducer.reduce(buffer))
            XCTAssertEqual(mono.frameLength, 480)
            XCTAssertEqual(mono.floatChannelData![0][479], Float(round) + sample(0, 479), accuracy: 1e-6)
        }
    }

    func testEmptyBufferIsDropped() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let reducer = try XCTUnwrap(MicrophoneMonoReducer(inputFormat: input))
        let empty = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 16)!
        XCTAssertNil(reducer.reduce(empty))
    }

    func testReducedBufferWrapsIntoWriterAudioSettings() throws {
        // The writer's AAC settings for the reduced format: mono, 48 kHz.
        let input = multichannel(48_000, 3)
        let reducer = try XCTUnwrap(MicrophoneMonoReducer(inputFormat: input))
        let settings = RecordingEncoding.audioSettings(
            sampleRate: reducer.outputFormat.sampleRate,
            channels: Int(reducer.outputFormat.channelCount)
        )
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 48_000)
    }
}
