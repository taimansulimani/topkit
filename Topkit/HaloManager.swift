import Foundation
import AppKit
import CoreGraphics

/// Holds the window and view for one screen
private struct HaloScreenOverlay {
    let window: NSWindow
    let view: HaloView
    let screen: NSScreen
}

class HaloManager: ObservableObject {
    static let shared = HaloManager()
    
    @Published var isHaloActive = false
    
    private var overlays: [HaloScreenOverlay] = []
    private var localKeyMonitor: Any?
    private var updateTimer: Timer?
    private var toastWindow: NSWindow?
    
    private var shouldPlayNotificationSounds: Bool {
        UserDefaults.standard.bool(forKey: "playNotificationSounds")
    }
    
    private var shouldShowToastNotifications: Bool {
        UserDefaults.standard.bool(forKey: "showToastNotifications")
    }
    
    // Callback for status bar icon update
    var onHaloStateChanged: ((Bool) -> Void)?
    
    private init() {}
    
    func startHalo() {
        if isHaloActive {
            stopHalo()
            return
        }
        (NSApp.delegate as? AppDelegate)?.orderOutPreferencesWindowForToolOverlay()
        isHaloActive = true
        EscapeCascade.push(.halo)
        onHaloStateChanged?(true)
        setupOverlay()
        setupKeyMonitor()
        setupUpdateTimer()
        if shouldPlayNotificationSounds {
            NSSound.beep()
        }
        showToast(message: "Halo active")
    }
    
    func stopHalo() {
        guard isHaloActive else { return }
        
        isHaloActive = false
        EscapeCascade.pop(.halo)
        onHaloStateChanged?(false)
        
        if shouldPlayNotificationSounds {
            NSSound.beep()
        }
        showToast(message: "Halo ended")
        
        cleanup()
    }

    /// Used by `EscapeCascade` while a screen recording owns the global Esc hotkey.
    @discardableResult
    func consumeEscape() -> Bool {
        guard isHaloActive else { return false }
        stopHalo()
        return true
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
    
    private func setupOverlay() {
        // Create one window per screen
        for (index, screen) in NSScreen.screens.enumerated() {
            let screenFrame = screen.frame
            let viewFrame = NSRect(origin: .zero, size: screenFrame.size)
            
            let window = MultiMonitorWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.acceptsMouseMovedEvents = false
            window.setFrame(screenFrame, display: true)
            
            let view = HaloView(frame: viewFrame)
            view.screenFrame = screenFrame // Pass screen frame for coordinate conversion
            window.contentView = view
            
            window.orderFront(nil)
            
            if index == 0 {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            
            overlays.append(HaloScreenOverlay(window: window, view: view, screen: screen))
            debugLog("Halo: Created overlay \(index) for screen at \(screenFrame)")
        }
    }
    
    private func setupKeyMonitor() {
        // Local monitor only: a global keyDown monitor never fires in a sandboxed app
        // without Input Monitoring.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.stopHalo()
                return nil
            }
            return event
        }
    }
    
    private func setupUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.updateCursorPosition()
        }
        RunLoop.main.add(updateTimer!, forMode: .common)
        
        DispatchQueue.main.async { [weak self] in
            self?.updateCursorPosition()
        }
    }
    
    private func updateCursorPosition() {
        let mouseLocation = NSEvent.mouseLocation
        
        // Find which screen contains the mouse
        for overlay in overlays {
            let isOnThisScreen = NSMouseInRect(mouseLocation, overlay.screen.frame, false)
            overlay.view.isActive = isOnThisScreen
            
            if isOnThisScreen {
                overlay.view.updateCursorPosition(mouseLocation)
            }
        }
    }
    
    private func cleanup() {
        updateTimer?.invalidate()
        updateTimer = nil
        
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        
        for overlay in overlays {
            overlay.window.orderOut(nil)
        }
        overlays.removeAll()
    }
}

// MARK: - Halo View

class HaloView: NSView {
    private var cursorPosition: NSPoint = .zero
    var screenFrame: NSRect = .zero // Set by HaloManager
    var isActive: Bool = false {
        didSet {
            setNeedsDisplay(bounds)
        }
    }
    
    private static let haloSizeMin: CGFloat = 40
    private static let haloSizeMax: CGFloat = 800

    private var haloSize: CGFloat {
        let size = UserDefaults.standard.double(forKey: "haloSize")
        let value = size > 0 ? CGFloat(size) : 160.0
        return min(Self.haloSizeMax, max(Self.haloSizeMin, value))
    }
    
    private var haloRadius: CGFloat {
        return haloSize / 2.0
    }
    
    private var haloThickness: CGFloat {
        return max(2.0, haloSize / 40.0)
    }
    
    private var haloColor: NSColor {
        let defaults = UserDefaults.standard
        let r = CGFloat(defaults.double(forKey: "haloColorRed"))
        let g = CGFloat(defaults.double(forKey: "haloColorGreen"))
        let b = CGFloat(defaults.double(forKey: "haloColorBlue"))
        let a = CGFloat(defaults.double(forKey: "haloColorAlpha"))
        return NSColor(red: r, green: g, blue: b, alpha: a > 0 ? a : 1.0)
    }
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func preferencesChanged() {
        setNeedsDisplay(bounds)
    }
    
    func updateCursorPosition(_ screenPosition: NSPoint) {
        // Convert screen coordinates to view coordinates (view origin is 0,0)
        let viewPosition = NSPoint(
            x: screenPosition.x - screenFrame.origin.x,
            y: screenPosition.y - screenFrame.origin.y
        )
        
        cursorPosition = viewPosition
        setNeedsDisplay(bounds)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Only draw if this is the active screen
        guard isActive else { return }
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let center = cursorPosition
        
        let haloPath = NSBezierPath()
        haloPath.appendArc(
            withCenter: center,
            radius: haloRadius,
            startAngle: 0,
            endAngle: 360,
            clockwise: false
        )
        
        let color = haloColor
        
        context.setShadow(offset: .zero, blur: 12, color: color.withAlphaComponent(0.5).cgColor)
        
        color.setStroke()
        haloPath.lineWidth = haloThickness
        haloPath.stroke()
        
        let innerPath = NSBezierPath()
        innerPath.appendArc(
            withCenter: center,
            radius: haloRadius - 2,
            startAngle: 0,
            endAngle: 360,
            clockwise: false
        )
        color.withAlphaComponent(0.6).setStroke()
        innerPath.lineWidth = 1.0
        innerPath.stroke()
        
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }
}
