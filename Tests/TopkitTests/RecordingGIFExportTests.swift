import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class RecordingGIFExportTests: XCTestCase {

    // MARK: - Presets

    func testQualityDefaultsToMedium() {
        XCTAssertEqual(RecordingGIFQuality.stored(nil), .medium)
        XCTAssertEqual(RecordingGIFQuality.stored("bogus"), .medium)
        XCTAssertEqual(RecordingGIFQuality.stored("high"), .high)
    }

    func testQualityPresetsRiseWithQuality() {
        let presets = RecordingGIFQuality.allCases
        XCTAssertEqual(presets, [.low, .medium, .high])
        XCTAssertEqual(presets.map(\.framesPerSecond), [10, 15, 20])
        XCTAssertEqual(presets.map(\.maxPixelWidth), [480, 720, 1080])
    }

    func testFolderModeDefaultsToSameAsVideo() {
        XCTAssertEqual(RecordingGIFFolderMode.stored(nil), .sameAsVideo)
        XCTAssertEqual(RecordingGIFFolderMode.stored("custom"), .custom)
    }

    // MARK: - Sample times + delays

    func testSampleTimesCoverDurationAtFrameRate() {
        let times = RecordingGIFMath.sampleTimes(duration: 1.0, framesPerSecond: 10)
        XCTAssertEqual(times.count, 10)
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times.last!, 0.9, accuracy: 1e-9)
    }

    func testSampleTimesForShortAndEmptyClips() {
        XCTAssertEqual(RecordingGIFMath.sampleTimes(duration: 0.01, framesPerSecond: 15), [0])
        XCTAssertEqual(RecordingGIFMath.sampleTimes(duration: 0, framesPerSecond: 15), [])
        XCTAssertEqual(RecordingGIFMath.sampleTimes(duration: .nan, framesPerSecond: 15), [])
        XCTAssertEqual(RecordingGIFMath.sampleTimes(duration: 1, framesPerSecond: 0), [])
    }

    func testDelaysAddUpWithoutDrift() {
        // 15 fps is 6.67 cs per frame; rounding on the timeline keeps 3 s at 300 cs.
        let times = RecordingGIFMath.sampleTimes(duration: 3, framesPerSecond: 15)
        var total = 0
        for (i, start) in times.enumerated() {
            let end = i + 1 < times.count ? times[i + 1] : 3
            total += RecordingGIFMath.delayCentiseconds(start: start, end: end)
        }
        XCTAssertEqual(total, 300)
    }

    func testDelayHasTwoCentisecondFloor() {
        XCTAssertEqual(RecordingGIFMath.delayCentiseconds(start: 0, end: 0.001), 2)
        XCTAssertEqual(RecordingGIFMath.delayCentiseconds(start: 0, end: 0.5), 50)
    }

    // MARK: - Size

    func testOutputSizeScalesDownKeepingAspect() {
        let size = RecordingGIFMath.outputSize(sourceWidth: 2880, sourceHeight: 1800, maxWidth: 720)
        XCTAssertEqual(size.width, 720)
        XCTAssertEqual(size.height, 450)
    }

    func testOutputSizeNeverUpscales() {
        let size = RecordingGIFMath.outputSize(sourceWidth: 300, sourceHeight: 200, maxWidth: 720)
        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 200)
    }

    // MARK: - Output location

    func testOutputURLUsesVideoBaseName() {
        let video = URL(fileURLWithPath: "/Users/me/Desktop/Recording_2026-11-07_10-00-00.mov")
        let folder = URL(fileURLWithPath: "/tmp/gifs", isDirectory: true)
        let url = RecordingGIFMath.outputURL(forVideo: video, in: folder) { _ in false }
        XCTAssertEqual(url.path, "/tmp/gifs/Recording_2026-11-07_10-00-00.gif")
    }

    func testOutputURLAvoidsTakenNames() {
        let video = URL(fileURLWithPath: "/Users/me/Desktop/Demo.mov")
        let folder = URL(fileURLWithPath: "/tmp/gifs", isDirectory: true)
        let taken: Set<String> = ["/tmp/gifs/Demo.gif", "/tmp/gifs/Demo_2.gif"]
        let url = RecordingGIFMath.outputURL(forVideo: video, in: folder) { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "Demo_3.gif")
    }

    // MARK: - Toolbar

    func testRecordingToolbarHasGIFToggleOffByDefaultAndPersists() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: RecordingGIFKeys.exportEnabled)
        defer { defaults.set(previous, forKey: RecordingGIFKeys.exportEnabled) }
        defaults.removeObject(forKey: RecordingGIFKeys.exportEnabled)

        let view = SelectionConfirmView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            selectionRect: NSRect(x: 100, y: 100, width: 200, height: 200),
            primaryTitle: "Start Recording",
            primaryIsDestructive: true,
            allowsResize: true,
            showsRecordingOptions: true
        )
        guard let gif = findCheckbox(in: view, title: "GIF") else {
            return XCTFail("Recording toolbar must show a GIF toggle")
        }
        XCTAssertEqual(gif.state, .off, "GIF is off by default")

        gif.state = .on
        _ = NSApp.sendAction(gif.action!, to: gif.target, from: gif)
        XCTAssertTrue(defaults.bool(forKey: RecordingGIFKeys.exportEnabled), "GIF toggle must persist")
    }

    func testNonRecordingToolbarHasNoGIFToggle() {
        let view = SelectionConfirmView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            selectionRect: NSRect(x: 100, y: 100, width: 200, height: 200),
            primaryTitle: "Capture",
            showsRecordingOptions: false
        )
        XCTAssertNil(findCheckbox(in: view, title: "GIF"))
    }

    private func findCheckbox(in view: NSView, title: String) -> NSButton? {
        for sub in view.subviews {
            if let button = sub as? NSButton, button.title == title { return button }
            if let found = findCheckbox(in: sub, title: title) { return found }
        }
        return nil
    }

    // MARK: - Encoder

    /// A 1 s screen-recording-like clip: a red frame at 0, a blue frame at
    /// 0.5 s and nothing new after (ScreenCaptureKit only sends changed
    /// frames). Low quality samples 10 frames; unchanged ones merge, so the
    /// GIF has 2 frames of 0.5 s each and loops forever.
    func testEncoderWritesLoopingGIFWithMergedFrames() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingGIFExportTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoURL = dir.appendingPathComponent("clip.mov")
        let gifURL = dir.appendingPathComponent("clip.gif")

        try await writeTestVideo(to: videoURL, width: 64, height: 48, frames: [
            (time: 0.0, color: (r: 255, g: 0, b: 0)),
            (time: 0.5, color: (r: 0, g: 0, b: 255)),
        ], endTime: 1.0)

        let frameCount = try await RecordingGIFEncoder.encode(videoURL: videoURL, to: gifURL, quality: .low)
        XCTAssertEqual(frameCount, 2)

        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            return XCTFail("GIF must be readable")
        }
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
        XCTAssertEqual(CGImageSourceGetCount(source), 2)

        let fileProps = CGImageSourceCopyProperties(source, nil) as? [String: Any]
        let fileGIF = fileProps?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        XCTAssertEqual(fileGIF?[kCGImagePropertyGIFLoopCount as String] as? Int, 0, "GIF loops forever")

        var total = 0.0
        for i in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
            let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            total += (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? 0
            XCTAssertEqual(props?[kCGImagePropertyPixelWidth as String] as? Int, 64)
        }
        XCTAssertEqual(total, 1.0, accuracy: 0.02, "GIF runs as long as the video")
    }

    private func writeTestVideo(
        to url: URL,
        width: Int,
        height: Int,
        frames: [(time: Double, color: (r: UInt8, g: UInt8, b: UInt8))],
        endTime: Double
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary, &buffer)
            guard let buffer else { return XCTFail("Pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * rowBytes + x * 4
                    p[0] = frame.color.b; p[1] = frame.color.g; p[2] = frame.color.r; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(seconds: frame.time, preferredTimescale: 600)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: endTime, preferredTimescale: 600))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
