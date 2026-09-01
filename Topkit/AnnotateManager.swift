import AppKit
import Carbon.HIToolbox
import Foundation

/// Hosts the live Annotate overlay: one full-screen canvas per display on which the
/// annotation tools work directly over whatever is on screen.
///
/// Modelled on `GuidesManager`. Guides is the only other overlay in this app that
/// gets multi-monitor hotplug, click-through, and key-window handling right — the
/// Draw overlay this replaced got all three wrong (its window could never become key,
/// so its `keyDown` was dead code, and it never restored focus to the app it took it
/// from).
final class AnnotateManager: ObservableObject {
    static let shared = AnnotateManager()

    @Published private(set) var isActive = false
    @Published private(set) var armedTool: AnnotationTool?

    var onAnnotateStateChanged: ((Bool) -> Void)?

    /// Ordered to match the screenshot editor's toolbar.
    private static let stripItems: [AnnotateToolStrip.Item] = [
        .init(tool: .freehand,    icon: "pencil.tip",       title: "Freehand"),
        .init(tool: .rectangle,   icon: "rectangle",        title: "Rectangle"),
        .init(tool: .circle,      icon: "circle",           title: "Circle"),
        .init(tool: .arrow,       icon: "arrow.up",         title: "Arrow"),
        .init(tool: .text,        icon: "textformat",       title: "Text"),
        .init(tool: .blur,        icon: "eye.slash.fill",   title: "Redact"),
        .init(tool: .sticker(.redX), icon: "xmark.circle.fill", title: "Sticker"),
        .init(tool: .numberBadge, icon: "1.circle",         title: "Numbered badge"),
        .init(tool: .measure,     icon: "ruler",            title: "Measure"),
        .init(tool: .guide(.vertical),   icon: "arrow.up.and.down",    title: "Vertical guide"),
        .init(tool: .guide(.horizontal), icon: "arrow.left.and.right", title: "Horizontal guide"),
        .init(tool: .grid,        icon: "square.grid.3x3",  title: "Grid"),
    ]

    private struct ScreenOverlay {
        let screen: NSScreen
        let window: LiveAnnotationOverlayWindow
        let view: ScreenshotAnnotationView
        /// The model lives here, not in the view: a hotplug rebuild throws the view
        /// away, and annotations must survive that.
        var annotations: [Annotation]
    }

    private var overlays: [ScreenOverlay] = []
    private var lastKnownScreenFrames: [NSRect] = []

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenParametersObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var escapeHotKeyId: UInt32?

    /// Restored on stop. Draw never does this, so it leaves the user's previous app
    /// unfocused after every session.
    private var applicationToRestore: NSRunningApplication?

    /// Set while a screenshot region pick is up. Annotate and the screenshot overlay
    /// share a window level, and ordering between same-level windows is undefined, so
    /// Annotate stands down rather than fighting for clicks.
    private var isSuspended = false

    /// Desktop pixels captured once when Redact is first armed, then cropped per
    /// mark. Captured once rather than per placement because SCScreenshotManager is
    /// asynchronous: baking per commit would leave a window in which the redaction
    /// renders as a solid black box.
    private var redactSource: [(screen: NSScreen, image: NSImage)] = []
    private var isCapturingRedactSource = false

    private init() {}

    // MARK: - Lifecycle

    /// Same tool again ends the session; a different tool swaps without restarting.
    func toggle(tool: AnnotationTool) {
        if isActive && armedTool == tool {
            stop()
            return
        }
        if isActive {
            arm(tool)
            return
        }
        start(tool: tool)
    }

    func start(tool: AnnotationTool?) {
        guard !isActive else { return }
        (NSApp.delegate as? AppDelegate)?.orderOutPreferencesWindowForToolOverlay()

        applicationToRestore = NSWorkspace.shared.frontmostApplication
        isActive = true
        EscapeCascade.push(.annotate)
        onAnnotateStateChanged?(true)

        lastKnownScreenFrames = currentScreenFrames()
        buildOverlays()
        arm(tool)

        setupMouseTracking()
        setupDisplayObservers()
        registerEscapeHotKey()

        if UserDefaults.standard.bool(forKey: "playNotificationSounds") {
            NSSound.beep()
        }
        ToastPresenter.shared.show(message: "Annotate active")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        armedTool = nil
        EscapeCascade.pop(.annotate)
        onAnnotateStateChanged?(false)

        if UserDefaults.standard.bool(forKey: "playNotificationSounds") {
            NSSound.beep()
        }
        ToastPresenter.shared.show(message: "Annotate ended")

        teardown()
    }

    /// Screen Recording was revoked mid-session. Freehand does not need it, but the
    /// redact tool will (phase 5), so the hook exists from the start.
    func cancelForPermissionLoss() {
        guard isActive else { return }
        stop()
    }

    /// Called around a screenshot region pick so the two overlays do not contend.
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        guard isActive else { return }
        if suspended {
            for overlay in overlays {
                overlay.window.ignoresMouseEvents = true
            }
        } else {
            updateClickThrough()
        }
    }

    /// The live overlay canvases, in screen order. Tests use this rather than
    /// scraping NSApp.windows, which also contains windows from earlier sessions.
    var overlayViews: [ScreenshotAnnotationView] { overlays.map(\.view) }

    var overlayWindows: [LiveAnnotationOverlayWindow] { overlays.map(\.window) }

    // MARK: - Tool arming

    func arm(_ tool: AnnotationTool?) {
        armedTool = tool
        if case .blur = tool { ensureRedactSource() }
        for overlay in overlays {
            overlay.view.setArmedTool(tool)
        }
        updateClickThrough()
    }

    // MARK: - Auto-end on an empty canvas

    /// The session deliberately survives having no tool armed, so a guide or a mark can
    /// stay put while the user clicks around in other apps. Nothing on any canvas and
    /// nothing armed means the overlay is invisible and doing nothing, so end it.
    ///
    /// Async: the notification fires from inside the view's own mutation and `stop()`
    /// tears that view down, so the callback must return first.
    private func scheduleAutoEndIfCanvasEmpty() {
        DispatchQueue.main.async { [weak self] in
            self?.autoEndIfCanvasEmpty()
        }
    }

    /// Armed means the user is still mid-work — undoing the only mark must not kill the
    /// session out from under a live tool.
    private func autoEndIfCanvasEmpty() {
        guard isActive, armedTool == nil else { return }
        // Per screen: clearing one display must not end a session with marks on another.
        guard overlays.allSatisfy({ $0.view.annotationsForHost.isEmpty }) else { return }
        stop()
    }

    // MARK: - Redaction source

    /// Redact is the only tool needing pixels from underneath the overlay, so it is
    /// also the only one gated on Screen Recording.
    private func ensureRedactSource() {
        guard redactSource.isEmpty, !isCapturingRedactSource else { return }
        isCapturingRedactSource = true

        PermissionManager.shared.verifyScreenRecordingPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.isCapturingRedactSource = false
                PermissionManager.shared.requestScreenRecordingAndWaitForGrant { [weak self] in
                    self?.ensureRedactSource()
                }
                return
            }
            // Exclude our own overlays: without this the bake would capture the marks
            // already drawn on top of the very pixels it is meant to hide.
            let ownWindowIDs = Set(self.overlays.map { CGWindowID($0.window.windowNumber) })
            ScreenCapture.captureAllDisplays(NSScreen.screens, excludingWindowIDs: ownWindowIDs) { [weak self] result in
                guard let self else { return }
                self.isCapturingRedactSource = false
                guard let result else {
                    ToastPresenter.shared.show(message: "Could not read the screen — check Screen Recording permission")
                    self.arm(nil)
                    return
                }
                self.redactSource = result
                for index in self.overlays.indices {
                    let screen = self.overlays[index].screen
                    if let match = result.first(where: { $0.screen.frame == screen.frame }) {
                        self.overlays[index].view.redactionSource = match.image
                    }
                }
            }
        }
    }

    // MARK: - Overlays

    private func buildOverlays() {
        // Preserve any existing annotations across a rebuild, matched by screen frame.
        let preserved = Dictionary(
            overlays.map { ($0.screen.frame.asKey, $0.annotations) },
            uniquingKeysWith: { first, _ in first }
        )
        teardownWindowsOnly()

        for screen in NSScreen.screens {
            let frame = screen.frame
            let window = LiveAnnotationOverlayWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.level = kScreenshotOverlayBaseLevel
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            // Start pass-through; the mouse monitor turns it on when the pointer is
            // over something interactive. Never leave this false on an idle overlay.
            window.ignoresMouseEvents = true
            // ARC owns these; close() must not also release them.
            window.isReleasedWhenClosed = false
            window.setFrame(frame, display: true)

            let view = ScreenshotAnnotationView(
                frame: NSRect(origin: .zero, size: frame.size),
                mode: .liveAnnotate
            )
            view.onArmedToolChanged = { [weak self] tool in
                guard let self else { return }
                self.armedTool = tool
                // Arming from the strip must capture the desktop just like `arm(_:)`
                // does, or Redact has no pixels to mosaic and falls back to black.
                if case .blur = tool { self.ensureRedactSource() }
                for overlay in self.overlays where overlay.view !== view {
                    overlay.view.setArmedTool(tool)
                }
                self.updateClickThrough()
            }
            view.onExitRequested = { [weak self] in self?.stop() }
            view.onCanvasEmptied = { [weak self] in self?.scheduleAutoEndIfCanvasEmpty() }
            view.installAnnotateChrome(tools: Self.stripItems)

            if let restored = preserved[frame.asKey] {
                view.annotationsForHost = restored
            }
            if let match = redactSource.first(where: { $0.screen.frame == frame }) {
                view.redactionSource = match.image
            }

            window.contentView = view
            window.orderFront(nil)

            overlays.append(ScreenOverlay(
                screen: screen,
                window: window,
                view: view,
                annotations: preserved[frame.asKey] ?? []
            ))
        }

        // A single call does not reliably take; the screenshot overlay does the same.
        if let first = overlays.first {
            focusOverlayForInteraction(window: first.window, view: first.view)
            DispatchQueue.main.async { [weak self] in
                guard let self, let first = self.overlays.first else { return }
                self.focusOverlayForInteraction(window: first.window, view: first.view)
            }
        }
    }

    private func focusOverlayForInteraction(window: NSWindow, view: NSView) {
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            window.makeKeyAndOrderFront(nil)
        }
        _ = window.makeFirstResponder(view)
        window.invalidateCursorRects(for: view)
    }

    /// Pull the live annotations out of the views so a rebuild can re-seed them.
    private func captureAnnotations() {
        for index in overlays.indices {
            overlays[index].annotations = overlays[index].view.annotationsForHost
        }
    }

    // MARK: - Click-through
    //
    // Cross-app click-through is decided by the window server from
    // `ignoresMouseEvents` BEFORE `hitTest` runs, so overriding `hitTest` alone does
    // nothing here. Global mouse monitors need no permission (global *keyboard*
    // monitors do, and never fire in this sandbox).

    private func setupMouseTracking() {
        removeMouseTracking()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            self.updateClickThrough()
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                // Observed globally means it went to another app, i.e. it landed on
                // pass-through space. Deselect — but not for clicks in the menu bar,
                // or opening the status menu would kill the selection first.
                guard !self.isPointInMenuBar(NSEvent.mouseLocation) else { return }
                DispatchQueue.main.async { self.deselectAll() }
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            self?.updateClickThrough()
            return event
        }

        updateClickThrough()
    }

    private func removeMouseTracking() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        // Force pass-through back on. Without this, a stranded overlay locks the user
        // out of their machine.
        for overlay in overlays {
            overlay.window.ignoresMouseEvents = true
        }
    }

    /// Per window, not ORed across all of them: Guides sets the same flag on every
    /// overlay, which makes every screen opaque to clicks when the pointer is over an
    /// element on one of them.
    private func updateClickThrough() {
        guard isActive, !isSuspended else { return }
        let screenPoint = NSEvent.mouseLocation
        let armed = armedTool != nil
        for overlay in overlays {
            let wants = armed
                || overlay.view.isMidGesture
                || overlay.view.isInteractive(atScreenPoint: screenPoint)
            overlay.window.ignoresMouseEvents = !wants
        }
    }

    private func isPointInMenuBar(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return false
        }
        return point.y >= screen.visibleFrame.maxY
    }

    private func deselectAll() {
        for overlay in overlays {
            overlay.view.deselectForHost()
        }
    }

    // MARK: - Escape
    //
    // With click-through active and no tool armed the overlay is NOT key, so no local
    // key monitor fires and Escape would do nothing — exactly when the user most wants
    // out. A Carbon hotkey is global and needs no permission.
    //
    // While a screen recording is running, recording owns the Esc hotkey and routes
    // through `EscapeCascade` (which calls `consumeEscape`). Registering a second Esc
    // here would double-fire on one keypress.

    private func registerEscapeHotKey() {
        unregisterEscapeHotKey()
        guard ScreenRecordingManager.shared.activity != .recording else { return }
        escapeHotKeyId = HotKeyManager.shared.registerTransient(
            keyCode: UInt32(kVK_Escape)
        ) { [weak self] in
            _ = self?.consumeEscape()
        }
    }

    private func unregisterEscapeHotKey() {
        if let id = escapeHotKeyId {
            HotKeyManager.shared.unregisterTransient(id: id)
            escapeHotKeyId = nil
        }
    }

    /// Recording claims Esc while active; when it ends, Annotate must take Esc back.
    func syncEscapeHotKeyWithRecording() {
        guard isActive else {
            unregisterEscapeHotKey()
            return
        }
        if ScreenRecordingManager.shared.activity == .recording {
            unregisterEscapeHotKey()
        } else if escapeHotKeyId == nil {
            registerEscapeHotKey()
        }
    }

    /// One Escape step while Annotate is live: deselect → disarm → end session.
    /// Returns `true` if Annotate was active and consumed the key.
    @discardableResult
    func consumeEscape() -> Bool {
        guard isActive else { return false }
        // Innermost first: a dimension field the user just opened is the thing Esc
        // should close, not the selection behind it or the whole session.
        var cancelledEdit = false
        for overlay in overlays where overlay.view.cancelInlineEditForHost() {
            cancelledEdit = true
        }
        if cancelledEdit { return true }
        var deselected = false
        for overlay in overlays where overlay.view.deselectForHost() {
            deselected = true
        }
        if deselected { return true }
        if armedTool != nil {
            arm(nil)
            return true
        }
        stop()
        return true
    }

    // MARK: - Display reconfiguration

    private func setupDisplayObservers() {
        removeDisplayObservers()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensureOverlayConfigurationCurrent(reason: "screen parameters changed")
        }
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensureOverlayConfigurationCurrent(reason: "system wake")
        }
    }

    private func removeDisplayObservers() {
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParametersObserver = nil
        }
        if let observer = workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceWakeObserver = nil
        }
    }

    private func currentScreenFrames() -> [NSRect] {
        NSScreen.screens.map(\.frame).sorted { lhs, rhs in
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            return lhs.height < rhs.height
        }
    }

    private func screenConfigurationChanged() -> Bool {
        let current = currentScreenFrames()
        guard current.count == lastKnownScreenFrames.count else { return true }
        let epsilon: CGFloat = 0.5
        for (index, frame) in current.enumerated() {
            let previous = lastKnownScreenFrames[index]
            if abs(frame.origin.x - previous.origin.x) > epsilon ||
                abs(frame.origin.y - previous.origin.y) > epsilon ||
                abs(frame.size.width - previous.size.width) > epsilon ||
                abs(frame.size.height - previous.size.height) > epsilon {
                return true
            }
        }
        return false
    }

    private func ensureOverlayConfigurationCurrent(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.ensureOverlayConfigurationCurrent(reason: reason)
            }
            return
        }
        guard isActive, screenConfigurationChanged() else { return }
        captureAnnotations()
        // The captured desktop belongs to the old display layout.
        redactSource.removeAll()
        lastKnownScreenFrames = currentScreenFrames()
        buildOverlays()
        arm(armedTool)
        updateClickThrough()
    }

    // MARK: - Teardown

    private func teardownWindowsOnly() {
        for overlay in overlays {
            overlay.window.ignoresMouseEvents = true
            overlay.window.orderOut(nil)
            // orderOut alone leaves the window alive in NSApp.windows, so every
            // session would leak one window per display. close() retires it —
            // isReleasedWhenClosed is false (set at creation) so ARC owns it.
            overlay.window.contentView = nil
            overlay.window.close()
        }
        overlays.removeAll()
    }

    private func teardown() {
        unregisterEscapeHotKey()
        removeDisplayObservers()
        removeMouseTracking()
        redactSource.removeAll()
        // Shared panel — leave it open and it floats forever after Annotate ends.
        for overlay in overlays { overlay.view.dismissColorPanel() }
        NSCursor.arrow.set()
        teardownWindowsOnly()

        // Hand focus back to whatever the user was in.
        if let app = applicationToRestore, app.processIdentifier != NSRunningApplication.current.processIdentifier {
            app.activate()
        }
        applicationToRestore = nil
    }
}

private extension NSRect {
    /// Stable key for matching an overlay to a screen across a rebuild.
    var asKey: String {
        "\(Int(origin.x))_\(Int(origin.y))_\(Int(width))_\(Int(height))"
    }
}
