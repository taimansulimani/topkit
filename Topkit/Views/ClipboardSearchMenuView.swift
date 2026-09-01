import AppKit

/// NSSearchField tuned for living inside a menu.
///
/// Two quirks handled here:
/// - macOS 14 hands keyboard focus to the first focusable view of a menu as
///   soon as it opens. We want click-to-focus, so first-responder status is
///   refused until a click inside the field arms it (re-disarmed every time
///   the menu closes and the view leaves its window).
/// - The caret is rendered by NSTextInsertionIndicator (macOS 14+), and
///   inside a menu window AppKit resolves the indicator's automatic display
///   mode to a private "suppressed" state (displayMode rawValue 100, caret
///   layer opacity 0): the field is focused and typing works, but no caret
///   is visible until the next selection recompute (which is why clicking
///   the clear button used to make it appear). Verified with a standalone
///   probe on macOS 26.5: forcing .visible sticks, and a selection nudge
///   right after lands the indicator back on .automatic in its RENDERING
///   state, after which it behaves like a normal field caret. It must run
///   deferred — done inside the click's own call stack, AppKit recomputes
///   straight back to suppressed.
private final class MenuSearchField: NSSearchField {
    private var clickArmed = false
    private var caretFixTimer: Timer?

    deinit {
        caretFixTimer?.invalidate()
    }

    override var acceptsFirstResponder: Bool { clickArmed }

    override func becomeFirstResponder() -> Bool {
        guard clickArmed else { return false }
        window?.makeKey()
        guard super.becomeFirstResponder() else { return false }
        scheduleCaretUnsuppress()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if !clickArmed {
            clickArmed = true
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
        scheduleCaretUnsuppress()
    }

    /// Runs unsuppressCaret on the next few run-loop passes. A short repeating
    /// timer (instead of a one-shot) covers the indicator being created
    /// lazily after focus; it stops as soon as the fix lands. Added to
    /// .eventTracking explicitly — that is the run-loop mode during menu
    /// tracking, where .default never fires.
    private func scheduleCaretUnsuppress() {
        guard #available(macOS 14.0, *), caretFixTimer == nil else { return }
        var attempts = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            attempts += 1
            if self.unsuppressCaret() || attempts >= 8 {
                timer.invalidate()
                self.caretFixTimer = nil
            }
        }
        caretFixTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
    }

    /// Returns true once the indicator was found and is out of the
    /// suppressed mode (or was never in it).
    @available(macOS 14.0, *)
    private func unsuppressCaret() -> Bool {
        guard let indicator = firstInsertionIndicator(in: self) else { return false }
        // .automatic (rawValue 0) is the healthy state; the menu-suppressed
        // private mode reads as a non-public rawValue.
        guard indicator.displayMode != .automatic else { return true }
        indicator.displayMode = .visible
        if let editor = currentEditor() as? NSTextView {
            let range = editor.selectedRange()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.setSelectedRange(range)
        }
        return true
    }

    @available(macOS 14.0, *)
    private func firstInsertionIndicator(in view: NSView) -> NSTextInsertionIndicator? {
        for sub in view.subviews {
            if let indicator = sub as? NSTextInsertionIndicator { return indicator }
            if let indicator = firstInsertionIndicator(in: sub) { return indicator }
        }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clickArmed = false
            caretFixTimer?.invalidate()
            caretFixTimer = nil
        }
    }
}

/// Custom view for the search NSMenuItem at the top of the clipboard menus.
/// Hosts an NSSearchField (which provides the clear (x) button natively) and
/// forwards edits to the owner. Not focused on menu open — click to focus —
/// so native menu type-select keeps working until the user opts into search.
final class ClipboardSearchMenuView: NSView, NSSearchFieldDelegate {

    /// Fired on every edit, including the clear button, with the new query.
    var onQueryChanged: ((String) -> Void)?
    /// Fired on Enter while the field is focused (pick the top match).
    var onCommit: (() -> Void)?

    let searchField: NSSearchField = MenuSearchField()

    private static let fieldHeight: CGFloat = 28
    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 3

    init(initialQuery: String) {
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: 250,
            height: Self.fieldHeight + Self.verticalPadding * 2
        ))
        autoresizingMask = [.width]

        searchField.stringValue = initialQuery
        searchField.placeholderString = String(localized: "Search")
        searchField.delegate = self
        searchField.target = self
        // Covers the clear (x) button, which mutates the text without a
        // controlTextDidChange notification.
        searchField.action = #selector(searchFieldAction(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: Self.fieldHeight)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        onQueryChanged?(sender.stringValue)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc clears the query if there is one; with an empty field the
            // event falls through and the menu closes as usual.
            guard !searchField.stringValue.isEmpty else { return false }
            searchField.stringValue = ""
            onQueryChanged?("")
            return true
        default:
            return false
        }
    }
}
