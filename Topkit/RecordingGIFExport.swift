import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Optional GIF saved alongside a recording (GIF toggle in the recording
/// toolbar, off by default). Folder and quality live in Preferences.
enum RecordingGIFKeys {
    /// Recording toolbar toggle.
    static let exportEnabled = "recordingExportGIF"
    static let quality = "recordingGIFQuality"
    /// `RecordingGIFFolderMode` raw value.
    static let folderMode = "recordingGIFFolderMode"
    static let folder = "recordingGIFFolder"
    static let folderBookmark = "recordingGIFFolderBookmark"
}

enum RecordingGIFFolderMode: String, CaseIterable {
    case sameAsVideo
    case custom

    static func stored(_ raw: String?) -> RecordingGIFFolderMode {
        raw.flatMap(RecordingGIFFolderMode.init(rawValue:)) ?? .sameAsVideo
    }
}

/// Low / Medium / High: frame rate plus a width cap (never upscaled).
/// Frame rates keep GIF centisecond delays close to even.
enum RecordingGIFQuality: String, CaseIterable {
    case low
    case medium
    case high

    static func stored(_ raw: String?) -> RecordingGIFQuality {
        raw.flatMap(RecordingGIFQuality.init(rawValue:)) ?? .medium
    }

    var framesPerSecond: Int {
        switch self {
        case .low: return 10
        case .medium: return 15
        case .high: return 20
        }
    }

    var maxPixelWidth: Int {
        switch self {
        case .low: return 480
        case .medium: return 720
        case .high: return 1080
        }
    }
}

/// Pure maths for the GIF export (unit tested).
enum RecordingGIFMath {
    /// Times (seconds) at which a frame is sampled: 0, 1/fps, 2/fps, … before
    /// `duration`. A clip shorter than one frame still gets the frame at 0.
    static func sampleTimes(duration: Double, framesPerSecond: Int) -> [Double] {
        guard duration.isFinite, duration > 0, framesPerSecond > 0 else { return [] }
        let count = max(1, Int((duration * Double(framesPerSecond)).rounded(.up)))
        return (0..<count).map { Double($0) / Double(framesPerSecond) }
    }

    /// GIF delay for a frame shown from `start` to `end`, in centiseconds.
    /// Rounded on the absolute timeline so per-frame rounding never drifts
    /// (15 fps gives 7, 7, 6, …, not 7 every frame). Floor 2: browsers slow
    /// anything faster to 10.
    static func delayCentiseconds(start: Double, end: Double) -> Int {
        max(2, Int((end * 100).rounded()) - Int((start * 100).rounded()))
    }

    /// Output pixel size: source scaled down to `maxWidth` (never up),
    /// aspect kept, at least 1×1.
    static func outputSize(sourceWidth: Int, sourceHeight: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (1, 1) }
        let width = min(sourceWidth, max(1, maxWidth))
        let height = max(1, Int((Double(sourceHeight) * Double(width) / Double(sourceWidth)).rounded()))
        return (width, height)
    }

    /// Same base name as the video with .gif. If that name is taken (a GIF
    /// from an earlier recording), `_2`, `_3`, … like recording filenames.
    static func outputURL(forVideo videoURL: URL, in folder: URL, isTaken: (URL) -> Bool) -> URL {
        let base = videoURL.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(base).gif")
        var n = 2
        while isTaken(candidate) {
            candidate = folder.appendingPathComponent("\(base)_\(n).gif")
            n += 1
        }
        return candidate
    }
}

enum RecordingGIFError: Error {
    case noVideoTrack
    case cannotRead
    case cannotWrite
}

/// Video → looping GIF with ImageIO. Frames come from one sequential
/// AVAssetReader pass (no per-frame seeking), sampled at the quality's frame
/// rate. Unchanged stretches (screen recordings only get new frames when
/// pixels change) collapse into one longer GIF frame, which keeps files small.
enum RecordingGIFEncoder {

    /// Writes the GIF to `outputURL`. Returns the number of GIF frames.
    /// Throws `CancellationError` when the task is cancelled.
    @discardableResult
    static func encode(videoURL: URL, to outputURL: URL, quality: RecordingGIFQuality) async throws -> Int {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingGIFError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let naturalSize = try await track.load(.naturalSize)
        try Task.checkCancellation()

        let times = RecordingGIFMath.sampleTimes(duration: duration, framesPerSecond: quality.framesPerSecond)
        guard !times.isEmpty else { throw RecordingGIFError.cannotRead }
        let size = RecordingGIFMath.outputSize(
            sourceWidth: Int(naturalSize.width.rounded()),
            sourceHeight: Int(naturalSize.height.rounded()),
            maxWidth: quality.maxPixelWidth
        )

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingGIFError.cannotRead }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecordingGIFError.cannotRead }
        defer { if reader.status == .reading { reader.cancelReading() } }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, times.count, nil
        ) else { throw RecordingGIFError.cannotWrite }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)

        let writer = FrameWriter(destination: destination, width: size.width, height: size.height)
        guard writer.isReady else { throw RecordingGIFError.cannotWrite }

        var targetIndex = 0
        var current: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Every sample time before this frame shows the previous frame.
            while targetIndex < times.count, times[targetIndex] + 0.0001 < pts {
                if let current { writer.add(current, at: times[targetIndex]) }
                targetIndex += 1
            }
            current = pixelBuffer
        }
        if reader.status == .failed { throw reader.error ?? RecordingGIFError.cannotRead }
        try Task.checkCancellation()
        while targetIndex < times.count {
            if let current { writer.add(current, at: times[targetIndex]) }
            targetIndex += 1
        }
        writer.flush(endTime: duration)
        guard writer.frameCount > 0, CGImageDestinationFinalize(destination) else {
            throw RecordingGIFError.cannotWrite
        }
        return writer.frameCount
    }

    /// Scales frames into one reusable bitmap, drops repeats, and writes each
    /// distinct frame once its display time is known.
    private final class FrameWriter {
        private let destination: CGImageDestination
        private let context: CGContext?
        private let byteCount: Int
        private var lastBuffer: CVPixelBuffer?
        private var lastBytes: [UInt8] = []
        private var pendingImage: CGImage?
        private var pendingStart: Double = 0
        private(set) var frameCount = 0

        var isReady: Bool { context != nil }

        init(destination: CGImageDestination, width: Int, height: Int) {
            self.destination = destination
            byteCount = width * height * 4
            context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.interpolationQuality = .high
        }

        func add(_ pixelBuffer: CVPixelBuffer, at time: Double) {
            // Same decoded frame as last time: the pending frame just runs longer.
            if let lastBuffer, lastBuffer === pixelBuffer { return }
            lastBuffer = pixelBuffer
            guard let context, let data = context.data else { return }
            var source: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &source)
            guard let source else { return }
            context.draw(source, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: byteCount)
            if pendingImage != nil, bytes.elementsEqual(lastBytes) { return }
            lastBytes = Array(bytes)
            guard let image = context.makeImage() else { return }
            if pendingImage != nil {
                writePending(endTime: time)
                pendingStart = time
            }
            pendingImage = image
        }

        func flush(endTime: Double) {
            writePending(endTime: max(endTime, pendingStart))
        }

        private func writePending(endTime: Double) {
            guard let image = pendingImage else { return }
            let delay = Double(RecordingGIFMath.delayCentiseconds(start: pendingStart, end: endTime)) / 100
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delay,
                ],
            ] as CFDictionary)
            frameCount += 1
            pendingImage = nil
        }
    }
}

/// The GIF that goes with one saved recording. Follows the recording through
/// the player: a trim re-exports it, a rename renames it, Delete moves it to
/// the Trash too. Main thread only; encoding runs in a background task.
final class RecordingGIFCompanion {
    private var videoURL: URL
    /// Set once the first export lands. Later exports overwrite it.
    private(set) var gifURL: URL?
    /// Bookmark of the folder the GIF lives in (GIF folder, or the video's).
    private var folderBookmarkKey: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isDiscarded = false

    init(videoURL: URL) {
        self.videoURL = videoURL
    }

    /// True when a GIF exists or is on its way.
    var hasGIF: Bool { gifURL != nil || task != nil }

    /// (Re-)export from the video as it is now. A newer call cancels an
    /// export still running.
    func export(from videoURL: URL) {
        guard !isDiscarded else { return }
        self.videoURL = videoURL
        task?.cancel()
        generation += 1
        let generation = generation
        let defaults = UserDefaults.standard
        let quality = RecordingGIFQuality.stored(defaults.string(forKey: RecordingGIFKeys.quality))
        let mode = RecordingGIFFolderMode.stored(defaults.string(forKey: RecordingGIFKeys.folderMode))
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIF_inprogress_\(UUID().uuidString).gif")

        // Holds self until the export lands; the task is dropped when it does.
        task = Task.detached(priority: .utility) {
            // The player's folder scope may end before the export does.
            let videoScope = RecordingDestination.beginSaveFolderAccess()
            defer { if let videoScope { RecordingDestination.endSaveFolderAccess(videoScope) } }
            let result: Result<Void, Error>
            do {
                try await RecordingGIFEncoder.encode(videoURL: videoURL, to: tempURL, quality: quality)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                guard self.generation == generation else {
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }
                self.task = nil
                self.finishExport(tempURL: tempURL, mode: mode, result: result)
            }
        }
    }

    private func finishExport(tempURL: URL, mode: RecordingGIFFolderMode, result: Result<Void, Error>) {
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if case .failure(let error) = result {
            if error is CancellationError { return }
            debugLog("❌ GIF export failed: \(error.localizedDescription)")
            ToastPresenter.shared.show(message: String(localized: "GIF export failed"), force: true)
            return
        }

        // Re-export: overwrite the GIF this recording already has.
        if let gifURL, let key = folderBookmarkKey {
            let replaced: URL?? = RecordingDestination.withFolderAccess(bookmarkKey: key) { _ in
                try FileManager.default.replaceItemAt(gifURL, withItemAt: tempURL)
            }
            if let replaced, let newURL = replaced {
                self.gifURL = newURL
                ToastPresenter.shared.show(message: String(localized: "GIF saved"))
            } else {
                ToastPresenter.shared.show(message: String(localized: "GIF export failed"), force: true)
            }
            return
        }

        // First export: GIF folder if chosen and reachable, else next to the video.
        var fellBack = false
        var saved: URL?
        if mode == .custom {
            saved = RecordingDestination.withFolderAccess(bookmarkKey: RecordingGIFKeys.folderBookmark) { folder in
                try self.moveNew(tempURL: tempURL, into: folder)
            }
            if saved != nil {
                folderBookmarkKey = RecordingGIFKeys.folderBookmark
            } else {
                fellBack = true
            }
        }
        if saved == nil {
            saved = RecordingDestination.withSaveFolderAccess { _ in
                try self.moveNew(tempURL: tempURL, into: self.videoURL.deletingLastPathComponent())
            }
            if saved != nil { folderBookmarkKey = RecordingDestinationKeys.folderBookmark }
        }
        guard let saved else {
            ToastPresenter.shared.show(message: String(localized: "GIF export failed"), force: true)
            return
        }
        gifURL = saved
        debugLog("✅ GIF saved to: \(saved.path)")
        ToastPresenter.shared.show(
            message: fellBack
                ? String(localized: "GIF folder unavailable — GIF saved next to the video")
                : String(localized: "GIF saved"),
            force: fellBack
        )
    }

    private func moveNew(tempURL: URL, into folder: URL) throws -> URL {
        let target = RecordingGIFMath.outputURL(forVideo: videoURL, in: folder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try FileManager.default.moveItem(at: tempURL, to: target)
        return target
    }

    /// The player renamed the video: give the GIF the same base name.
    func videoRenamed(to newVideoURL: URL) {
        videoURL = newVideoURL
        guard let gifURL, let key = folderBookmarkKey else { return }
        let newBase = newVideoURL.deletingPathExtension().lastPathComponent
        if let renamed = RecordingDestination.renameFile(at: gifURL, to: newBase, bookmarkKey: key) {
            self.gifURL = renamed
        } else {
            debugLog("❌ GIF rename failed: \(gifURL.path)")
        }
    }

    /// The player deleted the video: stop any export and move the GIF to the Trash.
    func discard() {
        isDiscarded = true
        task?.cancel()
        task = nil
        generation += 1
        guard let gifURL, let key = folderBookmarkKey else { return }
        let trashed: Void? = RecordingDestination.withFolderAccess(bookmarkKey: key) { _ in
            try FileManager.default.trashItem(at: gifURL, resultingItemURL: nil)
        }
        if trashed == nil { debugLog("❌ GIF move to Trash failed: \(gifURL.path)") }
        self.gifURL = nil
    }
}
