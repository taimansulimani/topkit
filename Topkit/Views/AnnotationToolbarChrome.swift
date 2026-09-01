import AppKit

/// Button that tracks hover so toolbars can render a hover background.
///
/// Lives here rather than in `ScreenshotAnnotationView` so both the screenshot
/// editor's toolbar and the Annotate overlay's tool strip can use it.
final class HoverStateButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            onHoverChanged?(isHovered)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            // .activeAlways, not .activeInKeyWindow: the Annotate overlay is often
            // not key (click-through), and hover must still respond there.
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        // AppKit's own tooltip opens behind the overlay window, so present our own.
        AnnotationTooltip.shared.scheduleShow(for: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        AnnotationTooltip.shared.hide(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        AnnotationTooltip.shared.hide(for: self)
        super.mouseDown(with: event)
    }

    /// The toolbars rebuild their buttons, and the overlay tears down while a button
    /// is still hovered — either way the tooltip has to go with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            AnnotationTooltip.shared.hide(for: self)
        }
    }
}

/// The single source of truth for annotation toolbar appearance.
///
/// The screenshot editor's toolbar and the Annotate overlay's tool strip both go
/// through here, so they cannot drift apart the way the two annotation renderers
/// did. Change a value here and both surfaces follow.
enum AnnotationToolbarChrome {

    // MARK: - Metrics

    static let height: CGFloat = 36
    static let sliderRowHeight: CGFloat = 28
    static let buttonSize: CGFloat = 28
    static let spacing: CGFloat = 4
    static let edgeInset: CGFloat = 6
    static let cornerRadius: CGFloat = 5
    static let buttonCornerRadius: CGFloat = 4
    static let symbolPointSize: CGFloat = 12
    static let dividerHeight: CGFloat = 18

    /// Vertical inset that centres a `buttonSize` button in a `height` bar.
    static var buttonY: CGFloat { (height - buttonSize) / 2 }

    // MARK: - Identifiers
    //
    // Toolbars used to be identified in tests by `cornerRadius == 5 && height == 36`.
    // Now that more than one surface shares that exact styling, geometry no longer
    // identifies anything — these do.

    enum Identifier {
        static let editorToolbar = NSUserInterfaceItemIdentifier("annotation.editor.toolbar")
        static let editorSliderRow = NSUserInterfaceItemIdentifier("annotation.editor.sliderRow")
        static let annotateToolStrip = NSUserInterfaceItemIdentifier("annotate.toolStrip")
    }

    // MARK: - Container

    /// Background, border, and appearance for a toolbar container, in both themes.
    static func applyContainerChrome(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            view.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
            view.layer?.borderWidth = 0
            view.layer?.borderColor = nil
            view.appearance = NSAppearance(named: .darkAqua)
        } else {
            view.layer?.backgroundColor = NSColor(white: 0.96, alpha: 0.97).cgColor
            view.layer?.borderWidth = 0.5
            view.layer?.borderColor = NSColor(white: 0.68, alpha: 0.85).cgColor
            view.appearance = NSAppearance(named: .aqua)
        }
    }

    // MARK: - Buttons

    /// `tooltip` defaults to the title; pass it when the hover text carries more than
    /// the name (the tool shortcut, typically).
    static func makeButton(icon: String, title: String, tooltip: String? = nil) -> HoverStateButton {
        let button = HoverStateButton(frame: .zero)
        button.title = ""
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = tooltip ?? title
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
            button.image = image.withSymbolConfiguration(config)
        }
        button.wantsLayer = true
        button.layer?.cornerRadius = buttonCornerRadius
        button.layer?.backgroundColor = NSColor.clear.cgColor
        return button
    }

    /// Selected / menu-pressed / hover background, matching the editor toolbar.
    static func applyButtonBackground(button: NSButton, isSelected: Bool, isMenuPressed: Bool = false) {
        let isHovered = (button as? HoverStateButton)?.isHovered ?? false
        let background: NSColor
        if isMenuPressed {
            background = NSColor.systemBlue.withAlphaComponent(0.42)
        } else if isSelected {
            background = NSColor.systemBlue.withAlphaComponent(0.3)
        } else if isHovered {
            background = NSColor.systemBlue.withAlphaComponent(0.16)
        } else {
            background = .clear
        }
        button.layer?.backgroundColor = background.cgColor
    }

    // MARK: - Divider

    static func makeDivider(atX x: CGFloat, buttonY: CGFloat, buttonSize: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(
            x: x,
            y: buttonY + (buttonSize - dividerHeight) / 2,
            width: 1,
            height: dividerHeight
        ))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }
}
