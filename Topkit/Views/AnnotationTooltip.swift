import AppKit

/// The subset a hovering view drives. Injectable so the wiring can be tested without
/// a panel on screen.
protocol HoverTooltipPresenting: AnyObject {
    func scheduleShow(for view: NSView, placement: AnnotationTooltip.Placement, maxWidth: CGFloat?, image: NSImage?)
    func hide(for view: NSView?)
}

/// Hover tooltips for surfaces AppKit refuses to draw them on.
///
/// The annotation toolbars: `toolTip` never becomes visible on either, because both
/// live in windows at `kScreenshotOverlayBaseLevel` (screenSaver + 1) while the
/// system's tooltip panel is created down around `.popUpMenu`, so it opens *behind*
/// the overlay. Exactly the bug the sticker menu had, and the same fix — present our
/// own panel above the overlay level.
///
/// The clipboard menu rows: a view-backed `NSMenuItem` gets no tooltip at all. NSMenu
/// only draws them for items it draws itself, and `NSToolTipManager` never arms inside
/// the menu's tracking loop — so the row presents this instead.
///
/// `HoverStateButton` and `ClipboardRowMenuView` drive it, so `toolTip` stays the
/// single source of the text (it still feeds accessibility).
final class AnnotationTooltip {
    static let shared = AnnotationTooltip()

    /// Where the panel sits relative to what it describes.
    enum Placement {
        /// Under the anchor, centred on it — toolbar buttons, which are small.
        case below
        /// Beside the anchor, vertically centred, flipping to the other side when
        /// there is no room — menu rows, where `below` would cover the rows under it.
        case trailing
    }

    /// Close enough to the system delay that the two don't feel like different UI.
    static let delay: TimeInterval = 0.45
    /// Distance between the hovered control and the tooltip.
    static let gap: CGFloat = 6
    /// Keeps the panel off the very edge of the display.
    static let screenMargin: CGFloat = 4
    private static let padding = NSSize(width: 8, height: 4)
    private static let fontSize: CGFloat = 11

    /// Above `kScreenshotOverlayBaseLevel`, matching the sticker menu and colour panel.
    static var windowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: kScreenshotOverlayBaseLevel.rawValue + 1)
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var imageView: NSImageView?
    private var pending: Timer?
    private weak var pendingOwner: NSView?
    private weak var owner: NSView?
    /// Which display the live panel was built for, so a hover on another one rebuilds
    /// it instead of moving it.
    private var panelScreenFrame: NSRect?

    private init() {
        // The window server pins a window to the Space it was first ordered into —
        // and, with "Displays have separate Spaces" on, to that display too. Every
        // other overlay in the app sidesteps this by being built per session; this
        // panel is long-lived, so once created it kept showing only in the Space it
        // was born in and looked broken everywhere else. Throw it away on a Space
        // switch and let the next hover build one where it is actually wanted.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.cancelPending()
            self?.discardPanel()
        }
        // Plugging or unplugging a display re-flows the Spaces the same way.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.cancelPending()
            self?.discardPanel()
        }
    }

    // MARK: - Geometry

    /// Places `size` against `anchor` per `placement`, flipping to the opposite side
    /// when there is no room, and clamped so the panel never runs off `screen`.
    static func frame(
        anchor: NSRect,
        size: NSSize,
        screen: NSRect,
        placement: Placement = .below
    ) -> NSRect {
        switch placement {
        case .below:
            var y = anchor.minY - gap - size.height
            if y < screen.minY + screenMargin {
                let above = anchor.maxY + gap
                // Only flip if above actually fits; otherwise stay below and clamp.
                y = (above + size.height <= screen.maxY - screenMargin)
                    ? above
                    : screen.minY + screenMargin
            }
            y = min(y, screen.maxY - screenMargin - size.height)

            var x = anchor.midX - size.width / 2
            x = max(screen.minX + screenMargin, min(x, screen.maxX - screenMargin - size.width))

            return NSRect(x: x, y: y, width: size.width, height: size.height)

        case .trailing:
            var x = anchor.maxX + gap
            if x + size.width > screen.maxX - screenMargin {
                let leading = anchor.minX - gap - size.width
                // Only flip if the leading side actually fits; otherwise stay and clamp.
                x = leading >= screen.minX + screenMargin
                    ? leading
                    : screen.maxX - screenMargin - size.width
            }
            x = max(screen.minX + screenMargin, x)

            var y = anchor.midY - size.height / 2
            y = max(screen.minY + screenMargin, min(y, screen.maxY - screenMargin - size.height))

            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    /// Measured size of `text`, wrapped when `maxWidth` is set. Clipboard rows set one:
    /// their text runs to the user's tooltip limit (200 characters by default), which
    /// on a single line is a panel wider than the display.
    static func textSize(_ text: String, maxWidth: CGFloat?) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]
        guard let maxWidth else {
            let size = (text as NSString).size(withAttributes: attributes)
            return NSSize(width: ceil(size.width), height: ceil(size.height))
        }
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return NSSize(width: min(ceil(bounds.width), maxWidth), height: ceil(bounds.height))
    }

    /// Index into `screenFrames` of the display the anchor sits on, taken from its
    /// centre. `window.screen` can't answer this: a window spanning two displays
    /// reports only one of them, and clamping to that one drags the panel onto the
    /// wrong display. nil when the anchor lands on no display at all.
    static func screenIndex(for anchor: NSRect, in screenFrames: [NSRect]) -> Int? {
        let centre = NSPoint(x: anchor.midX, y: anchor.midY)
        return screenFrames.firstIndex { $0.contains(centre) }
    }

    // MARK: - Presenting

    /// Arms the tooltip for `view`, using its `toolTip` as the text — or `image` in its
    /// place, which is how clipboard image rows preview themselves. No-op without either.
    func scheduleShow(
        for view: NSView,
        placement: Placement = .below,
        maxWidth: CGFloat? = nil,
        image: NSImage? = nil
    ) {
        cancelPending()
        let text = view.toolTip ?? ""
        guard image != nil || !text.isEmpty else { return }
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self, weak view] _ in
            guard let view else { return }
            self?.show(text: text, image: image, for: view, placement: placement, maxWidth: maxWidth)
        }
        pending = timer
        pendingOwner = view
        // .eventTracking as well as .default: a clipboard row arms this from inside
        // NSMenu's tracking loop, where a default-mode timer never fires.
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    /// Hides only what belongs to `view`, so a late exit from a button the user has
    /// already left cannot close the tooltip of the one they moved on to. Pass nil to
    /// hide unconditionally.
    func hide(for view: NSView?) {
        guard let view else {
            cancelPending()
            panel?.orderOut(nil)
            owner = nil
            return
        }
        if pendingOwner === view { cancelPending() }
        if owner === view {
            panel?.orderOut(nil)
            owner = nil
        }
    }

    /// True while a tooltip panel is on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    /// True between `scheduleShow` and the delay elapsing.
    var _isArmedForTesting: Bool { pending != nil }

    private func cancelPending() {
        pending?.invalidate()
        pending = nil
        pendingOwner = nil
    }

    private func show(text: String, image: NSImage?, for view: NSView, placement: Placement, maxWidth: CGFloat?) {
        pending = nil
        pendingOwner = nil
        // The button can be gone (toolbar rebuilt) or the overlay dismissed between
        // arming and firing.
        guard let window = view.window, window.isVisible else { return }
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screens = NSScreen.screens
        guard let screen = Self.screenIndex(for: anchor, in: screens.map(\.frame)).map({ screens[$0] })
            ?? window.screen
            ?? NSScreen.main
        else { return }

        let panel = panelForDisplay(on: screen)
        let label = self.label!
        let imageView = self.imageView!
        let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        panel.contentView?.appearance = panel.appearance
        applyChrome(to: panel.contentView!, isDark: isDark)

        label.isHidden = (image != nil)
        imageView.isHidden = (image == nil)
        imageView.image = image
        label.stringValue = text
        label.textColor = isDark ? .white : .labelColor
        label.usesSingleLineMode = (maxWidth == nil)
        label.maximumNumberOfLines = maxWidth == nil ? 1 : 0
        label.lineBreakMode = maxWidth == nil ? .byClipping : .byWordWrapping

        let contentSize = image?.size ?? Self.textSize(text, maxWidth: maxWidth)
        // Text sits in a tight band; an image reads better with the same inset all round.
        let inset = image == nil
            ? Self.padding
            : NSSize(width: Self.padding.width, height: Self.padding.width)
        var size = NSSize(
            width: contentSize.width + inset.width * 2,
            height: contentSize.height + inset.height * 2
        )
        // Clipboard text can be mostly newlines; clip rather than run off the display.
        size.height = min(size.height, screen.frame.height - Self.screenMargin * 2)
        panel.setFrame(Self.frame(anchor: anchor, size: size, screen: screen.frame, placement: placement), display: false)
        let contentFrame = NSRect(
            x: inset.width,
            y: inset.height,
            width: size.width - inset.width * 2,
            height: size.height - inset.height * 2
        )
        label.frame = contentFrame
        imageView.frame = contentFrame

        owner = view
        panel.orderFrontRegardless()
    }

    private func applyChrome(to view: NSView, isDark: Bool) {
        view.wantsLayer = true
        view.layer?.cornerRadius = AnnotationToolbarChrome.cornerRadius
        if isDark {
            view.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.98).cgColor
            view.layer?.borderWidth = 0.5
            view.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        } else {
            view.layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.98).cgColor
            view.layer?.borderWidth = 0.5
            view.layer?.borderColor = NSColor(white: 0.68, alpha: 0.85).cgColor
        }
    }

    /// Throws the panel away so the next tooltip builds a fresh one, in the Space and
    /// on the display where it is wanted.
    private func discardPanel() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        label = nil
        imageView = nil
        panelScreenFrame = nil
        owner = nil
    }

    private func panelForDisplay(on screen: NSScreen) -> NSPanel {
        if let panel, panelScreenFrame == screen.frame { return panel }
        // Built for a different display: the window server keeps it over there, so
        // start again rather than try to move it across.
        discardPanel()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = Self.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Never take a click or the focus away from the overlay underneath.
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        // `discardPanel` closes it; ARC owns it, so close() must not also release.
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: panel.contentLayoutRect)
        content.wantsLayer = true
        panel.contentView = content

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: Self.fontSize)
        label.lineBreakMode = .byClipping
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        content.addSubview(label)

        // Image rows preview themselves here instead of showing text.
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 3
        imageView.layer?.masksToBounds = true
        imageView.isHidden = true
        content.addSubview(imageView)

        self.panel = panel
        self.label = label
        self.imageView = imageView
        panelScreenFrame = screen.frame
        return panel
    }
}

extension AnnotationTooltip: HoverTooltipPresenting {}
