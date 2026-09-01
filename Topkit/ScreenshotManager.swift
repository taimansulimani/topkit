import Foundation
import AppKit
import CoreGraphics
import Combine

private enum ScreenshotPreferencesKeys {
    static let saveScreenshotsToFolder = "saveScreenshotsToFolder"
    static let screenshotSaveFolder = "screenshotSaveFolder"
    static let screenshotSaveFolderBookmark = "screenshotSaveFolderBookmark"
}

/// Borderless windows don't accept key input by default; this allows the annotation window to receive keyboard events (e.g. for text tool).
private final class AnnotationKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    // Allow window to span multiple monitors without being constrained
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// Secondary monitor during region annotate: full frozen grab + dim — never show live desktop through the overlay.
private final class FrozenDimScreenOverlayView: NSView {
    enum PointerPhase {
        case down
        case dragged
        case up
    }

    var frozenImage: NSImage? {
        didSet { needsDisplay = true }
    }
    /// Optional hole rect in local (view) coordinates. When set, the frozen
    /// screenshot shows through the hole and only the area outside is dimmed.
    var holeRect: NSRect? {
        didSet { needsDisplay = true }
    }
    var onPointerEvent: ((PointerPhase, NSPoint, Int) -> Void)?
    /// Draws the active annotation view's layers translated into this overlay's
    /// coordinates, so annotations on a cross-monitor hole show on this screen too.
    var annotationsRenderer: ((CGContext) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onPointerEvent?(.down, convert(event.locationInWindow, from: nil), event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) {
        onPointerEvent?(.dragged, convert(event.locationInWindow, from: nil), event.clickCount)
    }
    override func mouseUp(with event: NSEvent) {
        onPointerEvent?(.up, convert(event.locationInWindow, from: nil), event.clickCount)
    }

    private func drawResizeHandles(for rect: NSRect, within clipBounds: NSRect) {
        let handleSize: CGFloat = 6
        let halfHandle = handleSize / 2
        let positions: [NSPoint] = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
            NSPoint(x: rect.midX, y: rect.minY), NSPoint(x: rect.midX, y: rect.maxY),
            NSPoint(x: rect.minX, y: rect.midY), NSPoint(x: rect.maxX, y: rect.midY),
        ]
        for pos in positions {
            let handleRect = NSRect(
                x: pos.x - halfHandle,
                y: pos.y - halfHandle,
                width: handleSize,
                height: handleSize
            )
            guard handleRect.intersects(clipBounds) else { continue }
            NSColor.white.setFill()
            handleRect.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let border = NSBezierPath(rect: handleRect)
            border.lineWidth = 1
            border.stroke()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let img = frozenImage {
            let src = NSRect(origin: .zero, size: img.size)
            img.draw(in: bounds, from: src, operation: .sourceOver, fraction: 1.0)
        } else {
            NSColor.black.setFill()
            bounds.fill()
            return
        }
        let dim = NSColor.black.withAlphaComponent(kScreenshotDimOverlayAlpha)
        if let hole = holeRect, !hole.isEmpty {
            let clipped = bounds.intersection(hole)
            if !clipped.isEmpty {
                dim.setFill()
                let w = bounds.width, h = bounds.height
                if clipped.minY > 0 { NSRect(x: 0, y: 0, width: w, height: clipped.minY).fill() }
                if clipped.maxY < h { NSRect(x: 0, y: clipped.maxY, width: w, height: h - clipped.maxY).fill() }
                if clipped.minX > 0 { NSRect(x: 0, y: clipped.minY, width: clipped.minX, height: clipped.height).fill() }
                if clipped.maxX < w { NSRect(x: clipped.maxX, y: clipped.minY, width: w - clipped.maxX, height: clipped.height).fill() }
                let border = NSBezierPath(rect: clipped)
                border.lineWidth = 2
                NSColor.white.withAlphaComponent(0.8).setStroke()
                border.stroke()
                // Keep resize affordances visible when the selection spans
                // multiple monitors: each frozen overlay draws the handles that
                // intersect its own bounds.
                drawResizeHandles(for: hole, within: bounds)
            } else {
                dim.setFill()
                bounds.fill()
            }
        } else {
            dim.setFill()
            bounds.fill()
        }
        if let renderer = annotationsRenderer, let ctx = NSGraphicsContext.current?.cgContext {
            renderer(ctx)
        }
    }
}

/// Region picker must be key so the **system** crosshair is the only pointer (drawn + failed hide always left a double cursor while inactive).
private final class ScreenshotRegionPickWindow: MultiMonitorWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class ScreenshotManager: ObservableObject {
    static let shared = ScreenshotManager()
    
    @Published var isAnnotating = false
    
    private var annotationWindow: NSWindow?
    private var annotationView: ScreenshotAnnotationView?
    private var dimOverlayWindows: [NSWindow] = []
    private var dimOverlayViews: [FrozenDimScreenOverlayView] = []
    /// Origin of the active annotation screen in global coords; used to convert
    /// view-local selection rect changes to global, then back to each dim overlay's local coords.
    private var annotationScreenOrigin: CGPoint = .zero
    /// Screen frames for each dim overlay (parallel to dimOverlayViews).
    private var dimOverlayScreenFrames: [NSRect] = []
    /// Frozen per-screen snapshots kept for save + screen swap.
    private var currentFrozenSnaps: [(image: NSImage, frame: NSRect)] = []
    
    // Callback for status bar icon update
    var onScreenshotStateChanged: ((Bool) -> Void)?
    
    private init() {}
    
    // Multi-monitor: one selection window per screen
    private struct SelectionScreenOverlay {
        let screen: NSScreen
        let window: NSWindow
        let view: ScreenshotSelectionView
    }
    private var selectionOverlays: [SelectionScreenOverlay] = []
    private var selectionSharedState: SharedSelectionState?
    private var selectionDragMonitor: Any?
    private var selectionActivationObserver: NSObjectProtocol?
    /// True while the frozen per-display grabs are being captured (reentrancy guard).
    private var isCapturingFrozenGrabs = false
    /// Global mouse moves while the screenshot UI is up: with Topkit inactive, `NSCursor` / `mouseMoved` often do nothing until click — this keeps the crosshair (and annotation chrome cursors) in sync.
    private var screenshotToolCursorGlobalMonitor: Any?
    /// True while a resize/drag interaction started from a non-active dim overlay.
    private var dimOverlayPointerInteractionActive = false
    /// If `addGlobalMonitor` is unavailable (e.g. denied Input Monitoring), poll cursor position at a low rate instead.
    private var screenshotToolCursorFallbackTimer: Timer?
    private var screenRecordingPermissionTimer: Timer?
    
    // Legacy single references for compatibility
    private var selectionWindow: NSWindow? { selectionOverlays.first?.window }
    private var selectionView: ScreenshotSelectionView? { selectionOverlays.first?.view }
    
    /// Arm an annotation tool in the screenshot editor, if one is on screen.
    ///
    /// The global tool hotkeys fire regardless of what is in front, and while a
    /// screenshot is being annotated they used to open the standalone Annotate overlay
    /// on top of it. Returns true when the editor took the key, so the caller knows
    /// not to fall back to `AnnotateManager`.
    @discardableResult
    func armAnnotationToolFromShortcut(_ tool: AnnotationTool) -> Bool {
        guard isAnnotating else { return false }
        if let view = annotationView, let window = annotationWindow, window.isVisible {
            view.selectToolFromShortcut(tool)
            return true
        }
        // No editor yet, so this is the region pick. Swallow it: falling through would
        // start the standalone Annotate overlay underneath the picker, where it is
        // suspended, and the tool would arm on a dead surface.
        //
        // Keyed off real windows rather than `isAnnotating` alone — if that flag ever
        // stuck true with nothing on screen, every annotate shortcut in the app would
        // go dead with no way back.
        return !selectionOverlays.isEmpty
    }

    func takeScreenshot() {
        // Always use the LIVE check (SCShareableContent), not cached preflight.
        // `CGPreflightScreenCaptureAccess()` keeps returning true after the user revokes
        // permission mid-session, which would start a broken capture (desktop-only frozen
        // grab with a working toolbar) instead of re-prompting. The live check reflects the
        // true current state, so a revoke routes to the request flow.
        PermissionManager.shared.verifyScreenRecordingPermission { [weak self] hasPermission in
            if hasPermission {
                self?.runStartSelectionOnMain()
            } else {
                PermissionManager.shared.requestScreenRecordingAndWaitForGrant { [weak self] in
                    self?.runStartSelectionOnMain()
                }
            }
        }
    }
    
    private func runStartSelectionOnMain() {
        if Thread.isMainThread {
            startSelection()
        } else {
            DispatchQueue.main.async { [weak self] in self?.startSelection() }
        }
    }
    
    private func startSelection() {
        guard !isCapturingFrozenGrabs else { return }
        PermissionManager.shared.markScreenRecordingPermissionGranted()

        for overlay in selectionOverlays {
            overlay.window.orderOut(nil)
        }
        selectionOverlays.removeAll()
        selectionSharedState = nil
        removeSelectionDragMonitor()
        removeScreenshotToolCursorGlobalMonitor()

        // Grab each display into a bitmap **before** any Topkit window is shown (same idea as
        // macOS screencapture UI / Shottr-style tools). Transient host UI (Chrome ⋮ menus, etc.)
        // is in the snapshot; the marquee is drawn on that static image, so a click to drag does
        // not depend on the live menu staying open.
        isCapturingFrozenGrabs = true
        ScreenCapture.captureAllDisplays(NSScreen.screens) { [weak self] frozenPairs in
            guard let self = self else { return }
            self.isCapturingFrozenGrabs = false
            guard let frozenPairs else {
                self.log("❌ Failed to snapshot displays for region pick — check screen recording permission")
                self.isAnnotating = false; AnnotateManager.shared.setSuspended(false)
                self.onScreenshotStateChanged?(false)
                self.showToast(message: "Could not read the screen — check Screen Recording permission for Topkit")
                return
            }
            self.presentRegionPicker(frozenPairs: frozenPairs)
        }
    }

    private func presentRegionPicker(frozenPairs: [(screen: NSScreen, image: NSImage)]) {
        (NSApp.delegate as? AppDelegate)?.orderOutPreferencesWindowForToolOverlay()
        // Annotate shares this window level, and ordering between same-level windows
        // is undefined, so it stands down rather than contending for clicks.
        AnnotateManager.shared.setSuspended(true)
        isAnnotating = true
        onScreenshotStateChanged?(true)
        let showToasts = UserDefaults.standard.bool(forKey: "showToastNotifications")
        if showToasts {
            let toastLevel = NSWindow.Level(rawValue: kScreenshotOverlayBaseLevel.rawValue + 1)
            showToast(message: "Click a window or drag a region — then annotate on the frozen capture", windowLevel: toastLevel)
        }

        let combinedScreenFrame = MultiMonitorHelper.combinedScreenFrame()
        for (screen, snapshot) in frozenPairs {
            let screenFrame = screen.frame
            let viewFrame = NSRect(origin: .zero, size: screenFrame.size)
            let window = ScreenshotRegionPickWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = kScreenshotOverlayBaseLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.animationBehavior = .none
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.setFrame(screenFrame, display: true)
            let view = ScreenshotSelectionView(frame: viewFrame)
            view.frozenBackdrop = snapshot
            view.screenOffset = screenFrame.origin
            view.onSelectionComplete = { [weak self] rect in
                DispatchQueue.main.async {
                    self?.showLiveFrozenAnnotationOverlay(globalRect: rect)
                }
            }
            view.onWindowSelected = { [weak self] windowID in
                self?.captureWindow(windowID: windowID, screenFrame: combinedScreenFrame)
            }
            view.onCancel = { [weak self] in
                self?.cancelSelection()
            }
            window.contentView = view
            selectionOverlays.append(SelectionScreenOverlay(screen: screen, window: window, view: view))
        }
        let shared = SharedSelectionState()
        shared.allViews = selectionOverlays.map(\.view)
        for overlay in selectionOverlays {
            overlay.view.sharedState = shared
        }
        selectionSharedState = shared
        installSelectionDragMonitor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for overlay in selectionOverlays {
                overlay.window.orderFrontRegardless()
            }
        }
        for overlay in selectionOverlays {
            overlay.window.invalidateCursorRects(for: overlay.view)
        }
        flushRegionPickerWindowsToScreen()
        installScreenshotToolCursorGlobalMonitor()
        // One run loop later: frozen bitmap is already composited, then we activate so only the system crosshair shows (no fake overlay + arrow).
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.selectionOverlays.isEmpty else { return }
            self.focusRegionPickerForInteraction()
            self.applyScreenshotToolCursorForCurrentMouseLocation()
        }
        // Escape is handled by each ScreenshotSelectionView's local monitor / keyDown — a
        // global keyDown monitor never fires in a sandboxed app without Input Monitoring.
        startScreenRecordingPermissionMonitor()
        selectionActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.selectionOverlays.isEmpty else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                for overlay in self.selectionOverlays where overlay.window.isVisible {
                    overlay.window.orderFrontRegardless()
                }
            }
            self.focusRegionPickerForInteraction()
            self.applyScreenshotToolCursorForCurrentMouseLocation()
        }
    }
    
    /// After initial marquee: toolbar + tools on the active screen. Every pixel of the overlay is painted from the **frozen**
    /// grabs taken at shortcut time (full-screen bitmap + dim outside the selection); nothing shows the live desktop.
    private func showLiveFrozenAnnotationOverlay(globalRect: NSRect) {
        guard !selectionOverlays.isEmpty else {
            cancelSelection()
            return
        }
        let frozenSnaps: [(image: NSImage, frame: NSRect)] = selectionOverlays.compactMap { o in
            guard let img = o.view.frozenBackdrop else { return nil }
            return (image: img, frame: o.screen.frame)
        }
        currentFrozenSnaps = frozenSnaps
        if let obs = selectionActivationObserver {
            NotificationCenter.default.removeObserver(obs)
            selectionActivationObserver = nil
        }
        for overlay in selectionOverlays {
            overlay.window.orderOut(nil)
        }
        selectionOverlays.removeAll()
        selectionSharedState = nil
        removeSelectionDragMonitor()
        for dimWindow in dimOverlayWindows { dimWindow.orderOut(nil) }
        dimOverlayWindows.removeAll()
        dimOverlayViews.removeAll()
        dimOverlayScreenFrames.removeAll()
        let rectCenter = NSPoint(x: globalRect.midX, y: globalRect.midY)
        guard let activeScreen = MultiMonitorHelper.screenContaining(rectCenter)
            ?? NSScreen.main ?? NSScreen.screens.first else {
            cancelSelection()
            return
        }
        let activeScreenFrame = activeScreen.frame
        let localRect = NSRect(
            x: globalRect.origin.x - activeScreenFrame.origin.x,
            y: globalRect.origin.y - activeScreenFrame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        let capturedScreenOrigin = activeScreenFrame.origin
        annotationScreenOrigin = capturedScreenOrigin
        rebuildDimOverlays(activeScreen: activeScreen, globalRect: globalRect)
        let combinedFrame = MultiMonitorHelper.combinedScreenFrame()
        let allowedBounds = NSRect(
            x: combinedFrame.origin.x - activeScreenFrame.origin.x,
            y: combinedFrame.origin.y - activeScreenFrame.origin.y,
            width: combinedFrame.width,
            height: combinedFrame.height
        )
        let viewFrame = NSRect(origin: .zero, size: activeScreenFrame.size)
        let window = LiveAnnotationOverlayWindow(
            contentRect: activeScreenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.level = kScreenshotOverlayBaseLevel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.setFrame(activeScreenFrame, display: true)
        let view = ScreenshotAnnotationView(frame: viewFrame, screenshot: nil, screenshotRect: localRect)
        view.allowedSelectionBounds = allowedBounds
        view.onSelectionRectChanged = { [weak self] newLocalRect in
            self?.updateDimOverlayHoles(newLocalRect)
        }
        view.onSelectionDragEnded = { [weak self] newLocalRect in
            self?.swapAnnotationScreenIfNeeded(newLocalRect)
        }
        view.onSaveRequested = { [weak self] finalRect, annotations in
            guard let self = self else { return }
            self.saveFromFrozenLiveOverlay(
                rect: finalRect,
                annotations: annotations,
                screenOrigin: self.annotationScreenOrigin,
                frozenSnaps: self.currentFrozenSnaps
            )
        }
        view.onClose = { [weak self] in
            self?.closeAnnotationView()
        }
        view.configureLiveHoleFrozenSources(screenOrigin: activeScreenFrame.origin, snapshots: frozenSnaps.map { (frame: $0.frame, image: $0.image) })
        view.onContentNeedsRedraw = { [weak self] in
            guard let self = self else { return }
            for dimView in self.dimOverlayViews { dimView.needsDisplay = true }
        }
        view.onRequestWindowMove = { [weak self] globalPoint in
            guard let self = self,
                  let screen = MultiMonitorHelper.screenContaining(globalPoint) else { return }
            if abs(screen.frame.origin.x - self.annotationScreenOrigin.x) < 1,
               abs(screen.frame.origin.y - self.annotationScreenOrigin.y) < 1 {
                return
            }
            let localRect = self.annotationView?.currentSelectionRect ?? .zero
            let currentGlobalRect = NSRect(
                x: localRect.origin.x + self.annotationScreenOrigin.x,
                y: localRect.origin.y + self.annotationScreenOrigin.y,
                width: localRect.width,
                height: localRect.height
            )
            self.relocateAnnotationWindow(to: screen, globalRect: currentGlobalRect)
        }
        window.contentView = view
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            window.orderFrontRegardless()
        }
        annotationWindow = window
        annotationView = view
        focusLiveAnnotationOverlayForInteraction(window: window, view: view)
        applyScreenshotToolCursorForCurrentMouseLocation()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.annotationWindow === window, self.annotationView === view else { return }
            self.focusLiveAnnotationOverlayForInteraction(window: window, view: view)
            NSCursor.crosshair.set()
        }
    }
    
    private func saveFromFrozenLiveOverlay(rect: NSRect, annotations: [Annotation], screenOrigin: CGPoint, frozenSnaps: [(image: NSImage, frame: NSRect)]) {
        dimOverlayPointerInteractionActive = false
        annotationWindow?.orderOut(nil)
        annotationWindow = nil
        annotationView = nil
        for dimWindow in dimOverlayWindows { dimWindow.orderOut(nil) }
        dimOverlayWindows.removeAll()
        dimOverlayViews.removeAll()
        dimOverlayScreenFrames.removeAll()
        let globalRect = NSRect(
            x: rect.origin.x + screenOrigin.x,
            y: rect.origin.y + screenOrigin.y,
            width: rect.width,
            height: rect.height
        )
        guard let base = MultiMonitorHelper.compositeFrozenGlobalRect(globalRect, snapshots: frozenSnaps) else {
            log("❌ Failed to composite save region from frozen grabs")
            isAnnotating = false; AnnotateManager.shared.setSuspended(false)
            onScreenshotStateChanged?(false)
            stopScreenRecordingPermissionMonitor()
            removeScreenshotToolCursorGlobalMonitor()
            NSCursor.arrow.set()
            showToast(message: "Could not build screenshot from frozen capture")
            return
        }
        let composited = ScreenshotAnnotationView.renderAnnotations(on: base, annotations: annotations)
        saveAnnotatedScreenshot(composited)
    }
    
    private func captureWindow(windowID: CGWindowID, screenFrame: CGRect) {
        guard !selectionOverlays.isEmpty else {
            cancelSelection()
            return
        }
        // Hide all selection windows so the blue border isn't visible
        for overlay in selectionOverlays {
            overlay.window.orderOut(nil)
        }

        if let obs = selectionActivationObserver {
            NotificationCenter.default.removeObserver(obs)
            selectionActivationObserver = nil
        }

        // Figure out which monitor the captured window lives on. Used both to
        // scale the bitmap and to land the annotation UI on that same display
        // (multi-monitor users expect the picker UI on the display they clicked,
        // not in the combined-desktop middle).
        let hostScreen = screenForCapturedWindow(windowID: windowID)

        selectionOverlays.removeAll()
        selectionSharedState = nil
        removeSelectionDragMonitor()

        // Crisp single-window grab via ScreenCaptureKit (content only,
        // native pixel density). Sized by the backing factor of the display the window
        // actually lives on — NOT `NSScreen.main` (the key-window screen), which is wrong
        // on mixed-DPI setups and would size the screenshot at 2× or ½.
        ScreenCapture.captureWindowImage(windowID: windowID) { [weak self] cgImage in
            guard let self = self else { return }
            guard let cgImage else {
                self.log("❌ Failed to capture window")
                self.cancelSelection()
                return
            }
            let scale = hostScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
            )
            self.showAnnotationView(with: image, targetScreen: hostScreen)
        }
    }

    /// Look up the captured window's bounds via `CGWindowListCopyWindowInfo`
    /// and return the `NSScreen` whose frame contains its center, in global
    /// Cocoa coordinates. Returns `nil` if the window info can't be resolved or
    /// no screen contains the center.
    private func screenForCapturedWindow(windowID: CGWindowID) -> NSScreen? {
        guard let cocoa = cocoaBoundsForWindow(windowID: windowID) else { return nil }
        let center = NSPoint(x: cocoa.midX, y: cocoa.midY)
        return MultiMonitorHelper.screenContaining(center)
    }

    /// The captured window's bounds in global Cocoa coordinates (bottom-left origin),
    /// or `nil` if the window info can't be resolved.
    private func cocoaBoundsForWindow(windowID: CGWindowID) -> NSRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let qx = bounds["X"] as? CGFloat,
              let qy = bounds["Y"] as? CGFloat,
              let qw = bounds["Width"] as? CGFloat,
              let qh = bounds["Height"] as? CGFloat else {
            return nil
        }
        // Quartz (top-left relative to primary) → Cocoa (bottom-left).
        let primaryH = MultiMonitorHelper.primaryScreenHeight
        return NSRect(x: qx, y: primaryH - qy - qh, width: qw, height: qh)
    }
    
    private func cancelSelection() {
        let hadSelectionUI = !selectionOverlays.isEmpty
        
        if let obs = selectionActivationObserver {
            NotificationCenter.default.removeObserver(obs)
            selectionActivationObserver = nil
        }
        for overlay in selectionOverlays {
            overlay.window.orderOut(nil)
        }
        selectionOverlays.removeAll()
        selectionSharedState = nil
        removeSelectionDragMonitor()
        
        isAnnotating = false; AnnotateManager.shared.setSuspended(false)
        onScreenshotStateChanged?(false)
        stopScreenRecordingPermissionMonitor()
        removeScreenshotToolCursorGlobalMonitor()
        NSCursor.arrow.set()
        
        if hadSelectionUI {
            if UserDefaults.standard.bool(forKey: "playNotificationSounds") {
                NSSound.beep()
            }
            showToast(message: String(localized: "Screenshot canceled"))
        }
    }
    
    private func installSelectionDragMonitor() {
        removeSelectionDragMonitor()
        selectionDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleSelectionDragEvent(event)
            return event
        }
    }
    
    private func removeSelectionDragMonitor() {
        if let monitor = selectionDragMonitor {
            NSEvent.removeMonitor(monitor)
            selectionDragMonitor = nil
        }
    }
    
    private func handleSelectionDragEvent(_ event: NSEvent) {
        guard let shared = selectionSharedState, shared.isSelecting,
              let start = shared.globalStartPoint else { return }
        let globalPoint = NSEvent.mouseLocation
        
        if event.type == .leftMouseUp {
            let rect = shared.globalCurrentRect
            shared.isSelecting = false
            if let rect = rect, rect.width > 10, rect.height > 10 {
                DispatchQueue.main.async { [weak self] in
                    self?.showLiveFrozenAnnotationOverlay(globalRect: rect)
                }
            } else {
                shared.globalCurrentRect = nil
                shared.redrawAllViews()
            }
            return
        }
        
        shared.globalCurrentRect = NSRect(
            x: min(start.x, globalPoint.x),
            y: min(start.y, globalPoint.y),
            width: abs(globalPoint.x - start.x),
            height: abs(globalPoint.y - start.y)
        )
        shared.redrawAllViews()
    }
    
    /// When the annotation selection rect changes (resize/drag), update every dim overlay's hole.
    private func updateDimOverlayHoles(_ newLocalRect: NSRect) {
        let globalRect = NSRect(
            x: newLocalRect.origin.x + annotationScreenOrigin.x,
            y: newLocalRect.origin.y + annotationScreenOrigin.y,
            width: newLocalRect.width,
            height: newLocalRect.height
        )
        for (i, dimView) in dimOverlayViews.enumerated() {
            guard i < dimOverlayScreenFrames.count else { continue }
            let screenFrame = dimOverlayScreenFrames[i]
            let screenLocalHole = NSRect(
                x: globalRect.origin.x - screenFrame.origin.x,
                y: globalRect.origin.y - screenFrame.origin.y,
                width: globalRect.width,
                height: globalRect.height
            )
            dimView.holeRect = screenLocalHole
        }
    }
    
    /// After a selection drag/resize ends, check whether the selection center moved to a
    /// different screen. If so, relocate the annotation window to that screen.
    private func swapAnnotationScreenIfNeeded(_ localRect: NSRect) {
        let globalRect = NSRect(
            x: localRect.origin.x + annotationScreenOrigin.x,
            y: localRect.origin.y + annotationScreenOrigin.y,
            width: localRect.width,
            height: localRect.height
        )
        let center = NSPoint(x: globalRect.midX, y: globalRect.midY)
        guard let newScreen = MultiMonitorHelper.screenContaining(center) else { return }
        if abs(newScreen.frame.origin.x - annotationScreenOrigin.x) < 1 &&
           abs(newScreen.frame.origin.y - annotationScreenOrigin.y) < 1 {
            return
        }
        relocateAnnotationWindow(to: newScreen, globalRect: globalRect)
    }

    /// One frozen dim overlay per non-active screen, with pointer proxying into
    /// the annotation view and mirrored annotation rendering.
    private func rebuildDimOverlays(activeScreen: NSScreen, globalRect: NSRect) {
        for dimWindow in dimOverlayWindows { dimWindow.orderOut(nil) }
        dimOverlayWindows.removeAll()
        dimOverlayViews.removeAll()
        dimOverlayScreenFrames.removeAll()

        for screen in NSScreen.screens where screen != activeScreen {
            let snap = currentFrozenSnaps.first {
                $0.frame.origin == screen.frame.origin
                    && abs($0.frame.width - screen.frame.width) < 0.5
                    && abs($0.frame.height - screen.frame.height) < 0.5
            }
            let dimWindow = MultiMonitorWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            dimWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]
            dimWindow.level = kScreenshotOverlayBaseLevel
            dimWindow.isOpaque = false
            dimWindow.backgroundColor = .clear
            dimWindow.hasShadow = false
            dimWindow.animationBehavior = .none
            dimWindow.ignoresMouseEvents = false
            dimWindow.setFrame(screen.frame, display: true)
            let dimView = FrozenDimScreenOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            dimView.frozenImage = snap?.image
            let screenLocalHole = NSRect(
                x: globalRect.origin.x - screen.frame.origin.x,
                y: globalRect.origin.y - screen.frame.origin.y,
                width: globalRect.width,
                height: globalRect.height
            )
            dimView.holeRect = screenLocalHole
            dimView.onPointerEvent = { [weak self] phase, localPoint, clickCount in
                self?.handleDimOverlayPointerEvent(
                    phase: phase,
                    localPoint: localPoint,
                    clickCount: clickCount,
                    overlayScreenFrame: screen.frame
                )
            }
            dimView.annotationsRenderer = { [weak self] ctx in
                self?.annotationView?.drawAnnotationsForOverlay(in: ctx, overlayScreenOrigin: screen.frame.origin)
            }
            dimWindow.contentView = dimView
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                dimWindow.orderFrontRegardless()
            }
            dimOverlayWindows.append(dimWindow)
            dimOverlayViews.append(dimView)
            dimOverlayScreenFrames.append(screen.frame)
        }
    }

    /// Move the annotation window (toolbar and all) to `newScreen`, keeping the
    /// selection hole `globalRect` fixed in global coordinates.
    private func relocateAnnotationWindow(to newScreen: NSScreen, globalRect: NSRect) {
        guard let view = annotationView, let window = annotationWindow as? LiveAnnotationOverlayWindow else { return }
        let newFrame = newScreen.frame
        let newLocalRect = NSRect(
            x: globalRect.origin.x - newFrame.origin.x,
            y: globalRect.origin.y - newFrame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        let combinedFrame = MultiMonitorHelper.combinedScreenFrame()
        let newAllowedBounds = NSRect(
            x: combinedFrame.origin.x - newFrame.origin.x,
            y: combinedFrame.origin.y - newFrame.origin.y,
            width: combinedFrame.width,
            height: combinedFrame.height
        )

        // Rebuild dim overlays for every screen except the new active one.
        // IMPORTANT: do NOT detach `view` from its window. Re-attaching the content
        // view triggers `viewDidMoveToWindow` → `setupToolbar()` again, which would
        // leave an orphaned toolbar subview behind (visible as a "printed" ghost
        // toolbar on the new screen after the swap).
        rebuildDimOverlays(activeScreen: newScreen, globalRect: globalRect)

        annotationScreenOrigin = newFrame.origin
        // Move the annotation window onto the new screen. AppKit updates the
        // contentView frame automatically; the view keeps its toolbar subview,
        // so there is no re-setup pass and no orphan toolbar.
        window.setFrame(newFrame, display: false)
        view.relocateForScreenSwap(newScreenshotRect: newLocalRect, newScreenOrigin: newFrame.origin, newAllowedBounds: newAllowedBounds)
        window.displayIfNeeded()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            window.orderFrontRegardless()
        }
        focusLiveAnnotationOverlayForInteraction(window: window, view: view)
        applyScreenshotToolCursorForCurrentMouseLocation()
    }
    
    private func installScreenshotToolCursorGlobalMonitor() {
        removeScreenshotToolCursorGlobalMonitor()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        screenshotToolCursorGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.applyScreenshotToolCursorForCurrentMouseLocation()
            }
        }
        if screenshotToolCursorGlobalMonitor == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 45.0, repeats: true) { [weak self] _ in
                self?.applyScreenshotToolCursorForCurrentMouseLocation()
            }
            RunLoop.main.add(t, forMode: .common)
            screenshotToolCursorFallbackTimer = t
        }
    }
    
    private func removeScreenshotToolCursorGlobalMonitor() {
        dimOverlayPointerInteractionActive = false
        screenshotToolCursorFallbackTimer?.invalidate()
        screenshotToolCursorFallbackTimer = nil
        if let monitor = screenshotToolCursorGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            screenshotToolCursorGlobalMonitor = nil
        }
    }

    private func handleDimOverlayPointerEvent(
        phase: FrozenDimScreenOverlayView.PointerPhase,
        localPoint: NSPoint,
        clickCount: Int,
        overlayScreenFrame: NSRect
    ) {
        guard let view = annotationView,
              let window = annotationWindow,
              window.isVisible else { return }

        let globalPoint = NSPoint(
            x: overlayScreenFrame.origin.x + localPoint.x,
            y: overlayScreenFrame.origin.y + localPoint.y
        )
        let annotationLocalPoint = NSPoint(
            x: globalPoint.x - annotationScreenOrigin.x,
            y: globalPoint.y - annotationScreenOrigin.y
        )

        // Forward the complete interaction (drawing tools, layer select/drag/
        // resize, selection move) so annotating works on every monitor the
        // hole touches, not just the one hosting the annotation window.
        switch phase {
        case .down:
            // Only proxy interactions that start outside the active annotation window.
            guard !window.frame.contains(globalPoint) else { return }
            dimOverlayPointerInteractionActive = true
            view.handlePointerDown(at: annotationLocalPoint, clickCount: clickCount)
            applyScreenshotToolCursorForCurrentMouseLocation()
        case .dragged:
            guard dimOverlayPointerInteractionActive else { return }
            view.handlePointerDragged(at: annotationLocalPoint, modifierFlags: NSEvent.modifierFlags)
            applyScreenshotToolCursorForCurrentMouseLocation()
        case .up:
            guard dimOverlayPointerInteractionActive else { return }
            view.handlePointerUp()
            dimOverlayPointerInteractionActive = false
            applyScreenshotToolCursorForCurrentMouseLocation()
        }
    }
    
    private func flushRegionPickerWindowsToScreen() {
        for overlay in selectionOverlays {
            overlay.view.needsDisplay = true
            overlay.view.layoutSubtreeIfNeeded()
            overlay.window.contentView?.layoutSubtreeIfNeeded()
            overlay.window.displayIfNeeded()
            overlay.view.display()
        }
    }
    
    private func selectionOverlayPreferredForKey() -> SelectionScreenOverlay? {
        let p = NSEvent.mouseLocation
        if let o = selectionOverlays.first(where: { $0.window.frame.contains(p) }) {
            return o
        }
        return selectionOverlays.first(where: { $0.screen == NSScreen.main }) ?? selectionOverlays.first
    }
    
    private func focusRegionPickerForInteraction() {
        guard let target = selectionOverlayPreferredForKey() else {
            NSCursor.crosshair.set()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            target.window.makeKeyAndOrderFront(nil)
        }
        _ = target.window.makeFirstResponder(target.view)
        target.window.invalidateCursorRects(for: target.view)
        NSCursor.crosshair.set()
    }
    
    private func focusLiveAnnotationOverlayForInteraction(window: NSWindow, view: NSView) {
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            window.makeKeyAndOrderFront(nil)
        }
        _ = window.makeFirstResponder(view)
        window.invalidateCursorRects(for: view)
        NSCursor.crosshair.set()
    }
    
    private func applyScreenshotToolCursorForCurrentMouseLocation() {
        let p = NSEvent.mouseLocation
        if !selectionOverlays.isEmpty {
            guard selectionOverlays.contains(where: { $0.window.frame.contains(p) }) else { return }
            NSCursor.crosshair.set()
            return
        }
        if let win = annotationWindow, win.isVisible, let view = annotationView {
            if win.frame.contains(p) {
                view.synchronizeCursorFromScreenPoint(p)
                return
            }
            // Over a dim overlay on another monitor: drive the same cursor logic
            // with the annotation-window-local point (works outside bounds).
            if dimOverlayWindows.contains(where: { $0.isVisible && $0.frame.contains(p) }) {
                view.updateCursorForLocalPoint(NSPoint(
                    x: p.x - annotationScreenOrigin.x,
                    y: p.y - annotationScreenOrigin.y
                ))
            }
        }
    }
    
    /// Abort any in-progress region pick or annotation because screen recording was revoked.
    func abortForPermissionLoss() {
        if annotationWindow != nil {
            closeAnnotationView()
        } else if !selectionOverlays.isEmpty {
            cancelSelection()
        }
    }

    /// Show a toast regardless of the user's toast preference. Used for permission warnings
    /// that the user must see even if cosmetic toasts are switched off.
    func presentForcedToast(_ message: String) {
        showToast(message: message, force: true)
    }

    private func showToast(message: String, windowLevel: NSWindow.Level? = nil, force: Bool = false) {
        ToastPresenter.shared.show(message: message, windowLevel: windowLevel, force: force)
    }
    
    private func showAnnotationView(with image: NSImage, targetScreen: NSScreen?) {
        (NSApp.delegate as? AppDelegate)?.orderOutPreferencesWindowForToolOverlay()

        // Land the annotation overlay on the SAME physical display as the
        // captured window, using one screen-sized window per display rather than
        // a single window spanning the whole combined desktop. With "Displays
        // have separate Spaces" on (the default), a combined-spanning window
        // can't be live on two displays at once — AppKit binds it to one display
        // (in practice the primary), so a capture on a secondary monitor would
        // show nothing there. Per-screen windows keep each one cleanly inside
        // its display's Space, matching the region-drag path.
        guard let activeScreen = targetScreen
            ?? MultiMonitorHelper.screenWithMouse
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            log("❌ No screen available for annotation view")
            isAnnotating = false; AnnotateManager.shared.setSuspended(false)
            onScreenshotStateChanged?(false)
            stopScreenRecordingPermissionMonitor()
            removeScreenshotToolCursorGlobalMonitor()
            return
        }
        let activeFrame = activeScreen.frame

        // Dim every other display so focus stays on the captured window.
        for screen in NSScreen.screens where screen != activeScreen {
            let dimWindow = MultiMonitorWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            dimWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]
            dimWindow.level = kScreenshotOverlayBaseLevel
            dimWindow.isOpaque = false
            dimWindow.backgroundColor = NSColor.black.withAlphaComponent(kScreenshotDimOverlayAlpha)
            dimWindow.hasShadow = false
            dimWindow.animationBehavior = .none
            dimWindow.ignoresMouseEvents = false
            dimWindow.setFrame(screen.frame, display: true)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                dimWindow.orderFrontRegardless()
            }
            dimOverlayWindows.append(dimWindow)
        }

        // Aspect-fit the screenshot into the active screen, in screen-local
        // coords (origin 0,0 at the active screen origin).
        let reservedTop: CGFloat = 120
        let horizontalPadding: CGFloat = 16
        let screenshotRect = MultiMonitorHelper.annotationScreenshotRect(
            imageSize: image.size,
            targetScreenCocoaFrame: activeFrame,
            viewportCocoaOrigin: activeFrame.origin,
            reservedTop: reservedTop,
            horizontalPadding: horizontalPadding
        )

        let viewFrame = NSRect(origin: .zero, size: activeFrame.size)
        let window = AnnotationKeyableWindow(
            contentRect: activeFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.level = kScreenshotOverlayBaseLevel
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(kScreenshotDimOverlayAlpha)
        window.hasShadow = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = false
        window.setFrame(activeFrame, display: true)
        let view = ScreenshotAnnotationView(
            frame: viewFrame,
            screenshot: image,
            screenshotRect: screenshotRect
        )
        view.onClose = { [weak self] in
            self?.closeAnnotationView()
        }
        view.onSave = { [weak self] annotatedImage in
            self?.saveAnnotatedScreenshot(annotatedImage)
        }
        window.contentView = view
        annotationView = view
        annotationWindow = window
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            window.orderFrontRegardless()
        }
        focusLiveAnnotationOverlayForInteraction(window: window, view: view)
        NSCursor.crosshair.set()
        applyScreenshotToolCursorForCurrentMouseLocation()
    }
    
    private func closeAnnotationView() {
        isAnnotating = false; AnnotateManager.shared.setSuspended(false)
        onScreenshotStateChanged?(false)
        stopScreenRecordingPermissionMonitor()
        removeScreenshotToolCursorGlobalMonitor()
        dimOverlayPointerInteractionActive = false
        
        NSCursor.arrow.set()
        // Close color picker if it was opened from the annotation view (avoid orphaned panel)
        NSColorPanel.shared.orderOut(nil)
        annotationWindow?.orderOut(nil)
        annotationWindow = nil
        annotationView = nil
        for dimWindow in dimOverlayWindows { dimWindow.orderOut(nil) }
        dimOverlayWindows.removeAll()
        dimOverlayViews.removeAll()
        dimOverlayScreenFrames.removeAll()
    }
    
    private func saveAnnotatedScreenshot(_ image: NSImage) {
        // Copy annotated image to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        
        // Save to folder if enabled
        let saveToFolder = UserDefaults.standard.bool(forKey: ScreenshotPreferencesKeys.saveScreenshotsToFolder)
        var folderSaveFailed = false
        if saveToFolder {
            if let (folderURL, bookmarkIsStale) = screenshotSaveFolderURL() {
                let securityScopeStarted = folderURL.startAccessingSecurityScopedResource()
                defer {
                    if securityScopeStarted {
                        folderURL.stopAccessingSecurityScopedResource()
                    }
                }
                // Refresh a stale bookmark while the security scope is active — creating a
                // security-scoped bookmark from an un-started URL fails silently.
                if bookmarkIsStale, securityScopeStarted,
                   let refreshed = try? folderURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                   ) {
                    UserDefaults.standard.set(refreshed, forKey: ScreenshotPreferencesKeys.screenshotSaveFolderBookmark)
                }
                if let safeFolderURL = validatedScreenshotSaveDirectory(folderURL) {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                    let filename = "Screenshot_\(dateFormatter.string(from: Date())).png"
                    let fileURL = safeFolderURL.appendingPathComponent(filename)
                    
                    if let pngData = ImageHelpers.pngData(from: image) {
                        do {
                            try pngData.write(to: fileURL, options: .atomic)
                            log("✅ Screenshot saved to: \(fileURL.path)")
                        } catch {
                            folderSaveFailed = true
                            log("❌ Failed to save screenshot: \(error.localizedDescription)")
                        }
                    } else {
                        folderSaveFailed = true
                        log("❌ Failed to encode screenshot as PNG for disk save")
                    }
                } else {
                    folderSaveFailed = true
                }
            } else {
                folderSaveFailed = true
                log("⚠️ Save to folder enabled but no folder is set — choose one in Preferences")
            }
        }
        
        // Play sound if enabled
        let playSound = UserDefaults.standard.bool(forKey: "playNotificationSounds")
        if playSound {
            NSSound.beep()
        }
        
        let toastMessage: String
        if saveToFolder && folderSaveFailed {
            toastMessage = "Saved to clipboard - Folder save failed"
        } else {
            toastMessage = "Screenshot saved"
        }
        showToast(message: toastMessage)
        
        closeAnnotationView()
    }
    
    /// Ensures the path exists, is a directory, and is writable. Returns a standardized directory URL, or nil.
    private func validatedScreenshotSaveDirectory(_ folderURL: URL) -> URL? {
        // Keep logging behavior centralized in the app for now; the helper is pure/testable.
        let validated = ScreenshotDirectoryValidator.validatedScreenshotSaveDirectory(folderURL)
        if validated == nil {
            log("❌ Screenshot save directory validation failed: \(folderURL.path)")
        }
        return validated
    }

    /// Resolves the user-selected save folder. `bookmarkIsStale` tells the caller to
    /// re-create the bookmark once it has started the security scope.
    private func screenshotSaveFolderURL() -> (url: URL, bookmarkIsStale: Bool)? {
        let defaults = UserDefaults.standard

        if let bookmarkData = defaults.data(forKey: ScreenshotPreferencesKeys.screenshotSaveFolderBookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return (url, isStale)
            }
        }

        if let folderPath = defaults.string(forKey: ScreenshotPreferencesKeys.screenshotSaveFolder),
           !folderPath.isEmpty {
            return (URL(fileURLWithPath: folderPath, isDirectory: true), false)
        }

        return nil
    }
    
    // MARK: - Screen Recording Permission Monitor
    
    private func startScreenRecordingPermissionMonitor() {
        stopScreenRecordingPermissionMonitor()
        screenRecordingPermissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Use preflight only — the full verify path touches ScreenCaptureKit and can flicker the display.
            guard !PermissionManager.shared.hasScreenRecordingPermission() else { return }
            self.stopScreenRecordingPermissionMonitor()
            if self.annotationWindow != nil {
                self.closeAnnotationView()
            } else if !self.selectionOverlays.isEmpty {
                self.cancelSelection()
            }
        }
    }
    
    private func stopScreenRecordingPermissionMonitor() {
        screenRecordingPermissionTimer?.invalidate()
        screenRecordingPermissionTimer = nil
    }
    
    private func log(_ message: String) {
        debugLog(message)
    }
}
