import AppKit
import CoreGraphics

/// Window subclass that can span multiple monitors without being constrained
class MultiMonitorWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Return the frame unchanged - don't constrain to any single screen
        return frameRect
    }
}

/// Panel subclass that can span multiple monitors without being constrained
class MultiMonitorPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Return the frame unchanged - don't constrain to any single screen
        return frameRect
    }
}

/// Helper class for multi-monitor support
/// Provides consistent screen calculations across all tools
final class MultiMonitorHelper {
    
    /// Get the combined frame that encompasses all connected screens
    /// Returns a rect in screen coordinates (Cocoa coordinate system: origin at bottom-left of primary)
    static func combinedScreenFrame() -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080) // Fallback
        }
        
        // Start with the first screen's frame, not CGRect.zero
        // This avoids any edge cases with zero-size rect unions
        var combined = screens[0].frame
        for i in 1..<screens.count {
            combined = combined.union(screens[i].frame)
        }
        
        return combined
    }
    
    /// Get the frame for a view that fills a window covering all screens
    /// This returns a rect with origin at (0,0) and the size of the combined screen area
    static func viewFrameForFullScreenWindow() -> CGRect {
        let screenFrame = combinedScreenFrame()
        return CGRect(origin: .zero, size: screenFrame.size)
    }
    
    /// Get the primary screen (the one with the menu bar)
    /// This is always the first screen in NSScreen.screens
    static var primaryScreen: NSScreen? {
        return NSScreen.screens.first
    }
    
    /// Get the height of the primary screen (needed for Quartz coordinate conversion)
    static var primaryScreenHeight: CGFloat {
        return primaryScreen?.frame.height ?? 1080
    }
    
    /// Convert screen coordinates to view coordinates for a window
    /// - Parameters:
    ///   - screenPoint: Point in screen coordinates (Cocoa: origin at bottom-left of primary)
    ///   - window: The window to convert coordinates for
    /// - Returns: Point in view/window-local coordinates
    static func screenToView(_ screenPoint: NSPoint, in window: NSWindow) -> NSPoint {
        let windowOrigin = window.frame.origin
        return NSPoint(
            x: screenPoint.x - windowOrigin.x,
            y: screenPoint.y - windowOrigin.y
        )
    }
    
    /// Convert CGEvent location (Quartz coordinates) to Cocoa screen coordinates
    /// Quartz uses top-left origin on primary screen, Cocoa uses bottom-left
    /// - Parameter quartzPoint: Point from CGEvent.location
    /// - Returns: Point in Cocoa screen coordinates
    static func quartzToCocoa(_ quartzPoint: CGPoint) -> NSPoint {
        quartzToCocoa(quartzPoint, primaryScreenHeight: primaryScreenHeight)
    }

    /// Testable conversion overload: provides the primary height directly.
    static func quartzToCocoa(_ quartzPoint: CGPoint, primaryScreenHeight: CGFloat) -> NSPoint {
        return NSPoint(x: quartzPoint.x, y: primaryScreenHeight - quartzPoint.y)
    }

    /// Global Cocoa screen frame → rectangle for `CGWindowListCreateImage` (Quartz top-left relative to primary).
    static func quartzCaptureRect(forGlobalCocoaScreenFrame cocoa: NSRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: cocoa.origin.x,
            y: primaryScreenHeight - cocoa.maxY,
            width: cocoa.width,
            height: cocoa.height
        )
    }
    
    /// Intersects a global Cocoa hole rect with one frozen display snapshot. Returns `src` in snapshot image space and `dst` in the active annotation window’s coordinates.
    static func frozenHoleBlitRectangles(globalHole: NSRect, snapFrame: NSRect, activeScreenOrigin: CGPoint) -> (src: NSRect, dst: NSRect)? {
        let inter = globalHole.intersection(snapFrame)
        if inter.isEmpty { return nil }
        let src = NSRect(
            x: inter.minX - snapFrame.minX,
            y: inter.minY - snapFrame.minY,
            width: inter.width,
            height: inter.height
        )
        let dst = NSRect(
            x: inter.minX - activeScreenOrigin.x,
            y: inter.minY - activeScreenOrigin.y,
            width: inter.width,
            height: inter.height
        )
        return (src, dst)
    }
    
    /// Builds one image from frozen per-display snapshots for a global rect (used after region pick confirm).
    static func compositeFrozenGlobalRect(_ globalRect: NSRect, snapshots: [(image: NSImage, frame: NSRect)]) -> NSImage? {
        let pieces: [(inter: NSRect, image: NSImage, snapFrame: NSRect)] = snapshots.compactMap { snap in
            let inter = globalRect.intersection(snap.frame)
            guard !inter.isEmpty else { return nil }
            return (inter, snap.image, snap.frame)
        }
        guard !pieces.isEmpty else { return nil }
        let minX = pieces.map(\.inter.minX).min()!
        let minY = pieces.map(\.inter.minY).min()!
        let maxX = pieces.map(\.inter.maxX).max()!
        let maxY = pieces.map(\.inter.maxY).max()!
        let outW = maxX - minX
        let outH = maxY - minY
        guard outW > 0, outH > 0 else { return nil }
        let outSize = NSSize(width: outW, height: outH)

        // Preserve Retina detail. The frozen grabs are captured at native pixel density
        // (.bestResolution), so allocate the output bitmap in PIXELS (points × scale) and
        // tag rep.size back in points. Sizing it in points instead (the old behaviour)
        // downsamples real captured pixels to 1x. For a selection spanning mixed-DPI
        // displays, use the highest contributing scale so the sharpest screen isn't lost.
        let scale: CGFloat = pieces.reduce(1.0) { acc, piece in
            let pointW = piece.image.size.width
            guard pointW > 0,
                  let px = piece.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width
            else { return acc }
            return max(acc, CGFloat(px) / pointW)
        }
        let pixelsWide = max(1, Int((outW * scale).rounded()))
        let pixelsHigh = max(1, Int((outH * scale).rounded()))

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmapRep = rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Draw in pixel space (matches renderAnnotatedImage), then tag rep.size in points.
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: CGFloat(pixelsWide), height: CGFloat(pixelsHigh)).fill()
        for piece in pieces {
            let src = NSRect(
                x: piece.inter.minX - piece.snapFrame.minX,
                y: piece.inter.minY - piece.snapFrame.minY,
                width: piece.inter.width,
                height: piece.inter.height
            )
            let dst = NSRect(
                x: (piece.inter.minX - minX) * scale,
                y: (piece.inter.minY - minY) * scale,
                width: piece.inter.width * scale,
                height: piece.inter.height * scale
            )
            piece.image.draw(in: dst, from: src, operation: .copy, fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()
        bitmapRep.size = outSize
        let out = NSImage(size: outSize)
        out.addRepresentation(bitmapRep)
        return out
    }
    
    /// Get the screen that contains the given point
    /// - Parameter screenPoint: Point in screen coordinates
    /// - Returns: The screen containing the point, or nil if none
    static func screenContaining(_ screenPoint: NSPoint) -> NSScreen? {
        return NSScreen.screens.first(where: { NSMouseInRect(screenPoint, $0.frame, false) })
    }

    /// Compute the view-local rect to show a captured screenshot inside a
    /// full-desktop annotation window, placed on a specific target monitor.
    ///
    /// - The image is aspect-fit into the target monitor's area minus
    ///   `reservedTop` points (left free at the top for the annotation toolbar
    ///   and slider row) and `horizontalPadding` points of breathing room on
    ///   the left / right / bottom edges.
    /// - The result is returned in the annotation view's local coordinates
    ///   (origin 0,0 at `viewportCocoaOrigin` in global Cocoa coords).
    ///
    /// Pure / side-effect free so unit tests can lock down behaviour across
    /// monitor arrangements (primary-only, second-display-to-the-right,
    /// second-display-above, etc.).
    static func annotationScreenshotRect(
        imageSize: NSSize,
        targetScreenCocoaFrame: NSRect,
        viewportCocoaOrigin: CGPoint,
        reservedTop: CGFloat,
        horizontalPadding: CGFloat = 0
    ) -> NSRect {
        let localScreen = NSRect(
            x: targetScreenCocoaFrame.origin.x - viewportCocoaOrigin.x,
            y: targetScreenCocoaFrame.origin.y - viewportCocoaOrigin.y,
            width: targetScreenCocoaFrame.width,
            height: targetScreenCocoaFrame.height
        )
        let maxDisplayWidth = max(0, localScreen.width - horizontalPadding * 2)
        let maxDisplayHeight = max(0, localScreen.height - reservedTop - horizontalPadding)

        var displaySize = imageSize
        if imageSize.width > 0, imageSize.height > 0,
           (imageSize.width > maxDisplayWidth || imageSize.height > maxDisplayHeight) {
            let scale = min(maxDisplayWidth / imageSize.width, maxDisplayHeight / imageSize.height)
            displaySize = NSSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
        }

        let x = localScreen.origin.x + (localScreen.width - displaySize.width) / 2
        // Vertically center the image in the band between the bottom padding
        // and the reserved-top band (Cocoa Y increases upward, so we offset
        // from the bottom edge of the monitor).
        let availableH = max(0, localScreen.height - reservedTop - horizontalPadding)
        let y = localScreen.origin.y + horizontalPadding + max(0, (availableH - displaySize.height) / 2)

        return NSRect(x: x, y: y, width: displaySize.width, height: displaySize.height)
    }
    
    /// Get the screen where the mouse is currently located
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screenContaining(mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
    }
    
    /// Create a borderless window that spans all screens
    /// - Parameters:
    ///   - level: Window level (e.g., .screenSaver, .floating)
    ///   - collectionBehavior: Collection behavior (default includes .canJoinAllSpaces)
    /// - Returns: Configured MultiMonitorWindow (won't be constrained to single screen)
    static func createFullScreenWindow(
        level: NSWindow.Level = .screenSaver,
        collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary]
    ) -> NSWindow {
        let screenFrame = combinedScreenFrame()
        
        // Use MultiMonitorWindow to prevent macOS from constraining to single screen
        let window = MultiMonitorWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.level = level
        window.collectionBehavior = collectionBehavior
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        
        // Explicitly set the frame to ensure it covers all screens
        window.setFrame(screenFrame, display: true)
        
        return window
    }
    
}
