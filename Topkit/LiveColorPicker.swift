import AppKit
import CoreGraphics

// Custom view that handles keyboard and mouse events
class PickerEventView: NSView {
    var onEscape: (() -> Void)?
    var onClick: ((Bool) -> Void)? // Bool indicates if shift was held
    var onShiftChange: ((Bool) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
    }
    
    override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags.contains(.shift))
    }
    
    override func flagsChanged(with event: NSEvent) {
        onShiftChange?(event.modifierFlags.contains(.shift))
    }
}

// Panel that can become key and won't be constrained to single screen
class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// Holds the UI elements for one screen
private struct PickerScreenOverlay {
    let panel: PickerPanel
    let rootView: PickerEventView
    let uiContainer: NSView
    let magnifierView: NSImageView
    let crosshairView: NSView
    let hexLabel: NSTextField
    let colorDot: NSView
    let shiftHintLabel: NSTextField
    let screen: NSScreen
}

final class LiveColorPicker {
    // One overlay per screen
    private var overlays: [PickerScreenOverlay] = []
    private var activeOverlayIndex: Int = 0
    
    private var toastWindow: NSWindow?
    private var timer: Timer?
    private var localKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var completion: ((NSColor?) -> Void)?
    private var onColorPicked: ((NSColor) -> Void)?
    private var lastColor: NSColor = .black
    private var lastImageWidth: Int = 0
    private var isShiftPressed: Bool = false
    private var framesSincePermissionCheck: Int = 0
    
    private var shouldPlayNotificationSounds: Bool {
        UserDefaults.standard.bool(forKey: "playNotificationSounds")
    }
    
    private var shouldShowToastNotifications: Bool {
        UserDefaults.standard.bool(forKey: "showToastNotifications")
    }
    
    private static let colorPickerSizeMin: CGFloat = 40
    private static let colorPickerSizeMax: CGFloat = 800

    private var magnifierSize: CGFloat {
        let size = UserDefaults.standard.double(forKey: "colorPickerSize")
        let value = size > 0 ? CGFloat(size) : 160.0
        return min(Self.colorPickerSizeMax, max(Self.colorPickerSizeMin, value))
    }
    
    private let captureSize: CGFloat = 15 // ODD number for center pixel alignment
    
    func start(onColorPicked: ((NSColor) -> Void)? = nil, completion: @escaping (NSColor?) -> Void) {
        self.completion = completion
        self.onColorPicked = onColorPicked

        setupUI()
        setupMonitors()
        
        if shouldPlayNotificationSounds {
            NSSound.beep()
        }
        showToast(message: String(localized: "Color picker active"))
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(timer!, forMode: .common)
        
        update()
    }
    
    func cancel() {
        if shouldPlayNotificationSounds {
            NSSound.beep()
        }
        showToast(message: String(localized: "Color picker ended"))
        cleanup()
        completion?(nil)
    }
    
    var isActive: Bool {
        return !overlays.isEmpty
    }
    
    private func setupUI() {
        let size = magnifierSize
        
        // Create one overlay per screen
        for (index, screen) in NSScreen.screens.enumerated() {
            let screenFrame = screen.frame
            let viewFrame = NSRect(origin: .zero, size: screenFrame.size)
            
            let panel = PickerPanel(
                contentRect: screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            panel.ignoresMouseEvents = false
            panel.setFrame(screenFrame, display: true)
            
            let root = PickerEventView(frame: viewFrame)
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor.clear.cgColor
            root.onEscape = { [weak self] in self?.cancel() }
            root.onClick = { [weak self] shiftHeld in self?.pick(multiSample: shiftHeld) }
            root.onShiftChange = { [weak self] isShift in self?.updateShiftState(isShift) }
            panel.contentView = root
            
            // UI container
            let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size + 32))
            container.wantsLayer = true
            container.isHidden = true // Start hidden
            root.addSubview(container)
            
            // Magnifier
            let mag = NSImageView(frame: NSRect(x: 0, y: 32, width: size, height: size))
            mag.imageScaling = .scaleAxesIndependently
            mag.wantsLayer = true
            mag.layer?.cornerRadius = size / 2
            mag.layer?.masksToBounds = true
            mag.layer?.borderWidth = 2
            mag.layer?.borderColor = NSColor.white.cgColor
            container.addSubview(mag)
            
            // Crosshair
            let ch = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            ch.wantsLayer = true
            ch.layer?.borderWidth = 1.5
            ch.layer?.borderColor = NSColor.white.cgColor
            ch.layer?.backgroundColor = NSColor.clear.cgColor
            container.addSubview(ch)
            
            // Hex pill
            let pill = NSView(frame: NSRect(x: (size - 85)/2, y: 2, width: 85, height: 26))
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
            pill.layer?.cornerRadius = 5
            container.addSubview(pill)
            
            let dot = NSView(frame: NSRect(x: 5, y: 4, width: 18, height: 18))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 9
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = NSColor.white.cgColor
            pill.addSubview(dot)
            
            let lbl = NSTextField(labelWithString: "#000000")
            lbl.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            lbl.textColor = .white
            lbl.frame = NSRect(x: 26, y: 5, width: 56, height: 14)
            pill.addSubview(lbl)
            
            // Shift hint label
            let shiftHint = NSTextField(labelWithString: "⇧ hold for multi-sample")
            shiftHint.font = .systemFont(ofSize: 9, weight: .regular)
            shiftHint.textColor = NSColor(white: 0.6, alpha: 1)
            shiftHint.alignment = .center
            shiftHint.frame = NSRect(x: 0, y: -16, width: size, height: 14)
            container.addSubview(shiftHint)
            
            panel.orderFront(nil)
            
            if index == 0 {
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(root)
            }
            
            overlays.append(PickerScreenOverlay(
                panel: panel,
                rootView: root,
                uiContainer: container,
                magnifierView: mag,
                crosshairView: ch,
                hexLabel: lbl,
                colorDot: dot,
                shiftHintLabel: shiftHint,
                screen: screen
            ))
            
            debugLog("ColorPicker: Created overlay \(index) for screen at \(screenFrame)")
        }
        
        NSCursor.crosshair.set()
    }
    
    private func setupMonitors() {
        // Local monitors only: global keyDown/flagsChanged monitors never fire in a
        // sandboxed app without Input Monitoring. The key panel + PickerEventView's
        // keyDown/flagsChanged handle the non-monitor path.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancel(); return nil }
            return e
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.updateShiftState(e.modifierFlags.contains(.shift))
            return e
        }
    }
    
    private func updateShiftState(_ isShift: Bool) {
        isShiftPressed = isShift
        
        // Update all overlays
        for overlay in overlays {
            if isShift {
                overlay.shiftHintLabel.stringValue = "⇧ multi-sample active"
                overlay.shiftHintLabel.textColor = NSColor.systemGreen
            } else {
                overlay.shiftHintLabel.stringValue = "⇧ hold for multi-sample"
                overlay.shiftHintLabel.textColor = NSColor(white: 0.6, alpha: 1)
            }
        }
    }
    
    private func update() {
        // Check screen recording permission every ~1 second (60 frames at 60fps).
        // If revoked, cancel immediately — overlay panels at .screenSaver level
        // block all mouse input system-wide if left alive without permission.
        framesSincePermissionCheck += 1
        if framesSincePermissionCheck >= 60 {
            framesSincePermissionCheck = 0
            if !PermissionManager.shared.hasScreenRecordingPermission() {
                cancel()
                return
            }
        }
        
        let mouse = NSEvent.mouseLocation
        
        // Find which screen the mouse is on
        guard let screenIndex = overlays.firstIndex(where: { NSMouseInRect(mouse, $0.screen.frame, false) }) else {
            for overlay in overlays {
                overlay.uiContainer.isHidden = true
            }
            return
        }
        
        // Show UI on active screen only
        for (index, overlay) in overlays.enumerated() {
            overlay.uiContainer.isHidden = (index != screenIndex)
        }
        
        // Reset image width tracking when switching screens so crosshair gets updated
        if screenIndex != activeOverlayIndex {
            lastImageWidth = 0
        }
        
        let activeOverlay = overlays[screenIndex]
        activeOverlayIndex = screenIndex
        
        positionUI(mouse, in: activeOverlay)

        if let img = captureScreen(at: mouse), let color = getPixelColor(from: img) {
            lastColor = color
            let hex = String(format: "#%02X%02X%02X",
                Int(color.redComponent * 255),
                Int(color.greenComponent * 255),
                Int(color.blueComponent * 255))

            if img.width != lastImageWidth {
                lastImageWidth = img.width
                updateCrosshairSize(imageWidth: img.width, in: activeOverlay)
            }

            let size = magnifierSize
            let nsImg = createPixelatedImage(from: img, size: size)
            activeOverlay.magnifierView.image = nsImg
            activeOverlay.hexLabel.stringValue = hex
            activeOverlay.colorDot.layer?.backgroundColor = color.cgColor
        }
    }

    /// Live loupe capture stays on `CGWindowListCreateImage` DELIBERATELY. The
    /// ScreenCaptureKit replacement (SCScreenshotManager per frame) shipped broken in the
    /// field twice: first session wedged blank until the tool was reopened, and fractional
    /// sourceRects resample so the pixel grid swims under the lens. The CG call is
    /// deprecated (macOS 14) but fully functional, synchronous, pixel-snapped, and excludes
    /// our own overlay via `.optionOnScreenBelowWindow` — exactly the semantics this tool
    /// needs. Revisit only with a real SCStream implementation verified on hardware.
    private func captureScreen(at mouse: CGPoint) -> CGImage? {
        guard NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) != nil else {
            return nil
        }

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

        let windowNumber = overlays.isEmpty ? 0 : overlays[activeOverlayIndex].panel.windowNumber

        return CGWindowListCreateImage(
            rect,
            .optionOnScreenBelowWindow,
            CGWindowID(windowNumber),
            .nominalResolution
        )
    }
    
    private func updateCrosshairSize(imageWidth: Int, in overlay: PickerScreenOverlay) {
        let size = magnifierSize
        let pixelSize = size / CGFloat(imageWidth)
        
        overlay.crosshairView.frame = NSRect(
            x: size/2 - pixelSize/2,
            y: 32 + size/2 - pixelSize/2,
            width: pixelSize,
            height: pixelSize
        )
    }
    
    private func positionUI(_ mouse: CGPoint, in overlay: PickerScreenOverlay) {
        let screenFrame = overlay.screen.frame
        
        let local = CGPoint(
            x: mouse.x - screenFrame.origin.x,
            y: mouse.y - screenFrame.origin.y
        )
        
        let size = magnifierSize
        let origin = CGPoint(
            x: local.x - size/2,
            y: local.y - (32 + size/2)
        )
        overlay.uiContainer.setFrameOrigin(origin)
    }
    
    private func createPixelatedImage(from cgImage: CGImage, size: CGFloat) -> NSImage {
        let imgWidth = cgImage.width
        let imgHeight = cgImage.height
        let pixelSize = size / CGFloat(imgWidth)
        
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.lockFocus()
        
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let pixelData = CFDataGetBytePtr(data) else {
            nsImage.unlockFocus()
            return NSImage(size: NSSize(width: size, height: size))
        }
        
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        let isBGRA = cgImage.bitmapInfo.contains(.byteOrder32Little)
        
        for y in 0..<imgHeight {
            for x in 0..<imgWidth {
                let offset = y * bytesPerRow + x * bytesPerPixel
                
                let r: CGFloat
                let g: CGFloat
                let b: CGFloat
                
                if isBGRA {
                    b = CGFloat(pixelData[offset]) / 255.0
                    g = CGFloat(pixelData[offset + 1]) / 255.0
                    r = CGFloat(pixelData[offset + 2]) / 255.0
                } else {
                    r = CGFloat(pixelData[offset]) / 255.0
                    g = CGFloat(pixelData[offset + 1]) / 255.0
                    b = CGFloat(pixelData[offset + 2]) / 255.0
                }
                
                let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                color.setFill()
                
                let rect = NSRect(
                    x: CGFloat(x) * pixelSize,
                    y: CGFloat(imgHeight - 1 - y) * pixelSize,
                    width: pixelSize,
                    height: pixelSize
                )
                rect.fill()
            }
        }
        
        nsImage.unlockFocus()
        return nsImage
    }
    
    private func getPixelColor(from image: CGImage) -> NSColor? {
        let w = image.width
        let h = image.height
        
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        
        let cx = w / 2
        let cy = h / 2
        let offset = cy * bytesPerRow + cx * bytesPerPixel
        
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        
        if image.bitmapInfo.contains(.byteOrder32Little) {
            b = CGFloat(ptr[offset]) / 255.0
            g = CGFloat(ptr[offset + 1]) / 255.0
            r = CGFloat(ptr[offset + 2]) / 255.0
        } else {
            r = CGFloat(ptr[offset]) / 255.0
            g = CGFloat(ptr[offset + 1]) / 255.0
            b = CGFloat(ptr[offset + 2]) / 255.0
        }
        
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    
    private func pick(multiSample: Bool = false) {
        let color = lastColor
        
        if shouldPlayNotificationSounds {
            NSSound.beep()
        }
        
        onColorPicked?(color)
        showColorToast(for: color)
        
        if multiSample {
            flashFeedback()
        } else {
            cleanup()
            completion?(color)
        }
    }
    
    private func flashFeedback() {
        guard !overlays.isEmpty else { return }
        let mag = overlays[activeOverlayIndex].magnifierView
        
        let originalBorderColor = mag.layer?.borderColor
        mag.layer?.borderColor = NSColor.systemGreen.cgColor
        mag.layer?.borderWidth = 4
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            mag.layer?.borderColor = originalBorderColor
            mag.layer?.borderWidth = 2
        }
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
    
    private func showColorToast(for color: NSColor) {
        guard shouldShowToastNotifications else { return }
        
        toastWindow?.orderOut(nil)
        toastWindow = nil
        
        let hex = String(format: "#%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255))
        
        let tempLabel = NSTextField(labelWithString: hex)
        tempLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
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
        
        let label = NSTextField(labelWithString: hex)
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
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
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            let isCurrentToast = self?.toastWindow === toast
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                toast.animator().alphaValue = 0
            }) {
                toast.orderOut(nil)
                if isCurrentToast {
                    self?.toastWindow = nil
                }
            }
        }
    }
    
    private func cleanup() {
        timer?.invalidate()
        timer = nil
        
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        localKeyMonitor = nil
        localFlagsMonitor = nil
        
        NSCursor.arrow.set()
        
        for overlay in overlays {
            overlay.panel.orderOut(nil)
        }
        overlays.removeAll()
    }
}
