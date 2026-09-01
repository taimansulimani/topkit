import AppKit

/// Custom view for a clipboard history row in the status/cursor menus.
///
/// Replaces the plain NSMenuItem rendering so a pin button can live at the
/// trailing edge: hidden until the row is hovered (or keyboard-highlighted),
/// always visible once the item is pinned (filled pin = toggled on).
/// Everything else mimics a native Sonoma menu row — accent-coloured rounded
/// highlight inset from the edges, menu font, leading icon (image preview or
/// hex swatch).
///
/// NSMenu does not draw highlights or dispatch clicks for view-backed items,
/// so this view tracks hover itself, draws the selection, and forwards a
/// click to `onSelect`. Keyboard highlight arrives from the menu delegate via
/// `isMenuHighlighted` (see AppDelegate.menu(_:willHighlight:)); Return on a
/// highlighted row still fires the NSMenuItem's action through AppKit.
final class ClipboardRowMenuView: NSView {

    /// Click anywhere on the row except the pin button: copy this item.
    var onSelect: (() -> Void)?
    /// Click on the pin button: toggle the item's pinned state.
    var onTogglePin: (() -> Void)?

    /// Set from the menu delegate when keyboard navigation highlights this row.
    /// The highlighted row grabs first-responder status: the menu tracking
    /// session hands key events to the menu window's first responder when one
    /// exists (that's how the search field receives typing), and it's the ONLY
    /// reliable way to see Return here — AppKit's own Return handling for a
    /// view-backed item just dismisses the menu without firing the action, and
    /// local keyDown monitors never see menu-tracking key events at all.
    var isMenuHighlighted = false {
        didSet {
            guard isMenuHighlighted != oldValue else { return }
            updateAppearance()
            syncFirstResponderToHighlight()
        }
    }

    private(set) var isPinned = false
    private(set) var titleText = ""
    /// Shown in the tooltip in place of text: image rows have no hover text, they
    /// preview themselves at the size set by "Tooltip size". Resolved on hover rather
    /// than at menu-build time — a full-size decode per row would be paid for every
    /// row, and almost none of them get hovered.
    private(set) var tooltipImageProvider: (() -> NSImage?)?
    var tooltipImage: NSImage? { tooltipImageProvider?() }

    /// Hover text is presented by our own panel. A view-backed menu item gets no
    /// tooltip from AppKit at all: NSMenu only draws them for items it draws itself,
    /// and `NSToolTipManager` never arms inside the menu's tracking loop — so the
    /// `toolTip` set in `configure` would simply never be seen. Injectable for tests.
    var tooltipPresenter: HoverTooltipPresenting = AnnotationTooltip.shared

    private let highlightView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .selection
        view.state = .active
        view.isEmphasized = true
        view.blendingMode = .behindWindow
        view.maskImage = ClipboardRowMenuView.highlightMask(cornerRadius: 4)
        view.isHidden = true
        return view
    }()

    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        return view
    }()

    private let titleField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.menuFont(ofSize: 0)
        field.lineBreakMode = .byTruncatingTail
        field.textColor = .labelColor
        return field
    }()

    private let pinButton: NSButton = {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        return button
    }()

    private var mouseInside = false {
        didSet {
            guard mouseInside != oldValue else { return }
            updateAppearance()
            updateTooltip()
        }
    }

    /// Wraps the hover text rather than letting a 200-character clipboard preview
    /// stretch the panel across the display.
    static let tooltipMaxWidth: CGFloat = 320

    // Layout metrics tuned to match native menu rows on macOS 14+.
    private static let highlightInset: CGFloat = 5
    private static let contentLeading: CGFloat = 14
    private static let contentTrailing: CGFloat = 12
    private static let iconGap: CGFloat = 6
    private static let pinButtonSize: CGFloat = 20
    private static let pinGap: CGFloat = 8
    private static let textRowHeight: CGFloat = 22
    private static let minWidth: CGFloat = 250

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.textRowHeight))
        autoresizingMask = [.width]
        addSubview(highlightView)
        addSubview(iconView)
        addSubview(titleField)
        addSubview(pinButton)
        pinButton.target = self
        pinButton.action = #selector(pinButtonClicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// (Re)populates the row. Called at build time and again in place when a
    /// pin toggle reorders the open menu.
    func configure(
        title: String,
        image: NSImage?,
        isPinned: Bool,
        toolTip: String?,
        tooltipImageProvider: (() -> NSImage?)?
    ) {
        titleText = title
        self.isPinned = isPinned
        titleField.stringValue = title
        iconView.image = image
        iconView.isHidden = (image == nil)
        self.toolTip = toolTip
        self.tooltipImageProvider = tooltipImageProvider

        let symbolName = isPinned ? "pin.fill" : "pin"
        let label = isPinned ? String(localized: "Unpin Item") : String(localized: "Pin Item")
        pinButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        pinButton.toolTip = label
        pinButton.setAccessibilityLabel(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(isPinned ? "\(title), \(String(localized: "Pinned"))" : title)

        // Only size the row while it isn't being tracked in an open menu; an
        // in-place reorder keeps the row's existing frame (NSMenu won't
        // re-measure an open menu) and lets layout() fit content into it.
        if window == nil {
            frame.size = preferredSize(image: image, title: title)
        }
        needsLayout = true
        updateAppearance()
    }

    private func preferredSize(image: NSImage?, title: String) -> NSSize {
        let titleWidth = (title as NSString).size(withAttributes: [.font: titleField.font as Any]).width
        var width = Self.contentLeading + ceil(titleWidth) + Self.pinGap + Self.pinButtonSize + Self.contentTrailing
        var height = Self.textRowHeight
        if let image {
            width += image.size.width + Self.iconGap
            height = max(height, image.size.height + 6)
        }
        return NSSize(width: max(width, Self.minWidth), height: height)
    }

    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: Self.highlightInset, dy: 0)

        var x = Self.contentLeading
        if !iconView.isHidden, let image = iconView.image {
            // Fit the icon inside the row height so an in-place reorder that
            // lands an image in a shorter text row scales instead of clipping.
            let maxHeight = bounds.height - 4
            let scale = min(1, maxHeight / max(image.size.height, 1))
            let iconSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            iconView.frame = NSRect(
                x: x,
                y: (bounds.height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            x += iconSize.width + Self.iconGap
        }

        let pinX = bounds.width - Self.contentTrailing - Self.pinButtonSize
        pinButton.frame = NSRect(
            x: pinX,
            y: (bounds.height - Self.pinButtonSize) / 2,
            width: Self.pinButtonSize,
            height: Self.pinButtonSize
        )

        let titleHeight = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(
            x: x,
            y: (bounds.height - titleHeight) / 2,
            width: max(0, pinX - Self.pinGap - x),
            height: titleHeight
        )
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        ))
        // AppKit calls this when an `.inVisibleRect` area needs remeasuring, i.e. also
        // when the menu scrolls — a second chance to catch hover that moved without a
        // mouse event.
        recomputeHoverFromPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopObservingGeometry()
            mouseInside = false
            isMenuHighlighted = false
            // Unconditional: the menu can tear down while the row is still hovered,
            // and `mouseInside` was already false if it wasn't.
            tooltipPresenter.hide(for: self)
            updateAppearance()
        } else {
            observeGeometry()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // The ancestor chain we watch has changed, so the old tokens point at the
        // wrong views.
        if window != nil { observeGeometry() }
    }

    // MARK: - Hover during menu scrolling
    //
    // A tall menu scrolls its rows under a stationary pointer. AppKit does not
    // re-evaluate tracking areas during its menu tracking loop, so no row gets a
    // mouseExited and no row gets a mouseEntered: every row that passes under the
    // pointer keeps the highlight it was given, and the list ends up striped.
    // Frame/bounds notifications DO fire in that loop (NotificationCenter posts are
    // synchronous), so use them to re-derive hover from where the pointer actually is.

    private var geometryObservers: [NSObjectProtocol] = []

    private func observeGeometry() {
        stopObservingGeometry()
        // Whether AppKit scrolls a menu by moving each row or by shifting a container,
        // something in this chain changes geometry — watch all of it up to the window.
        var view: NSView? = self
        while let current = view {
            current.postsFrameChangedNotifications = true
            current.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                geometryObservers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: current, queue: nil
                    ) { [weak self] _ in
                        self?.recomputeHoverFromPointer()
                    }
                )
            }
            if current === window?.contentView { break }
            view = current.superview
        }
    }

    private func stopObservingGeometry() {
        geometryObservers.forEach(NotificationCenter.default.removeObserver)
        geometryObservers.removeAll()
    }

    /// Hit-test rather than a plain bounds check: rows scrolled under the menu's
    /// scroll arrows are still inside their own bounds, and only the row the pointer
    /// genuinely lands on may light up.
    private func recomputeHoverFromPointer(screenPoint: NSPoint = NSEvent.mouseLocation) {
        guard let window else { return }
        let pointInWindow = window.convertPoint(fromScreen: screenPoint)
        let inside: Bool
        if let hit = window.contentView?.hitTest(pointInWindow) {
            inside = hit.isDescendant(of: self)
        } else {
            inside = visibleRect.contains(convert(pointInWindow, from: nil))
        }
        mouseInside = inside
    }

    deinit { stopObservingGeometry() }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        tooltipPresenter.hide(for: self)
        onSelect?()
    }

    // MARK: - Keyboard (Return selects the highlighted row)

    override var acceptsFirstResponder: Bool { true }

    /// Take/release first-responder as the keyboard highlight moves. Deferred
    /// onto the run loop in .eventTracking mode — responder changes inside the
    /// menu delegate callout are recomputed away (same trick as the pin
    /// button's in-place resplice).
    private func syncFirstResponderToHighlight() {
        if isMenuHighlighted {
            RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
                guard let self, self.isMenuHighlighted, let window = self.window,
                      window.firstResponder !== self else { return }
                window.makeFirstResponder(self)
            }
        } else if let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            onSelect?()
        default:
            // Everything else (arrows, Esc, type-select letters) goes back to
            // the menu's own handling via the responder chain.
            super.keyDown(with: event)
        }
    }

    /// VoiceOver AXPress (and any accessibility-driven activation).
    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    @objc private func pinButtonClicked() {
        // The pin reorders the menu under the pointer, so the row this tooltip is
        // anchored beside is about to move.
        tooltipPresenter.hide(for: self)
        onTogglePin?()
    }

    // MARK: - Appearance

    private var isHighlighted: Bool { mouseInside || isMenuHighlighted }

    /// Hover only, matching native menus: keyboard highlight shows no tooltip.
    private func updateTooltip() {
        guard mouseInside, window != nil else {
            tooltipPresenter.hide(for: self)
            return
        }
        tooltipPresenter.scheduleShow(
            for: self,
            placement: .trailing,
            maxWidth: Self.tooltipMaxWidth,
            image: tooltipImage
        )
    }

    private func updateAppearance() {
        highlightView.isHidden = !isHighlighted
        titleField.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        pinButton.isHidden = !(isPinned || isHighlighted)
        pinButton.contentTintColor = isHighlighted
            ? .selectedMenuItemTextColor
            : (isPinned ? .labelColor : .secondaryLabelColor)
    }

    /// Rounded-rect mask so the behind-window selection material gets the
    /// native menu highlight shape (layer cornerRadius doesn't clip vibrancy).
    private static func highlightMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Testing

    var _isHoveredForTesting: Bool { mouseInside }
    var _geometryObserverCountForTesting: Int { geometryObservers.count }

    /// Drive the scroll-time recompute from a fixed pointer position; the real one
    /// depends on where the tester's mouse happens to be.
    func _recomputeHoverForTesting(atScreenPoint point: NSPoint) {
        recomputeHoverFromPointer(screenPoint: point)
    }
}
