import AppKit

/// Passive toast chrome (no key); shared by the screenshot and recording flows.
private final class PassiveToastWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Centralised toast presentation (was private to ScreenshotManager).
/// Honours the "showToastNotifications" preference unless `force` is true.
final class ToastPresenter {
    static let shared = ToastPresenter()
    private var toastWindow: NSWindow?
    private init() {}

    func show(message: String, windowLevel: NSWindow.Level? = nil, force: Bool = false) {
        let showToasts = UserDefaults.standard.bool(forKey: "showToastNotifications")
        if !force && !showToasts { return }

        toastWindow?.orderOut(nil)
        toastWindow = nil

        // Calculate toast size based on message - wrap tightly around content
        let tempLabel = NSTextField(labelWithString: message)
        tempLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textSize = tempLabel.sizeThatFits(NSSize(width: 1000, height: 18))
        let horizontalPadding: CGFloat = 12
        let actualTextWidth = textSize.width
        let toastWidth: CGFloat = horizontalPadding + actualTextWidth + horizontalPadding
        let toastHeight: CGFloat = 36

        // Show toast on the screen where the mouse is located
        guard let screen = MultiMonitorHelper.screenWithMouse else { return }
        let toastX = screen.frame.midX - toastWidth / 2
        let toastY = screen.frame.maxY - 80

        let toast = PassiveToastWindow(
            contentRect: NSRect(x: toastX, y: toastY, width: toastWidth, height: toastHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.level = windowLevel ?? .floating
        toast.collectionBehavior = [.canJoinAllSpaces, .stationary]
        toast.ignoresMouseEvents = true
        toast.appearance = NSApp.effectiveAppearance
        toast.animationBehavior = .none

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight))
        ToastChrome.styleContainer(contentView)

        // Label - width exactly matches text width
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = ToastChrome.primaryLabelColor()
        label.frame = NSRect(x: horizontalPadding, y: 9, width: actualTextWidth, height: 18)
        contentView.addSubview(label)

        toast.contentView = contentView
        toast.alphaValue = 0
        toast.orderFrontRegardless()
        toastWindow = toast

        // Animate in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            toast.animator().alphaValue = 1
        })

        // Animate out after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                toast.animator().alphaValue = 0
            }) {
                toast.orderOut(nil)
            }
        }
    }
}
