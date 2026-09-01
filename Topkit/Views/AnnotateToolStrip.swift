import AppKit

/// Floating tool picker for the live Annotate overlay.
///
/// Visually identical to the screenshot editor's toolbar — it goes through
/// `AnnotationToolbarChrome` for metrics, colours, hover and selection states, so the
/// two cannot drift. What differs is behaviour, not appearance: no Save, no
/// discard-and-close, and it stays visible with nothing armed, because it doubles as
/// the only indication that Annotate mode is on (the status-bar icon ORs across every
/// overlay tool, so with two live at once it says nothing).
final class AnnotateToolStrip: NSView {

    struct Item {
        let tool: AnnotationTool
        let icon: String
        let title: String
    }

    /// Nil means "disarm" — the user clicked the already-armed tool.
    var onToolPicked: ((AnnotationTool?) -> Void)?
    var onExit: (() -> Void)?

    private let items: [Item]
    private var toolButtons: [HoverStateButton] = []
    private var armed: AnnotationTool?

    init(items: [Item]) {
        self.items = items
        super.init(frame: .zero)
        identifier = AnnotationToolbarChrome.Identifier.annotateToolStrip
        buildButtons()
        AnnotationToolbarChrome.applyContainerChrome(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildButtons() {
        let size = AnnotationToolbarChrome.buttonSize
        let spacing = AnnotationToolbarChrome.spacing
        let y = AnnotationToolbarChrome.buttonY
        var x = AnnotationToolbarChrome.edgeInset

        for (index, item) in items.enumerated() {
            let button = AnnotationToolbarChrome.makeButton(
                icon: item.icon,
                title: item.title,
                tooltip: AnnotationToolShortcuts.tooltip(item.title, tool: item.tool)
            )
            button.tag = index
            button.target = self
            button.action = #selector(toolClicked(_:))
            button.onHoverChanged = { [weak self] _ in self?.refreshButtonBackgrounds() }
            button.frame = NSRect(x: x, y: y, width: size, height: size)
            addSubview(button)
            toolButtons.append(button)
            x += size + spacing
        }

        // Divider before the exit action, matching the editor toolbar's separation of
        // drawing tools from Close / Save.
        x += spacing
        addSubview(AnnotationToolbarChrome.makeDivider(atX: x, buttonY: y, buttonSize: size))
        x += 1 + spacing * 2

        let exit = AnnotationToolbarChrome.makeButton(
            icon: "xmark",
            title: "End Annotate",
            tooltip: AnnotationToolShortcuts.tooltip(
                "End Annotate",
                fixedKey: AnnotationToolShortcuts.FixedKey.escape
            )
        )
        exit.target = self
        exit.action = #selector(exitClicked)
        exit.onHoverChanged = { [weak self] _ in self?.refreshButtonBackgrounds() }
        exit.frame = NSRect(x: x, y: y, width: size, height: size)
        addSubview(exit)
        x += size + AnnotationToolbarChrome.edgeInset

        frame = NSRect(x: 0, y: 0, width: x, height: AnnotationToolbarChrome.height)
    }

    @objc private func toolClicked(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        let picked = items[sender.tag].tool
        // Clicking the armed tool disarms; it does not end the session. Ending is the
        // job of the shortcut, the menu, and the exit button.
        onToolPicked?(picked == armed ? nil : picked)
    }

    @objc private func exitClicked() {
        onExit?()
    }

    func setArmed(_ tool: AnnotationTool?) {
        armed = tool
        refreshButtonBackgrounds()
    }

    private func refreshButtonBackgrounds() {
        for (index, button) in toolButtons.enumerated() {
            let isSelected = items.indices.contains(index) && items[index].tool == armed
            AnnotationToolbarChrome.applyButtonBackground(button: button, isSelected: isSelected)
        }
        for case let button as HoverStateButton in subviews where !toolButtons.contains(button) {
            AnnotationToolbarChrome.applyButtonBackground(button: button, isSelected: false)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AnnotationToolbarChrome.applyContainerChrome(self)
        refreshButtonBackgrounds()
    }
}
