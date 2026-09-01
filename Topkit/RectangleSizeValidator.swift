import AppKit
import Foundation

enum RectangleSizeValidator {
    /// Clamps a rectangle size to a viewport, and ensures the result is at least 1x1.
    static func clamp(size: NSSize, toViewport viewportSize: NSSize) -> NSSize {
        let maxWidth = min(size.width, viewportSize.width)
        let maxHeight = min(size.height, viewportSize.height)
        return NSSize(width: max(1, maxWidth), height: max(1, maxHeight))
    }
}

