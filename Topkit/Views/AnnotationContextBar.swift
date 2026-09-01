import AppKit

/// Options for the currently selected annotation, floating next to it.
///
/// Distinct from the tool strip, which arms the *next* mark. This edits the one
/// already on screen, so it appears on selection and dies on deselect. Styled through
/// `AnnotationToolbarChrome` like every other toolbar surface.
final class AnnotationContextBar: NSView {

    /// Which controls a given annotation type needs. Pure function of the type, so it
    /// can be tested without building any views.
    enum Control: Equatable {
        case color
        /// Rainbow/mono gradient toggle. Offered on every colourable tool: the mode is
        /// a session-wide property, so a solid swatch over a rainbow mark would lie.
        case rainbow
        case thickness
        case fontSize
        case badgeSize
        case stickerType
        case stickerSize
        /// Opacity dropdown. On every mark except redaction (a translucent mosaic
        /// would leak the pixels it hides).
        case opacity
        /// Vertical/horizontal flip. Guide lines only.
        case orientation

        static func controls(for tool: AnnotationTool) -> [Control] {
            switch tool {
            case .freehand, .rectangle, .circle, .arrow, .measure:
                return [.color, .rainbow, .thickness, .opacity]
            case .text:
                return [.color, .rainbow, .fontSize, .opacity]
            case .numberBadge:
                return [.color, .rainbow, .badgeSize, .opacity]
            case .sticker:
                // Stickers colour themselves from their type, so no colour well.
                return [.stickerType, .stickerSize, .opacity]
            case .guide:
                return [.color, .rainbow, .thickness, .opacity, .orientation]
            case .grid:
                // Sized by dragging, so no thickness slider; the fill needs its opacity.
                return [.color, .rainbow, .opacity]
            case .blur:
                // Redaction has no adjustable options.
                return []
            }
        }
    }

    var onColorClicked: (() -> Void)?
    var onRainbowToggled: ((Bool) -> Void)?
    var onSliderChanged: ((Control, CGFloat) -> Void)?
    var onStickerTypeChanged: ((StickerType) -> Void)?
    /// New opacity (0...1) picked from the dropdown.
    var onOpacityChanged: ((CGFloat) -> Void)?
    /// Guide flipped to the given orientation.
    var onOrientationToggled: ((GuideOrientation) -> Void)?
    /// Remove the selected annotation. Same effect as Backspace.
    var onDelete: (() -> Void)?

    private(set) var controls: [Control] = []
    private var slider: NSSlider?
    private var colorWell: NSButton?
    private var opacityButton: NSButton?
    private var orientationButton: NSButton?
    private var deleteButton: NSButton?
    private var opacity: CGFloat = 1.0
    private var orientation: GuideOrientation = .horizontal

    private let sliderWidth: CGFloat = 96

    private var rainbowButton: NSButton?
    private var isRainbow = false
    /// Solid colour shown when rainbow is off. Kept separately because the colour
    /// well's `contentTintColor` is cleared while a rainbow swatch is displayed.
    private var solidColor: NSColor = .red
    private var selectedStickerType: StickerType?

    init(controls: [Control], color: NSColor, value: CGFloat, stickerType: StickerType?, isRainbow: Bool = false, opacity: CGFloat = 1.0, orientation: GuideOrientation = .horizontal) {
        super.init(frame: .zero)
        self.controls = controls
        self.isRainbow = isRainbow
        self.solidColor = color
        self.selectedStickerType = stickerType
        self.opacity = opacity
        self.orientation = orientation
        identifier = NSUserInterfaceItemIdentifier("annotate.contextBar")
        build(color: color, value: value, stickerType: stickerType)
        AnnotationToolbarChrome.applyContainerChrome(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(color: NSColor, value: CGFloat, stickerType: StickerType?) {
        let size = AnnotationToolbarChrome.buttonSize
        let y = AnnotationToolbarChrome.buttonY
        var x = AnnotationToolbarChrome.edgeInset

        if controls.contains(.color) {
            let well = AnnotationToolbarChrome.makeButton(icon: "circle.fill", title: "Colour")
            applySwatch(to: well, color: color)
            well.target = self
            well.action = #selector(colorClicked)
            well.onHoverChanged = { [weak self] _ in self?.refreshButtonBackgrounds() }
            well.frame = NSRect(x: x, y: y, width: size, height: size)
            addSubview(well)
            colorWell = well
            x += size + AnnotationToolbarChrome.spacing
        }

        if controls.contains(.rainbow) {
            let b = AnnotationToolbarChrome.makeButton(icon: "rainbow", title: "Rainbow brush")
            b.target = self
            b.action = #selector(rainbowClicked)
            b.onHoverChanged = { [weak self] _ in self?.refreshButtonBackgrounds() }
            b.frame = NSRect(x: x, y: y, width: size, height: size)
            addSubview(b)
            rainbowButton = b
            x += size + AnnotationToolbarChrome.spacing
        }

        if controls.contains(.orientation) {
            let b = AnnotationToolbarChrome.makeButton(icon: Self.orientationIcon(orientation), title: "Flip orientation")
            b.target = self
            b.action = #selector(orientationClicked)
            b.onHoverChanged = { [weak self] _ in self?.refreshButtonBackgrounds() }
            b.frame = NSRect(x: x, y: y, width: size, height: size)
            addSubview(b)
            orientationButton = b
            x += size + AnnotationToolbarChrome.spacing
        }

        if controls.contains(.stickerType) {
            for (icon, tint, type) in [
                ("xmark.circle.fill", NSColor.systemRed, StickerType.redX),
                ("checkmark.circle.fill", NSColor.systemGreen, StickerType.greenCheck),
                ("exclamationmark.triangle.fill", NSColor.systemYellow, StickerType.yellowExclamation),
            ] {
                let b = AnnotationToolbarChrome.makeButton(icon: icon, title: "Sticker")
                b.contentTintColor = tint
                b.target = self
                b.action = #selector(stickerTypeClicked(_:))
                b.tag = Self.tag(for: type)
                b.onHoverChanged = { [weak self] _ in self?.refreshButtonBackgrounds() }
                b.frame = NSRect(x: x, y: y, width: size, height: size)
                addSubview(b)
                x += size + AnnotationToolbarChrome.spacing
            }
        }

        refreshButtonBackgrounds()

        if let sliderControl = controls.first(where: {
            $0 == .thickness || $0 == .fontSize || $0 == .badgeSize || $0 == .stickerSize
        }) {
            let range = Self.range(for: sliderControl)
            let s = NSSlider(frame: NSRect(x: x, y: y + 2, width: sliderWidth, height: size - 4))
            s.controlSize = .small
            s.minValue = Double(range.lowerBound)
            s.maxValue = Double(range.upperBound)
            s.doubleValue = Double(min(max(value, range.lowerBound), range.upperBound))
            s.target = self
            s.action = #selector(sliderMoved(_:))
            s.tag = Self.tag(for: sliderControl)
            addSubview(s)
            slider = s
            x += sliderWidth + AnnotationToolbarChrome.spacing
        }

        if controls.contains(.opacity) {
            let b = AnnotationToolbarChrome.makeButton(icon: "circle.lefthalf.filled", title: "Opacity")
            b.target = self
            b.action = #selector(opacityClicked)
            b.onHoverChanged = { [weak self] _ in self?.refreshButtonBackgrounds() }
            b.toolTip = Self.opacityTooltip(opacity)
            b.frame = NSRect(x: x, y: y, width: size, height: size)
            addSubview(b)
            opacityButton = b
            AnnotationToolbarChrome.applyButtonBackground(button: b, isSelected: false)
            x += size + AnnotationToolbarChrome.spacing
        }

        // Divider, then a delete button that removes the selected mark — the same
        // action as Backspace. Present on every selection's bar.
        x += AnnotationToolbarChrome.spacing
        addSubview(AnnotationToolbarChrome.makeDivider(atX: x, buttonY: y, buttonSize: size))
        x += 1 + AnnotationToolbarChrome.spacing * 2

        let delete = AnnotationToolbarChrome.makeButton(icon: "trash", title: "Delete")
        delete.target = self
        delete.action = #selector(deleteClicked)
        delete.onHoverChanged = { [weak self] _ in self?.refreshButtonBackgrounds() }
        delete.frame = NSRect(x: x, y: y, width: size, height: size)
        addSubview(delete)
        deleteButton = delete
        AnnotationToolbarChrome.applyButtonBackground(button: delete, isSelected: false)
        x += size + AnnotationToolbarChrome.spacing

        x += AnnotationToolbarChrome.edgeInset - AnnotationToolbarChrome.spacing
        frame = NSRect(x: 0, y: 0, width: max(x, size * 2), height: AnnotationToolbarChrome.height)
    }

    // MARK: - Ranges, matching the editor's sliders

    static func range(for control: Control) -> ClosedRange<CGFloat> {
        switch control {
        case .thickness:   return 1...20
        case .fontSize:    return 8...72
        case .badgeSize:   return 16...120
        case .stickerSize: return 16...160
        default:           return 0...1
        }
    }

    private static func tag(for control: Control) -> Int {
        switch control {
        case .color:       return 0
        case .thickness:   return 1
        case .fontSize:    return 2
        case .badgeSize:   return 3
        case .stickerType: return 4
        case .stickerSize: return 5
        case .rainbow:     return 6
        case .opacity:     return 7
        case .orientation: return 8
        }
    }

    private static func control(forTag tag: Int) -> Control? {
        switch tag {
        case 1: return .thickness
        case 2: return .fontSize
        case 3: return .badgeSize
        case 5: return .stickerSize
        default: return nil
        }
    }

    private static func tag(for type: StickerType) -> Int {
        switch type {
        case .redX: return 10
        case .greenCheck: return 11
        case .yellowExclamation: return 12
        }
    }

    private static func stickerType(forTag tag: Int) -> StickerType? {
        switch tag {
        case 10: return .redX
        case 11: return .greenCheck
        case 12: return .yellowExclamation
        default: return nil
        }
    }

    // MARK: - Actions

    @objc private func colorClicked() { onColorClicked?() }

    @objc private func deleteClicked() { onDelete?() }

    @objc private func opacityClicked() {
        guard let button = opacityButton else { return }
        let menu = NSMenu()
        for percent in stride(from: 100, through: 10, by: -10) {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(opacityMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            if Int((opacity * 100).rounded()) == percent { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func opacityMenuPicked(_ sender: NSMenuItem) {
        let value = CGFloat(sender.tag) / 100.0
        opacity = value
        opacityButton?.toolTip = Self.opacityTooltip(value)
        onOpacityChanged?(value)
    }

    private static func opacityTooltip(_ opacity: CGFloat) -> String {
        "Opacity (\(Int((opacity * 100).rounded()))%)"
    }

    @objc private func orientationClicked() {
        orientation = orientation.opposite
        orientationButton?.image = Self.orientationImage(orientation)
        refreshButtonBackgrounds()
        onOrientationToggled?(orientation)
    }

    private static func orientationIcon(_ o: GuideOrientation) -> String {
        o == .horizontal ? "arrow.left.and.right" : "arrow.up.and.down"
    }

    private static func orientationImage(_ o: GuideOrientation) -> NSImage? {
        guard let img = NSImage(systemSymbolName: orientationIcon(o), accessibilityDescription: "Flip orientation") else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: AnnotationToolbarChrome.symbolPointSize, weight: .regular)
        return img.withSymbolConfiguration(config)
    }

    @objc private func rainbowClicked() {
        isRainbow.toggle()
        if let well = colorWell { applySwatch(to: well, color: solidColor) }
        // Clear AppKit's momentary highlight so a just-deselected toggle does not
        // keep looking "on" until the next mouse move.
        rainbowButton?.isHighlighted = false
        refreshButtonBackgrounds()
        onRainbowToggled?(isRainbow)
    }

    /// Re-apply selected / hover chrome. Required on hover enter/exit — without it a
    /// deselected rainbow button keeps its blue wash after the pointer leaves.
    private func refreshButtonBackgrounds() {
        if let well = colorWell {
            AnnotationToolbarChrome.applyButtonBackground(button: well, isSelected: false)
        }
        if let b = rainbowButton {
            AnnotationToolbarChrome.applyButtonBackground(button: b, isSelected: isRainbow)
        }
        if let b = deleteButton {
            AnnotationToolbarChrome.applyButtonBackground(button: b, isSelected: false)
        }
        if let b = opacityButton {
            AnnotationToolbarChrome.applyButtonBackground(button: b, isSelected: false)
        }
        if let b = orientationButton {
            AnnotationToolbarChrome.applyButtonBackground(button: b, isSelected: false)
        }
        if controls.contains(.stickerType) {
            for case let b as HoverStateButton in subviews where b !== colorWell && b !== rainbowButton && b !== deleteButton && b !== opacityButton && b !== orientationButton {
                let type = Self.stickerType(forTag: b.tag)
                AnnotationToolbarChrome.applyButtonBackground(
                    button: b,
                    isSelected: type != nil && type == selectedStickerType
                )
            }
        }
    }

    /// A rainbow stroke gets a gradient swatch: a solid red dot next to a rainbow
    /// stroke is exactly the mismatch this control exists to remove.
    private func applySwatch(to button: NSButton, color: NSColor) {
        solidColor = color
        if isRainbow {
            button.image = Self.rainbowSwatch(diameter: AnnotationToolbarChrome.symbolPointSize + 2)
            button.contentTintColor = nil
        } else {
            if let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Colour") {
                let config = NSImage.SymbolConfiguration(pointSize: AnnotationToolbarChrome.symbolPointSize, weight: .regular)
                button.image = image.withSymbolConfiguration(config)
            }
            button.contentTintColor = color
        }
    }

    static func rainbowSwatch(diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
        path.addClip()
        // Sample the same curve the brush uses, so the swatch matches the stroke.
        let steps = 24
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            AnnotationRenderer.rainbowColor(at: t).setFill()
            NSRect(x: t * diameter, y: 0, width: diameter / CGFloat(steps) + 1, height: diameter).fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let control = Self.control(forTag: sender.tag) else { return }
        onSliderChanged?(control, CGFloat(sender.doubleValue))
    }

    @objc private func stickerTypeClicked(_ sender: NSButton) {
        guard let type = Self.stickerType(forTag: sender.tag) else { return }
        selectedStickerType = type
        refreshButtonBackgrounds()
        onStickerTypeChanged?(type)
    }

    /// Updates the colour well. Picking a concrete colour always means solid —
    /// leaving rainbow on would keep painting a gradient over the colour just chosen.
    func updateColorSwatch(_ color: NSColor, isRainbow: Bool? = nil) {
        if let isRainbow { self.isRainbow = isRainbow }
        refreshButtonBackgrounds()
        guard let well = colorWell else { return }
        applySwatch(to: well, color: color)
    }

    /// Layer background currently drawn for the rainbow toggle — nil / clear when off
    /// and not hovered. Tests use this to catch a stuck "selected" wash.
    var _rainbowButtonBackgroundColorForTesting: CGColor? {
        rainbowButton?.layer?.backgroundColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AnnotationToolbarChrome.applyContainerChrome(self)
    }

    // MARK: - Placement

    /// Anchor above the element, flipping below when it would leave the screen, and
    /// clamped horizontally. `avoid` is the tool strip, which the bar must not cover.
    static func origin(
        forSelection selection: NSRect,
        barSize: NSSize,
        in canvas: NSRect,
        avoiding avoid: NSRect?
    ) -> NSPoint {
        let gap: CGFloat = 8
        let inset: CGFloat = 8

        var y = selection.maxY + gap
        if y + barSize.height > canvas.maxY - inset {
            y = selection.minY - gap - barSize.height
        }
        y = min(max(y, canvas.minY + inset), canvas.maxY - inset - barSize.height)

        var x = selection.midX - barSize.width / 2
        x = min(max(x, canvas.minX + inset), canvas.maxX - inset - barSize.width)

        // If it would sit on the tool strip, push it above the strip instead.
        if let avoid, NSIntersectsRect(NSRect(x: x, y: y, width: barSize.width, height: barSize.height), avoid) {
            y = avoid.maxY + gap
            y = min(y, canvas.maxY - inset - barSize.height)
        }

        return NSPoint(x: x, y: y)
    }
}
