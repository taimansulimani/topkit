import AppKit

/// Dragging a recording out of the player's title bar into other apps (Finder, Mail,
/// Messages, Slack, Notes, a browser upload field…), like dragging the file
/// from Finder.
///
/// What gets dragged is the recording file itself. Every edit the player
/// offers is already on disk by the time a drag can start: captions are
/// burned in while recording, the file lands in the save folder when the
/// recording stops, and committing a trim overwrites that same file. So the
/// file IS what saving produced: no second exporter, no temp copy. While a
/// committed trim is being written over it, no drag starts.
enum RecordingDrag {

    /// Longest side of the drag image (the current frame), in points: about a
    /// Finder file icon, so it reads as a file being dragged.
    static let maxImageDimension: CGFloat = 80

    /// Corner radius of the drag image.
    static let imageCornerRadius: CGFloat = 6

    /// How far the pointer must move, in points, before a title bar press
    /// becomes a file drag (a shorter move is a click).
    static let dragThreshold: CGFloat = 3

    static func hasPassedThreshold(from start: NSPoint, to point: NSPoint, threshold: CGFloat = dragThreshold) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= threshold
    }

    /// The file to put on the drag pasteboard, or nil when nothing should be
    /// dragged: a committed trim is being written (the file on disk is about
    /// to be replaced), or the file is gone.
    static func draggableFile(
        _ fileURL: URL,
        trimInProgress: Bool,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        guard !trimInProgress, fileURL.isFileURL, fileExists(fileURL) else { return nil }
        return fileURL
    }

    /// Drag image frame: the image scaled to fit `maxDimension` (never
    /// enlarged), centred on the press so the frame sits under the pointer.
    static func dragImageFrame(imageSize: NSSize, centeredAt point: NSPoint, maxDimension: CGFloat = maxImageDimension) -> NSRect {
        let longest = max(imageSize.width, imageSize.height)
        let scale = longest > maxDimension && longest > 0 ? maxDimension / longest : 1
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
    }
}
