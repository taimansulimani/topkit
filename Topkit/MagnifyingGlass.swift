import AppKit
import CoreGraphics

// Custom view that handles keyboard and mouse events
class MagnifierEventView: NSView {
    var onEscape: (() -> Void)?
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    var onMouseMoved: ((NSEvent) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
    }
    
    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(event)
    }
    
    override func mouseUp(with event: NSEvent) {
        onMouseUp?(event)
    }
    
    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(event)
    }
}

// Panel that can become key and won't be constrained to single screen
class MagnifierPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// Holds the UI elements for one screen
private struct ScreenOverlay {
    let panel: MagnifierPanel
    let rootView: MagnifierEventView
    let uiContainer: NSView
    let magnifierView: NSImageView
    let screen: NSScreen
}

final class MagnifyingGlass {
    // One overlay per screen
    private var overlays: [ScreenOverlay] = []
    private var activeOverlayIndex: Int = 0
    
    private var timer: Timer?
    private var localKeyMonitor: Any?
    private var mouseMonitor: Any?
    private var completion: (() -> Void)?
    private var isDragging = false
    private var lastMouseLocation: CGPoint = .zero
    private var toastWindow: NSWindow?
    private var updatesSincePermissionCheck: Int = 0
    
    private var shouldPlayNotificationSounds: Bool {
        UserDefaults.standard.bool(forKey: "playNotificationSounds")
    }
    
    private var shouldShowToastNotifications: Bool {
        UserDefaults.standard.bool(forKey: "showToastNotifications")
    }
    
    private static let magnifierSizeMin: CGFloat = 40
    private static let magnifierSizeMax: CGFloat = 800

    private var magnifierSize: CGFloat {
        let size = UserDefaults.standard.double(forKey: "magnifyingGlassSize")
        let value = size > 0 ? CGFloat(size) : 160.0
        return min(Self.magnifierSizeMax, max(Self.magnifierSizeMin, value))
    }
    
    private var captureSize: CGFloat {
        // 2x magnification means we capture half the size and display at full size
        return magnifierSize / 2.0
    }
    
    func start(completion: @escaping () -> Void) {
        self.completion = completion

        setupUI()
        setupMonitors()
        
        // Play sound and show toast
        if shouldPlayNotificationSounds {
            NSSound.beep()
        }
        showToast(message: "Magnify active")
        
        // Use higher frame rate for smoother cursor tracking (120fps)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(timer!, forMode: .common)
        
        // Set up mouse event monitor for smooth tracking and to detect drags
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            let mouse = NSEvent.mouseLocation
            self?.lastMouseLocation = mouse
            self?.updateMagnifier(at: mouse)
            
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                self?.isDragging = true
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                self?.isDragging = false
            default:
                break
            }
        }
        
        update()
    }
    
    private func setupUI() {
        let size = magnifierSize
        
        // Create one overlay per screen
        for (index, screen) in NSScreen.screens.enumerated() {
            let screenFrame = screen.frame
            let viewFrame = NSRect(origin: .zero, size: screenFrame.size)
            
            let panel = MagnifierPanel(
                contentRect: screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            panel.ignoresMouseEvents = true
            panel.setFrame(screenFrame, display: true)
            
            let root = MagnifierEventView(frame: viewFrame)
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor.clear.cgColor
            root.onEscape = { [weak self] in self?.cancelWithToast() }
            panel.contentView = root
            
            // UI container for magnifier
            let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            container.wantsLayer = true
            container.isHidden = true // Start hidden, show on active screen
            root.addSubview(container)
            
            // Magnifier view
            let mag = NSImageView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            mag.imageScaling = .scaleAxesIndependently
            mag.wantsLayer = true
            mag.layer?.cornerRadius = size / 2
            mag.layer?.masksToBounds = true
            mag.layer?.borderWidth = 0
            mag.layer?.magnificationFilter = .linear
            mag.layer?.minificationFilter = .linear
            mag.layer?.allowsEdgeAntialiasing = true
            container.addSubview(mag)
            
            panel.orderFront(nil)
            
            // Make first panel key
            if index == 0 {
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(root)
            }
            
            overlays.append(ScreenOverlay(
                panel: panel,
                rootView: root,
                uiContainer: container,
                magnifierView: mag,
                screen: screen
            ))
            
            debugLog("Magnifier: Created overlay \(index) for screen at \(screenFrame)")
        }
        
        NSCursor.crosshair.set()
    }
    
    private func setupMonitors() {
        // Local monitor only: a global keyDown monitor never fires in a sandboxed app
        // without Input Monitoring. The key panel + MagnifierEventView.keyDown cover ESC.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancelWithToast(); return nil }
            return e
        }
    }
    
    private func update() {
        // Check screen recording permission every ~1 second (120 frames at 120fps).
        // If revoked, cancel immediately — overlay panels at .screenSaver level
        // can visually block the user if left alive without permission.
        updatesSincePermissionCheck += 1
        if updatesSincePermissionCheck >= 120 {
            updatesSincePermissionCheck = 0
            if !PermissionManager.shared.hasScreenRecordingPermission() {
                cancelWithToast()
                return
            }
        }
        
        let mouse = NSEvent.mouseLocation
        updateMagnifier(at: mouse)
    }
    
    private func updateMagnifier(at mouse: CGPoint) {
        // Find which screen the mouse is on
        guard let screenIndex = overlays.firstIndex(where: { NSMouseInRect(mouse, $0.screen.frame, false) }) else {
            // Mouse is not on any screen - hide all
            for overlay in overlays {
                overlay.uiContainer.isHidden = true
            }
            return
        }
        
        // Show UI on active screen, hide on others
        for (index, overlay) in overlays.enumerated() {
            overlay.uiContainer.isHidden = (index != screenIndex)
        }
        
        let activeOverlay = overlays[screenIndex]
        activeOverlayIndex = screenIndex
        
        // Position UI within the active screen's panel
        positionUI(mouse, in: activeOverlay)

        // Capture and display magnified content
        if let img = captureScreen(at: mouse) {
            let size = magnifierSize
            let nsImg = createMagnifiedImage(from: img, size: size, scale: activeOverlay.screen.backingScaleFactor)
            activeOverlay.magnifierView.image = nsImg
        }
    }

    /// Live magnifier capture stays on `CGWindowListCreateImage` DELIBERATELY — see the
    /// matching note in LiveColorPicker.captureScreen: the per-frame ScreenCaptureKit
    /// replacement wedged blank on first use and swam sub-pixel under the lens. Deprecated
    /// but functional, synchronous, pixel-snapped, excludes our own panel via
    /// `.optionOnScreenBelowWindow`. Revisit only with a hardware-verified SCStream port.
    private func captureScreen(at mouse: CGPoint) -> CGImage? {
        guard NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) != nil else {
            return nil
        }

        // Convert Cocoa coordinates to Quartz coordinates
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let primaryHeight = primaryScreen.frame.height

        let quartzX = mouse.x
        let quartzY = primaryHeight - mouse.y

        let halfPoints = captureSize / 2
        let rect = CGRect(
            x: quartzX - halfPoints,
            y: quartzY - halfPoints,
            width: captureSize,
            height: captureSize
        )

        // Get the window number to exclude from capture
        let windowNumber = overlays.isEmpty ? 0 : overlays[activeOverlayIndex].panel.windowNumber

        return CGWindowListCreateImage(
            rect,
            .optionOnScreenBelowWindow,
            CGWindowID(windowNumber),
            .bestResolution
        )
    }
    
    private func positionUI(_ mouse: CGPoint, in overlay: ScreenOverlay) {
        let screenFrame = overlay.screen.frame
        
        // Convert global mouse to panel-local coords (panel frame matches screen frame)
        let local = CGPoint(
            x: mouse.x - screenFrame.origin.x,
            y: mouse.y - screenFrame.origin.y
        )
        
        // Center magnifier on cursor
        let size = magnifierSize
        let origin = CGPoint(
            x: local.x - size/2,
            y: local.y - size/2
        )
        overlay.uiContainer.setFrameOrigin(origin)
    }
    
    private func createMagnifiedImage(from cgImage: CGImage, size: CGFloat, scale: CGFloat) -> NSImage {
        let pixelSize = max(1, Int(size * scale))
        
        let bytesPerRow = pixelSize * 4
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: bytesPerRow,
            bitsPerPixel: 32
        ) else {
            return createMagnifiedImageLegacy(from: cgImage, size: size)
        }
        
        let targetRect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.shouldAntialias = true
        
        let tempImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        tempImage.draw(
            in: targetRect,
            from: NSRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height),
            operation: .sourceOver,
            fraction: 1.0
        )
        
        NSGraphicsContext.restoreGraphicsState()
        
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.addRepresentation(rep)
        return nsImage
    }
    
    private func createMagnifiedImageLegacy(from cgImage: CGImage, size: CGFloat) -> NSImage {
        let tempImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        tempImage.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: NSRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height),
            operation: .sourceOver,
            fraction: 1.0
        )
        nsImage.unlockFocus()
        return nsImage
    }
    
    func cancel() {
        cleanup(clearToast: true)
        completion?()
    }
    
    func cancelWithToast() {
        if shouldPlayNotificationSounds {
            NSSound.beep()
        }
        showToast(message: "Magnify ended")
        cleanup(clearToast: false)
        completion?()
    }
    
    private func showToast(message: String) {
        guard shouldShowToastNotifications else { return }
        
        toastWindow?.orderOut(nil)
        toastWindow = nil
        
        let tempLabel = NSTextField(labelWithString: message)
        tempLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textSize = tempLabel.sizeThatFits(NSSize(width: 1000, height: 18))
        let horizontalPadding: CGFloat = 12
        let actualTextWidth = textSize.width
        let toastWidth: CGFloat = horizontalPadding + actualTextWidth + horizontalPadding
        let toastHeight: CGFloat = 36
        
        guard let screen = MultiMonitorHelper.screenWithMouse else { return }
        let toastX = screen.frame.midX - toastWidth / 2
        let toastY = screen.frame.maxY - 80
        
        let toast = NSWindow(
            contentRect: NSRect(x: toastX, y: toastY, width: toastWidth, height: toastHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.level = .floating
        toast.collectionBehavior = [.canJoinAllSpaces, .stationary]
        toast.ignoresMouseEvents = true
        toast.appearance = NSApp.effectiveAppearance
        
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight))
        ToastChrome.styleContainer(contentView)
        
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = ToastChrome.primaryLabelColor()
        label.frame = NSRect(x: horizontalPadding, y: 9, width: actualTextWidth, height: 18)
        contentView.addSubview(label)
        
        toast.contentView = contentView
        toast.alphaValue = 0
        toast.orderFront(nil)
        
        toastWindow = toast
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            toast.animator().alphaValue = 1
        })
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                toast.animator().alphaValue = 0
            }) {
                toast.orderOut(nil)
            }
        }
    }
    
    private func cleanup(clearToast: Bool = true) {
        timer?.invalidate()
        timer = nil
        
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        localKeyMonitor = nil
        mouseMonitor = nil
        
        isDragging = false
        NSCursor.arrow.set()
        
        if clearToast {
            toastWindow?.orderOut(nil)
            toastWindow = nil
        }
        
        // Close all panels
        for overlay in overlays {
            overlay.panel.orderOut(nil)
        }
        overlays.removeAll()
    }
}
