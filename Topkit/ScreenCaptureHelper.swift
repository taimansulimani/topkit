import AppKit
import ScreenCaptureKit

/// One-shot ScreenCaptureKit captures — the modern replacement for the deprecated
/// `CGWindowListCreateImage`. All completions are delivered on the main thread.
enum ScreenCapture {

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Frozen full-display grab of every screen at native pixel density. Captures
    /// everything on screen (including Topkit's guide overlays, so guides stay in
    /// screenshots — WYSIWYG). Returns nil if any display fails to capture.
    /// - Parameter excludingWindowIDs: windows to omit from the capture. The Annotate
    ///   overlay passes its own window IDs so a redaction does not bake in the marks
    ///   drawn on top of the pixels it is meant to hide. The screenshot flow
    ///   deliberately passes nothing, so guides and annotations stay WYSIWYG.
    static func captureAllDisplays(
        _ screens: [NSScreen],
        excludingWindowIDs: Set<CGWindowID> = [],
        completion: @escaping ([(screen: NSScreen, image: NSImage)]?) -> Void
    ) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content, error == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var images = [Int: NSImage]()
            for (index, screen) in screens.enumerated() {
                guard let id = displayID(for: screen),
                      let display = content.displays.first(where: { $0.displayID == id }) else {
                    continue
                }
                let excluded = excludingWindowIDs.isEmpty
                    ? []
                    : content.windows.filter { excludingWindowIDs.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let config = SCStreamConfiguration()
                let scale = screen.backingScaleFactor
                config.width = Int(screen.frame.width * scale)
                config.height = Int(screen.frame.height * scale)
                config.showsCursor = false
                config.captureResolution = .best
                group.enter()
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { cgImage, _ in
                    if let cgImage {
                        lock.lock()
                        images[index] = NSImage(cgImage: cgImage, size: screen.frame.size)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard images.count == screens.count else {
                    completion(nil)
                    return
                }
                completion(screens.enumerated().map { ($0.element, images[$0.offset]!) })
            }
        }
    }

    /// Crisp single-window grab (content only, no shadow) at native pixel density.
    static func captureWindowImage(windowID: CGWindowID, completion: @escaping (CGImage?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { cgImage, _ in
                DispatchQueue.main.async { completion(cgImage) }
            }
        }
    }
}
