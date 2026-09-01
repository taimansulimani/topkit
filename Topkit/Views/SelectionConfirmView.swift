import AppKit

/// Full-screen overlay shown after the user draws a selection rect. Dimmed with a
/// live "hole" at the selection; resize handles; a primary-action + Cancel toolbar.
/// Used by the recording flow (Start Recording); originally built for screenshots.
class SelectionConfirmView: NSView {
    private let kResizeHandleSize: CGFloat = 12
    private let kResizeEdgeThickness: CGFloat = 10
    private let minSelectionSize: CGFloat = 40

    var selectionRect: NSRect
    var onConfirm: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    /// Fired when the toolbar's Subtitles / Audio toggles change (recording flow only).
    /// The view already persists the new value to UserDefaults; the handler updates the
    /// in-flight recording session (permission requests etc.).
    var onSubtitlesToggled: ((Bool) -> Void)?
    var onMicAudioToggled: ((Bool) -> Void)?
    /// False for window-mode recording: the hole follows the window, the user can't resize it.
    let allowsResize: Bool
    /// When true, the toolbar shows Subtitles + Audio toggles (the recording flow).
    private let showsRecordingOptions: Bool
    private let primaryTitle: String
    private let primaryIsDestructive: Bool

    private var resizingEdge: ResizeEdge = .none
    private var resizeStartPoint: NSPoint?
    private var resizeOriginalRect: NSRect?
    private var isMovingSelection = false
    private var moveStartPoint: NSPoint?
    private var moveOriginalRect: NSRect?

    private var toolbarView: NSView?

    override var isFlipped: Bool { false }

    init(frame: NSRect, selectionRect: NSRect, primaryTitle: String, primaryIsDestructive: Bool = false, allowsResize: Bool = true, showsRecordingOptions: Bool = false) {
        self.selectionRect = selectionRect
        self.primaryTitle = primaryTitle
        self.primaryIsDestructive = primaryIsDestructive
        self.allowsResize = allowsResize
        self.showsRecordingOptions = showsRecordingOptions
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Reposition the hole from outside (window-mode recording tracks the
    /// target window's live frame).
    func updateSelectionRect(_ rect: NSRect) {
        selectionRect = rect
        updateToolbarPosition()
        setNeedsDisplay(bounds)
    }

    private func setupToolbar() {
        let toolbarHeight: CGFloat = 36
        let buttonHeight: CGFloat = 28
        let spacing: CGFloat = 4
        var x: CGFloat = 6
        let y: CGFloat = 4

        let toolbar = NSView(frame: .zero)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 5

        // Layout order: [Subtitles] [Audio] | divider | [Cancel] [Start Recording].
        // Recording flow: Subtitles + Audio toggles first (sharing the Preferences prefs),
        // then a divider before the action buttons.
        if showsRecordingOptions {
            let subtitlesToggle = makeOptionToggle(
                title: String(localized: "Subtitles"),
                isOn: UserDefaults.standard.bool(forKey: "recordingDictationSubtitles"),
                action: #selector(subtitlesToggled(_:))
            )
            subtitlesToggle.frame.origin = NSPoint(x: x, y: y + (buttonHeight - subtitlesToggle.frame.height) / 2)
            toolbar.addSubview(subtitlesToggle)
            x += subtitlesToggle.frame.width + spacing

            let audioToggle = makeOptionToggle(
                title: String(localized: "Audio"),
                isOn: UserDefaults.standard.bool(forKey: "recordingMicrophoneAudio"),
                action: #selector(micAudioToggled(_:))
            )
            audioToggle.frame.origin = NSPoint(x: x, y: y + (buttonHeight - audioToggle.frame.height) / 2)
            toolbar.addSubview(audioToggle)
            x += audioToggle.frame.width + spacing

            x += spacing
            toolbar.addSubview(makeDivider(atX: x, buttonY: y, buttonHeight: buttonHeight))
            x += 1 + spacing * 2
        }

        let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.sizeToFit()
        cancelButton.frame = NSRect(x: x, y: y, width: max(cancelButton.frame.width + 16, 70), height: buttonHeight)
        toolbar.addSubview(cancelButton)
        x += cancelButton.frame.width + spacing

        let primaryButton = NSButton(title: primaryTitle, target: self, action: #selector(confirmTapped))
        primaryButton.bezelStyle = .rounded
        if primaryIsDestructive {
            primaryButton.bezelColor = .systemRed
        }
        primaryButton.sizeToFit()
        primaryButton.frame = NSRect(x: x, y: y, width: max(primaryButton.frame.width + 16, 90), height: buttonHeight)
        toolbar.addSubview(primaryButton)
        x += primaryButton.frame.width + spacing

        let toolbarWidth = x + 2
        let gapAboveSelection: CGFloat = 16
        let toolbarY = selectionRect.origin.y + selectionRect.height + gapAboveSelection
        let toolbarX = selectionRect.origin.x + (selectionRect.width - toolbarWidth) / 2
        toolbar.frame = NSRect(x: toolbarX, y: toolbarY, width: toolbarWidth, height: toolbarHeight)
        addSubview(toolbar)
        toolbarView = toolbar
        updateToolbarPosition()
        applyConfirmToolbarChrome()
    }

    private func applyConfirmToolbarChrome() {
        guard let toolbar = toolbarView else { return }
        let useDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if useDark {
            toolbar.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
            toolbar.layer?.borderWidth = 0
            toolbar.layer?.borderColor = nil
            toolbar.appearance = NSAppearance(named: .darkAqua)
        } else {
            toolbar.layer?.backgroundColor = NSColor(white: 0.96, alpha: 0.97).cgColor
            toolbar.layer?.borderWidth = 0.5
            toolbar.layer?.borderColor = NSColor(white: 0.68, alpha: 0.85).cgColor
            toolbar.appearance = NSAppearance(named: .aqua)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyConfirmToolbarChrome()
    }
    
    private func updateToolbarPosition() {
        guard let toolbar = toolbarView else { return }
        let gapAboveSelection: CGFloat = 16
        var toolbarY = selectionRect.origin.y + selectionRect.height + gapAboveSelection
        if toolbarY + toolbar.frame.height > bounds.maxY - 8 {
            toolbarY = selectionRect.origin.y - gapAboveSelection - toolbar.frame.height
        }
        var toolbarX = selectionRect.origin.x + (selectionRect.width - toolbar.frame.width) / 2
        toolbarX = max(8, min(toolbarX, bounds.maxX - 8 - toolbar.frame.width))
        toolbar.frame.origin = NSPoint(x: toolbarX, y: max(8, toolbarY))
    }

    /// A thin vertical divider for the toolbar, vertically centred on the button band.
    private func makeDivider(atX x: CGFloat, buttonY: CGFloat, buttonHeight: CGFloat) -> NSView {
        let dividerHeight: CGFloat = 18
        let v = NSView(frame: NSRect(x: x, y: buttonY + (buttonHeight - dividerHeight) / 2, width: 1, height: dividerHeight))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }

    private func makeOptionToggle(title: String, isOn: Bool, action: Selector) -> NSButton {
        let toggle = NSButton(checkboxWithTitle: title, target: self, action: action)
        toggle.state = isOn ? .on : .off
        toggle.controlSize = .small
        toggle.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        toggle.sizeToFit()
        return toggle
    }

    @objc private func subtitlesToggled(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "recordingDictationSubtitles")
        onSubtitlesToggled?(on)
    }

    @objc private func micAudioToggled(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "recordingMicrophoneAudio")
        onMicAudioToggled?(on)
    }

    @objc private func confirmTapped() {
        onConfirm?(selectionRect)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Enter
            onConfirm?(selectionRect)
        }
    }
    
    private func resizeEdgeAt(point: NSPoint) -> ResizeEdge {
        let r = selectionRect
        let left = r.minX, right = r.maxX, bottom = r.minY, top = r.maxY
        let x = point.x, y = point.y
        
        if x >= left - kResizeHandleSize && x <= left + kResizeHandleSize &&
           y >= bottom - kResizeHandleSize && y <= bottom + kResizeHandleSize { return .bottomLeft }
        if x >= right - kResizeHandleSize && x <= right + kResizeHandleSize &&
           y >= bottom - kResizeHandleSize && y <= bottom + kResizeHandleSize { return .bottomRight }
        if x >= left - kResizeHandleSize && x <= left + kResizeHandleSize &&
           y >= top - kResizeHandleSize && y <= top + kResizeHandleSize { return .topLeft }
        if x >= right - kResizeHandleSize && x <= right + kResizeHandleSize &&
           y >= top - kResizeHandleSize && y <= top + kResizeHandleSize { return .topRight }
        if x >= left - kResizeEdgeThickness && x <= left + kResizeEdgeThickness &&
           y > bottom + kResizeHandleSize && y < top - kResizeHandleSize { return .left }
        if x >= right - kResizeEdgeThickness && x <= right + kResizeEdgeThickness &&
           y > bottom + kResizeHandleSize && y < top - kResizeHandleSize { return .right }
        if y >= bottom - kResizeEdgeThickness && y <= bottom + kResizeEdgeThickness &&
           x > left + kResizeHandleSize && x < right - kResizeHandleSize { return .bottom }
        if y >= top - kResizeEdgeThickness && y <= top + kResizeEdgeThickness &&
           x > left + kResizeHandleSize && x < right - kResizeHandleSize { return .top }
        return .none
    }
    
    private func drawResizeHandles(for rect: NSRect) {
        let handleSize: CGFloat = 6
        let half = handleSize / 2
        let positions: [NSPoint] = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
            NSPoint(x: rect.midX, y: rect.minY), NSPoint(x: rect.midX, y: rect.maxY),
            NSPoint(x: rect.minX, y: rect.midY), NSPoint(x: rect.maxX, y: rect.midY),
        ]
        for pos in positions {
            let hr = NSRect(x: pos.x - half, y: pos.y - half, width: handleSize, height: handleSize)
            NSColor.white.setFill()
            hr.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            NSBezierPath(rect: hr).lineWidth = 1
            NSBezierPath(rect: hr).stroke()
        }
    }
    
    private func setCursorForEdge(_ edge: ResizeEdge) {
        switch edge {
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .top, .bottom: NSCursor.resizeUpDown.set()
        case .topLeft, .bottomRight: ResizeEdge.resizeNWSE.set()
        case .topRight, .bottomLeft: ResizeEdge.resizeNESW.set()
        case .none: NSCursor.arrow.set()
        }
    }
    
    private func clampSelectionRect() {
        var r = selectionRect
        r.size.width = max(minSelectionSize, min(r.width, bounds.width - r.origin.x))
        r.size.height = max(minSelectionSize, min(r.height, bounds.height - r.origin.y))
        r.origin.x = max(0, min(r.origin.x, bounds.width - minSelectionSize))
        r.origin.y = max(0, min(r.origin.y, bounds.height - minSelectionSize))
        if r.size.width < minSelectionSize { r.size.width = minSelectionSize }
        if r.size.height < minSelectionSize { r.size.height = minSelectionSize }
        selectionRect = r
    }
    
    private func handleResizeDrag(to point: NSPoint) {
        guard let original = resizeOriginalRect else { return }
        var newX = original.origin.x
        var newY = original.origin.y
        var newW = original.width
        var newH = original.height
        
        switch resizingEdge {
        case .left:
            let delta = point.x - original.origin.x
            newX = original.origin.x + delta
            newW = original.width - delta
            if newW < minSelectionSize { newW = minSelectionSize; newX = original.maxX - minSelectionSize }
        case .right:
            newW = point.x - original.origin.x
            if newW < minSelectionSize { newW = minSelectionSize }
        case .bottom:
            let delta = point.y - original.origin.y
            newY = original.origin.y + delta
            newH = original.height - delta
            if newH < minSelectionSize { newH = minSelectionSize; newY = original.maxY - minSelectionSize }
        case .top:
            newH = point.y - original.origin.y
            if newH < minSelectionSize { newH = minSelectionSize }
        case .topLeft:
            let dx = point.x - original.origin.x
            newX = original.origin.x + dx
            newW = original.width - dx
            if newW < minSelectionSize { newW = minSelectionSize; newX = original.maxX - minSelectionSize }
            newH = point.y - original.origin.y
            if newH < minSelectionSize { newH = minSelectionSize }
        case .topRight:
            newW = point.x - original.origin.x
            if newW < minSelectionSize { newW = minSelectionSize }
            newH = point.y - original.origin.y
            if newH < minSelectionSize { newH = minSelectionSize }
        case .bottomLeft:
            let dx = point.x - original.origin.x
            newX = original.origin.x + dx
            newW = original.width - dx
            if newW < minSelectionSize { newW = minSelectionSize; newX = original.maxX - minSelectionSize }
            let dy = point.y - original.origin.y
            newY = original.origin.y + dy
            newH = original.height - dy
            if newH < minSelectionSize { newH = minSelectionSize; newY = original.maxY - minSelectionSize }
        case .bottomRight:
            newW = point.x - original.origin.x
            if newW < minSelectionSize { newW = minSelectionSize }
            let dy = point.y - original.origin.y
            newY = original.origin.y + dy
            newH = original.height - dy
            if newH < minSelectionSize { newH = minSelectionSize; newY = original.maxY - minSelectionSize }
        case .none:
            return
        }
        
        selectionRect = NSRect(x: newX, y: newY, width: newW, height: newH)
        clampSelectionRect()
    }
    
    override func draw(_ dirtyRect: NSRect) {
        // Dim everywhere except the selection rect (hole = live screen)
        let path = NSBezierPath(rect: bounds)
        let hole = NSBezierPath(rect: selectionRect)
        path.append(hole)
        path.windingRule = .evenOdd
        // Match the screenshot overlay dim so the record-area picker looks identical to it.
        NSColor.black.withAlphaComponent(kScreenshotDimOverlayAlpha).setFill()
        path.fill()
        
        // Border around the hole
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let borderPath = NSBezierPath(rect: selectionRect)
        borderPath.lineWidth = 2
        borderPath.stroke()
        
        // Resize handles
        if allowsResize {
            drawResizeHandles(for: selectionRect)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        if let toolbar = toolbarView, toolbar.frame.contains(point) {
            super.mouseDown(with: event)
            return
        }

        let edge = allowsResize ? resizeEdgeAt(point: point) : .none
        if edge != .none {
            resizingEdge = edge
            resizeStartPoint = point
            resizeOriginalRect = selectionRect
            setNeedsDisplay(bounds)
            return
        }

        // Drag inside the hole: pan the selection (same as the screenshot tool).
        if allowsResize && selectionRect.contains(point) {
            isMovingSelection = true
            moveStartPoint = point
            moveOriginalRect = selectionRect
            NSCursor.closedHand.set()
            return
        }

        // Click on dimmed area: do nothing (use Cancel button or ESC to cancel)
    }
    
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isMovingSelection, let start = moveStartPoint, let original = moveOriginalRect {
            var origin = NSPoint(
                x: original.origin.x + (point.x - start.x),
                y: original.origin.y + (point.y - start.y)
            )
            origin.x = max(0, min(origin.x, bounds.width - original.width))
            origin.y = max(0, min(origin.y, bounds.height - original.height))
            selectionRect = NSRect(origin: origin, size: original.size)
            updateToolbarPosition()
            setNeedsDisplay(bounds)
            return
        }

        if resizingEdge != .none {
            handleResizeDrag(to: point)
            updateToolbarPosition()
            setNeedsDisplay(bounds)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isMovingSelection {
            isMovingSelection = false
            moveStartPoint = nil
            moveOriginalRect = nil
            NSCursor.openHand.set()
            setNeedsDisplay(bounds)
        }
        if resizingEdge != .none {
            resizingEdge = .none
            resizeStartPoint = nil
            resizeOriginalRect = nil
            setNeedsDisplay(bounds)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if resizingEdge != .none || isMovingSelection { return }
        let edge = allowsResize ? resizeEdgeAt(point: point) : .none
        if edge == .none, allowsResize, selectionRect.contains(point) {
            NSCursor.openHand.set()
            return
        }
        setCursorForEdge(edge)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            let ta = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(ta)
        }
    }
}
