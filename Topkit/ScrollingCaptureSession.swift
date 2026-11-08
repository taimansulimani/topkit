import AppKit
import ScreenCaptureKit

/// Pure geometry for the scrolling capture, kept apart so it can be tested.
enum ScrollingCaptureGeometry {

    /// `rect` clamped to `screenFrame` and snapped to that screen's pixel grid, so
    /// every frame is the same whole number of pixels. Nil when nothing is left.
    static func captureRect(for rect: NSRect, screenFrame: NSRect, scale: CGFloat) -> NSRect? {
        let clamped = rect.intersection(screenFrame)
        guard !clamped.isNull, scale > 0 else { return nil }
        let minX = (clamped.minX * scale).rounded(.up) / scale
        let minY = (clamped.minY * scale).rounded(.up) / scale
        let maxX = (clamped.maxX * scale).rounded(.down) / scale
        let maxY = (clamped.maxY * scale).rounded(.down) / scale
        guard maxX - minX >= 1, maxY - minY >= 1 else { return nil }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The region in ScreenCaptureKit's display space: points, top-left origin,
    /// relative to the display.
    static func sourceRect(for rect: NSRect, screenFrame: NSRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Pixel size of a frame of `rect` at `scale` (2 on Retina).
    static func pixelSize(for rect: NSRect, scale: CGFloat) -> (width: Int, height: Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    /// Where the Done / Cancel bar goes: centred under the region, else above it,
    /// else inside its bottom edge. Always kept on the visible part of the screen.
    static func controlOrigin(controlSize: NSSize, region: NSRect, visibleFrame: NSRect, gap: CGFloat = 12) -> NSPoint {
        var x = region.midX - controlSize.width / 2
        x = min(max(x, visibleFrame.minX + gap), visibleFrame.maxX - controlSize.width - gap)
        let below = region.minY - gap - controlSize.height
        let above = region.maxY + gap
        let y: CGFloat
        if below >= visibleFrame.minY {
            y = below
        } else if above + controlSize.height <= visibleFrame.maxY {
            y = above
        } else {
            y = max(region.minY + gap, visibleFrame.minY + gap)
        }
        return NSPoint(x: x, y: y)
    }
}

/// "You scroll, it stitches" (TEC-246). Puts a click-through frame around the region
/// and a small Done / Cancel bar outside it, grabs the region whenever the user
/// scrolls (plus a slow timer for keyboard scrolling and momentum), and feeds every
/// grab to `ScrollingStitcher`. Topkit's own windows are left out of every grab.
final class ScrollingCaptureSession {

    /// Called once on the main thread: the stitched image (pixels) or nil on failure.
    var onFinish: ((CGImage?) -> Void)?
    var onCancel: (() -> Void)?

    let region: NSRect
    let screen: NSScreen
    let scale: CGFloat

    private let stitcher: ScrollingStitcher
    private let stitchQueue = DispatchQueue(label: "com.topkit.scrolling-stitch", qos: .userInitiated)

    private var frameWindow: NSWindow?
    private var controlPanel: ScrollingControlPanel?
    private var scrollMonitor: Any?
    private var idleTimer: Timer?
    private var throttleTimer: Timer?
    private var hintResetTimer: Timer?

    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?

    private var captureInFlight = false
    private var captureRequested = false
    /// Grabs taken but not stitched yet. The next grab does not wait for the last
    /// one to be stitched (that set the pace, and fast scrolling left no overlap),
    /// but never more than `maxPendingStitches` wait.
    private var pendingStitches = 0
    /// Done was pressed and its last grab has started.
    private var finalGrabStarted = false
    private var lastCaptureStart = Date.distantPast
    private var isFinishing = false
    private var isEnded = false
    private var stitchedHeight = 0
    private var hint: String?

    /// Shortest gap between two grabs while the user is scrolling.
    private static let minCaptureInterval: TimeInterval = 0.03
    private static let maxPendingStitches = 2
    /// Slow background grab, for scrolling that sends no wheel events.
    private static let idleCaptureInterval: TimeInterval = 0.5
    /// Overlay scroll bars sit within this many points of the right edge.
    private static let scrollBarBand: CGFloat = 16

    /// Nil when the region has no pixels left on `screen`.
    init?(region: NSRect, screen: NSScreen) {
        let scale = screen.backingScaleFactor
        guard let snapped = ScrollingCaptureGeometry.captureRect(for: region, screenFrame: screen.frame, scale: scale) else {
            return nil
        }
        self.region = snapped
        self.screen = screen
        self.scale = scale
        self.stitcher = ScrollingStitcher(
            maxHeight: 20_000,
            ignoredTrailingColumns: Int(Self.scrollBarBand * scale)
        )
    }

    // MARK: Lifecycle

    func start() {
        showFrame()
        showControls()
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.requestCapture()
        }
        scrollMonitor = monitor
        let timer = Timer(timeInterval: Self.idleCaptureInterval, repeats: true) { [weak self] _ in
            self?.requestCapture()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
        prepareFilter()
    }

    /// Done: take one last grab so the final scroll position is in, then stitch.
    func finish() {
        guard !isEnded, !isFinishing else { return }
        isFinishing = true
        controlPanel?.setBusy(true)
        guard filter != nil else {
            // Nothing could ever be captured.
            end()
            onFinish?(nil)
            return
        }
        // The last grab starts once the one in flight is back.
        if !captureInFlight { capture() }
    }

    func cancel() {
        // Once Done is stitching, it finishes.
        guard !isEnded, !isFinishing else { return }
        end()
        onCancel?()
    }

    private func end() {
        isEnded = true
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        throttleTimer?.invalidate()
        throttleTimer = nil
        hintResetTimer?.invalidate()
        hintResetTimer = nil
        frameWindow?.orderOut(nil)
        frameWindow = nil
        controlPanel?.orderOut(nil)
        controlPanel = nil
    }

    // MARK: Windows

    private func showFrame() {
        let inset = ScrollingFrameView.borderWidth + 1
        let window = NSWindow(
            contentRect: region.insetBy(dx: -inset, dy: -inset),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = kScreenshotOverlayBaseLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        // Click-through: the content under the frame must take the scroll wheel.
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = ScrollingFrameView(frame: NSRect(origin: .zero, size: window.frame.size), inset: inset)
        window.orderFrontRegardless()
        frameWindow = window
    }

    private func showControls() {
        let panel = ScrollingControlPanel()
        panel.onDone = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.setStatus(String(localized: "Scroll down to capture"))
        let origin = ScrollingCaptureGeometry.controlOrigin(
            controlSize: panel.frame.size,
            region: region,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        // Key so Esc and Return reach it. Non-activating, so the app being scrolled
        // keeps its focus.
        panel.makeKey()
        controlPanel = panel
    }

    // MARK: Capturing

    private func prepareFilter() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, !self.isEnded else { return }
                guard let content,
                      let displayID = ScreenCapture.displayID(for: self.screen),
                      let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    self.cancelForFailure()
                    return
                }
                // Leave every Topkit window out: the frame, the bar, any menu.
                let pid = ProcessInfo.processInfo.processIdentifier
                let filter: SCContentFilter
                if let ownApp = content.applications.first(where: { $0.processID == pid }) {
                    filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
                } else {
                    // A window not on screen has no number yet (-1): skip it, never trap.
                    let ownWindowIDs = Set(NSApp.windows.compactMap { CGWindowID(exactly: $0.windowNumber) })
                    filter = SCContentFilter(
                        display: display,
                        excludingWindows: content.windows.filter { ownWindowIDs.contains($0.windowID) }
                    )
                }
                let config = SCStreamConfiguration()
                config.sourceRect = ScrollingCaptureGeometry.sourceRect(for: self.region, screenFrame: self.screen.frame)
                let size = ScrollingCaptureGeometry.pixelSize(for: self.region, scale: self.scale)
                config.width = size.width
                config.height = size.height
                config.showsCursor = false
                config.captureResolution = .best
                self.filter = filter
                self.configuration = config
                self.requestCapture()
            }
        }
    }

    private func cancelForFailure() {
        guard !isEnded else { return }
        end()
        onFinish?(nil)
    }

    /// Throttled: at most one grab in flight, no more than `maxPendingStitches`
    /// waiting to be stitched, and no closer together than `minCaptureInterval`.
    /// A request while held back queues exactly one more.
    private func requestCapture() {
        guard !isEnded, !isFinishing, filter != nil else { return }
        if captureInFlight || pendingStitches >= Self.maxPendingStitches {
            captureRequested = true
            return
        }
        let wait = Self.minCaptureInterval - Date().timeIntervalSince(lastCaptureStart)
        if wait <= 0 {
            capture()
        } else if throttleTimer == nil {
            let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                self?.throttleTimer = nil
                self?.requestCapture()
            }
            RunLoop.main.add(timer, forMode: .common)
            throttleTimer = timer
        }
    }

    private func capture() {
        guard !isEnded, let filter, let configuration else { return }
        captureInFlight = true
        captureRequested = false
        if isFinishing { finalGrabStarted = true }
        lastCaptureStart = Date()
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, _ in
            DispatchQueue.main.async {
                self?.grabDidFinish(image: image)
            }
        }
    }

    private func grabDidFinish(image: CGImage?) {
        captureInFlight = false
        guard !isEnded else { return }
        pendingStitches += 1
        stitchQueue.async { [weak self] in
            guard let self else { return }
            let outcome = image.map { self.stitcher.add($0) }
            let height = self.stitcher.height
            DispatchQueue.main.async {
                self.stitchDidFinish(outcome: outcome, height: height)
            }
        }
        continueAfterGrab()
    }

    private func stitchDidFinish(outcome: ScrollingStitcher.Outcome?, height: Int) {
        pendingStitches -= 1
        guard !isEnded else { return }
        stitchedHeight = height
        switch outcome {
        case .noMatch:
            showHint(String(localized: "Scroll more slowly"))
        case .reachedLimit:
            hint = String(localized: "Maximum length reached")
        default:
            break
        }
        updateStatus()
        continueAfterGrab()
    }

    /// After a grab comes back or a stitch is done: the next grab, or once Done's
    /// last grab is stitched, the image.
    private func continueAfterGrab() {
        if isFinishing {
            guard !captureInFlight else { return }
            if !finalGrabStarted {
                capture()
            } else if pendingStitches == 0 {
                deliver()
            }
            return
        }
        if captureRequested { requestCapture() }
    }

    private func deliver() {
        stitchQueue.async { [weak self] in
            guard let self else { return }
            let image = self.stitcher.makeImage()
            DispatchQueue.main.async {
                guard !self.isEnded else { return }
                self.end()
                self.onFinish?(image)
            }
        }
    }

    // MARK: Status

    private func showHint(_ text: String) {
        guard !stitcher.isAtLimit else { return }
        hint = text
        hintResetTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hint = nil
            self.updateStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        hintResetTimer = timer
    }

    private func updateStatus() {
        if let hint {
            controlPanel?.setStatus(hint)
        } else if stitchedHeight > 0 {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: stitchedHeight), number: .decimal)
            controlPanel?.setStatus(String(localized: "\(formatted) px tall"))
        }
    }
}

// MARK: - Frame

/// Border drawn just outside the region, so it never sits on captured pixels.
private final class ScrollingFrameView: NSView {
    static let borderWidth: CGFloat = 2
    private let inset: CGFloat

    init(frame: NSRect, inset: CGFloat) {
        self.inset = inset
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let half = Self.borderWidth / 2
        let ring = bounds.insetBy(dx: inset - half, dy: inset - half)
        // A dark hairline outside the accent ring keeps it visible on any content.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let outer = NSBezierPath(rect: ring.insetBy(dx: -half - 0.5, dy: -half - 0.5))
        outer.lineWidth = 1
        outer.stroke()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: ring)
        path.lineWidth = Self.borderWidth
        path.stroke()
    }
}

// MARK: - Done / Cancel bar

/// Small bar in the editor toolbar's style: live height, Cancel, Done.
/// Esc cancels and Return finishes while it is key.
final class ScrollingControlPanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let doneButton: HoverStateButton
    private let cancelButton: HoverStateButton

    private static let statusWidth: CGFloat = 150

    init() {
        let size = AnnotationToolbarChrome.buttonSize
        let spacing = AnnotationToolbarChrome.spacing
        let edge = AnnotationToolbarChrome.edgeInset
        let height = AnnotationToolbarChrome.height
        let width = edge + Self.statusWidth + spacing * 2 + 1 + spacing * 2 + size + spacing + size + edge

        cancelButton = AnnotationToolbarChrome.makeButton(
            icon: "xmark",
            title: String(localized: "Cancel"),
            tooltip: AnnotationToolShortcuts.tooltip(String(localized: "Cancel"), fixedKey: AnnotationToolShortcuts.FixedKey.escape)
        )
        doneButton = AnnotationToolbarChrome.makeButton(
            icon: "checkmark",
            title: String(localized: "Done"),
            tooltip: AnnotationToolShortcuts.tooltip(String(localized: "Done"), fixedKey: AnnotationToolShortcuts.FixedKey.return)
        )

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = kScreenshotOverlayBaseLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        AnnotationToolbarChrome.applyContainerChrome(container)

        let buttonY = (height - size) / 2
        var x = edge
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .left
        let labelHeight = statusLabel.intrinsicContentSize.height
        statusLabel.frame = NSRect(x: x + 2, y: (height - labelHeight) / 2, width: Self.statusWidth - 2, height: labelHeight)
        container.addSubview(statusLabel)
        x += Self.statusWidth + spacing
        container.addSubview(AnnotationToolbarChrome.makeDivider(atX: x, buttonY: buttonY, buttonSize: size))
        x += 1 + spacing * 2

        for (button, action) in [(cancelButton, #selector(cancelClicked)), (doneButton, #selector(doneClicked))] {
            button.frame = NSRect(x: x, y: buttonY, width: size, height: size)
            button.target = self
            button.action = action
            button.onHoverChanged = { [weak button] _ in
                guard let button else { return }
                AnnotationToolbarChrome.applyButtonBackground(button: button, isSelected: false)
            }
            container.addSubview(button)
            x += size + spacing
        }
        doneButton.identifier = NSUserInterfaceItemIdentifier("scrolling.done")
        cancelButton.identifier = NSUserInterfaceItemIdentifier("scrolling.cancel")
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// While the last grab is stitched: no second Done, no Cancel racing it.
    func setBusy(_ busy: Bool) {
        doneButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        if busy { setStatus(String(localized: "Stitching…")) }
    }

    /// Caught here rather than in `keyDown`, so no responder in between can eat them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch event.keyCode {
            case 53:                         // Esc
                onCancel?()
                return
            case 36, 76:                     // Return, keypad Enter
                onDone?()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    @objc private func doneClicked() { onDone?() }
    @objc private func cancelClicked() { onCancel?() }
}
