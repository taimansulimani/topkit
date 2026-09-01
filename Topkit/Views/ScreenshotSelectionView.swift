import AppKit

/// Shared state for cross-monitor region selection. All per-screen selection views
/// reference the same instance so a drag starting on one screen extends onto another.
class SharedSelectionState {
    var globalStartPoint: NSPoint?
    var globalCurrentRect: NSRect?
    var isSelecting = false
    var allViews: [ScreenshotSelectionView] = []

    func redrawAllViews() {
        for view in allViews {
            view.needsDisplay = true
        }
        for view in allViews {
            view.displayIfNeeded()
        }
    }
}

class ScreenshotSelectionView: NSView {
    /// Full-screen snapshot for this display; region pick is drawn on top (frozen-frame picker).
    var frozenBackdrop: NSImage?

    /// Shared cross-monitor selection state; set by ScreenshotManager before display.
    var sharedState: SharedSelectionState?

    private var windowCapturePending = false
    private var windowCaptureWindowID: CGWindowID?
    private let windowCaptureDragThreshold: CGFloat = 4
    private var highlightedWindowID: CGWindowID?
    private var windowHighlightTimer: Timer?
    private var dragOriginLocal: NSPoint?

    var onSelectionComplete: ((NSRect) -> Void)?
    var onWindowSelected: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?

    var screenOffset: CGPoint = .zero

    private var keyMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
    }
    
    override var isOpaque: Bool { false }

    deinit {
        windowHighlightTimer?.invalidate()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .cursorUpdate],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            NSCursor.crosshair.set()

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {
                    self?.onCancel?()
                    return nil
                }
                return event
            }
        } else {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            NSCursor.arrow.set()
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    private func localToGlobal(_ local: NSPoint) -> NSPoint {
        NSPoint(x: local.x + screenOffset.x, y: local.y + screenOffset.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard let shared = sharedState else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        let globalPoint = NSEvent.mouseLocation
        dragOriginLocal = localPoint

        if let windowID = highlightedWindowID {
            windowCapturePending = true
            windowCaptureWindowID = windowID
            shared.isSelecting = false
            shared.globalStartPoint = globalPoint
            shared.globalCurrentRect = nil
            shared.redrawAllViews()
            return
        }

        shared.isSelecting = true
        shared.globalStartPoint = globalPoint
        shared.globalCurrentRect = nil
        windowCapturePending = false
        windowCaptureWindowID = nil
        shared.redrawAllViews()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let shared = sharedState else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        let globalPoint = NSEvent.mouseLocation

        if windowCapturePending, let dragStart = dragOriginLocal {
            let dx = localPoint.x - dragStart.x
            let dy = localPoint.y - dragStart.y
            if dx * dx + dy * dy > windowCaptureDragThreshold * windowCaptureDragThreshold {
                windowCapturePending = false
                windowCaptureWindowID = nil
                shared.isSelecting = true
                guard let start = shared.globalStartPoint else { return }
                shared.globalCurrentRect = NSRect(
                    x: min(start.x, globalPoint.x),
                    y: min(start.y, globalPoint.y),
                    width: abs(globalPoint.x - start.x),
                    height: abs(globalPoint.y - start.y)
                )
                shared.redrawAllViews()
                return
            }
            return
        }

        guard shared.isSelecting, let start = shared.globalStartPoint else { return }

        shared.globalCurrentRect = NSRect(
            x: min(start.x, globalPoint.x),
            y: min(start.y, globalPoint.y),
            width: abs(globalPoint.x - start.x),
            height: abs(globalPoint.y - start.y)
        )
        shared.redrawAllViews()
    }

    override func mouseUp(with event: NSEvent) {
        guard let shared = sharedState else { return }

        if windowCapturePending, let windowID = windowCaptureWindowID {
            windowCapturePending = false
            windowCaptureWindowID = nil
            onWindowSelected?(windowID)
            shared.redrawAllViews()
            return
        }

        guard shared.isSelecting, shared.globalStartPoint != nil, let rect = shared.globalCurrentRect else {
            shared.isSelecting = false
            windowCapturePending = false
            return
        }

        shared.isSelecting = false

        if rect.width > 10 && rect.height > 10 {
            onSelectionComplete?(rect)
        } else {
            shared.globalCurrentRect = nil
            shared.redrawAllViews()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        let point = convert(event.locationInWindow, from: nil)
        if let win = self.window {
            let screenPoint = win.convertPoint(toScreen: point)
            findWindow(at: screenPoint)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
    }

    private func findWindow(at screenPoint: NSPoint) {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let screenHeight = MultiMonitorHelper.primaryScreenHeight
        // Skip every window Topkit itself owns (the region picker, plus full-screen
        // guide/halo/magnifier/measure overlays). These sit at high window levels, so
        // without this filter the topmost-layer test below would keep latching onto our
        // own guide overlay (a viewport-sized window) instead of the real app underneath.
        let ourPID = Int(ProcessInfo.processInfo.processIdentifier)

        var foundWindowID: CGWindowID?
        var highestLayer: Int = Int.min

        for windowInfo in windowList ?? [] {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int else {
                continue
            }

            if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int, ownerPID == ourPID {
                continue
            }

            if let ourWindow = self.window, CGWindowID(ourWindow.windowNumber) == windowID {
                continue
            }

            if width < 50 || height < 50 {
                continue
            }

            let windowRect = NSRect(x: x, y: screenHeight - y - height, width: width, height: height)
            if windowRect.contains(screenPoint) && layer > highestLayer {
                highestLayer = layer
                foundWindowID = windowID
            }
        }

        if foundWindowID != highlightedWindowID {
            highlightedWindowID = foundWindowID
            setNeedsDisplay(bounds)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let backdrop = frozenBackdrop {
            let src = NSRect(origin: .zero, size: backdrop.size)
            backdrop.draw(in: bounds, from: src, operation: .sourceOver, fraction: 1.0)
        }

        if let windowID = highlightedWindowID, let windowInfo = getWindowInfo(windowID: windowID) {
            drawWindowHighlight(windowInfo: windowInfo, in: context)
        }

        if let globalRect = sharedState?.globalCurrentRect {
            let localRect = NSRect(
                x: globalRect.origin.x - screenOffset.x,
                y: globalRect.origin.y - screenOffset.y,
                width: globalRect.width,
                height: globalRect.height
            )
            guard bounds.intersects(localRect) else { return }
            drawSelectionRect(localRect, in: context)
        }
    }

    private func drawSelectionRect(_ rect: NSRect, in context: CGContext) {
        let borderWidth: CGFloat = 2
        let insetRect = rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(borderWidth)
        context.stroke(insetRect)
        let handleSize: CGFloat = 8
        let inset: CGFloat = borderWidth
        let handles: [NSPoint] = [
            NSPoint(x: rect.minX + inset, y: rect.minY + inset),
            NSPoint(x: rect.maxX - inset, y: rect.minY + inset),
            NSPoint(x: rect.maxX - inset, y: rect.maxY - inset),
            NSPoint(x: rect.minX + inset, y: rect.maxY - inset)
        ]
        context.setFillColor(NSColor.systemBlue.cgColor)
        for handle in handles {
            let handleRect = NSRect(
                x: handle.x - handleSize / 2,
                y: handle.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            if bounds.intersects(handleRect) {
                context.fillEllipse(in: handleRect)
            }
        }
    }

    private func getWindowInfo(windowID: CGWindowID) -> [String: Any]? {
        let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        return windowList?.first
    }

    private func drawWindowHighlight(windowInfo: [String: Any], in context: CGContext) {
        guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return
        }
        let screenHeight = MultiMonitorHelper.primaryScreenHeight
        let windowRect = NSRect(
            x: x - screenOffset.x,
            y: (screenHeight - y - height) - screenOffset.y,
            width: width,
            height: height
        )
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(3)
        context.stroke(windowRect.insetBy(dx: -1, dy: -1))
    }
}
