import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import Carbon.HIToolbox

private let kRecordingOverlayLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

/// Key-capable borderless window for the confirm step (Esc, button clicks).
private final class RecordingConfirmWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Dim-with-live-hole view shown on every screen while recording (hole only
/// on the recorded screen). Entire window is click-through.
private final class RecordingDimHoleView: NSView {
    var holeRect: NSRect? {
        didSet { needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(kScreenshotDimOverlayAlpha)
        if let hole = holeRect, !hole.isEmpty, bounds.intersects(hole) {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: hole))
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
        } else {
            dim.setFill()
            bounds.fill()
        }
    }
}

class ScreenRecordingManager: ObservableObject {
    static let shared = ScreenRecordingManager()

    enum Activity: Int {
        case idle
        case selecting   // region picker / confirm step showing
        case recording   // stream running
    }

    @Published private(set) var activity: Activity = .idle

    /// Status bar icon + menu title updates.
    var onRecordingStateChanged: ((Activity) -> Void)?

    private enum CaptureTarget {
        case region(screen: NSScreen, globalRect: NSRect)
        case window(windowID: CGWindowID, screen: NSScreen, globalRect: NSRect)
    }

    // Selection phase (live picker, no frozen backdrop)
    private struct SelectionScreenOverlay {
        let screen: NSScreen
        let window: NSWindow
        let view: ScreenshotSelectionView
    }
    private var selectionOverlays: [SelectionScreenOverlay] = []
    private var selectionSharedState: SharedSelectionState?
    private var selectionDragMonitor: Any?

    // Confirm phase
    private var confirmWindow: NSWindow?
    private var confirmView: SelectionConfirmView?
    private var confirmDimWindows: [NSWindow] = []
    private var pendingTarget: CaptureTarget?

    // Recording phase
    private var recorder: ScreenRecorder?
    private var recordingDimWindows: [NSWindow] = []
    private var recordingDimViews: [RecordingDimHoleView] = []
    private var recordingDimScreenFrames: [NSRect] = []
    /// Plain Esc, registered only while the stream runs (stop control).
    private var escHotKeyID: UInt32?
    private var windowTrackingTimer: Timer?
    private var permissionTimer: Timer?
    private var isStopping = false
    private var playerController: RecordingPlayerWindowController?
    /// Folder scope held open for the player's lifetime (see beginSaveFolderAccess).
    private var playerFolderScopeURL: URL?

    // Dictation subtitles + mic audio (preflighted per session — a denied TCC
    // grant degrades the recording gracefully instead of blocking it)
    private var sessionCaptionsEnabled = false
    private var sessionMicAudioEnabled = false
    private var micSource: MicrophoneAudioSource?
    private var captionSession: CaptionSession?
    private var captionOverlay: CaptionOverlayController?
    private var recordingPixelSize: (width: Int, height: Int) = (0, 0)

    private init() {}

    // MARK: - Entry points

    /// Menu/shortcut entry: idle → start flow; selecting → cancel; recording → stop.
    func toggle() {
        switch activity {
        case .idle: startRecordingFlow()
        case .selecting: cancelFlow(toast: String(localized: "Recording canceled"))
        case .recording: stopRecording()
        }
    }

    func startRecordingFlow() {
        guard activity == .idle else { return }
        // Same live permission check as screenshots (preflight lies after revoke).
        PermissionManager.shared.verifyScreenRecordingPermission { [weak self] hasPermission in
            let proceed = { [weak self] in
                DispatchQueue.main.async { self?.ensureDestinationThenSelect() }
            }
            if hasPermission {
                proceed()
            } else {
                PermissionManager.shared.requestScreenRecordingAndWaitForGrant { proceed() }
            }
        }
    }

    func abortForPermissionLoss() {
        switch activity {
        case .idle: return
        case .selecting: cancelFlow(toast: nil)
        case .recording: stopRecording()
        }
    }

    // MARK: - Destination grant (one-time, before any overlay exists)

    private func ensureDestinationThenSelect() {
        guard activity == .idle else { return }
        PermissionManager.shared.markScreenRecordingPermissionGranted()
        if RecordingDestination.hasSaveFolder {
            preflightCaptureExtrasThenSelect()
            return
        }
        RecordingDestination.requestSaveFolderGrant { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.preflightCaptureExtrasThenSelect()
                } else {
                    ToastPresenter.shared.show(message: String(localized: "Recording needs a save folder — canceled"), force: true)
                }
            }
        }
    }

    // MARK: - Subtitles / mic preflight (before any overlay exists, so TCC
    // dialogs aren't buried under the selection chrome)

    private func preflightCaptureExtrasThenSelect() {
        let defaults = UserDefaults.standard
        let captionsWanted = defaults.bool(forKey: "recordingDictationSubtitles")
        let micWanted = defaults.bool(forKey: "recordingMicrophoneAudio")
        sessionCaptionsEnabled = false
        sessionMicAudioEnabled = false
        guard captionsWanted || micWanted else {
            startSelection()
            return
        }
        PermissionManager.shared.ensureMicrophoneAccess { [weak self] micGranted in
            guard let self else { return }
            guard micGranted else {
                ToastPresenter.shared.show(message: String(localized: "No microphone access — recording without subtitles or audio"), force: true)
                self.startSelection()
                return
            }
            self.sessionMicAudioEnabled = micWanted
            guard captionsWanted else {
                self.startSelection()
                return
            }
            guard CaptionEngineFactory.needsSpeechRecognitionPermission else {
                self.sessionCaptionsEnabled = true
                self.startSelection()
                return
            }
            PermissionManager.shared.ensureSpeechRecognitionAccess { [weak self] speechGranted in
                guard let self else { return }
                self.sessionCaptionsEnabled = speechGranted
                if !speechGranted {
                    ToastPresenter.shared.show(message: String(localized: "No speech recognition access — recording without subtitles"), force: true)
                }
                self.startSelection()
            }
        }
    }

    /// Toolbar toggled microphone audio during the confirm step. Re-resolve the session flag,
    /// requesting permission when turning on (mirrors `preflightCaptureExtrasThenSelect`).
    private func updateSessionMic(_ on: Bool) {
        guard on else {
            sessionMicAudioEnabled = false
            return
        }
        PermissionManager.shared.ensureMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            self.sessionMicAudioEnabled = granted
            if !granted {
                ToastPresenter.shared.show(message: String(localized: "No microphone access — recording without audio"), force: true)
            }
        }
    }

    /// Toolbar toggled subtitles during the confirm step. Subtitles are dictated from the
    /// microphone, so this needs mic access and (when required) speech-recognition access.
    private func updateSessionCaptions(_ on: Bool) {
        guard on else {
            sessionCaptionsEnabled = false
            return
        }
        PermissionManager.shared.ensureMicrophoneAccess { [weak self] micGranted in
            guard let self else { return }
            guard micGranted else {
                self.sessionCaptionsEnabled = false
                ToastPresenter.shared.show(message: String(localized: "No microphone access — recording without subtitles"), force: true)
                return
            }
            guard CaptionEngineFactory.needsSpeechRecognitionPermission else {
                self.sessionCaptionsEnabled = true
                return
            }
            PermissionManager.shared.ensureSpeechRecognitionAccess { [weak self] speechGranted in
                guard let self else { return }
                self.sessionCaptionsEnabled = speechGranted
                if !speechGranted {
                    ToastPresenter.shared.show(message: String(localized: "No speech recognition access — recording without subtitles"), force: true)
                }
            }
        }
    }

    // MARK: - Selection (live region picker, same UX as screenshots)

    private func startSelection() {
        (NSApp.delegate as? AppDelegate)?.orderOutPreferencesWindowForToolOverlay()
        setActivity(.selecting)
        ToastPresenter.shared.show(
            message: String(localized: "Click a window or drag a region to record"),
            windowLevel: NSWindow.Level(rawValue: kRecordingOverlayLevel.rawValue + 1)
        )

        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let window = MultiMonitorWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = kRecordingOverlayLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.animationBehavior = .none
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.setFrame(screenFrame, display: true)
            let view = ScreenshotSelectionView(frame: NSRect(origin: .zero, size: screenFrame.size))
            view.frozenBackdrop = nil // LIVE picker: the desktop stays visible and running
            view.screenOffset = screenFrame.origin
            view.onSelectionComplete = { [weak self] rect in
                DispatchQueue.main.async { self?.regionSelected(globalRect: rect) }
            }
            view.onWindowSelected = { [weak self] windowID in
                DispatchQueue.main.async { self?.windowSelected(windowID: windowID) }
            }
            view.onCancel = { [weak self] in
                self?.cancelFlow(toast: String(localized: "Recording canceled"))
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            for overlay in selectionOverlays { overlay.window.orderFrontRegardless() }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let target = selectionOverlays.first(where: { $0.window.frame.contains(NSEvent.mouseLocation) }) ?? selectionOverlays.first {
            target.window.makeKeyAndOrderFront(nil)
            _ = target.window.makeFirstResponder(target.view)
        }
        NSCursor.crosshair.set()
        startPermissionMonitor()
    }

    /// Cross-monitor drags: same local-monitor trick as ScreenshotManager
    /// (each view only sees events while its window is key).
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
            if let rect, rect.width > 10, rect.height > 10 {
                DispatchQueue.main.async { [weak self] in self?.regionSelected(globalRect: rect) }
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

    private func teardownSelectionOverlays() {
        for overlay in selectionOverlays { overlay.window.orderOut(nil) }
        selectionOverlays.removeAll()
        selectionSharedState = nil
        removeSelectionDragMonitor()
    }

    // MARK: - Confirm step

    private func regionSelected(globalRect: NSRect) {
        guard activity == .selecting else { return }
        teardownSelectionOverlays()
        let center = NSPoint(x: globalRect.midX, y: globalRect.midY)
        guard let screen = MultiMonitorHelper.screenContaining(center) ?? NSScreen.main ?? NSScreen.screens.first else {
            cancelFlow(toast: nil)
            return
        }
        // One SCStream = one display: clamp the selection to its display.
        let clamped = RecordingRegionMath.clamped(selection: globalRect, toDisplay: screen.frame)
        showConfirm(target: .region(screen: screen, globalRect: clamped))
    }

    private func windowSelected(windowID: CGWindowID) {
        guard activity == .selecting else { return }
        teardownSelectionOverlays()
        guard let rect = Self.cocoaBounds(windowID: windowID),
              let screen = MultiMonitorHelper.screenContaining(NSPoint(x: rect.midX, y: rect.midY))
                ?? NSScreen.main ?? NSScreen.screens.first else {
            cancelFlow(toast: nil)
            return
        }
        showConfirm(target: .window(windowID: windowID, screen: screen, globalRect: rect))
    }

    private func showConfirm(target: CaptureTarget) {
        pendingTarget = target
        let (screen, globalRect, allowsResize): (NSScreen, NSRect, Bool) = {
            switch target {
            case .region(let s, let r): return (s, r, true)
            case .window(_, let s, let r): return (s, r, false)
            }
        }()
        let screenFrame = screen.frame
        let localRect = NSRect(
            x: globalRect.origin.x - screenFrame.origin.x,
            y: globalRect.origin.y - screenFrame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        let window = RecordingConfirmWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = kRecordingOverlayLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        // Explicit false: without this, AppKit lets clicks fall through the
        // window's fully transparent pixels — i.e. straight through the hole.
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.setFrame(screenFrame, display: true)
        let view = SelectionConfirmView(
            frame: NSRect(origin: .zero, size: screenFrame.size),
            selectionRect: localRect,
            primaryTitle: String(localized: "Start Recording"),
            primaryIsDestructive: true,
            allowsResize: allowsResize,
            showsRecordingOptions: true
        )
        // Toolbar toggles update the in-flight session (the preflight already resolved
        // permissions from the saved prefs before selection; a mid-flow change must
        // re-resolve them so it applies to this recording).
        view.onSubtitlesToggled = { [weak self] on in self?.updateSessionCaptions(on) }
        view.onMicAudioToggled = { [weak self] on in self?.updateSessionMic(on) }
        view.onConfirm = { [weak self] finalLocalRect in
            let finalGlobal = NSRect(
                x: finalLocalRect.origin.x + screenFrame.origin.x,
                y: finalLocalRect.origin.y + screenFrame.origin.y,
                width: finalLocalRect.width,
                height: finalLocalRect.height
            )
            self?.beginRecording(finalGlobalRect: finalGlobal)
        }
        view.onCancel = { [weak self] in
            self?.cancelFlow(toast: String(localized: "Recording canceled"))
        }
        window.contentView = view
        confirmWindow = window
        confirmView = view

        // Plain dim on every other screen while confirming.
        for other in NSScreen.screens where other != screen {
            let dim = MultiMonitorWindow(
                contentRect: other.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            dim.level = kRecordingOverlayLevel
            dim.collectionBehavior = [.canJoinAllSpaces, .stationary]
            dim.isOpaque = false
            dim.backgroundColor = NSColor.black.withAlphaComponent(kScreenshotDimOverlayAlpha)
            dim.hasShadow = false
            dim.animationBehavior = .none
            dim.orderFrontRegardless()
            confirmDimWindows.append(dim)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(view)
        NSCursor.arrow.set()
    }

    private func teardownConfirmUI() {
        confirmWindow?.orderOut(nil)
        confirmWindow = nil
        confirmView = nil
        for dim in confirmDimWindows { dim.orderOut(nil) }
        confirmDimWindows.removeAll()
    }

    // MARK: - Recording

    private func beginRecording(finalGlobalRect: NSRect) {
        guard let target = pendingTarget else {
            cancelFlow(toast: nil)
            return
        }
        // Region target may have been resized in the confirm step.
        let effectiveTarget: CaptureTarget = {
            switch target {
            case .region(let screen, _):
                return .region(screen: screen, globalRect: RecordingRegionMath.clamped(selection: finalGlobalRect, toDisplay: screen.frame))
            case .window:
                return target
            }
        }()
        pendingTarget = effectiveTarget
        teardownConfirmUI()

        let (screen, globalRect): (NSScreen, NSRect) = {
            switch effectiveTarget {
            case .region(let s, let r): return (s, r)
            case .window(_, let s, let r): return (s, r)
            }
        }()

        // Recording chrome FIRST, so it exists in shareable content and can
        // be excluded from the capture filter.
        buildRecordingChrome(holeGlobalRect: globalRect)

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let content, error == nil else {
                    self.failRecordingStart(String(localized: "Could not read the screen — check Screen Recording permission for Topkit"))
                    return
                }
                self.startStream(content: content, target: effectiveTarget, screen: screen, globalRect: globalRect)
            }
        }
    }

    private func startStream(content: SCShareableContent, target: CaptureTarget, screen: NSScreen, globalRect: NSRect) {
        var ourWindowIDs = Set(recordingDimWindows.map { CGWindowID($0.windowNumber) })
        if let captionOverlay {
            // The live caption pill must never appear in the capture — the
            // burned-in render is the only copy that belongs in the file.
            ourWindowIDs.insert(captionOverlay.windowID)
        }
        let excluded = content.windows.filter { ourWindowIDs.contains($0.windowID) }

        let config = SCStreamConfiguration()
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(RecordingEncoding.frameRate))
        config.queueDepth = 8
        config.capturesAudio = false
        // Explicit BGRA: the caption compositor stamps pixels directly and
        // must know the layout (this is also SCK's default).
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let filter: SCContentFilter
        let pixelSize: (width: Int, height: Int)

        switch target {
        case .region:
            guard let displayID = ScreenCapture.displayID(for: screen),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                failRecordingStart(String(localized: "Could not find the display to record"))
                return
            }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            config.sourceRect = RecordingRegionMath.sourceRect(selectionGlobal: globalRect, displayFrame: screen.frame)
            pixelSize = RecordingRegionMath.evenPixelSize(pointSize: globalRect.size, scale: screen.backingScaleFactor)
        case .window(let windowID, _, _):
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                failRecordingStart(String(localized: "The selected window is gone"))
                return
            }
            let windowFilter = SCContentFilter(desktopIndependentWindow: scWindow)
            filter = windowFilter
            let scale = CGFloat(windowFilter.pointPixelScale)
            pixelSize = RecordingRegionMath.evenPixelSize(pointSize: windowFilter.contentRect.size, scale: scale)
        }
        config.width = pixelSize.width
        config.height = pixelSize.height
        recordingPixelSize = pixelSize

        // Mic first: the writer needs the tap format up front to add the AAC
        // track, and the caption engine wants it too. A mic that fails to
        // start degrades to a plain silent recording.
        if sessionMicAudioEnabled || sessionCaptionsEnabled {
            let source = MicrophoneAudioSource()
            do {
                try source.start()
                micSource = source
            } catch {
                debugLog("❌ Microphone start failed: \(error.localizedDescription)")
                sessionMicAudioEnabled = false
                sessionCaptionsEnabled = false
                ToastPresenter.shared.show(message: String(localized: "Microphone unavailable — recording without subtitles or audio"), force: true)
            }
        }

        let recorder = ScreenRecorder(
            outputURL: RecordingDestination.makeStagingURL(),
            micFormat: sessionMicAudioEnabled ? micSource?.format : nil,
            burnsInCaptions: sessionCaptionsEnabled
        )
        recorder.onStreamStoppedUnexpectedly = { [weak self] _ in
            // Display unplugged / recorded window closed / permission pulled:
            // salvage what was captured.
            self?.stopRecording()
        }
        self.recorder = recorder
        recorder.start(filter: filter, configuration: config, pixelWidth: pixelSize.width, pixelHeight: pixelSize.height) { [weak self] error in
            guard let self else { return }
            if let error {
                self.recorder = nil
                self.failRecordingStart(String(localized: "Could not start recording: ") + error.localizedDescription)
                return
            }
            self.setActivity(.recording)
            self.startCaptureExtras()
            // Esc stops the recording only after any live overlay tool has had a chance
            // to consume it (Annotate / Halo / Measure / …). Recording's Carbon hotkey
            // otherwise eats Esc system-wide and those tools never see the key.
            self.escHotKeyID = HotKeyManager.shared.registerTransient(keyCode: UInt32(kVK_Escape)) { [weak self] in
                if EscapeCascade.consume() { return }
                self?.stopRecording()
            }
            if case .window(let windowID, _, _) = target {
                self.startWindowTracking(windowID: windowID)
            }
            if UserDefaults.standard.bool(forKey: "playNotificationSounds") { NSSound.beep() }
        }
    }

    /// Starts the mic fan-out and the caption engine once the stream is live.
    private func startCaptureExtras() {
        guard let micSource else { return }
        if sessionCaptionsEnabled, let format = micSource.format {
            let session = CaptionSession()
            session.onDisplayTextChanged = { [weak self] text in
                self?.captionDisplayTextChanged(text)
            }
            captionSession = session
            session.start(format: format)
        }
        let wantsAudioTrack = sessionMicAudioEnabled
        micSource.onBuffer = { [weak self] buffer, when in
            // Audio tap thread — both sinks handle their own queue hops.
            self?.captionSession?.append(buffer)
            if wantsAudioTrack {
                self?.recorder?.appendMicrophoneBuffer(buffer, at: when)
            }
        }
    }

    /// Main thread, from CaptionSession: update the live pill and hand the
    /// recorder a freshly rendered burn-in image.
    private func captionDisplayTextChanged(_ text: String?) {
        captionOverlay?.setText(text)
        guard let recorder else { return }
        if let text,
           let burn = CaptionBurnInRenderer.render(
               text: text,
               videoWidth: recordingPixelSize.width,
               videoHeight: recordingPixelSize.height
           ) {
            recorder.updateCaption(burn)
        } else {
            recorder.updateCaption(nil)
        }
    }

    private func teardownCaptureExtras() {
        captionSession?.stop()
        captionSession = nil
        micSource?.stop()
        micSource = nil
        captionOverlay?.close()
        captionOverlay = nil
        sessionCaptionsEnabled = false
        sessionMicAudioEnabled = false
    }

    /// Click-through dim + hole on every screen. No control bar: the red tray
    /// icon is the indicator; the menu item / shortcut / Esc are the stop controls.
    private func buildRecordingChrome(holeGlobalRect: NSRect) {
        for screen in NSScreen.screens {
            let dim = MultiMonitorWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            dim.level = kRecordingOverlayLevel
            dim.collectionBehavior = [.canJoinAllSpaces, .stationary]
            dim.isOpaque = false
            dim.backgroundColor = .clear
            dim.hasShadow = false
            dim.animationBehavior = .none
            dim.ignoresMouseEvents = true // the whole point: record + interact
            dim.setFrame(screen.frame, display: true)
            let view = RecordingDimHoleView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.holeRect = NSRect(
                x: holeGlobalRect.origin.x - screen.frame.origin.x,
                y: holeGlobalRect.origin.y - screen.frame.origin.y,
                width: holeGlobalRect.width,
                height: holeGlobalRect.height
            )
            dim.contentView = view
            dim.orderFrontRegardless()
            recordingDimWindows.append(dim)
            recordingDimViews.append(view)
            recordingDimScreenFrames.append(screen.frame)
        }
        if sessionCaptionsEnabled {
            // Created (and ordered front, transparent) BEFORE the shareable
            // content fetch so the capture filter can exclude it by window ID.
            captionOverlay = CaptionOverlayController(
                anchorRect: holeGlobalRect,
                level: NSWindow.Level(rawValue: kRecordingOverlayLevel.rawValue + 1)
            )
        }
    }

    /// Window mode: keep the hole glued to the (movable) recorded window.
    private func startWindowTracking(windowID: CGWindowID) {
        windowTrackingTimer?.invalidate()
        let t = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            guard let self, let rect = Self.cocoaBounds(windowID: windowID) else { return }
            self.captionOverlay?.updateAnchor(rect)
            for (i, view) in self.recordingDimViews.enumerated() {
                guard i < self.recordingDimScreenFrames.count else { continue }
                let f = self.recordingDimScreenFrames[i]
                view.holeRect = NSRect(
                    x: rect.origin.x - f.origin.x,
                    y: rect.origin.y - f.origin.y,
                    width: rect.width,
                    height: rect.height
                )
            }
        }
        RunLoop.main.add(t, forMode: .common)
        windowTrackingTimer = t
    }

    func stopRecording() {
        guard activity == .recording, !isStopping, let recorder else { return }
        isStopping = true
        // Extras first: no caption/audio appends may race the writer finalize.
        teardownCaptureExtras()
        if let escHotKeyID {
            HotKeyManager.shared.unregisterTransient(id: escHotKeyID)
            self.escHotKeyID = nil
        }
        windowTrackingTimer?.invalidate()
        windowTrackingTimer = nil
        recorder.stop { [weak self] error in
            guard let self else { return }
            self.recorder = nil
            self.teardownRecordingChrome()
            self.isStopping = false
            self.setActivity(.idle)
            self.stopPermissionMonitor()
            if let error {
                debugLog("❌ Recording failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: recorder.outputURL)
                ToastPresenter.shared.show(message: String(localized: "Recording failed"), force: true)
                return
            }
            self.saveFinishedRecording(stagingURL: recorder.outputURL)
        }
    }

    private func saveFinishedRecording(stagingURL: URL) {
        if UserDefaults.standard.bool(forKey: "playNotificationSounds") { NSSound.beep() }
        guard let finalURL = RecordingDestination.moveIntoSaveFolder(stagingURL: stagingURL) else {
            debugLog("❌ Could not move recording into save folder; left at \(stagingURL.path)")
            ToastPresenter.shared.show(message: String(localized: "Recording save failed — choose a folder in Preferences"), force: true)
            return
        }
        debugLog("✅ Recording saved to: \(finalURL.path)")
        ToastPresenter.shared.show(message: String(localized: "Recording saved"))
        presentPlayer(for: finalURL)
    }

    /// The post-recording player. Closing it releases everything; there is no
    /// other way to open a video in Topkit.
    private func presentPlayer(for url: URL) {
        playerController?.close() // its onClose ends any previous folder scope
        // Keep the save folder's security scope open while the player lives:
        // AVPlayer and the trim export read the file lazily, and the sandbox
        // denies those reads once the save's own scope has ended.
        playerFolderScopeURL = RecordingDestination.beginSaveFolderAccess()
        (NSApp.delegate as? AppDelegate)?.pushRegularActivation()
        let controller = RecordingPlayerWindowController(fileURL: url) { [weak self] in
            guard let self else { return }
            self.playerController = nil
            if let scoped = self.playerFolderScopeURL {
                RecordingDestination.endSaveFolderAccess(scoped)
                self.playerFolderScopeURL = nil
            }
            (NSApp.delegate as? AppDelegate)?.popRegularActivation()
        }
        playerController = controller
        controller.present()
    }

    private func failRecordingStart(_ message: String) {
        teardownRecordingChrome()
        setActivity(.idle)
        stopPermissionMonitor()
        ToastPresenter.shared.show(message: message, force: true)
    }

    private func teardownRecordingChrome() {
        teardownCaptureExtras()
        for dim in recordingDimWindows { dim.orderOut(nil) }
        recordingDimWindows.removeAll()
        recordingDimViews.removeAll()
        recordingDimScreenFrames.removeAll()
        if let escHotKeyID {
            HotKeyManager.shared.unregisterTransient(id: escHotKeyID)
            self.escHotKeyID = nil
        }
        pendingTarget = nil
    }

    // MARK: - Cancel / state

    private func cancelFlow(toast: String?) {
        teardownSelectionOverlays()
        teardownConfirmUI()
        teardownRecordingChrome()
        stopPermissionMonitor()
        setActivity(.idle)
        NSCursor.arrow.set()
        if let toast {
            if UserDefaults.standard.bool(forKey: "playNotificationSounds") { NSSound.beep() }
            ToastPresenter.shared.show(message: toast)
        }
    }

    private func setActivity(_ new: Activity) {
        let previous = activity
        activity = new
        onRecordingStateChanged?(new)
        // Recording owns the global Esc hotkey; Annotate must drop/reclaim its own.
        if previous == .recording || new == .recording {
            AnnotateManager.shared.syncEscapeHotKeyWithRecording()
        }
    }

    // MARK: - Permission monitor (selection/confirm phases only; the stream
    // itself reports revocation via didStopWithError while recording)

    private func startPermissionMonitor() {
        stopPermissionMonitor()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.activity == .selecting else { return }
            guard !PermissionManager.shared.hasScreenRecordingPermission() else { return }
            self.cancelFlow(toast: nil)
        }
    }

    private func stopPermissionMonitor() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Window bounds lookup (Quartz → Cocoa)

    static func cocoaBounds(windowID: CGWindowID) -> NSRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let qx = bounds["X"] as? CGFloat,
              let qy = bounds["Y"] as? CGFloat,
              let qw = bounds["Width"] as? CGFloat,
              let qh = bounds["Height"] as? CGFloat else {
            return nil
        }
        let primaryH = MultiMonitorHelper.primaryScreenHeight
        return NSRect(x: qx, y: primaryH - qy - qh, width: qw, height: qh)
    }
}
