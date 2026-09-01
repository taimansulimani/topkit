import AppKit
import ObjectiveC

// Custom text field that ensures it can receive keyboard input
class EditableTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // Ensure we're editable when we become first responder
        if result {
            isEditable = true
            isSelectable = true
        }
        return result
    }
}



// MARK: - Main Annotation View

// Resize handle constants (match GuidesOverlayNSView for consistency)
private let kResizeHandleSize: CGFloat = 12
private let kResizeEdgeThickness: CGFloat = 10


/// Minimum arrow length when created with a single click (no drag).
private let kMinArrowLength: CGFloat = 60
/// Hit tolerance for selecting an arrow by clicking near its line (points).
private let kArrowLineHitTolerance: CGFloat = 14
/// Minimum arrow frame dimension to count as "dragged" (otherwise single-click).
private let kMinArrowDragSize: CGFloat = 20
/// Mouse must move this far (points) before a click on an annotation becomes a drag.
private let kAnnotationDragThreshold: CGFloat = 4
/// Rect/circle drags smaller than this in both dimensions are treated as stray clicks and discarded.
private let kMinShapeSize: CGFloat = 4

/// One dim level for every screenshot overlay surface (active-screen dim
/// outside the hole, secondary-monitor frozen overlays, window-capture
/// backdrop) so no flow looks lighter than another.
let kScreenshotDimOverlayAlpha: CGFloat = 0.80

/// Which surface this view is drawing on.
///
/// `liveRegion` is the screenshot flow's frozen selection-hole step: a full-screen
/// frozen bitmap, dimmed outside a resizable hole, ending in save-to-file.
/// `liveAnnotate` is the standalone Annotate overlay: no backdrop, no dim, no hole,
/// no save — the whole view is the canvas.
enum CanvasMode {
    case staticImage(NSImage)
    case liveRegion
    case liveAnnotate
}

class ScreenshotAnnotationView: NSView, NSTextFieldDelegate, NSMenuDelegate {
    private let mode: CanvasMode
    private var screenshotRect: NSRect
    private var annotations: [Annotation] = []

    private var screenshot: NSImage? {
        if case .staticImage(let image) = mode { return image }
        return nil
    }

    /// True for both live surfaces. Kept as the shim the pre-existing branches use.
    private var isLiveMode: Bool { screenshot == nil }

    /// True only for the screenshot flow's selection-hole step. Gates the backdrop,
    /// the dim, the hole's own resize handles, and everything that drags the hole.
    private var isRegionMode: Bool { if case .liveRegion = mode { return true }; return false }

    /// True only for the standalone Annotate overlay.
    var isAnnotateMode: Bool { if case .liveAnnotate = mode { return true }; return false }

    /// Save is meaningless on the Annotate overlay: the marks are already on screen.
    private var canSave: Bool { !isAnnotateMode }
    
    // Undo/redo (keyboard only: Cmd+Z / Cmd+Shift+Z)
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private let maxUndoSteps = 50
    
    /// Copied annotations for Cmd+V paste (stores deep copies with original coords; paste applies offset and new IDs).
    private var copiedAnnotations: [Annotation]?
    
    /// Live frozen-hole mode: save passes final rect + annotations in rect-local coords.
    var onSaveRequested: ((NSRect, [Annotation]) -> Void)?
    
    /// Fires when the selection rect changes (resize/drag) with the new rect in view-local coordinates.
    var onSelectionRectChanged: ((NSRect) -> Void)?
    
    /// Fires when a selection drag/resize ends, with the final rect in view-local coordinates.
    var onSelectionDragEnded: ((NSRect) -> Void)?

    /// Total area the selection is allowed to occupy (combined desktop in view-local coords).
    /// When nil, defaults to `bounds`.
    var allowedSelectionBounds: NSRect?

    /// Fired whenever this view invalidates, so cross-monitor overlay windows can
    /// mirror the annotation layers in the same frame.
    var onContentNeedsRedraw: (() -> Void)?

    /// Live mode: ask the manager to move the annotation window to the screen
    /// containing the given global Cocoa point (used when inline text editing
    /// starts on a monitor the window isn't on — an off-window field would be
    /// invisible). The manager updates this view via `relocateForScreenSwap`.
    var onRequestWindowMove: ((NSPoint) -> Void)?

    /// Current selection rect in view-local coordinates (live mode hole).
    var currentSelectionRect: NSRect { screenshotRect }
    
    private var currentAnnotation: Annotation?
    private var isDrawing = false
    private var startPoint: NSPoint?
    private var selectedAnnotationId: UUID? {
        didSet {
            guard selectedAnnotationId != oldValue else { return }
            if selectedAnnotationId == nil {
                dismissColorPanel()
            }
            guard isAnnotateMode else { return }
            refreshContextBar()
        }
    }
    private var isDragging = false
    private var dragOffset: NSPoint = .zero
    /// Set on mouseDown when the click landed on an annotation; a drag only starts
    /// from this annotation once the mouse moves past `kAnnotationDragThreshold`.
    /// Prevents 1px click jitter from registering as a drag (which made first
    /// clicks feel dead) and stops drags starting from clicks that missed the layer.
    private var pendingDragAnnotationId: UUID?
    private var pendingDragStartRefPoint: NSPoint?
    
    // Annotation resize state (screenshot-local coordinates)
    private var resizingAnnotationId: UUID?
    private var resizingAnnotationEdge: ResizeEdge = .none
    /// When resizing an arrow: true = dragging start point, false = dragging end point.
    private var resizingArrowEndpoint: Bool? = nil
    private var resizeAnnotationStartPoint: NSPoint?
    private var resizeAnnotationOriginalRect: NSRect?
    
    // Live mode: selection rect resize / drag (view coordinates)
    private var resizingSelectionEdge: ResizeEdge = .none
    private var resizeSelectionOriginalRect: NSRect?
    private var draggingSelectionRect = false
    private var selectionDragStartPoint: NSPoint?
    private var selectionDragStartOrigin: NSPoint?
    private let minSelectionSize: CGFloat = 40
    
    /// Frozen annotation coords relative to first hole rect so marks stay put when the selection is resized.
    private var annotationReferenceRect: NSRect?
    private var frozenDisplaySnaps: [(frame: NSRect, image: NSImage)] = []
    private var liveHoleScreenOrigin: CGPoint = .zero
    
    // Freehand drawing state
    private var currentFreehandPoints: [NSPoint] = []
    private var freehandStartPoint: NSPoint?
    private var freehandStraightLineDirection: FreehandStraightDirection?
    
    private enum FreehandStraightDirection {
        case horizontal, vertical
    }
    
    // Tool state (nil = no tool selected; no preselection)
    private var currentTool: AnnotationTool? = nil
    /// One sticker type is always selected; shown on the toolbar button and used when placing stickers.
    private var selectedStickerType: StickerType = .redX
    private var currentColor: NSColor = .red
    /// Session colour mode for new marks. Seeded from the "Default colour mode"
    /// preference per surface; carries to the next mark once the user changes it.
    private var currentColorMode: AnnotationColorMode = .solid
    /// Session opacity (0...1) for new marks, mirroring how thickness carries.
    private var currentOpacity: CGFloat = 1.0
    private var currentThickness: CGFloat = 3.0
    private var currentFontSize: CGFloat = 16.0
    /// Diameter for numbered badges (adjustable via the secondary-bar size slider).
    private var currentBadgeSize: CGFloat = 34.0
    private let badgeSizeMin: CGFloat = 16
    private let badgeSizeMax: CGFloat = 120
    
    // Toolbar
    private var toolbarView: NSView?
    private var isStickerMenuOpen = false
    
    var onClose: (() -> Void)?
    var onSave: ((NSImage) -> Void)?
    
    init(frame: NSRect, mode: CanvasMode, screenshotRect: NSRect? = nil) {
        self.mode = mode
        self.screenshotRect = screenshotRect ?? frame
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
        focusRingType = .none
        seedColorDefaultsFromPreferences()
        setupKeyMonitor()
    }
    
    /// Screenshot-flow convenience: an image means the static editor, nil means the
    /// frozen selection-hole step.
    convenience init(frame: NSRect, screenshot: NSImage? = nil, screenshotRect: NSRect? = nil) {
        self.init(frame: frame,
                  mode: screenshot.map { CanvasMode.staticImage($0) } ?? .liveRegion,
                  screenshotRect: screenshotRect)
    }

    private var toolStripView: AnnotateToolStrip?

    /// Fired when the user disarms or ends from the strip, so the host can mirror state.
    var onArmedToolChanged: ((AnnotationTool?) -> Void)?
    var onExitRequested: (() -> Void)?

    /// Fired when a removal (delete, undo, an abandoned text field) leaves this canvas
    /// with nothing on it. Only the Annotate overlay uses it: the session is allowed to
    /// outlive its armed tool so guides and marks keep sitting over other apps, so once
    /// the last one goes there is nothing left to keep alive.
    var onCanvasEmptied: (() -> Void)?

    private func notifyIfCanvasEmptied() {
        guard isAnnotateMode, annotations.isEmpty else { return }
        onCanvasEmptied?()
    }

    /// Build the Annotate overlay's own chrome. Called by the host after the view is
    /// attached; `setupToolbar` deliberately does nothing in this mode.
    func installAnnotateChrome(tools: [AnnotateToolStrip.Item]) {
        guard isAnnotateMode, toolStripView == nil else { return }
        let strip = AnnotateToolStrip(items: tools)
        strip.onToolPicked = { [weak self] tool in
            guard let self else { return }
            self.setArmedTool(tool)
            self.onArmedToolChanged?(tool)
        }
        strip.onExit = { [weak self] in self?.onExitRequested?() }
        strip.isHidden = true
        addSubview(strip)
        toolStripView = strip
        repositionAnnotateChrome()
        updateToolStripSelection()
    }

    // MARK: - Redaction (Annotate overlay)

    /// This screen's desktop pixels, captured once by the host when Redact was armed
    /// and with our own overlay excluded. Cropped per mark at placement time.
    var redactionSource: NSImage? {
        didSet { rebakeAllRedactions() }
    }

    /// Pixelate the region under `frame` from the captured desktop.
    /// Frames are in annotation space (top-left, Y-down), which is also how the
    /// captured image is addressed, so the rect maps across unchanged.
    private func bakedMosaicFromSource(forFrame frame: NSRect) -> NSImage? {
        guard let source = redactionSource, frame.width >= 1, frame.height >= 1 else { return nil }
        return AnnotationRenderer.bakedMosaic(of: source, sourceRect: frame, outSize: frame.size)
    }

    /// Re-bake a mark after it has been moved or resized, so it shows the pixels it
    /// now covers rather than stretching the ones it used to.
    private func rebakeRedaction(id: UUID) {
        guard isAnnotateMode,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case .blur = annotations[index].type else { return }
        annotations[index].bakedMosaic = bakedMosaicFromSource(forFrame: annotations[index].frame)
        setNeedsDisplay(bounds)
    }

    private func rebakeAllRedactions() {
        guard isAnnotateMode, redactionSource != nil else { return }
        for index in annotations.indices where annotations[index].bakedMosaic == nil {
            if case .blur = annotations[index].type {
                annotations[index].bakedMosaic = bakedMosaicFromSource(forFrame: annotations[index].frame)
            }
        }
        setNeedsDisplay(bounds)
    }

    // MARK: - Contextual bar (Annotate overlay)

    private var contextBar: AnnotationContextBar?

    /// Rebuild the bar for the current selection, or tear it down if nothing is
    /// selected. Cheap enough to rebuild rather than diff: it is at most six controls.
    private func refreshContextBar() {
        updateAnnotateChromeVisibility()
        contextBar?.removeFromSuperview()
        contextBar = nil

        guard isAnnotateMode,
              let id = selectedAnnotationId,
              let annotation = annotations.first(where: { $0.id == id }) else { return }

        let controls = AnnotationContextBar.Control.controls(for: annotation.type)
        guard !controls.isEmpty else { return }

        let stickerType: StickerType? = {
            if case .sticker(let t) = annotation.type { return t }
            return nil
        }()
        let guideOrientation: GuideOrientation = {
            if case .guide(let o) = annotation.type { return o }
            return .horizontal
        }()

        let bar = AnnotationContextBar(
            controls: controls,
            color: annotation.color,
            value: contextBarValue(for: annotation, controls: controls),
            stickerType: stickerType,
            isRainbow: annotation.colorMode == .rainbow,
            opacity: annotation.opacity,
            orientation: guideOrientation
        )
        bar.onColorClicked = { [weak self] in self?.showColorPicker() }
        bar.onOpacityChanged = { [weak self] value in self?.applyOpacity(value) }
        bar.onRainbowToggled = { [weak self] isRainbow in
            self?.applyColorMode(isRainbow ? .rainbow : .solid)
        }
        bar.onSliderChanged = { [weak self] control, value in
            self?.applyContextBarSlider(control, value: value)
        }
        bar.onStickerTypeChanged = { [weak self] type in
            self?.applyStickerType(type)
        }
        bar.onOrientationToggled = { [weak self] orientation in
            self?.applyGuideOrientation(orientation)
        }
        bar.onDelete = { [weak self] in _ = self?.deleteSelectedAnnotation() }
        addSubview(bar)
        contextBar = bar
        positionContextBar()
    }

    private func contextBarValue(for annotation: Annotation, controls: [AnnotationContextBar.Control]) -> CGFloat {
        if controls.contains(.fontSize) { return annotation.fontSize ?? currentFontSize }
        if controls.contains(.badgeSize) { return annotation.frame.height }
        if controls.contains(.stickerSize) { return annotation.frame.height }
        return annotation.thickness
    }

    private func applyContextBarSlider(_ control: AnnotationContextBar.Control, value: CGFloat) {
        guard let id = selectedAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch control {
        case .thickness:
            pushUndoForContinuousEdit(.thickness, annotationId: id)
            annotations[index].thickness = value
            currentThickness = value
        case .fontSize:
            pushUndoForContinuousEdit(.fontSize, annotationId: id)
            annotations[index].fontSize = value
            currentFontSize = value
            annotations[index].frame = AnnotationRenderer.textAnnotationFrame(
                text: annotations[index].text ?? "",
                fontSize: value,
                topLeft: annotations[index].frame.origin
            )
        case .badgeSize, .stickerSize:
            pushUndoForContinuousEdit(.badgeSize, annotationId: id)
            var frame = annotations[index].frame
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            frame.size = NSSize(width: value, height: value)
            frame.origin = NSPoint(x: centre.x - value / 2, y: centre.y - value / 2)
            annotations[index].frame = frame
        case .color, .stickerType, .rainbow, .opacity, .orientation:
            return
        }
        setNeedsDisplay(bounds)
        // Do not move the bar while the slider is being dragged. Font/badge/sticker
        // size changes the selection bounds, which would re-anchor the bar under the
        // cursor and make the thumb fight the mouse (severe flicker). Snap on release.
        if NSApp.currentEvent?.type == .leftMouseUp {
            positionContextBar()
            lastContinuousEdit = nil
        }
    }

    private func applyOpacity(_ value: CGFloat) {
        // Carry to the next mark, mirroring thickness.
        currentOpacity = value
        guard let id = selectedAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        annotations[index].opacity = value
        setNeedsDisplay(bounds)
    }

    private func applyColorMode(_ mode: AnnotationColorMode) {
        // Carry the choice to the next mark, so flipping a mark to rainbow keeps the
        // following marks rainbow until the user switches back (per the session model).
        currentColorMode = mode
        guard let id = selectedAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        annotations[index].colorMode = mode
        setNeedsDisplay(bounds)
    }

    private func applyStickerType(_ type: StickerType) {
        guard let id = selectedAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case .sticker = annotations[index].type else { return }
        pushUndo()
        let old = annotations[index]
        annotations[index] = Annotation(
            id: old.id, type: .sticker(type), frame: old.frame, color: old.color,
            thickness: old.thickness, text: old.text, fontSize: old.fontSize,
            startPoint: old.startPoint, endPoint: old.endPoint, pathPoints: old.pathPoints,
            stickerPointerDirection: old.stickerPointerDirection, badgeNumber: old.badgeNumber,
            colorMode: old.colorMode
        )
        setNeedsDisplay(bounds)
        refreshContextBar()
    }

    /// Flip a guide between horizontal and vertical, re-spanning the canvas through its
    /// current centre. `type` is a `let`, so the mark is rebuilt like a sticker's type.
    private func applyGuideOrientation(_ orientation: GuideOrientation) {
        guard let id = selectedAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case .guide = annotations[index].type else { return }
        pushUndo()
        let old = annotations[index]
        let t = max(old.thickness, 2)
        let canvas = visibleAnnotationSpaceRect
        let centre = NSPoint(x: old.frame.midX, y: old.frame.midY)
        let frame: NSRect = orientation == .horizontal
            ? NSRect(x: canvas.minX, y: centre.y - t / 2, width: canvas.width, height: t)
            : NSRect(x: centre.x - t / 2, y: canvas.minY, width: t, height: canvas.height)
        annotations[index] = Annotation(
            id: old.id, type: .guide(orientation), frame: frame, color: old.color,
            thickness: old.thickness, text: old.text, fontSize: old.fontSize,
            startPoint: old.startPoint, endPoint: old.endPoint, pathPoints: old.pathPoints,
            stickerPointerDirection: old.stickerPointerDirection, badgeNumber: old.badgeNumber,
            colorMode: old.colorMode, opacity: old.opacity, bakedMosaic: old.bakedMosaic
        )
        setNeedsDisplay(bounds)
        refreshContextBar()
        positionContextBar()
    }

    private func positionContextBar() {
        guard let bar = contextBar,
              let id = selectedAnnotationId,
              let annotation = annotations.first(where: { $0.id == id }) else { return }
        // Annotation frames are top-left/Y-down; convert to this view's coordinates.
        let f = effectiveFrame(for: annotation)
        let topLeft = viewPointFromAnnotationSpace(NSPoint(x: f.minX, y: f.minY))
        let bottomRight = viewPointFromAnnotationSpace(NSPoint(x: f.maxX, y: f.maxY))
        let selection = NSRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
        bar.frame.origin = AnnotationContextBar.origin(
            forSelection: selection,
            barSize: bar.frame.size,
            in: bounds,
            avoiding: (toolStripView?.isHidden == false) ? toolStripView?.frame : nil
        )
    }

    /// Annotation space is top-left/Y-down; this view is bottom-left/Y-up.
    /// `convertPointFromAnnotationSpace` used to look like the right tool for this and
    /// is not — it returns screenshot-local Y-down, and was deleted for that reason.
    private func viewPointFromAnnotationSpace(_ p: NSPoint) -> NSPoint {
        let ref = annotationSpaceRect
        return NSPoint(x: ref.origin.x + p.x, y: ref.maxY - p.y)
    }

    private func repositionAnnotateChrome() {
        positionContextBar()
        guard let strip = toolStripView else { return }
        let bottomInset: CGFloat = 48
        strip.frame.origin = NSPoint(
            x: (bounds.width - strip.frame.width) / 2,
            y: bottomInset
        )
    }

    private func updateToolStripSelection() {
        toolStripView?.setArmed(currentTool)
        updateAnnotateChromeVisibility()
    }

    /// Idle Annotate (no tool armed, nothing selected) shows the marks and nothing
    /// else — the strip would otherwise sit permanently over the user's screen.
    /// Re-arming from there goes through the menu or a shortcut.
    private func updateAnnotateChromeVisibility() {
        guard isAnnotateMode, let strip = toolStripView else { return }
        strip.isHidden = (currentTool == nil && selectedAnnotationId == nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard isAnnotateMode else { return }
        // Annotation space IS the whole view here. If bounds moves and screenshotRect
        // does not, every mark and every hit-test shifts by the height delta.
        screenshotRect = bounds
        annotationReferenceRect = bounds
        repositionAnnotateChrome()
    }

    // MARK: - Annotate overlay API

    /// The manager owns the annotation list so a hotplug-driven view rebuild does not
    /// wipe the canvas (the view is thrown away; the model is not).
    var annotationsForHost: [Annotation] {
        get { annotations }
        set {
            annotations = newValue
            selectedAnnotationId = nil
            setNeedsDisplay(bounds)
        }
    }

    /// Called when the host needs to know whether this point should be captured or
    /// passed through to the app underneath. True means "this overlay wants the click".
    func isInteractive(atViewPoint point: NSPoint) -> Bool {
        // An armed tool captures everywhere, or you could never start a mark.
        if currentTool != nil { return true }
        if let strip = toolStripView, !strip.isHidden, strip.frame.contains(point) { return true }
        // The context bar floats away from its annotation, so a point over it hits
        // neither the mark nor its handles. Without this the overlay goes
        // pass-through under the pointer and every button on the bar is dead.
        if let bar = contextBar, !bar.isHidden, bar.frame.contains(point) { return true }
        if inlineTextField != nil { return true }
        // An open dimension field (or its W/H label outside a small grid) sits away
        // from the mark body — without this, click-through swallows the click and
        // the field never becomes first responder.
        if gridSizeField != nil { return true }
        let refPoint = convertPointToAnnotationSpace(convertPointToScreenshotCoordinates(point))
        if gridLabelHit(at: refPoint) != nil { return true }
        if findAnnotation(at: refPoint) != nil { return true }
        if let id = selectedAnnotationId,
           let annotation = annotations.first(where: { $0.id == id }) {
            let rect = effectiveFrame(for: annotation)
            let edge: ResizeEdge
            if case .guide = annotation.type {
                // A full-canvas guide is not resized — only moved perpendicular.
                edge = .none
            } else if case .text = annotation.type {
                edge = textResizeEdgeAtAnnotationSpace(point: refPoint, rect: rect)
            } else {
                edge = resizeEdgeAtAnnotationSpace(point: refPoint, rect: rect)
            }
            if edge != .none { return true }
        }
        return false
    }

    /// Screen-point variant for the host's click-through monitor, which works in
    /// global coordinates and has no view to convert against.
    func isInteractive(atScreenPoint screenPoint: NSPoint) -> Bool {
        guard let window = window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = convert(windowPoint, from: nil)
        guard bounds.contains(viewPoint) else { return false }
        return isInteractive(atViewPoint: viewPoint)
    }

    /// True while a mark is being drawn or an element dragged, so the host keeps the
    /// overlay interactive even if the pointer strays onto empty canvas mid-gesture.
    var isMidGesture: Bool { isDragging || isDrawing || resizingAnnotationId != nil }

    /// Deselect without ending anything else. Returns true if there was a selection.
    @discardableResult
    func deselectForHost() -> Bool {
        guard selectedAnnotationId != nil else { return false }
        selectedAnnotationId = nil
        setNeedsDisplay(bounds)
        return true
    }

    /// Arm a tool from the host (menu, shortcut, or tool strip).
    func setArmedTool(_ tool: AnnotationTool?) {
        if tool != currentTool {
            dismissColorPanel()
        }
        currentTool = tool
        updateToolStripSelection()
        setNeedsDisplay(bounds)
    }

    var armedTool: AnnotationTool? { currentTool }

    func configureLiveHoleFrozenSources(screenOrigin: CGPoint, snapshots: [(frame: NSRect, image: NSImage)]) {
        liveHoleScreenOrigin = screenOrigin
        frozenDisplaySnaps = snapshots
        setNeedsDisplay(bounds)
    }
    
    /// Move this view to a different screen. Adjusts the view's own frame/bounds,
    /// screenshotRect, annotation reference, frozen backdrop origin, allowed
    /// bounds, and repositions the toolbar. The view stays attached to its
    /// window; we deliberately do NOT detach + re-attach, to avoid triggering
    /// `viewDidMoveToWindow` → `setupToolbar()` which would leave an orphaned
    /// toolbar subview ("printed" ghost toolbar) behind.
    func relocateForScreenSwap(newScreenshotRect: NSRect, newScreenOrigin: CGPoint, newAllowedBounds: NSRect) {
        let oldRect = screenshotRect
        if let window = self.window {
            let target = NSRect(origin: .zero, size: window.frame.size)
            if frame != target {
                frame = target
                bounds = target
            }
        }
        screenshotRect = newScreenshotRect
        liveHoleScreenOrigin = newScreenOrigin
        allowedSelectionBounds = newAllowedBounds
        if let ref = annotationReferenceRect {
            let dx = newScreenshotRect.origin.x - oldRect.origin.x
            let dy = newScreenshotRect.origin.y - oldRect.origin.y
            annotationReferenceRect = NSRect(x: ref.origin.x + dx, y: ref.origin.y + dy,
                                             width: ref.width, height: ref.height)
        }
        updateToolbarPosition()
        setNeedsDisplay(bounds)
    }
    
    /// Frozen grab for this overlay’s display (full screen), for painting the whole view — not a live desktop.
    /// Draw all frozen per-display snapshots tiled at the correct positions within this view.
    private func drawFrozenBackdropTiled() {
        let windowOrigin = liveHoleScreenOrigin
        for snap in frozenDisplaySnaps {
            let dst = NSRect(
                x: snap.frame.origin.x - windowOrigin.x,
                y: snap.frame.origin.y - windowOrigin.y,
                width: snap.frame.width,
                height: snap.frame.height
            )
            let src = NSRect(origin: .zero, size: snap.image.size)
            snap.image.draw(in: dst, from: src, operation: .sourceOver, fraction: 1.0)
        }
    }
    
    /// Dim only **outside** the selection rect, on top of the already-drawn full-screen frozen bitmap.
    private func fillDimOutsideSelection(_ r: NSRect) {
        let dim = NSColor.black.withAlphaComponent(kScreenshotDimOverlayAlpha)
        dim.setFill()
        let w = bounds.width
        let h = bounds.height
        if r.minY > 0 {
            NSRect(x: 0, y: 0, width: w, height: r.minY).fill()
        }
        if r.maxY < h {
            NSRect(x: 0, y: r.maxY, width: w, height: h - r.maxY).fill()
        }
        if r.minX > 0 && r.height > 0 {
            NSRect(x: 0, y: r.minY, width: r.minX, height: r.height).fill()
        }
        if r.maxX < w && r.height > 0 {
            NSRect(x: r.maxX, y: r.minY, width: w - r.maxX, height: r.height).fill()
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupToolbar()
            if !isRegionMode {
                window?.makeKey()
                if inlineTextField == nil {
                    window?.makeFirstResponder(self)
                }
            }
            setupKeyMonitor()
        } else {
            removeAllKeyMonitors()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        onContentNeedsRedraw?()
    }

    override var acceptsFirstResponder: Bool {
        // Don't accept first responder while a field editor owns the keyboard —
        // otherwise the canvas steals focus back from the inline / grid field.
        inlineTextField == nil && gridSizeField == nil
    }
    override var canBecomeKeyView: Bool {
        inlineTextField == nil && gridSizeField == nil
    }
    
    override func keyDown(with event: NSEvent) {
        // If text field exists and has editor, don't intercept at all
        if let textField = inlineTextField, textField.currentEditor() != nil {
            // Let the responder chain handle it - don't intercept
            super.keyDown(with: event)
            return
        }
        if let field = gridSizeField, field.currentEditor() != nil {
            super.keyDown(with: event)
            return
        }
        
        // No active text field or editor - handle shortcuts
        if event.keyCode == 53 { // ESC
            closeAnnotation()
        } else if event.keyCode == 36 { // Enter/Return
            saveScreenshot()
        } else {
            super.keyDown(with: event)
        }
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // If text field exists and has editor, don't handle key equivalents
        if let textField = inlineTextField, textField.currentEditor() != nil {
            return false
        }
        if let field = gridSizeField, field.currentEditor() != nil {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
    
    // MARK: - Toolbar Setup
    
    private func setupToolbar() {
        // The Annotate overlay has its own tool strip; the editor toolbar carries a
        // Save button and would sit inside the canvas as a permanent dead zone.
        guard !isAnnotateMode else { return }

        // Idempotent: if we already built a toolbar (e.g. the view was detached
        // and re-attached to its window), throw away the old subviews before
        // creating fresh ones. Otherwise the old toolbar/slider would be
        // orphaned in the view hierarchy — the root cause of the "ghost /
        // printed toolbar on the other monitor" bug after a screen swap.
        toolbarView?.removeFromSuperview()
        sliderContainer?.removeFromSuperview()
        toolbarView = nil
        sliderContainer = nil
        thicknessSlider = nil
        fontSizeSlider = nil
        badgeSizeSlider = nil
        colorButton = nil
        editorRainbowButton = nil
        editorOpacityButton = nil

        let toolbarHeight: CGFloat = 36
        let buttonSize: CGFloat = 28
        let spacing: CGFloat = 4
        var x: CGFloat = 6
        let y: CGFloat = 4
        
        // Build toolbar content first to calculate width
        let toolbar = NSView(frame: .zero)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 5
        
        // Freehand tool (first, default)
        let freehandButton = createToolButton(title: "Freehand", icon: "pencil.tip", tool: .freehand)
        freehandButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(freehandButton)
        x += buttonSize + spacing
        
        // Rectangle tool
        let rectButton = createToolButton(title: "Rectangle", icon: "rectangle", tool: .rectangle)
        rectButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(rectButton)
        x += buttonSize + spacing
        
        // Circle tool
        let circleButton = createToolButton(title: "Circle", icon: "circle", tool: .circle)
        circleButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(circleButton)
        x += buttonSize + spacing
        
        // Arrow tool
        let arrowButton = createToolButton(title: "Arrow", icon: "arrow.up", tool: .arrow)
        arrowButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(arrowButton)
        x += buttonSize + spacing
        
        // Text tool
        let textButton = createToolButton(title: "Text", icon: "textformat", tool: .text)
        textButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(textButton)
        x += buttonSize + spacing
        
        // Redact (mosaic blur) tool — before the sticker per requested tool order.
        let blurButton = createToolButton(title: "Redact", icon: "eye.slash.fill", tool: .blur)
        blurButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(blurButton)
        x += buttonSize + spacing

        // Sticker button — wider than square so the type-menu chevron sits to the RIGHT of
        // the circle (not below), which also visually signals the split-button behaviour.
        let stickerButtonWidth = buttonSize + 12
        let stickerButton = createStickerButton()
        stickerButton.frame = NSRect(x: x, y: y, width: stickerButtonWidth, height: buttonSize)
        toolbar.addSubview(stickerButton)
        x += stickerButtonWidth + spacing

        // Numbered badge tool
        let badgeButton = createToolButton(title: "Numbered badge", icon: "1.circle", tool: .numberBadge)
        badgeButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(badgeButton)
        x += buttonSize + spacing

        // Measure tool (two-point ruler with a pixel-distance label).
        let measureButton = createToolButton(title: "Measure", icon: "ruler", tool: .measure)
        measureButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(measureButton)
        x += buttonSize + spacing

        // Guides + grid (folded in from the old Add Guides menu).
        let vGuideButton = createToolButton(title: "Vertical guide", icon: "arrow.up.and.down", tool: .guide(.vertical))
        vGuideButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(vGuideButton)
        x += buttonSize + spacing

        let hGuideButton = createToolButton(title: "Horizontal guide", icon: "arrow.left.and.right", tool: .guide(.horizontal))
        hGuideButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(hGuideButton)
        x += buttonSize + spacing

        let gridButton = createToolButton(title: "Grid", icon: "square.grid.3x3", tool: .grid)
        gridButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        toolbar.addSubview(gridButton)
        x += buttonSize + spacing

        // Divider separating the drawing tools from the Close / Save actions.
        x += spacing
        toolbar.addSubview(makeToolbarDivider(atX: x, buttonY: y, buttonSize: buttonSize))
        x += 1 + spacing * 2

        // Close button. These two pass `.freehand` only to satisfy the tag helper, so
        // their tooltips are set explicitly — otherwise they would advertise the
        // Freehand shortcut.
        let closeButton = createToolButton(title: "Close", icon: "xmark", tool: .freehand)
        closeButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        closeButton.tag = 0
        closeButton.action = #selector(closeAnnotation)
        closeButton.toolTip = AnnotationToolShortcuts.tooltip(
            "Close", fixedKey: AnnotationToolShortcuts.FixedKey.escape
        )
        toolbar.addSubview(closeButton)
        x += buttonSize + spacing

        // Save button
        let saveButton = createToolButton(title: "Save", icon: "checkmark", tool: .freehand)
        saveButton.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        saveButton.tag = 0
        saveButton.action = #selector(saveScreenshot)
        saveButton.toolTip = AnnotationToolShortcuts.tooltip(
            "Save", fixedKey: AnnotationToolShortcuts.FixedKey.return
        )
        toolbar.addSubview(saveButton)
        x += buttonSize + spacing
        
        // Calculate actual width needed (hug content)
        let toolbarWidth = x
        
        // Position toolbar above or below screenshot so it and the slider stay in viewport; keep slider clear of screenshot top
        let gapAboveScreenshot: CGFloat = 44  // enough so slider row doesn’t cover screenshot top
        let sliderRowHeight: CGFloat = 28
        let gapBetweenToolbarAndSlider: CGFloat = 4
        let sliderContainerWidth = toolbarWidth
        let requiredSpace: CGFloat = gapAboveScreenshot + toolbarHeight + gapBetweenToolbarAndSlider + sliderRowHeight
        let spaceAboveSelection = bounds.height - (screenshotRect.origin.y + screenshotRect.height)
        let spaceBelowSelection = screenshotRect.origin.y
        let toolbarY: CGFloat
        if spaceAboveSelection >= requiredSpace {
            toolbarY = screenshotRect.origin.y + screenshotRect.height + gapAboveScreenshot
        } else if spaceBelowSelection >= requiredSpace {
            let gapBelow: CGFloat = 44
            toolbarY = screenshotRect.origin.y - gapBelow - toolbarHeight - gapBetweenToolbarAndSlider - sliderRowHeight
        } else {
            let inset: CGFloat = 8
            toolbarY = screenshotRect.origin.y + screenshotRect.height - inset - toolbarHeight - gapBetweenToolbarAndSlider - sliderRowHeight
        }
        let toolbarX = screenshotRect.origin.x + (screenshotRect.width - toolbarWidth) / 2
        toolbar.frame = NSRect(x: toolbarX, y: toolbarY, width: toolbarWidth, height: toolbarHeight)
        toolbar.identifier = AnnotationToolbarChrome.Identifier.editorToolbar
        addSubview(toolbar)
        toolbarView = toolbar
        
        // Row 2: slider container (slider + color button), below the toolbar
        let sliderContainer = NSView(frame: NSRect(x: toolbarX, y: toolbarY - sliderRowHeight - gapBetweenToolbarAndSlider, width: sliderContainerWidth, height: sliderRowHeight))
        sliderContainer.wantsLayer = true
        sliderContainer.layer?.cornerRadius = 5
        sliderContainer.identifier = AnnotationToolbarChrome.Identifier.editorSliderRow
        sliderContainer.isHidden = true
        
        let colorButtonSize: CGFloat = 24
        let clusterGap: CGFloat = 4
        // Right cluster, left→right: colour well, rainbow toggle, opacity dropdown —
        // pick a colour, decide whether it is a gradient, then set how strong it is.
        let sliderRightPadding: CGFloat = 6 + colorButtonSize * 3 + clusterGap * 2 + 6
        let sliderWidth = sliderContainerWidth - 12 - sliderRightPadding
        
        // Thickness slider
        let sliderInsetY: CGFloat = 2
        let sliderHeight: CGFloat = sliderRowHeight - (sliderInsetY * 2)
        let thicknessSlider = NSSlider(frame: NSRect(x: 6, y: sliderInsetY, width: sliderWidth, height: sliderHeight))
        thicknessSlider.controlSize = .small
        thicknessSlider.minValue = 1
        thicknessSlider.maxValue = 20
        thicknessSlider.doubleValue = Double(currentThickness)
        thicknessSlider.target = self
        thicknessSlider.action = #selector(thicknessChanged(_:))
        sliderContainer.addSubview(thicknessSlider)
        self.thicknessSlider = thicknessSlider
        
        // Font size slider - same layout
        let fontSizeSlider = NSSlider(frame: NSRect(x: 6, y: sliderInsetY, width: sliderWidth, height: sliderHeight))
        fontSizeSlider.controlSize = .small
        fontSizeSlider.minValue = 8
        fontSizeSlider.maxValue = 72
        fontSizeSlider.doubleValue = Double(currentFontSize)
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(fontSizeChanged(_:))
        sliderContainer.addSubview(fontSizeSlider)
        self.fontSizeSlider = fontSizeSlider

        // Badge size slider - same layout; controls the numbered-badge diameter.
        let badgeSizeSlider = NSSlider(frame: NSRect(x: 6, y: sliderInsetY, width: sliderWidth, height: sliderHeight))
        badgeSizeSlider.controlSize = .small
        badgeSizeSlider.minValue = Double(badgeSizeMin)
        badgeSizeSlider.maxValue = Double(badgeSizeMax)
        badgeSizeSlider.doubleValue = Double(currentBadgeSize)
        badgeSizeSlider.target = self
        badgeSizeSlider.action = #selector(badgeSizeChanged(_:))
        badgeSizeSlider.isHidden = true
        sliderContainer.addSubview(badgeSizeSlider)
        self.badgeSizeSlider = badgeSizeSlider
        
        // Color button on row 2, after the slider (right side of row)
        // Align to the slider knob's true center Y so visuals match AppKit rendering.
        let colorButtonY: CGFloat = {
            guard let cell = thicknessSlider.cell as? NSSliderCell else {
                return floor((sliderRowHeight - colorButtonSize) / 2)
            }
            let knobRect = cell.knobRect(flipped: false)
            let knobMidYInContainer = thicknessSlider.frame.minY + knobRect.midY
            return floor(knobMidYInContainer - (colorButtonSize / 2))
        }()
        // Laid out right to left, so opacity is the rightmost of the three.
        let opacityX = sliderContainerWidth - 6 - colorButtonSize
        let rainbowX = opacityX - clusterGap - colorButtonSize
        let colorX = rainbowX - clusterGap - colorButtonSize

        let colorButton = createColorButton()
        colorButton.frame = NSRect(x: colorX, y: colorButtonY, width: colorButtonSize, height: colorButtonSize)
        sliderContainer.addSubview(colorButton)
        self.colorButton = colorButton

        let rainbowButton = makeSliderRowButton(icon: "rainbow", tooltip: "Rainbow", action: #selector(editorRainbowToggled))
        rainbowButton.frame = NSRect(x: rainbowX, y: colorButtonY, width: colorButtonSize, height: colorButtonSize)
        sliderContainer.addSubview(rainbowButton)
        self.editorRainbowButton = rainbowButton

        let opacityButton = makeSliderRowButton(icon: "circle.lefthalf.filled", tooltip: "Opacity", action: #selector(editorOpacityClicked))
        opacityButton.frame = NSRect(x: opacityX, y: colorButtonY, width: colorButtonSize, height: colorButtonSize)
        sliderContainer.addSubview(opacityButton)
        self.editorOpacityButton = opacityButton

        addSubview(sliderContainer)
        self.sliderContainer = sliderContainer

        // Ensure default tool (freehand) is shown as selected
        updateToolButtonStates()
        updateSliderVisibility()
        updateColorButtonIcon()
        updateEditorColorModeButtonState()
        applyAnnotationToolbarChrome()
    }

    private func makeSliderRowButton(icon: String, tooltip: String, action: Selector) -> HoverStateButton {
        let button = HoverStateButton(frame: .zero)
        button.title = ""
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = tooltip
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            button.image = image.withSymbolConfiguration(config)
        }
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.onHoverChanged = { [weak self] _ in self?.updateEditorColorModeButtonState() }
        return button
    }

    /// Repaint the slider row's right cluster: rainbow lit while the session is in
    /// rainbow mode, the other two hover-only.
    ///
    /// These buttons live in `sliderContainer`, not `toolbarView`, so the toolbar's own
    /// refresh never reached them. Without this the hover wash painted on the rainbow
    /// toggle outlived the pointer and read as "still selected" after switching it off.
    private func updateEditorColorModeButtonState() {
        if let b = editorRainbowButton {
            AnnotationToolbarChrome.applyButtonBackground(button: b, isSelected: currentColorMode == .rainbow)
        }
        if let b = editorOpacityButton {
            AnnotationToolbarChrome.applyButtonBackground(button: b, isSelected: false)
        }
        if let b = colorButton {
            AnnotationToolbarChrome.applyButtonBackground(button: b, isSelected: false)
        }
    }

    @objc private func editorRainbowToggled() {
        applyColorMode(currentColorMode == .rainbow ? .solid : .rainbow)
        updateColorButtonIcon()
        // Drop AppKit's momentary press highlight, or a just-deselected toggle keeps
        // looking on until the next mouse move.
        editorRainbowButton?.isHighlighted = false
        updateEditorColorModeButtonState()
    }

    @objc private func editorOpacityClicked() {
        guard let button = editorOpacityButton else { return }
        let menu = NSMenu()
        for percent in stride(from: 100, through: 10, by: -10) {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(editorOpacityMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            if Int((currentOpacity * 100).rounded()) == percent { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func editorOpacityMenuPicked(_ sender: NSMenuItem) {
        applyOpacity(CGFloat(sender.tag) / 100.0)
        editorOpacityButton?.toolTip = "Opacity (\(sender.tag)%)"
    }

    /// Toolbar matches system appearance: light panel in light mode, dark panel in dark mode.
    private func applyAnnotationToolbarChrome() {
        guard let toolbar = toolbarView, let slider = sliderContainer else { return }
        AnnotationToolbarChrome.applyContainerChrome(toolbar)
        AnnotationToolbarChrome.applyContainerChrome(slider)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAnnotationToolbarChrome()
    }
    
    /// A thin vertical divider for the toolbar, vertically centred on the button band.
    private func makeToolbarDivider(atX x: CGFloat, buttonY: CGFloat, buttonSize: CGFloat) -> NSView {
        AnnotationToolbarChrome.makeDivider(atX: x, buttonY: buttonY, buttonSize: buttonSize)
    }

    private func createToolButton(title: String, icon: String, tool: AnnotationTool) -> NSButton {
        let button = HoverStateButton(frame: .zero)
        button.title = ""
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.isBordered = false
        // Same tooltip text as the Annotate strip, shortcut included — the two toolbars
        // arm the same tools with the same keys, so they must read the same.
        button.toolTip = AnnotationToolShortcuts.tooltip(title, tool: tool)

        if let iconImage = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            button.image = iconImage.withSymbolConfiguration(config)
        }
        
        button.target = self
        button.action = #selector(toolButtonClicked(_:))
        button.tag = toolToTag(tool)
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.onHoverChanged = { [weak self] _ in
            self?.updateToolButtonStates()
        }
        
        return button
    }
    
    private func createColorButton() -> NSButton {
        let button = HoverStateButton(frame: .zero)
        button.title = ""
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.isBordered = false
        
        // Create a small colored square icon (same visual weight as other icons)
        let iconSize: CGFloat = 12
        let colorIcon = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { rect in
            self.currentColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            return true
        }
        button.image = colorIcon
        // The key already carries an en-GB "Colour" override, so localise rather than
        // hardcoding either spelling.
        button.toolTip = String(localized: "Color")

        button.target = self
        button.action = #selector(showColorPicker)
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.onHoverChanged = { [weak self] _ in
            self?.updateToolButtonStates()
        }
        
        // Store reference to update icon when color changes
        objc_setAssociatedObject(button, "isColorButton", true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        return button
    }
    
    private var stickerButton: NSButton?
    private var stickerMenu: NSMenu?
    /// Set when showing sticker pointer context menu; used by menu action to know which sticker to update.
    private var contextMenuStickerAnnotationId: UUID?
    
    private func stickerIcon(symbol: String, color: NSColor, pointSize: CGFloat = 12) -> NSImage? {
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let configured = img.withSymbolConfiguration(config) else { return nil }
        // Render at the symbol's natural size (same as createToolButton's icons) so the sticker
        // circle is the same diameter as the numbered-badge "1.circle" icon, not oversized.
        let size = configured.size
        let result = NSImage(size: size)
        result.lockFocus()
        configured.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
    
    private func createStickerButton() -> NSButton {
        let button = HoverStateButton(frame: .zero)
        button.title = ""
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.tag = 6 // sticker button (not 1–5)
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.onHoverChanged = { [weak self] _ in
            self?.updateToolButtonStates()
        }
        button.target = self
        button.action = #selector(stickerButtonClicked(_:))
        stickerButton = button
        // Menu: pick which sticker type (one is always selected)
        let menu = NSMenu()
        let redItem = NSMenuItem(title: "Red X", action: #selector(stickerMenuItemPicked(_:)), keyEquivalent: "")
        redItem.tag = 10
        redItem.target = self
        menu.addItem(redItem)
        let greenItem = NSMenuItem(title: "Green Check", action: #selector(stickerMenuItemPicked(_:)), keyEquivalent: "")
        greenItem.tag = 11
        greenItem.target = self
        menu.addItem(greenItem)
        let yellowItem = NSMenuItem(title: "Yellow Exclamation", action: #selector(stickerMenuItemPicked(_:)), keyEquivalent: "")
        yellowItem.tag = 12
        yellowItem.target = self
        menu.addItem(yellowItem)
        menu.delegate = self
        stickerMenu = menu
        updateStickerButtonIcon()
        return button
    }
    
    private func updateStickerButtonIcon() {
        guard let button = stickerButton else { return }
        let type = (currentTool.flatMap { t in if case .sticker(let s) = t { return s }; return nil }) ?? selectedStickerType
        let (symbol, color): (String, NSColor) = {
            switch type {
            case .redX: return ("xmark.circle.fill", .systemRed)
            case .greenCheck: return ("checkmark.circle.fill", .systemGreen)
            case .yellowExclamation: return ("exclamationmark.triangle.fill", .systemYellow)
            }
        }()
        button.image = stickerButtonImage(symbol: symbol, color: color)
        let name = AnnotationToolShortcuts.displayString(for: .sticker(type))
            .map { "Sticker (\($0))" } ?? "Sticker"
        button.toolTip = "\(name) — click to select, click again to change type"
    }

    /// Sticker glyph with a small disclosure chevron in the corner, signalling the hidden
    /// type menu (per split-button UI convention).
    private func stickerButtonImage(symbol: String, color: NSColor) -> NSImage? {
        guard let base = stickerIcon(symbol: symbol, color: color) else { return nil }
        let baseSize = base.size
        // Lay the disclosure chevron OUT to the right of the circle (the button is wider than
        // square to make room), vertically centred on it — a side-by-side split-button look.
        var chevronImage: NSImage?
        var chevronSize = NSSize.zero
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)) {
            chevronSize = chevron.size
            let tinted = NSImage(size: chevronSize)
            tinted.lockFocus()
            chevron.draw(in: NSRect(origin: .zero, size: chevronSize), from: .zero, operation: .sourceOver, fraction: 1.0)
            NSColor.labelColor.set()
            NSRect(origin: .zero, size: chevronSize).fill(using: .sourceAtop)
            tinted.unlockFocus()
            chevronImage = tinted
        }
        let gap: CGFloat = 2
        let canvas = NSSize(width: baseSize.width + gap + chevronSize.width, height: baseSize.height)
        let composed = NSImage(size: canvas)
        composed.lockFocus()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        chevronImage?.draw(
            at: NSPoint(x: baseSize.width + gap, y: (canvas.height - chevronSize.height) / 2),
            from: .zero, operation: .sourceOver, fraction: 1.0
        )
        composed.unlockFocus()
        composed.isTemplate = false
        return composed
    }
    
    @objc private func stickerButtonClicked(_ sender: NSButton) {
        if case .sticker = currentTool {
            // Already selected: show menu to pick a different sticker type
            guard let menu = stickerMenu else { return }
            isStickerMenuOpen = true
            updateToolButtonStates()
            let frame = sender.convert(sender.bounds, to: nil)
            guard let window = sender.window else { return }
            let screenPoint = window.convertPoint(toScreen: NSPoint(x: frame.minX, y: frame.minY))
            menu.popUp(positioning: nil, at: screenPoint, in: nil)
        } else {
            // First click: just select the sticker tool (no menu)
            currentTool = .sticker(selectedStickerType)
            updateStickerButtonIcon()
            updateToolButtonStates()
            updateSliderVisibility()
        }
    }
    
    @objc private func stickerMenuItemPicked(_ sender: NSMenuItem) {
        switch sender.tag {
        case 10: selectedStickerType = .redX
        case 11: selectedStickerType = .greenCheck
        case 12: selectedStickerType = .yellowExclamation
        default: return
        }
        currentTool = .sticker(selectedStickerType)
        updateStickerButtonIcon()
        updateToolButtonStates()
        updateSliderVisibility()
    }
    
    // MARK: - NSMenuDelegate (sticker menu must sit above `kScreenshotOverlayBaseLevel`)
    func menuWillOpen(_ menu: NSMenu) {
        let aboveOverlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        DispatchQueue.main.async { [weak self] in
            guard self?.window != nil else { return }
            for w in NSApp.windows where w.isVisible {
                let lv = w.level.rawValue
                if lv >= NSWindow.Level.popUpMenu.rawValue && lv < NSWindow.Level.screenSaver.rawValue {
                    w.level = aboveOverlay
                    break
                }
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isStickerMenuOpen = false
        updateToolButtonStates()
    }
    
    private func toolToTag(_ tool: AnnotationTool) -> Int {
        switch tool {
        case .freehand: return 1
        case .rectangle: return 2
        case .circle: return 5
        case .arrow: return 3
        case .text: return 4
        case .sticker: return 0
        case .blur: return 7
        case .numberBadge: return 8
        case .measure: return 9
        case .guide(.vertical): return 10
        case .guide(.horizontal): return 11
        case .grid: return 12
        }
    }

    /// Toolbar tags that map to a plain (non-sticker) drawing tool, toggled by `toolButtonClicked`.
    private func toolForToolbarTag(_ tag: Int) -> AnnotationTool? {
        switch tag {
        case 1: return .freehand
        case 2: return .rectangle
        case 5: return .circle
        case 3: return .arrow
        case 4: return .text
        case 7: return .blur
        case 8: return .numberBadge
        case 9: return .measure
        case 10: return .guide(.vertical)
        case 11: return .guide(.horizontal)
        case 12: return .grid
        default: return nil
        }
    }
    
    private func stickerToTag(_ sticker: StickerType) -> Int {
        switch sticker {
        case .redX: return 10
        case .greenCheck: return 11
        case .yellowExclamation: return 12
        }
    }
    
    @objc private func toolButtonClicked(_ sender: NSButton) {
        // Tag 0 = close/save (no tool); otherwise toggle: same tool again = deselect
        guard let tool = toolForToolbarTag(sender.tag) else {
            updateToolButtonStates()
            updateSliderVisibility()
            return
        }
        // When leaving text tool (switching to another or deselecting), dismiss inline text field immediately
        if currentTool == .text {
            finishInlineText()
        }
        if currentTool == tool {
            currentTool = nil
        } else {
            currentTool = tool
        }
        dismissColorPanel()
        updateToolButtonStates()
        updateSliderVisibility()
    }

    /// Arm a tool from a global shortcut while the screenshot editor is up.
    ///
    /// Behaves exactly like clicking that toolbar button, including the toggle-off on
    /// the armed tool, so the same key does the same thing whether the user is
    /// annotating the desktop or a freshly picked region. Returns false when this view
    /// declined it — the Annotate overlay, or a field editor mid-typing.
    @discardableResult
    func selectToolFromShortcut(_ tool: AnnotationTool) -> Bool {
        // The Annotate overlay's strip is driven by `setArmedTool`; this is the
        // editor's path only.
        guard !isAnnotateMode else { return false }
        // A grid dimension field owns the keyboard — the user is typing a number, not
        // switching tools.
        guard gridSizeField == nil else { return false }

        // The toolbar's sticker button always places the type it is currently showing,
        // so the shortcut has to resolve to that rather than to the menu's default.
        let resolved: AnnotationTool
        if case .sticker = tool {
            resolved = .sticker(selectedStickerType)
        } else {
            resolved = tool
        }

        if currentTool == .text {
            finishInlineText()
        }
        currentTool = (currentTool == resolved) ? nil : resolved
        dismissColorPanel()
        updateToolButtonStates()
        updateSliderVisibility()
        setNeedsDisplay(bounds)
        return true
    }


    private func updateToolButtonStates() {
        // Update button states to show selected, hover, and open-menu-pressed visuals.
        for subview in toolbarView?.subviews ?? [] {
            guard let button = subview as? NSButton else { continue }
            if toolForToolbarTag(button.tag) != nil {
                let isSelected = currentTool != nil && button.tag == toolToTag(currentTool!)
                applyToolbarButtonBackground(button: button, isSelected: isSelected, isMenuPressed: false)
            } else if button.tag == 6 {
                // Sticker button: highlight when sticker tool is active
                let isSelected: Bool
                if case .sticker = currentTool { isSelected = true }
                else { isSelected = false }
                applyToolbarButtonBackground(button: button, isSelected: isSelected, isMenuPressed: isStickerMenuOpen)
            } else {
                // Action buttons (close/save): hover only.
                applyToolbarButtonBackground(button: button, isSelected: false, isMenuPressed: false)
            }
        }
        if let colorButton {
            applyToolbarButtonBackground(button: colorButton, isSelected: false, isMenuPressed: false)
        }
        updateStickerButtonIcon()
    }

    private func applyToolbarButtonBackground(button: NSButton, isSelected: Bool, isMenuPressed: Bool) {
        AnnotationToolbarChrome.applyButtonBackground(button: button, isSelected: isSelected, isMenuPressed: isMenuPressed)
    }
    
    private var thicknessSlider: NSSlider?
    private var fontSizeSlider: NSSlider?
    private var badgeSizeSlider: NSSlider?
    private var sliderContainer: NSView?
    private var colorButton: NSButton?
    /// Editor slider-row rainbow toggle + opacity dropdown (the overlay uses its
    /// context bar for these; the editor's shared toolbar hosts them here).
    private var editorRainbowButton: NSButton?
    private var editorOpacityButton: NSButton?

    private func updateSliderVisibility() {
        // The bottom row hosts the thickness slider, the font-size slider, and the colour
        // button. Show the row whenever any of those is relevant to the current tool.
        let shouldShowRow: Bool
        switch currentTool {
        case .freehand, .rectangle, .circle, .arrow, .text, .numberBadge, .measure, .guide, .grid:
            shouldShowRow = true
        case .blur, .sticker, .none:
            shouldShowRow = false
        }

        sliderContainer?.isHidden = !shouldShowRow

        if shouldShowRow {
            // Text uses the font-size slider; numbered badge uses the size slider; a grid
            // has none (it is sized by dragging); everything else uses thickness. Exactly
            // one slider is visible at a time, or none.
            let tool = currentTool
            let isGrid = tool == .grid
            thicknessSlider?.isHidden = (tool == .text || tool == .numberBadge || isGrid)
            fontSizeSlider?.isHidden = (tool != .text)
            badgeSizeSlider?.isHidden = (tool != .numberBadge)
        }
    }
    
    @objc private func showColorPicker() {
        let colorPanel = NSColorPanel.shared
        colorPanel.color = currentColor
        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(colorChanged(_:)))
        // Above `kScreenshotOverlayBaseLevel` (screenSaver + 1) used by live/static annotation windows.
        colorPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        colorPanel.orderFront(nil)
    }

    /// Hide the shared colour panel and detach it from this view so a stale target
    /// cannot keep painting after the selection / session ends.
    func dismissColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
    }
    
    @objc private func colorChanged(_ sender: NSColorPanel) {
        currentColor = sender.color
        // Picking a concrete colour is a request for solid; carry that to new marks.
        currentColorMode = .solid
        // Update selected annotation if one is selected
        if let selectedId = selectedAnnotationId,
           let index = annotations.firstIndex(where: { $0.id == selectedId }) {
            pushUndoForContinuousEdit(.color, annotationId: selectedId)
            var annotation = annotations[index]
            annotation.color = currentColor
            // Choosing a specific colour is an explicit request for a solid stroke;
            // leaving it rainbow would ignore the colour just picked.
            annotation.colorMode = .solid
            annotations[index] = annotation
            setNeedsDisplay(bounds)
            // Don't rebuild the bar on every colour-panel tick — just flip rainbow
            // off and refresh the swatch. Rebuild would recreate tracking areas and
            // the rainbow image on every drag sample for no visible gain.
            contextBar?.updateColorSwatch(currentColor, isRainbow: false)
        }
        updateColorButtonIcon()
    }
    
    private func updateColorButtonIcon() {
        guard let button = colorButton else { return }
        // A rainbow session shows a gradient swatch, matching the overlay's colour well,
        // so the well never lies about what the next mark will be.
        if currentColorMode == .rainbow {
            button.image = AnnotationContextBar.rainbowSwatch(diameter: 12)
            return
        }
        let iconSize: CGFloat = 12
        let colorIcon = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { rect in
            self.currentColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            return true
        }
        button.image = colorIcon
    }
    
    @objc private func thicknessChanged(_ sender: NSSlider) {
        currentThickness = CGFloat(sender.doubleValue)
        // Update selected annotation if one is selected
        if let selectedId = selectedAnnotationId,
           let index = annotations.firstIndex(where: { $0.id == selectedId }) {
            pushUndoForContinuousEdit(.thickness, annotationId: selectedId)
            var annotation = annotations[index]
            annotation.thickness = currentThickness
            annotations[index] = annotation
            setNeedsDisplay(bounds)
        }
        if NSApp.currentEvent?.type == .leftMouseUp { lastContinuousEdit = nil }
    }
    
    @objc private func fontSizeChanged(_ sender: NSSlider) {
        currentFontSize = CGFloat(sender.doubleValue)
        // Update selected text annotation: resize font and bounding box (works even while typing/focused)
        if let selectedId = selectedAnnotationId,
           let index = annotations.firstIndex(where: { $0.id == selectedId }) {
            pushUndoForContinuousEdit(.fontSize, annotationId: selectedId)
            var annotation = annotations[index]
            if case .text = annotation.type {
                annotation.fontSize = currentFontSize
                // Recompute bounding box to fit text at new size (keep top-left fixed)
                let topLeft = annotation.frame.origin
                let text = annotation.text ?? ""
                annotation.frame = AnnotationRenderer.textAnnotationFrame(text: text, fontSize: currentFontSize, topLeft: topLeft)
                annotations[index] = annotation
                // If this text is being edited (inline field), sync font and frame so box follows
                if inlineTextAnnotationId == selectedId, let textField = inlineTextField {
                    let fontName = UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica"
                    textField.font = NSFont(name: fontName, size: currentFontSize) ?? NSFont.systemFont(ofSize: currentFontSize)
                    let annRect = annotationSpaceRect
                    let viewX = annRect.origin.x + annotation.frame.origin.x
                    let bottomY = annRect.maxY - annotation.frame.origin.y - annotation.frame.height
                    let rowH = inlineTextEditingHeight(fontSize: currentFontSize)
                    textField.frame = NSRect(x: viewX, y: bottomY, width: textAnnotationMinWidth, height: rowH)
                    textFieldChanged(textField)
                    applyInlineTextFieldOutlineTypingAttributes()
                }
            } else {
                annotation.fontSize = currentFontSize
                annotations[index] = annotation
            }
            setNeedsDisplay(bounds)
        }
        if NSApp.currentEvent?.type == .leftMouseUp { lastContinuousEdit = nil }
    }
    
    @objc private func badgeSizeChanged(_ sender: NSSlider) {
        currentBadgeSize = CGFloat(sender.doubleValue)
        // Resize the selected badge about its centre so it grows/shrinks in place.
        if let selectedId = selectedAnnotationId,
           let index = annotations.firstIndex(where: { $0.id == selectedId }),
           annotations[index].type == .numberBadge {
            pushUndoForContinuousEdit(.badgeSize, annotationId: selectedId)
            var annotation = annotations[index]
            let center = NSPoint(x: annotation.frame.midX, y: annotation.frame.midY)
            annotation.frame = NSRect(
                x: center.x - currentBadgeSize / 2,
                y: center.y - currentBadgeSize / 2,
                width: currentBadgeSize,
                height: currentBadgeSize
            )
            annotations[index] = annotation
            setNeedsDisplay(bounds)
        }
        if NSApp.currentEvent?.type == .leftMouseUp { lastContinuousEdit = nil }
    }

    private func updateUIForSelectedAnnotation(_ annotation: Annotation) {
        // Update thickness slider and current font size if it's a text annotation
        if case .text = annotation.type {
            if let fs = annotation.fontSize { currentFontSize = fs }
            fontSizeSlider?.doubleValue = Double(annotation.fontSize ?? currentFontSize)
        } else if case .numberBadge = annotation.type {
            // Sync the size slider to the selected badge's diameter.
            currentBadgeSize = annotation.frame.width
            badgeSizeSlider?.doubleValue = Double(annotation.frame.width)
        } else if case .sticker = annotation.type {
            // Stickers don't use thickness
        } else {
            thicknessSlider?.doubleValue = Double(annotation.thickness)
        }
        // The screenshot editor deliberately conflates "options for the selection"
        // with "options for the next mark" — one toolbar serves both. The Annotate
        // overlay separates them: the strip arms the next mark, the context bar edits
        // this one. Clobbering currentTool here would disarm the user's tool every
        // time they clicked an existing element.
        if !isAnnotateMode {
            currentTool = annotation.type
            // The editor's toolbar is shared, so load the selection's colour mode +
            // opacity into it, mirroring how the slider loads its thickness.
            currentColorMode = annotation.colorMode
            currentOpacity = annotation.opacity
        }
        if case .sticker(let type) = annotation.type {
            selectedStickerType = type
        }
        updateToolButtonStates()
        updateSliderVisibility()
        currentColor = annotation.color
        updateColorButtonIcon()
        updateEditorColorModeButtonState()
    }
    
    @objc private func saveScreenshot() {
        guard canSave else { return }
        if isLiveMode {
            let toSave = annotationReferenceRect != nil ? annotations.map { convertAnnotationToCaptureRect($0) } : annotations
            onSaveRequested?(screenshotRect, toSave)
            return
        }
        let annotatedImage = renderAnnotatedImage()
        onSave?(annotatedImage)
    }
    
    @objc private func closeAnnotation() {
        dismissColorPanel()
        onClose?()
    }
    
    /// Deletes the currently selected annotation. Returns true if an annotation was deleted.
    private func deleteSelectedAnnotation() -> Bool {
        guard let id = selectedAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let annotation = annotations[index]
        // Drop any dimension field belonging to the mark about to disappear, or it
        // would be left floating with nothing to commit to.
        cancelGridSizeEditIfNeeded(for: annotation.id)
        // If it's the inline text being edited, finish and remove it
        if annotation.id == inlineTextAnnotationId {
            finishInlineText()
        } else {
            pushUndo()
            annotations.remove(at: index)
            selectedAnnotationId = nil
            setNeedsDisplay(bounds)
            notifyIfCanvasEmptied()
        }
        return true
    }
    
    /// Copy the selected annotation to the internal paste buffer (Cmd+C).
    private func copySelectedAnnotations() {
        guard let id = selectedAnnotationId,
              let annotation = annotations.first(where: { $0.id == id }) else { return }
        // Store a copy with same coords; paste will assign new ID and offset
        copiedAnnotations = [copyAnnotation(annotation, offset: .zero)]
    }
    
    /// Paste from the copy buffer with a small offset and new IDs (Cmd+V). Returns true if paste was performed.
    private func pasteAnnotations() -> Bool {
        guard let copied = copiedAnnotations, !copied.isEmpty else { return false }
        let pasteOffset: CGFloat = 15
        pushUndo()
        let startIndex = annotations.count
        for a in copied {
            annotations.append(copyAnnotation(a, offset: NSPoint(x: pasteOffset, y: pasteOffset)))
        }
        selectedAnnotationId = annotations[startIndex].id
        setNeedsDisplay(bounds)
        return true
    }
    
    // MARK: - Undo / Redo
    
    /// Colour mode for the next mark: the session's live mode. Seeded from the saved
    /// "Default colour mode" at open (per surface), then whatever the user last chose.
    /// Applies to every colourable tool, not just freehand.
    private func colorModeForNewMark() -> AnnotationColorMode { currentColorMode }

    /// Colour for the next solid mark: the session's current colour. In rainbow mode
    /// it is unused (the gradient wins) but is still stored so a later toggle to solid
    /// shows the configured colour rather than a default.
    private func colorForNewMark() -> NSColor { currentColor }

    /// Seed the session's colour mode + colour from the saved "Default colour mode"
    /// preference. A fresh view backs every Annotate overlay session and every
    /// screenshot-editor open, so seeding here gives the per-surface reset: each new
    /// session starts from the default, and changes within it stick until changed.
    private func seedColorDefaultsFromPreferences() {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "brushColorMode") ?? "mono"
        currentColorMode = (mode == "mono") ? .solid : .rainbow
        // The configured mono colour is the "normal colour", used whenever a mark is
        // solid. Only override the red fallback when one was actually chosen.
        let r = defaults.double(forKey: "brushColorRed")
        let g = defaults.double(forKey: "brushColorGreen")
        let b = defaults.double(forKey: "brushColorBlue")
        if defaults.object(forKey: "brushColorRed") != nil {
            let alpha = defaults.double(forKey: "brushColorAlpha")
            currentColor = NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b),
                                   alpha: alpha > 0 ? CGFloat(alpha) : 1.0)
        }
    }

    private func snapshotAnnotations() -> [Annotation] {
        annotations.map { a in
            Annotation(
                id: a.id,
                type: a.type,
                frame: a.frame,
                color: a.color.copy() as! NSColor,
                thickness: a.thickness,
                text: a.text,
                fontSize: a.fontSize,
                startPoint: a.startPoint,
                endPoint: a.endPoint,
                pathPoints: a.pathPoints,
                stickerPointerDirection: a.stickerPointerDirection,
                badgeNumber: a.badgeNumber,
                colorMode: a.colorMode,
                opacity: a.opacity,
                bakedMosaic: a.bakedMosaic
            )
        }
    }

    /// Deep copy of one annotation with a new ID; optional offset in screenshot-local coordinates (for paste).
    private func copyAnnotation(_ a: Annotation, offset: NSPoint = .zero) -> Annotation {
        var frame = a.frame
        frame.origin.x += offset.x
        frame.origin.y += offset.y
        let startPoint = a.startPoint.map { NSPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        let endPoint = a.endPoint.map { NSPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        let pathPoints = a.pathPoints.map { $0.map { NSPoint(x: $0.x + offset.x, y: $0.y + offset.y) } }
        return Annotation(
            id: UUID(),
            type: a.type,
            frame: frame,
            color: a.color.copy() as! NSColor,
            thickness: a.thickness,
            text: a.text,
            fontSize: a.fontSize,
            startPoint: startPoint,
            endPoint: endPoint,
            pathPoints: pathPoints,
            stickerPointerDirection: a.stickerPointerDirection,
            badgeNumber: a.badgeNumber,
            colorMode: a.colorMode,
            opacity: a.opacity,
            // Deliberately not carried: a pasted redaction must re-bake at its new
            // position, or it would display the pixels from where it was copied.
            bakedMosaic: nil
        )
    }
    
    private func pushUndo() {
        lastContinuousEdit = nil
        let snapshot = snapshotAnnotations()
        undoStack.append(snapshot)
        if undoStack.count > maxUndoSteps {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private enum ContinuousEditKind { case color, thickness, fontSize, badgeSize }
    /// Continuous controls (sliders, colour panel) fire their action per tick;
    /// pushing undo every tick floods the 50-step stack with micro-states. Coalesce:
    /// one undo snapshot per (control, annotation) run, reset by any other edit.
    private var lastContinuousEdit: (kind: ContinuousEditKind, annotationId: UUID)?

    private func pushUndoForContinuousEdit(_ kind: ContinuousEditKind, annotationId: UUID) {
        if let last = lastContinuousEdit, last.kind == kind, last.annotationId == annotationId { return }
        pushUndo()
        lastContinuousEdit = (kind, annotationId)
    }
    
    private func performUndo() {
        guard !undoStack.isEmpty else { return }
        endInlineTextEditingIfActive()
        redoStack.append(snapshotAnnotations())
        annotations = undoStack.removeLast()
        selectedAnnotationId = nil
        setNeedsDisplay(bounds)
        notifyIfCanvasEmptied()
    }
    
    private func performRedo() {
        guard !redoStack.isEmpty else { return }
        endInlineTextEditingIfActive()
        undoStack.append(snapshotAnnotations())
        annotations = redoStack.removeLast()
        selectedAnnotationId = nil
        setNeedsDisplay(bounds)
        notifyIfCanvasEmptied()
    }
    
    private func endInlineTextEditingIfActive() {
        guard inlineTextField != nil else { return }
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil
        inlineTextAnnotationId = nil
        isCreatingTextField = false
        releaseLiveOverlayWindowKeyboardIfNeeded()
    }
    
    private func prepareLiveOverlayWindowForTextEditing() {
        guard isLiveMode, let live = window as? LiveAnnotationOverlayWindow else { return }
        live.allowsKeyboardFocus = true
    }
    
    private func releaseLiveOverlayWindowKeyboardIfNeeded() {
        guard isLiveMode, let live = window as? LiveAnnotationOverlayWindow else { return }
        live.allowsKeyboardFocus = false
    }
    
    // MARK: - Key Monitor
    
    private var keyMonitors: [Any] = []
    
    private func removeAllKeyMonitors() {
        for monitor in keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitors.removeAll()
    }
    
    /// Returns true if the event was handled (swallow for local monitor).
    private func handleAnnotationKeyMonitorEvent(_ event: NSEvent) -> Bool {
        if let textField = inlineTextField {
            if event.keyCode == 53 {
                if textField.currentEditor() != nil {
                    finishInlineText()
                } else {
                    closeAnnotation()
                }
                return true
            }
            return false
        }
        // Let the field editor own typing while a grid dimension is open. Esc is
        // the one exception — cancel the edit rather than closing the whole editor.
        if gridSizeField != nil {
            if event.keyCode == 53 {
                finishGridSizeEdit(commit: false)
                return true
            }
            return false
        }
        
        if event.keyCode == 53 {
            closeAnnotation()
            return true
        }
        if event.keyCode == 36 {
            saveScreenshot()
            return true
        }
        if event.keyCode == 51 {
            if deleteSelectedAnnotation() {
                return true
            }
        }
        // Match by typed character, not physical keyCode, so Cmd+Z/C/V work on
        // non-QWERTY layouts (AZERTY, QWERTZ, ...).
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "z" {
                if event.modifierFlags.contains(.shift) {
                    performRedo()
                } else {
                    performUndo()
                }
                return true
            }
            if key == "c" {
                copySelectedAnnotations()
                return true
            }
            if key == "v" {
                if pasteAnnotations() {
                    return true
                }
            }
        }
        return false
    }
    
    private func setupKeyMonitor() {
        removeAllKeyMonitors()

        // Local monitor only: a global keyDown monitor never fires in a sandboxed app
        // without Input Monitoring. The annotation window is key, so this suffices.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self = self else { return event }
            if self.handleAnnotationKeyMonitorEvent(event) {
                return nil
            }
            return event
        }) {
            keyMonitors.append(local)
        }
    }
    
    deinit {
        removeAllKeyMonitors()
    }
    
    // MARK: - Mouse Events
    
    private func convertPointToScreenshotCoordinates(_ point: NSPoint) -> NSPoint {
        // Convert view coordinates to screenshot-local coordinates
        // Annotations are stored in screenshot-local coordinates (0,0 at top-left of screenshot image)
        // View uses bottom-left origin
        let localX = point.x - screenshotRect.origin.x
        // For Y: screenshot image uses top-left origin, view uses bottom-left
        // screenshotRect.maxY is the top of the screenshot in view coordinates
        let localY = screenshotRect.maxY - point.y
        return NSPoint(x: localX, y: localY)
    }
    
    private var annotationSpaceRect: NSRect {
        annotationReferenceRect ?? screenshotRect
    }

    /// The selection hole expressed in annotation space. Guides span this rect (then
    /// the draw path clips to the hole), so enlarging the selection grows the guide
    /// instead of leaving a stub of the size it had when placed.
    private var visibleAnnotationSpaceRect: NSRect {
        let topLeft = convertPointToAnnotationSpace(.zero)
        let bottomRight = convertPointToAnnotationSpace(
            NSPoint(x: screenshotRect.width, y: screenshotRect.height)
        )
        return NSRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }
    
    private func ensureAnnotationReferenceRect() {
        if isLiveMode, annotationReferenceRect == nil {
            annotationReferenceRect = screenshotRect
        }
    }
    
    private func convertAnnotationToCaptureRect(_ a: Annotation) -> Annotation {
        guard let ref = annotationReferenceRect else { return a }
        let deltaX = ref.origin.x - screenshotRect.origin.x
        let deltaY = screenshotRect.maxY - ref.maxY
        func translate(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x + deltaX, y: p.y + deltaY) }
        // Guides re-span the capture rect: they are infinite lines clipped to the hole,
        // so the saved mark must fill the final crop, not the (possibly smaller) size
        // it had when first placed.
        if case .guide(let orientation) = a.type {
            let canvas = NSRect(origin: .zero, size: screenshotRect.size)
            let shifted = Annotation(
                id: a.id, type: a.type,
                frame: a.frame.offsetBy(dx: deltaX, dy: deltaY),
                color: a.color, thickness: a.thickness, text: a.text, fontSize: a.fontSize,
                startPoint: nil, endPoint: nil, pathPoints: nil,
                stickerPointerDirection: a.stickerPointerDirection, badgeNumber: a.badgeNumber,
                colorMode: a.colorMode, opacity: a.opacity, bakedMosaic: nil
            )
            let spanned = AnnotationRenderer.guideFrame(for: shifted, orientation: orientation, spanning: canvas)
            return Annotation(
                id: a.id, type: a.type, frame: spanned, color: a.color.copy() as! NSColor,
                thickness: a.thickness, text: a.text, fontSize: a.fontSize,
                startPoint: nil, endPoint: nil, pathPoints: nil,
                stickerPointerDirection: a.stickerPointerDirection, badgeNumber: a.badgeNumber,
                colorMode: a.colorMode, opacity: a.opacity, bakedMosaic: nil
            )
        }
        var frame = a.frame
        frame.origin = translate(frame.origin)
        return Annotation(
            id: a.id,
            type: a.type,
            frame: frame,
            color: a.color.copy() as! NSColor,
            thickness: a.thickness,
            text: a.text,
            fontSize: a.fontSize,
            startPoint: a.startPoint.map(translate),
            endPoint: a.endPoint.map(translate),
            pathPoints: a.pathPoints.map { $0.map(translate) },
            stickerPointerDirection: a.stickerPointerDirection,
            badgeNumber: a.badgeNumber,
            colorMode: a.colorMode,
            opacity: a.opacity,
            // Deliberately not carried: a pasted redaction must re-bake at its new
            // position, or it would display the pixels from where it was copied.
            bakedMosaic: nil
        )
    }
    
    /// Convert point from current screenshotRect-local to annotation-space-local.
    /// This maps through absolute view coordinates (translate only, no scaling), so
    /// existing annotations remain stable when the live selection rect is resized.
    private func convertPointToAnnotationSpace(_ screenshotLocalPoint: NSPoint) -> NSPoint {
        let ref = annotationSpaceRect
        let viewPoint = NSPoint(
            x: screenshotRect.origin.x + screenshotLocalPoint.x,
            y: screenshotRect.maxY - screenshotLocalPoint.y
        )
        return NSPoint(
            x: viewPoint.x - ref.origin.x,
            y: ref.maxY - viewPoint.y
        )
    }
    
    
    
    /// Detect which resize edge/corner the point is over for a given rect (point and rect in same coordinate system).
    private func resizeEdgeAt(point: NSPoint, rect: NSRect) -> ResizeEdge {
        let left = rect.minX
        let right = rect.maxX
        let bottom = rect.minY
        let top = rect.maxY
        let x = point.x
        let y = point.y
        
        // Corners first
        if x >= left - kResizeHandleSize && x <= left + kResizeHandleSize &&
           y >= bottom - kResizeHandleSize && y <= bottom + kResizeHandleSize { return .bottomLeft }
        if x >= right - kResizeHandleSize && x <= right + kResizeHandleSize &&
           y >= bottom - kResizeHandleSize && y <= bottom + kResizeHandleSize { return .bottomRight }
        if x >= left - kResizeHandleSize && x <= left + kResizeHandleSize &&
           y >= top - kResizeHandleSize && y <= top + kResizeHandleSize { return .topLeft }
        if x >= right - kResizeHandleSize && x <= right + kResizeHandleSize &&
           y >= top - kResizeHandleSize && y <= top + kResizeHandleSize { return .topRight }
        
        // Edges
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

    /// Hit-test resize handles for annotation frames stored in **screenshot-style** coords:
    /// origin is the **top-left**, Y increases **downward** (same as `convertPointToAnnotationSpace`).
    /// `resizeEdgeAt` is for AppKit rects (origin bottom-left); use this for annotation geometry.
    private func resizeEdgeAtAnnotationSpace(point: NSPoint, rect: NSRect) -> ResizeEdge {
        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY
        let x = point.x
        let y = point.y

        // Corners (top = smaller y, bottom = larger y)
        if x >= left - kResizeHandleSize && x <= left + kResizeHandleSize &&
            y >= top - kResizeHandleSize && y <= top + kResizeHandleSize { return .topLeft }
        if x >= right - kResizeHandleSize && x <= right + kResizeHandleSize &&
            y >= top - kResizeHandleSize && y <= top + kResizeHandleSize { return .topRight }
        if x >= left - kResizeHandleSize && x <= left + kResizeHandleSize &&
            y >= bottom - kResizeHandleSize && y <= bottom + kResizeHandleSize { return .bottomLeft }
        if x >= right - kResizeHandleSize && x <= right + kResizeHandleSize &&
            y >= bottom - kResizeHandleSize && y <= bottom + kResizeHandleSize { return .bottomRight }

        if x >= left - kResizeEdgeThickness && x <= left + kResizeEdgeThickness &&
            y > top + kResizeHandleSize && y < bottom - kResizeHandleSize { return .left }
        if x >= right - kResizeEdgeThickness && x <= right + kResizeEdgeThickness &&
            y > top + kResizeHandleSize && y < bottom - kResizeHandleSize { return .right }
        if y >= top - kResizeEdgeThickness && y <= top + kResizeEdgeThickness &&
            x > left + kResizeHandleSize && x < right - kResizeHandleSize { return .top }
        if y >= bottom - kResizeEdgeThickness && y <= bottom + kResizeEdgeThickness &&
            x > left + kResizeHandleSize && x < right - kResizeHandleSize { return .bottom }

        return .none
    }

    /// Text annotations only support horizontal resizing from side-middle handles.
    private func textResizeEdgeAtAnnotationSpace(point: NSPoint, rect: NSRect) -> ResizeEdge {
        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY
        let x = point.x
        let y = point.y

        // For short text boxes, the old fixed "exclude top/bottom by handle size" rule can
        // leave no valid vertical grab zone at all. Use an adaptive inset.
        let verticalInset = min(kResizeHandleSize, max(0, rect.height * 0.3))
        let inVerticalBand = y >= top + verticalInset && y <= bottom - verticalInset

        if x >= left - kResizeHandleSize && x <= left + kResizeHandleSize && inVerticalBand { return .left }
        if x >= right - kResizeHandleSize && x <= right + kResizeHandleSize && inVerticalBand { return .right }

        return .none
    }
    
    /// Bounding box used for selection and resize handles.
    private func effectiveFrame(for annotation: Annotation) -> NSRect {
        if case .guide(let orientation) = annotation.type {
            return AnnotationRenderer.guideFrame(
                for: annotation, orientation: orientation, spanning: visibleAnnotationSpaceRect
            )
        }
        return AnnotationRenderer.textFrame(for: annotation)
    }

    /// Render context shared by on-screen and export paths in this view.
    private func rendererContext(showsGridLabels: Bool = false) -> AnnotationRenderer.Context {
        AnnotationRenderer.Context(
            textFrame: { [weak self] in self?.effectiveFrame(for: $0) ?? $0.frame },
            guideFrame: { [weak self] in self?.effectiveFrame(for: $0) ?? $0.frame },
            isInlineEditing: { [weak self] in $0.id == self?.inlineTextAnnotationId },
            mosaic: { [weak self] in self?.mosaicRegionImage(forFrame: $0.frame) },
            showsGridLabels: showsGridLabels,
            editingGridLabel: { [weak self] in
                guard let self, $0.id == self.gridSizeAnnotationId else { return nil }
                return self.gridSizeEditingLabel
            }
        )
    }
    
    /// Arrow and measure are both two-point line tools: identical drag, endpoint
    /// handles and segment hit-test. They differ only in how they render.
    private func isTwoPointLine(_ type: AnnotationTool) -> Bool {
        type == .arrow || type == .measure
    }

    /// For a two-point line: which endpoint handle is at the point? true = start,
    /// false = end, nil = neither.
    private func arrowResizeHandleAt(point: NSPoint, annotation: Annotation) -> Bool? {
        guard isTwoPointLine(annotation.type),
              let start = annotation.startPoint,
              let end = annotation.endPoint else { return nil }
        let handleRadius: CGFloat = 10
        let dStart = hypot(point.x - start.x, point.y - start.y)
        let dEnd = hypot(point.x - end.x, point.y - end.y)
        if dStart <= handleRadius && dStart <= dEnd { return true }
        if dEnd <= handleRadius { return false }
        return nil
    }
    
    /// Squared distance from point to line segment (start, end). Used for arrow hit-test.
    private func distanceSqFromPoint(_ p: NSPoint, toSegment start: NSPoint, end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lenSq = dx * dx + dy * dy
        if lenSq <= 0 { return (p.x - start.x) * (p.x - start.x) + (p.y - start.y) * (p.y - start.y) }
        var t = ((p.x - start.x) * dx + (p.y - start.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = NSPoint(x: start.x + t * dx, y: start.y + t * dy)
        return (p.x - proj.x) * (p.x - proj.x) + (p.y - proj.y) * (p.y - proj.y)
    }
    
    private func cursorForResizeEdge(_ edge: ResizeEdge) -> NSCursor {
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return ResizeEdge.resizeNWSE
        case .topRight, .bottomLeft: return ResizeEdge.resizeNESW
        case .none: return .arrow
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCursorForLocalPoint(point)
    }
    
    /// Point in this view's coordinate space (same as `convert(event.locationInWindow, from: nil)`).
    func updateCursorForLocalPoint(_ point: NSPoint) {
        let screenshotPoint = convertPointToScreenshotCoordinates(point)
        
        if resizingAnnotationId != nil || resizingSelectionEdge != .none {
            return // Keep current cursor during resize
        }
        if isRegionMode && draggingSelectionRect {
            NSCursor.closedHand.set()
            return
        }
        if isDragging {
            NSCursor.closedHand.set()
            return
        }
        if let toolbar = toolbarView, toolbar.frame.contains(point) {
            NSCursor.pointingHand.set()
            return
        }
        if let slider = sliderContainer, !slider.isHidden, slider.frame.contains(point) {
            NSCursor.pointingHand.set()
            return
        }
        if isRegionMode {
            let selectionEdge = resizeEdgeAt(point: point, rect: screenshotRect)
            if selectionEdge != .none {
                cursorForResizeEdge(selectionEdge).set()
                return
            }
        }
        let refPoint = convertPointToAnnotationSpace(screenshotPoint)
        if let selectedId = selectedAnnotationId,
           let annotation = annotations.first(where: { $0.id == selectedId }) {
            if isTwoPointLine(annotation.type), arrowResizeHandleAt(point: refPoint, annotation: annotation) != nil {
                NSCursor.crosshair.set()
                return
            }
            let rect = effectiveFrame(for: annotation)
            let annEdge: ResizeEdge
            if case .text = annotation.type {
                annEdge = textResizeEdgeAtAnnotationSpace(point: refPoint, rect: rect)
            } else {
                annEdge = resizeEdgeAtAnnotationSpace(point: refPoint, rect: rect)
            }
            if annEdge != .none {
                cursorForResizeEdge(annEdge).set()
                return
            }
        }
        if findAnnotation(at: refPoint) != nil {
            NSCursor.pointingHand.set()
            return
        }
        if isAnnotateMode {
            // Empty canvas with no tool armed is the click-through state: the pointer
            // belongs to whatever is underneath, so do not claim it with a grab cursor.
            NSCursor.arrow.set()
            if currentTool != nil {
                NSCursor.crosshair.set()
            }
        } else if isRegionMode {
            if screenshotRect.contains(point) {
                if currentTool == nil {
                    NSCursor.openHand.set()
                } else {
                    NSCursor.crosshair.set()
                }
            } else {
                NSCursor.arrow.set()
            }
        } else if screenshotRect.contains(point) {
            if currentTool != nil || isDrawing {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }
    
    /// Used when Topkit is not active: `mouseMoved` may not run, but a global monitor still needs correct cursors over the overlay.
    func synchronizeCursorFromScreenPoint(_ screenPoint: NSPoint) {
        guard let win = window else { return }
        let windowPoint = win.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        guard bounds.contains(local) else { return }
        updateCursorForLocalPoint(local)
    }

    /// Draw resize handles for a rect (in the same coordinate system as the current context).
    private func drawResizeHandles(for rect: NSRect) {
        let handleSize: CGFloat = 6
        let halfHandle = handleSize / 2
        let handleRects: [NSRect] = [
            // Corners (outside the border)
            NSRect(x: rect.minX - handleSize, y: rect.minY - handleSize, width: handleSize, height: handleSize),
            NSRect(x: rect.maxX, y: rect.minY - handleSize, width: handleSize, height: handleSize),
            NSRect(x: rect.minX - handleSize, y: rect.maxY, width: handleSize, height: handleSize),
            NSRect(x: rect.maxX, y: rect.maxY, width: handleSize, height: handleSize),
            // Edge middles (outside the border)
            NSRect(x: rect.midX - halfHandle, y: rect.minY - handleSize, width: handleSize, height: handleSize),
            NSRect(x: rect.midX - halfHandle, y: rect.maxY, width: handleSize, height: handleSize),
            NSRect(x: rect.minX - handleSize, y: rect.midY - halfHandle, width: handleSize, height: handleSize),
            NSRect(x: rect.maxX, y: rect.midY - halfHandle, width: handleSize, height: handleSize),
        ]
        for handleRect in handleRects {
            NSColor.white.setFill()
            handleRect.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let border = NSBezierPath(rect: handleRect)
            border.lineWidth = 1
            border.stroke()
        }
    }

    /// Draw only side-middle resize handles (used by text annotations).
    private func drawHorizontalResizeHandles(for rect: NSRect) {
        let handleSize: CGFloat = 6
        let halfHandle = handleSize / 2
        let handleRects: [NSRect] = [
            NSRect(x: rect.minX - handleSize, y: rect.midY - halfHandle, width: handleSize, height: handleSize),
            NSRect(x: rect.maxX, y: rect.midY - halfHandle, width: handleSize, height: handleSize),
        ]
        for handleRect in handleRects {
            NSColor.white.setFill()
            handleRect.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let border = NSBezierPath(rect: handleRect)
            border.lineWidth = 1
            border.stroke()
        }
    }

    /// Draw resize handles at specific points (e.g. arrow start/end).
    private func drawResizeHandles(for points: [NSPoint]) {
        let handleSize: CGFloat = 8
        let halfHandle = handleSize / 2
        for pos in points {
            let handleRect = NSRect(x: pos.x - halfHandle, y: pos.y - halfHandle, width: handleSize, height: handleSize)
            NSColor.white.setFill()
            handleRect.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let border = NSBezierPath(rect: handleRect)
            border.lineWidth = 1
            border.stroke()
        }
    }
    
    private func updateToolbarPosition() {
        guard isRegionMode, let toolbar = toolbarView, let slider = sliderContainer else { return }
        let gapAboveScreenshot: CGFloat = 44
        let sliderRowHeight: CGFloat = 28
        let gapBetween: CGFloat = 4
        let requiredSpace: CGFloat = gapAboveScreenshot + toolbar.frame.height + gapBetween + sliderRowHeight
        let spaceAboveSelection = bounds.height - (screenshotRect.origin.y + screenshotRect.height)
        let spaceBelowSelection = screenshotRect.origin.y
        let toolbarY: CGFloat
        if spaceAboveSelection >= requiredSpace {
            toolbarY = screenshotRect.origin.y + screenshotRect.height + gapAboveScreenshot
        } else if spaceBelowSelection >= requiredSpace {
            let gapBelow: CGFloat = 44
            toolbarY = screenshotRect.origin.y - gapBelow - toolbar.frame.height - gapBetween - sliderRowHeight
        } else {
            let inset: CGFloat = 8
            toolbarY = screenshotRect.origin.y + screenshotRect.height - inset - toolbar.frame.height - gapBetween - sliderRowHeight
        }
        // A hole spanning multiple monitors extends past this window's edges;
        // clamp so the toolbar (and slider row below it) stay fully on-window.
        let edgeInset: CGFloat = 8
        let idealX = screenshotRect.origin.x + (screenshotRect.width - toolbar.frame.width) / 2
        let toolbarX = max(edgeInset, min(idealX, bounds.width - toolbar.frame.width - edgeInset))
        let clampedY = max(edgeInset + sliderRowHeight + gapBetween,
                           min(toolbarY, bounds.height - toolbar.frame.height - edgeInset))
        toolbar.frame.origin = NSPoint(x: toolbarX, y: clampedY)
        slider.frame.origin = NSPoint(x: toolbarX, y: clampedY - sliderRowHeight - gapBetween)
    }
    
    private func clampSelectionRect() {
        let limit = allowedSelectionBounds ?? bounds
        var r = screenshotRect
        r.size.width = max(minSelectionSize, min(r.width, limit.maxX - r.origin.x))
        r.size.height = max(minSelectionSize, min(r.height, limit.maxY - r.origin.y))
        r.origin.x = max(limit.minX, min(r.origin.x, limit.maxX - minSelectionSize))
        r.origin.y = max(limit.minY, min(r.origin.y, limit.maxY - minSelectionSize))
        if r.size.width < minSelectionSize { r.size.width = minSelectionSize }
        if r.size.height < minSelectionSize { r.size.height = minSelectionSize }
        screenshotRect = r
    }
    
    private func handleSelectionResizeDrag(to point: NSPoint) {
        guard let original = resizeSelectionOriginalRect else { return }
        var newX = original.origin.x
        var newY = original.origin.y
        var newW = original.width
        var newH = original.height
        switch resizingSelectionEdge {
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
        screenshotRect = NSRect(x: newX, y: newY, width: newW, height: newH)
        clampSelectionRect()
        onSelectionRectChanged?(screenshotRect)
    }
    
    private func handleAnnotationResizeDrag(annotationIndex index: Int, to point: NSPoint, original: NSRect, retainAspectRatio: Bool) {
        let minSize: CGFloat = 8
        var newX = original.origin.x
        var newY = original.origin.y
        var newW = original.width
        var newH = original.height
        
        // Annotation frames use top-left origin with Y increasing downward (image / screenshot style).
        let ox = original.minX
        let oy = original.minY
        let ow = original.width
        let oh = original.height
        let px = point.x
        let py = point.y

        switch resizingAnnotationEdge {
        case .left:
            newX = min(px, ox + ow - minSize)
            newW = ox + ow - newX
        case .right:
            newW = max(minSize, px - ox)
        case .top:
            newY = min(py, oy + oh - minSize)
            newH = oy + oh - newY
        case .bottom:
            newH = max(minSize, py - oy)
        case .topLeft:
            newX = min(px, ox + ow - minSize)
            newY = min(py, oy + oh - minSize)
            newW = ox + ow - newX
            newH = oy + oh - newY
        case .topRight:
            newY = min(py, oy + oh - minSize)
            newH = oy + oh - newY
            newW = max(minSize, px - ox)
        case .bottomLeft:
            newX = min(px, ox + ow - minSize)
            newW = ox + ow - newX
            newH = max(minSize, py - oy)
        case .bottomRight:
            newW = max(minSize, px - ox)
            newH = max(minSize, py - oy)
        case .none:
            return
        }
        
        // Retain aspect ratio when Shift is held
        if retainAspectRatio && original.width > 0 && original.height > 0 {
            let ratio: CGFloat
            if index < annotations.count && annotations[index].type == .circle {
                // Shift on circle tool should force a perfect circle.
                ratio = 1
            } else {
                ratio = original.width / original.height
            }
            if newW / newH > ratio {
                newH = newW / ratio
            } else {
                newW = newH * ratio
            }
            if newW < minSize { newW = minSize; newH = newW / ratio }
            if newH < minSize { newH = minSize; newW = newH * ratio }
            // Reposition so the anchored corner/edge stays fixed (top-left origin, Y down).
            switch resizingAnnotationEdge {
            case .right, .bottom, .bottomRight:
                newX = ox
                newY = oy
            case .left, .top, .topLeft:
                newX = ox + ow - newW
                newY = oy + oh - newH
            case .topRight:
                newX = ox
                newY = oy + oh - newH
            case .bottomLeft:
                newX = ox + ow - newW
                newY = oy
            case .none:
                break
            }
        }
        
        var annotation = annotations[index]
        let oldFrame = annotation.frame
        annotation.frame = NSRect(x: newX, y: newY, width: newW, height: newH)
        
        // For a two-point line: update startPoint/endPoint to keep the line shape
        if isTwoPointLine(annotation.type), let start = annotation.startPoint, let end = annotation.endPoint {
            let scaleX = newW / max(0.01, oldFrame.width)
            let scaleY = newH / max(0.01, oldFrame.height)
            let oldMinX = oldFrame.minX
            let oldMinY = oldFrame.minY
            annotation.startPoint = NSPoint(
                x: newX + (start.x - oldMinX) * scaleX,
                y: newY + (start.y - oldMinY) * scaleY
            )
            annotation.endPoint = NSPoint(
                x: newX + (end.x - oldMinX) * scaleX,
                y: newY + (end.y - oldMinY) * scaleY
            )
        }
        // For freehand: scale path points
        if case .freehand = annotation.type, let points = annotation.pathPoints, !points.isEmpty {
            let scaleX = newW / max(0.01, oldFrame.width)
            let scaleY = newH / max(0.01, oldFrame.height)
            let oldMinX = oldFrame.minX
            let oldMinY = oldFrame.minY
            annotation.pathPoints = points.map {
                NSPoint(x: newX + ($0.x - oldMinX) * scaleX, y: newY + ($0.y - oldMinY) * scaleY)
            }
        }
        
        // For text: side handles should resize horizontally (font follows width change),
        // while preserving the opposite side as the fixed anchor.
        if case .text = annotation.type, let currentFontSize = annotation.fontSize {
            let scale: CGFloat
            switch resizingAnnotationEdge {
            case .left, .right:
                scale = oldFrame.width > 0 ? (newW / oldFrame.width) : 1
            default:
                scale = oldFrame.height > 0 ? (newH / oldFrame.height) : 1
            }

            let newFontSize = min(max(currentFontSize * scale, 8), 72)
            annotation.fontSize = newFontSize

            // Snap to tight text bounds after resizing.
            var snapped = AnnotationRenderer.textAnnotationFrame(
                text: annotation.text ?? "",
                fontSize: newFontSize,
                topLeft: NSPoint(x: newX, y: newY)
            )

            // Keep opposite side fixed when resizing horizontally.
            switch resizingAnnotationEdge {
            case .left:
                let fixedRight = oldFrame.maxX
                snapped.origin.x = fixedRight - snapped.width
            case .right:
                snapped.origin.x = oldFrame.minX
            default:
                break
            }

            annotation.frame = snapped
        }
        
        annotations[index] = annotation
    }
    
    override func mouseDown(with event: NSEvent) {
        handlePointerDown(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    /// Full mouse-down handling from a view-local point. The point may lie
    /// outside bounds when proxied from another monitor's overlay (selection
    /// hole spanning multiple displays).
    func handlePointerDown(at point: NSPoint, clickCount: Int) {
        // If clicking on inline text field, don't interfere
        if let textField = inlineTextField, textField.frame.contains(point) {
            return
        }
        
        // Check if clicking on toolbar or sliders - don't start annotation
        if let toolbar = toolbarView, toolbar.frame.contains(point) {
            return
        }
        if let sliderContainer = sliderContainer, !sliderContainer.isHidden && sliderContainer.frame.contains(point) {
            return
        }
        
        // Clicking a grid's own dimension readout types into it. Checked before any
        // selection or drag handling, and before the region-mode branches, because the
        // label overhangs the shape on a small grid and would otherwise start a drag.
        if let field = gridSizeField, field.frame.contains(point) {
            window?.makeFirstResponder(field)
            field.selectText(nil)
            return
        }

        let screenshotPoint = convertPointToScreenshotCoordinates(point)
        let refPoint = convertPointToAnnotationSpace(screenshotPoint)

        if let hit = gridLabelHit(at: refPoint) {
            beginGridSizeEdit(annotationId: hit.id, label: hit.label)
            return
        }

        if isRegionMode {
            let selectionEdge = resizeEdgeAt(point: point, rect: screenshotRect)
            if selectionEdge != .none {
                resizingSelectionEdge = selectionEdge
                resizeSelectionOriginalRect = screenshotRect
                setNeedsDisplay(bounds)
                return
            }
            if currentTool == nil && screenshotRect.contains(point) {
                if findAnnotation(at: refPoint) == nil {
                    draggingSelectionRect = true
                    selectionDragStartPoint = point
                    selectionDragStartOrigin = screenshotRect.origin
                    setNeedsDisplay(bounds)
                    return
                }
            }
        }
        
        // 1) Annotation resize: if we have a selected annotation, check if click is on its resize edge (annotation-space)
        if let selectedId = selectedAnnotationId,
           let index = annotations.firstIndex(where: { $0.id == selectedId }) {
            let annotation = annotations[index]
            if isTwoPointLine(annotation.type), let isStart = arrowResizeHandleAt(point: refPoint, annotation: annotation) {
                pushUndo()
                resizingAnnotationId = selectedId
                resizingAnnotationEdge = .none
                resizingArrowEndpoint = isStart
                resizeAnnotationStartPoint = refPoint
                resizeAnnotationOriginalRect = annotation.frame
                setNeedsDisplay(bounds)
                return
            }
            let rect = effectiveFrame(for: annotation)
            let edge: ResizeEdge
            if case .guide = annotation.type {
                // A full-canvas guide is not resized — only moved perpendicular.
                edge = .none
            } else if case .text = annotation.type {
                edge = textResizeEdgeAtAnnotationSpace(point: refPoint, rect: rect)
            } else {
                edge = resizeEdgeAtAnnotationSpace(point: refPoint, rect: rect)
            }
            if edge != .none {
                pushUndo()
                resizingAnnotationId = selectedId
                resizingAnnotationEdge = edge
                resizingArrowEndpoint = nil
                resizeAnnotationStartPoint = refPoint
                resizeAnnotationOriginalRect = (annotation.type == .circle) ? rect : annotation.frame
                setNeedsDisplay(bounds)
                return
            }
        }
        
        // 2) Check if clicking on an existing annotation: always select it (and adopt its
        // tool), regardless of which tool is active — creating happens on empty canvas only.
        if let clickedAnnotation = findAnnotation(at: refPoint) {
            // If we have an inline text field (e.g. empty new one we haven't typed in), finish it
            // so it disappears when we click back on an existing annotation
            if inlineTextField != nil {
                finishInlineText()
            }
            selectedAnnotationId = clickedAnnotation.id
            isDragging = false
            pendingDragAnnotationId = clickedAnnotation.id
            pendingDragStartRefPoint = refPoint
            updateUIForSelectedAnnotation(clickedAnnotation)
            setNeedsDisplay(bounds)
            // Double-click on text annotation: start editing
            if clickCount == 2, case .text = clickedAnnotation.type {
                if !bounds.contains(point) {
                    _ = rebasePointAfterWindowMoveIfNeeded(point)
                }
                beginEditingTextAnnotation(clickedAnnotation)
            }
            return
        }
        
        // Click on empty area (e.g. screenshot body): deselect annotation
        if screenshotRect.contains(point) {
            selectedAnnotationId = nil
            setNeedsDisplay(bounds)
        }
        
        // No tool selected: only selecting was allowed above; don't create new annotation
        guard let tool = currentTool else { return }
        
        // Handle text tool separately - don't remove existing text field if clicking to create new text
        if case .text = tool {
            // If clicking on existing text field, focus it instead of creating new one
            if let textField = inlineTextField, textField.frame.contains(point) {
                window?.makeFirstResponder(textField)
                textField.selectText(nil)
                return
            }
            // Check if within screenshot bounds
            if !screenshotRect.contains(point) {
                // Remove existing text field if clicking outside screenshot
                if inlineTextField != nil {
                    finishInlineText()
                }
                return
            }
            // Clicked on empty area: if already typing, commit and stop — do not create a new field
            // on the same click (user must click again to place another text).
            if inlineTextField != nil {
                finishInlineText()
                return
            }
            createInlineTextField(at: rebasePointAfterWindowMoveIfNeeded(point))
            return
        }
        
        // For non-text tools, remove inline text field if clicking elsewhere
        if inlineTextField != nil {
            finishInlineText()
        }
        
        // Stickers and numbered badges are markers and can be placed anywhere (even
        // outside the screenshot). Other tools (including redaction) must land inside.
        switch tool {
        case .sticker, .numberBadge:
            break
        default:
            if !screenshotRect.contains(point) {
                return
            }
        }
        
        ensureAnnotationReferenceRect()
        selectedAnnotationId = nil
        startPoint = refPoint
        
        switch tool {
        case .freehand:
            freehandStartPoint = refPoint
            freehandStraightLineDirection = nil
            currentFreehandPoints = [refPoint]
        case .rectangle, .circle, .arrow, .blur, .measure, .grid:
            isDrawing = true
            currentAnnotation = Annotation(
                id: UUID(),
                type: tool,
                frame: NSRect(origin: refPoint, size: .zero),
                color: colorForNewMark(),
                thickness: currentThickness,
                text: nil,
                fontSize: nil,
                startPoint: refPoint,
                endPoint: refPoint,
                pathPoints: nil,
                colorMode: colorModeForNewMark(),
                // Redaction stays opaque or it leaks the pixels it hides; a grid is a
                // see-through overlay, so it starts translucent.
                opacity: tool == .blur ? 1.0 : (tool == .grid ? alignmentAidDefaultOpacity : currentOpacity)
            )
        case .text:
            break
        case .numberBadge:
            let badgeSize = currentBadgeSize
            let ref = annotationSpaceRect
            let bx: CGFloat
            let by: CGFloat
            if screenshotRect.contains(point) {
                bx = max(0, min(refPoint.x - badgeSize/2, ref.width - badgeSize))
                by = max(0, min(refPoint.y - badgeSize/2, ref.height - badgeSize))
            } else {
                bx = refPoint.x - badgeSize/2
                by = refPoint.y - badgeSize/2
            }
            let badge = Annotation(
                id: UUID(),
                type: .numberBadge,
                frame: NSRect(x: bx, y: by, width: badgeSize, height: badgeSize),
                color: colorForNewMark(),
                thickness: currentThickness,
                text: nil,
                fontSize: nil,
                startPoint: nil,
                endPoint: nil,
                pathPoints: nil,
                stickerPointerDirection: nil,
                badgeNumber: Self.nextBadgeNumber(in: annotations),
                colorMode: colorModeForNewMark(),
                opacity: currentOpacity
            )
            pushUndo()
            annotations.append(badge)
            selectedAnnotationId = badge.id
            setNeedsDisplay(bounds)
        case .sticker(let stickerType):
            let stickerSize: CGFloat = 40
            let ref = annotationSpaceRect
            let stickerX: CGFloat
            let stickerY: CGFloat
            if screenshotRect.contains(point) {
                stickerX = max(0, min(refPoint.x - stickerSize/2, ref.width - stickerSize))
                stickerY = max(0, min(refPoint.y - stickerSize/2, ref.height - stickerSize))
            } else {
                stickerX = refPoint.x - stickerSize/2
                stickerY = refPoint.y - stickerSize/2
            }
            let stickerAnnotation = Annotation(
                id: UUID(),
                type: .sticker(stickerType),
                frame: NSRect(x: stickerX, y: stickerY, width: stickerSize, height: stickerSize),
                color: currentColor,
                thickness: currentThickness,
                text: nil,
                fontSize: nil,
                startPoint: nil,
                endPoint: nil,
                pathPoints: nil,
                opacity: currentOpacity
            )
            pushUndo()
            annotations.append(stickerAnnotation)
            setNeedsDisplay(bounds)
        case .guide(let orientation):
            // A guide is placed by a single click and spans the whole visible canvas.
            // It is a hairline by default: a guide's job is to mark an edge precisely,
            // which a thick stroke defeats, so it starts at the slider's minimum rather
            // than inheriting the drawing tools' thickness.
            let canvas = visibleAnnotationSpaceRect
            let guideThickness = AnnotationContextBar.range(for: .thickness).lowerBound
            let t = max(guideThickness, 2)
            let frame: NSRect
            if orientation == .horizontal {
                frame = NSRect(x: canvas.minX, y: refPoint.y - t / 2, width: canvas.width, height: t)
            } else {
                frame = NSRect(x: refPoint.x - t / 2, y: canvas.minY, width: t, height: canvas.height)
            }
            let guide = Annotation(
                id: UUID(),
                type: .guide(orientation),
                frame: frame,
                color: colorForNewMark(),
                thickness: guideThickness,
                text: nil,
                fontSize: nil,
                startPoint: nil,
                endPoint: nil,
                pathPoints: nil,
                colorMode: colorModeForNewMark(),
                opacity: alignmentAidDefaultOpacity
            )
            pushUndo()
            annotations.append(guide)
            selectedAnnotationId = guide.id
            setNeedsDisplay(bounds)
        }
    }

    /// If the point lies outside this view's bounds (interaction proxied from
    /// another monitor), ask the manager to move the annotation window to that
    /// screen, then rebase the point into the relocated view's coordinates.
    private func rebasePointAfterWindowMoveIfNeeded(_ point: NSPoint) -> NSPoint {
        guard isRegionMode, !bounds.contains(point), let move = onRequestWindowMove else { return point }
        let global = NSPoint(x: point.x + liveHoleScreenOrigin.x, y: point.y + liveHoleScreenOrigin.y)
        move(global)
        // If the manager relocated the view, liveHoleScreenOrigin has changed.
        return NSPoint(x: global.x - liveHoleScreenOrigin.x, y: global.y - liveHoleScreenOrigin.y)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let _ = inlineTextField, inlineTextField?.frame.contains(point) == true { return }
        if let toolbar = toolbarView, toolbar.frame.contains(point) { return }
        if let sliderContainer = sliderContainer, !sliderContainer.isHidden, sliderContainer.frame.contains(point) { return }
        let screenshotPoint = convertPointToScreenshotCoordinates(point)
        let refPoint = convertPointToAnnotationSpace(screenshotPoint)
        if let clicked = findAnnotation(at: refPoint), case .sticker = clicked.type {
            selectedAnnotationId = clicked.id
            updateUIForSelectedAnnotation(clicked)
            contextMenuStickerAnnotationId = clicked.id
            let menu = buildStickerPointerMenu()
            menu.popUp(positioning: nil, at: event.locationInWindow, in: self)
            setNeedsDisplay(bounds)
            return
        }
        super.rightMouseDown(with: event)
    }
    
    private func buildStickerPointerMenu() -> NSMenu {
        let menu = NSMenu()
        let pointerSubmenu = NSMenu()
        let noneItem = NSMenuItem(title: "None", action: #selector(stickerPointerDirectionPicked(_:)), keyEquivalent: "")
        noneItem.tag = -1
        noneItem.target = self
        pointerSubmenu.addItem(noneItem)
        pointerSubmenu.addItem(NSMenuItem.separator())
        for dir in StickerPointerDirection.allCases {
            let item = NSMenuItem(title: dir.menuTitle, action: #selector(stickerPointerDirectionPicked(_:)), keyEquivalent: "")
            item.tag = dir.rawValue
            item.target = self
            pointerSubmenu.addItem(item)
        }
        let pointerItem = NSMenuItem(title: "Pointer direction", action: nil, keyEquivalent: "")
        pointerItem.submenu = pointerSubmenu
        menu.addItem(pointerItem)
        return menu
    }
    
    @objc private func stickerPointerDirectionPicked(_ sender: NSMenuItem) {
        guard let id = contextMenuStickerAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        var annotation = annotations[index]
        annotation.stickerPointerDirection = sender.tag >= 0 ? StickerPointerDirection(rawValue: sender.tag) : nil
        annotations[index] = annotation
        contextMenuStickerAnnotationId = nil
        setNeedsDisplay(bounds)
    }
    
    override func flagsChanged(with event: NSEvent) {
        // Update shift state during freehand for straight-line constraint
        if case .freehand? = currentTool, currentFreehandPoints.count > 0 {
            let shiftNow = event.modifierFlags.contains(.shift)
            if !shiftNow {
                freehandStraightLineDirection = nil
            }
            setNeedsDisplay(bounds)
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        handlePointerDragged(at: convert(event.locationInWindow, from: nil), modifierFlags: event.modifierFlags)
    }

    /// Full mouse-drag handling from a view-local point (may be outside bounds
    /// when proxied from another monitor's overlay).
    func handlePointerDragged(at point: NSPoint, modifierFlags: NSEvent.ModifierFlags) {
        defer { if isAnnotateMode { positionContextBar() } }
        let screenshotPoint = convertPointToScreenshotCoordinates(point)
        
        if isRegionMode && resizingSelectionEdge != .none {
            handleSelectionResizeDrag(to: point)
            updateToolbarPosition()
            setNeedsDisplay(bounds)
            return
        }
        if isRegionMode && draggingSelectionRect,
           let start = selectionDragStartPoint,
           let originStart = selectionDragStartOrigin {
            let deltaX = point.x - start.x
            let deltaY = point.y - start.y
            screenshotRect.origin.x = originStart.x + deltaX
            screenshotRect.origin.y = originStart.y + deltaY
            clampSelectionRect()
            onSelectionRectChanged?(screenshotRect)
            updateToolbarPosition()
            setNeedsDisplay(bounds)
            return
        }
        
        let refPoint = convertPointToAnnotationSpace(screenshotPoint)
        
        // Annotation resize (including arrow endpoint drag) - all in annotation space
        if let annId = resizingAnnotationId, let index = annotations.firstIndex(where: { $0.id == annId }) {
            if let isStart = resizingArrowEndpoint {
                var annotation = annotations[index]
                guard isTwoPointLine(annotation.type), annotation.startPoint != nil, annotation.endPoint != nil else {
                    resizingArrowEndpoint = nil
                    setNeedsDisplay(bounds)
                    return
                }
                if isStart {
                    annotation.startPoint = refPoint
                } else {
                    annotation.endPoint = refPoint
                }
                let s = annotation.startPoint!
                let e = annotation.endPoint!
                annotation.frame = NSRect(x: min(s.x, e.x), y: min(s.y, e.y), width: max(s.x, e.x) - min(s.x, e.x), height: max(s.y, e.y) - min(s.y, e.y))
                annotations[index] = annotation
                setNeedsDisplay(bounds)
                return
            }
            if let original = resizeAnnotationOriginalRect {
                let retainAspect = modifierFlags.contains(.shift)
                handleAnnotationResizeDrag(annotationIndex: index, to: refPoint, original: original, retainAspectRatio: retainAspect)
                setNeedsDisplay(bounds)
                return
            }
        }
        
        // Start dragging only once a click that landed on the annotation moves past the
        // threshold. Offset is taken from the mouse-down point so the shape doesn't jump.
        if !isDragging,
           let annotationId = pendingDragAnnotationId,
           let startRef = pendingDragStartRefPoint,
           let index = annotations.firstIndex(where: { $0.id == annotationId }) {
            let dx = refPoint.x - startRef.x
            let dy = refPoint.y - startRef.y
            if dx * dx + dy * dy >= kAnnotationDragThreshold * kAnnotationDragThreshold {
                pushUndo()
                isDragging = true
                selectedAnnotationId = annotationId
                let annotation = annotations[index]
                dragOffset = NSPoint(
                    x: startRef.x - annotation.frame.origin.x,
                    y: startRef.y - annotation.frame.origin.y
                )
            }
        }
        
        if isDragging, let annotationId = selectedAnnotationId,
           let index = annotations.firstIndex(where: { $0.id == annotationId }) {
            // Drag existing annotation (new origin in annotation space)
            var annotation = annotations[index]
            var newOrigin = NSPoint(
                x: refPoint.x - dragOffset.x,
                y: refPoint.y - dragOffset.y
            )
            // A guide moves only perpendicular; its spanning axis is always the
            // current visible canvas so enlarging the hole never leaves a gap.
            if case .guide(let orientation) = annotation.type {
                let canvas = visibleAnnotationSpaceRect
                let t = max(orientation == .horizontal ? annotation.frame.height : annotation.frame.width, 2)
                if orientation == .horizontal {
                    annotation.frame = NSRect(
                        x: canvas.minX, y: newOrigin.y, width: canvas.width, height: t
                    )
                } else {
                    annotation.frame = NSRect(
                        x: newOrigin.x, y: canvas.minY, width: t, height: canvas.height
                    )
                }
                annotations[index] = annotation
                setNeedsDisplay(bounds)
                return
            }
            let deltaX = newOrigin.x - annotation.frame.origin.x
            let deltaY = newOrigin.y - annotation.frame.origin.y
            
            // Update frame origin
            annotation.frame.origin = newOrigin
            
            // For arrows, also update startPoint and endPoint
            if case .freehand = annotation.type, let points = annotation.pathPoints, !points.isEmpty {
                annotation.pathPoints = points.map { NSPoint(x: $0.x + deltaX, y: $0.y + deltaY) }
                // Recompute frame from path points
                let pts = annotation.pathPoints!
                var minX = pts[0].x, minY = pts[0].y, maxX = pts[0].x, maxY = pts[0].y
                for p in pts.dropFirst() {
                    minX = min(minX, p.x); minY = min(minY, p.y)
                    maxX = max(maxX, p.x); maxY = max(maxY, p.y)
                }
                annotation.frame = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            } else if isTwoPointLine(annotation.type), let start = annotation.startPoint, let end = annotation.endPoint {
                annotation.startPoint = NSPoint(x: start.x + deltaX, y: start.y + deltaY)
                annotation.endPoint = NSPoint(x: end.x + deltaX, y: end.y + deltaY)
                // Recalculate frame from start/end points
                let minX = min(annotation.startPoint!.x, annotation.endPoint!.x)
                let minY = min(annotation.startPoint!.y, annotation.endPoint!.y)
                let maxX = max(annotation.startPoint!.x, annotation.endPoint!.x)
                let maxY = max(annotation.startPoint!.y, annotation.endPoint!.y)
                annotation.frame = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            
            annotations[index] = annotation
            setNeedsDisplay(bounds)
            return
        }
        
        // Freehand: update path points in annotation space (with shift = straight line)
        if currentTool == .freehand, let start = freehandStartPoint, !currentFreehandPoints.isEmpty {
            let isShiftHeld = modifierFlags.contains(.shift)
            var point = refPoint
            if isShiftHeld {
                if freehandStraightLineDirection == nil {
                    let dx = abs(point.x - start.x)
                    let dy = abs(point.y - start.y)
                    if dx > 10 || dy > 10 {
                        freehandStraightLineDirection = dx > dy ? .horizontal : .vertical
                    }
                }
                if let direction = freehandStraightLineDirection {
                    switch direction {
                    case .horizontal: point.y = start.y
                    case .vertical: point.x = start.x
                    }
                    currentFreehandPoints = [start, point]
                } else {
                    currentFreehandPoints.append(point)
                }
            } else {
                freehandStraightLineDirection = nil
                currentFreehandPoints.append(point)
            }
            setNeedsDisplay(bounds)
            return
        }
        
        guard isDrawing, let start = startPoint else { return }
        
        // Update current annotation (rectangle / circle / arrow / measure) in annotation space
        switch currentTool {
        case .arrow, .measure:
            var endPoint = refPoint
            if modifierFlags.contains(.shift) {
                let dx = abs(refPoint.x - start.x)
                let dy = abs(refPoint.y - start.y)
                if dx > dy {
                    endPoint.y = start.y
                } else {
                    endPoint.x = start.x
                }
            }
            if var annotation = currentAnnotation {
                annotation.endPoint = endPoint
                let minX = min(start.x, endPoint.x)
                let minY = min(start.y, endPoint.y)
                let maxX = max(start.x, endPoint.x)
                let maxY = max(start.y, endPoint.y)
                annotation.frame = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                currentAnnotation = annotation
                setNeedsDisplay(bounds)
            }
        case .rectangle, .circle, .blur, .grid:
            if var annotation = currentAnnotation {
                let minX = min(start.x, refPoint.x)
                let minY = min(start.y, refPoint.y)
                let maxX = max(start.x, refPoint.x)
                let maxY = max(start.y, refPoint.y)
                var frame = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                if annotation.type == .circle, modifierFlags.contains(.shift) {
                    let side = max(frame.width, frame.height)
                    let originX = refPoint.x >= start.x ? start.x : start.x - side
                    let originY = refPoint.y >= start.y ? start.y : start.y - side
                    frame = NSRect(x: originX, y: originY, width: side, height: side)
                }
                annotation.frame = frame
                annotation.endPoint = refPoint
                currentAnnotation = annotation
                setNeedsDisplay(bounds)
            }
        default:
            break
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        handlePointerUp()
    }

    /// Full mouse-up handling; pairs with `handlePointerDown` / `handlePointerDragged`
    /// for interactions proxied from another monitor's overlay.
    func handlePointerUp() {
        // Every exit from this function can have moved, resized or created a
        // redaction. Rather than patch each `return`, capture which mark was under
        // manipulation and re-bake it once on the way out.
        let redactionUnderEdit: UUID? = isAnnotateMode
            ? (resizingAnnotationId ?? selectedAnnotationId ?? currentAnnotation?.id)
            : nil
        defer {
            if let id = redactionUnderEdit { rebakeRedaction(id: id) }
            if isAnnotateMode, let newest = annotations.last, newest.bakedMosaic == nil {
                rebakeRedaction(id: newest.id)
            }
        }
        pendingDragAnnotationId = nil
        pendingDragStartRefPoint = nil
        if resizingSelectionEdge != .none {
            resizingSelectionEdge = .none
            resizeSelectionOriginalRect = nil
            onSelectionRectChanged?(screenshotRect)
            onSelectionDragEnded?(screenshotRect)
            setNeedsDisplay(bounds)
            return
        }
        if draggingSelectionRect {
            draggingSelectionRect = false
            selectionDragStartPoint = nil
            selectionDragStartOrigin = nil
            onSelectionRectChanged?(screenshotRect)
            onSelectionDragEnded?(screenshotRect)
            setNeedsDisplay(bounds)
            return
        }
        // End annotation resize
        if resizingAnnotationId != nil {
            // Sync font size slider if we resized a text annotation
            if let selectedId = resizingAnnotationId,
               let annotation = annotations.first(where: { $0.id == selectedId }),
               case .text = annotation.type, let fontSize = annotation.fontSize {
                fontSizeSlider?.doubleValue = Double(fontSize)
                currentFontSize = fontSize
            }
            resizingAnnotationId = nil
            resizingAnnotationEdge = .none
            resizingArrowEndpoint = nil
            resizeAnnotationStartPoint = nil
            resizeAnnotationOriginalRect = nil
            setNeedsDisplay(bounds)
            return
        }
        
        if isDragging {
            // Keep the annotation selected after a drag; deselecting here made the
            // next click on it feel dead (it only re-selected).
            isDragging = false
            setNeedsDisplay(bounds)
            return
        }
        
        // Commit freehand path
        if currentTool == .freehand, currentFreehandPoints.count >= 2 {
            var minX = currentFreehandPoints[0].x, minY = currentFreehandPoints[0].y
            var maxX = minX, maxY = minY
            for p in currentFreehandPoints.dropFirst() {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            let frame = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let annotation = Annotation(
                id: UUID(),
                type: .freehand,
                frame: frame,
                color: colorForNewMark(),
                thickness: currentThickness,
                text: nil,
                fontSize: nil,
                startPoint: nil,
                endPoint: nil,
                pathPoints: currentFreehandPoints,
                colorMode: colorModeForNewMark(),
                opacity: currentOpacity
            )
            pushUndo()
            annotations.append(annotation)
            currentFreehandPoints = []
            freehandStartPoint = nil
            freehandStraightLineDirection = nil
            setNeedsDisplay(bounds)
            return
        }

        // Single-point freehand (stray click): drop the leftover state so it doesn't
        // linger into the next interaction.
        if currentTool == .freehand {
            currentFreehandPoints = []
            freehandStartPoint = nil
            freehandStraightLineDirection = nil
        }

        guard isDrawing else { return }
        isDrawing = false

        if var annotation = currentAnnotation {
            // Rect/circle from a stray click (no real drag) would be an invisible
            // zero-size layer that still steals hit-tests — discard it.
            if annotation.type == .rectangle || annotation.type == .circle || annotation.type == .blur || annotation.type == .grid,
               annotation.frame.width < kMinShapeSize && annotation.frame.height < kMinShapeSize {
                currentAnnotation = nil
                startPoint = nil
                setNeedsDisplay(bounds)
                return
            }
            // Measure: a stray click is too short to be a useful measurement. Unlike an
            // arrow (which defaults to a visible upward arrow), a zero-length ruler is
            // meaningless, so discard it.
            if annotation.type == .measure, let start = annotation.startPoint, let end = annotation.endPoint,
               (end.x - start.x) * (end.x - start.x) + (end.y - start.y) * (end.y - start.y) < kMinArrowDragSize * kMinArrowDragSize {
                currentAnnotation = nil
                startPoint = nil
                setNeedsDisplay(bounds)
                return
            }
            pushUndo()
            // Arrow: single-click (no meaningful drag) -> create default upward arrow of minimum length
            if annotation.type == .arrow, let start = annotation.startPoint, let end = annotation.endPoint {
                let dx = end.x - start.x
                let dy = end.y - start.y
                if dx * dx + dy * dy < kMinArrowDragSize * kMinArrowDragSize {
                    annotation.endPoint = NSPoint(x: start.x, y: start.y - kMinArrowLength)
                }
                let s = annotation.startPoint!
                let e = annotation.endPoint!
                annotation.frame = NSRect(x: min(s.x, e.x), y: min(s.y, e.y), width: max(s.x, e.x) - min(s.x, e.x), height: max(s.y, e.y) - min(s.y, e.y))
            }
            // Measure: derive the bounding frame from the endpoints, like the arrow.
            if annotation.type == .measure, let s = annotation.startPoint, let e = annotation.endPoint {
                annotation.frame = NSRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y))
            }
            annotations.append(annotation)
            currentAnnotation = nil
            setNeedsDisplay(bounds)
        }
        
        startPoint = nil
    }
    
    private func findAnnotation(at point: NSPoint) -> Annotation? {
        // Point is already in screenshot coordinates
        // Check annotations in reverse order (top to bottom)
        let hitAreaPadding: CGFloat = 8
        let arrowToleranceSq = kArrowLineHitTolerance * kArrowLineHitTolerance
        for annotation in annotations.reversed() {
            let rect = effectiveFrame(for: annotation)
            let expandedRect = rect.insetBy(dx: -hitAreaPadding, dy: -hitAreaPadding)
            if expandedRect.contains(point) { return annotation }
            // For two-point lines, also accept a click near the segment so a thin line is easy to select
            if isTwoPointLine(annotation.type), let start = annotation.startPoint, let end = annotation.endPoint,
               distanceSqFromPoint(point, toSegment: start, end: end) <= arrowToleranceSq {
                return annotation
            }
        }
        return nil
    }
    
    private var inlineTextField: NSTextField?
    private var inlineTextAnnotationId: UUID?
    private var isCreatingTextField = false
    
    /// Start editing an existing text annotation (double-click). Creates inline text field at annotation position.
    private func beginEditingTextAnnotation(_ annotation: Annotation) {
        guard case .text = annotation.type,
              let text = annotation.text,
              let fontSize = annotation.fontSize else { return }
        // Remove any existing inline field
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil
        
        isCreatingTextField = true
        inlineTextAnnotationId = annotation.id
        
        // Position using annotation space rect so it stays fixed when selection is resized
        let annRect = annotationSpaceRect
        let viewX = annRect.origin.x + annotation.frame.origin.x
        let bottomY = annRect.maxY - annotation.frame.origin.y - annotation.frame.height
        let fontNameEdit = UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica"
        let fontEdit = NSFont(name: fontNameEdit, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let strokePadEdit = AnnotationRenderer.textOutlineStrokeWidth(for: fontEdit)
        let wrapWEdit = max(1, annotation.frame.width - textAnnotationPadding - strokePadEdit * 2)
        let rowH = max(
            annotation.frame.height,
            textEditingHeight(for: text, fontSize: fontSize, width: wrapWEdit, outlinePad: strokePadEdit)
        )
        let viewFrame = NSRect(x: viewX, y: bottomY, width: annotation.frame.width, height: rowH)

        let textField = EditableTextField(frame: viewFrame)
        textField.stringValue = text
        textField.font = NSFont(name: UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textField.textColor = .clear
        textField.isEditable = true
        textField.isSelectable = true
        textField.isEnabled = true
        textField.delegate = self
        configureInlineTextFieldAppearance(textField)
        textField.refusesFirstResponder = false
        addSubview(textField, positioned: .above, relativeTo: nil)
        inlineTextField = textField
        textFieldChanged(textField)
        setNeedsDisplay(bounds)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.inlineTextField != nil else {
                self?.isCreatingTextField = false
                return
            }
            self.prepareLiveOverlayWindowForTextEditing()
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self, let textField = self.inlineTextField else {
                    self?.isCreatingTextField = false
                    return
                }
                _ = self.window?.makeFirstResponder(textField)
                textField.selectText(nil)
                self.applyInlineTextFieldOutlineTypingAttributes()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.isCreatingTextField = false
                }
            }
        }
    }
    
    private func createInlineTextField(at point: NSPoint) {
        // Remove existing inline text field if any
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil
        
        // Set flag to prevent immediate dismissal
        isCreatingTextField = true
        ensureAnnotationReferenceRect()
        
        let fieldHeight = inlineTextEditingHeight(fontSize: currentFontSize)
        let topLeftView = NSPoint(x: point.x, y: point.y - fieldHeight/2 + fieldHeight)
        let topLeftScreenshot = convertPointToScreenshotCoordinates(topLeftView)
        let topLeftRef = convertPointToAnnotationSpace(topLeftScreenshot)
        
        // Create text annotation in annotation space (size in ref units = view pixels at freeze time)
        let textAnnotation = Annotation(
            id: UUID(),
            type: .text,
            frame: NSRect(origin: topLeftRef, size: NSSize(width: textAnnotationMinWidth, height: fieldHeight)),
            color: colorForNewMark(),
            thickness: currentThickness,
            text: "",
            fontSize: currentFontSize,
            startPoint: nil,
            endPoint: nil,
            pathPoints: nil,
            colorMode: colorModeForNewMark(),
            opacity: currentOpacity
        )
        inlineTextAnnotationId = textAnnotation.id
        pushUndo()
        annotations.append(textAnnotation)
        
        // Position text field in view using annotation space rect so it stays fixed when selection is resized
        let annRect = annotationSpaceRect
        let viewX = annRect.origin.x + topLeftRef.x
        let viewY = annRect.maxY - topLeftRef.y - fieldHeight
        let textField = EditableTextField(frame: NSRect(x: viewX, y: viewY, width: textAnnotationMinWidth, height: fieldHeight))
        textField.stringValue = ""
        textField.font = NSFont(name: UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica", size: currentFontSize) ?? NSFont.systemFont(ofSize: currentFontSize)
        textField.textColor = .clear
        textField.isEditable = true
        textField.isSelectable = true
        textField.isEnabled = true
        textField.delegate = self
        configureInlineTextFieldAppearance(textField)
        
        // Make sure the field can become first responder
        textField.refusesFirstResponder = false
        
        // Make sure text field is above other views
        addSubview(textField, positioned: .above, relativeTo: nil)
        inlineTextField = textField
        
        // Keep key monitor active so ESC is caught and discards the text field
        // (monitor returns event for other keys so they reach the text field)
        
        // Ensure field is visible
        textField.isHidden = false
        textFieldChanged(textField)
        
        // Update display to show the field
        setNeedsDisplay(bounds)
        
        // Force window to be key and give focus to text field
        // Use exact pattern from GuidesOverlayView which works
        if let win = window {
            win.ignoresMouseEvents = false
            isCreatingTextField = true
            
            // Defer to next run loop tick so we are no longer inside the mouse tracking session
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.inlineTextField != nil else {
                    self?.isCreatingTextField = false
                    return
                }
                
                self.prepareLiveOverlayWindowForTextEditing()
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                
                // Small delay to ensure window is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self = self, let textField = self.inlineTextField else {
                        self?.isCreatingTextField = false
                        return
                    }
                    
                    // Make text field first responder
                    let becameFirstResponder = win.makeFirstResponder(textField)
                    
                    if becameFirstResponder {
                        // Select text to activate editor
                        textField.selectText(nil)
                        self.applyInlineTextFieldOutlineTypingAttributes()

                        // Clear flag after editor should be active
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            self.isCreatingTextField = false
                        }
                    } else {
                        // Failed to become first responder - try once more
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            guard let self = self, let textField = self.inlineTextField else {
                                self?.isCreatingTextField = false
                                return
                            }
                            win.makeFirstResponder(textField)
                            textField.selectText(nil)
                            self.applyInlineTextFieldOutlineTypingAttributes()
                            self.isCreatingTextField = false
                        }
                    }
                }
            }
        } else {
            isCreatingTextField = false
        }
    }
    
    /// Returns the annotation frame (screenshot coords) that tightly fits the text at the given font size, keeping top-left origin.
    
    @objc private func textFieldChanged(_ sender: NSTextField) {
        guard let id = inlineTextAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        
        var annotation = annotations[index]
        annotation.text = sender.stringValue
        
        let fontSize = annotation.fontSize ?? currentFontSize
        let topLeftRef = annotation.frame.origin
        let tightFrame = AnnotationRenderer.textAnnotationFrame(text: sender.stringValue, fontSize: fontSize, topLeft: topLeftRef)
        annotation.frame = tightFrame

        let annRect = annotationSpaceRect
        sender.frame = NSRect(
            x: annRect.origin.x + tightFrame.origin.x,
            y: annRect.maxY - tightFrame.origin.y - tightFrame.height,
            width: tightFrame.width,
            height: tightFrame.height
        )
        
        annotations[index] = annotation
        setNeedsDisplay(bounds)
    }

    private func configureInlineTextFieldAppearance(_ textField: NSTextField) {
        textField.backgroundColor = .clear
        textField.drawsBackground = false
        textField.isBordered = false
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.maximumNumberOfLines = 0
        if let cell = textField.cell {
            cell.truncatesLastVisibleLine = false
            cell.lineBreakMode = .byWordWrapping
            cell.isScrollable = false
            cell.wraps = true
            cell.usesSingleLineMode = false
        }
    }

    private func textEditingHeight(for text: String, fontSize: CGFloat, width: CGFloat, outlinePad: CGFloat) -> CGFloat {
        let fontName = UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica"
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let verticalPad = AnnotationRenderer.textVerticalPad(for: font)
        let attributes = AnnotationRenderer.textFillAttributes(font: font, color: .labelColor)
        let attributedString = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
        let bounds = attributedString.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        let measuredTextHeight = ceil(bounds.height)
        _ = outlinePad
        return max(AnnotationRenderer.textContentLineHeight(for: font), measuredTextHeight) + verticalPad * 2
    }

    private func inlineTextEditingHeight(fontSize: CGFloat) -> CGFloat {
        let fontName = UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica"
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let verticalPad = AnnotationRenderer.textVerticalPad(for: font)
        return AnnotationRenderer.textContentLineHeight(for: font) + verticalPad * 2
    }

    /// Keep field-editor glyphs invisible and let annotation renderer draw text,
    /// so focused and unfocused states use the exact same outline rendering path.
    private func applyInlineTextFieldOutlineTypingAttributes() {
        guard let textField = inlineTextField,
              let id = inlineTextAnnotationId,
              let ann = annotations.first(where: { $0.id == id }),
              let fs = ann.fontSize else { return }
        let fontName = UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica"
        let font = NSFont(name: fontName, size: fs) ?? NSFont.systemFont(ofSize: fs)
        let typing: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.clear,
            .strokeColor: NSColor.clear,
            .strokeWidth: 0
        ]
        if let tv = textField.window?.fieldEditor(true, for: textField) as? NSTextView {
            tv.typingAttributes = typing
            tv.textColor = .clear
            tv.insertionPointColor = ann.color
            // Keep editor text invisible for existing content too.
            let selectedRange = tv.selectedRange()
            tv.textStorage?.setAttributes(typing, range: NSRange(location: 0, length: tv.string.utf16.count))
            tv.setSelectedRange(selectedRange)
        }
    }

    
    // MARK: - Drawing
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let screenshotDrawRect = screenshotRect
        
        if isRegionMode {
            if !frozenDisplaySnaps.isEmpty {
                drawFrozenBackdropTiled()
            } else {
                NSColor.black.setFill()
                bounds.fill()
            }
            fillDimOutsideSelection(screenshotDrawRect)
            let borderPath = NSBezierPath(rect: screenshotDrawRect)
            borderPath.lineWidth = 2
            NSColor.white.withAlphaComponent(0.8).setStroke()
            borderPath.stroke()
            drawResizeHandles(for: screenshotDrawRect)
        } else {
            context.saveGState()
            context.clip(to: screenshotDrawRect)
            context.setStrokeColor(NSColor.clear.cgColor)
            context.setLineWidth(0)
            context.setLineDash(phase: 0, lengths: [])
            if let img = screenshot,
               let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cgImage, in: screenshotDrawRect)
            } else if let img = screenshot {
                img.draw(in: screenshotDrawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            context.restoreGState()
        }
        
        drawAnnotationLayers(in: context)
    }

    /// Mirror the annotation layers (committed + in-progress + selection
    /// highlight) into another screen's overlay context, so annotations stay
    /// visible on every monitor a cross-screen hole touches. The overlay's
    /// context is translated so this view's local coordinates line up.
    func drawAnnotationsForOverlay(in context: CGContext, overlayScreenOrigin: CGPoint) {
        context.saveGState()
        context.translateBy(
            x: liveHoleScreenOrigin.x - overlayScreenOrigin.x,
            y: liveHoleScreenOrigin.y - overlayScreenOrigin.y
        )
        drawAnnotationLayers(in: context)
        context.restoreGState()
    }

    /// Draws all annotation layers assuming `context` is in this view's local
    /// coordinate space.
    private func drawAnnotationLayers(in context: CGContext) {
        // Draw annotations in annotation space (aligned to screenshot rect). Clip to
        // the selection hole so guides — which span the visible canvas as infinite
        // lines — do not bleed into the dimmed area outside.
        let annotationRect = annotationSpaceRect
        context.saveGState()
        context.clip(to: screenshotRect)
        context.translateBy(x: annotationRect.origin.x, y: annotationRect.origin.y)
        context.translateBy(x: 0, y: annotationRect.height)
        context.scaleBy(x: 1.0, y: -1.0)

        let onScreen = rendererContext(showsGridLabels: true)
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, in: context, using: onScreen)
        }
        
        // Draw current annotation being drawn (rectangle/circle/arrow) in annotation space
        if let annotation = currentAnnotation {
            AnnotationRenderer.draw(annotation, in: context, using: onScreen)
        }
        
        // Draw current freehand path while dragging (points in annotation space).
        // Preview with the exact colour + mode the committed stroke will use, so a
        // mono-blue brush previews blue instead of the default red, and a rainbow
        // brush previews its gradient live rather than snapping to it on release.
        if currentFreehandPoints.count >= 2 {
            context.saveGState()
            context.setAlpha(currentOpacity)
            context.setLineWidth(currentThickness)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if colorModeForNewMark() == .rainbow {
                AnnotationRenderer.strokeRainbowPath(currentFreehandPoints, in: context)
            } else {
                context.setStrokeColor(colorForNewMark().cgColor)
                context.move(to: currentFreehandPoints[0])
                for i in 1..<currentFreehandPoints.count {
                    context.addLine(to: currentFreehandPoints[i])
                }
                context.strokePath()
            }
            context.restoreGState()
        }
        context.restoreGState()
        
        // Highlight selected annotation and draw resize handles (annotation space)
        if let selectedId = selectedAnnotationId,
           let annotation = annotations.first(where: { $0.id == selectedId }),
           selectedId != inlineTextAnnotationId {
            context.saveGState()
            context.clip(to: screenshotRect)
            context.translateBy(x: annotationRect.origin.x, y: annotationRect.origin.y)
            context.translateBy(x: 0, y: annotationRect.height)
            context.scaleBy(x: 1.0, y: -1.0)
            
            let rect = effectiveFrame(for: annotation)
            let selectionFrame = rect.insetBy(dx: -4, dy: -4)
            
            // Outer glow (yellow/orange to be more visible)
            context.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(3)
            context.setLineDash(phase: 0, lengths: [])
            context.stroke(selectionFrame)
            
            // Inner dashed border
            context.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.stroke(selectionFrame.insetBy(dx: 1, dy: 1))
            context.setLineDash(phase: 0, lengths: [])
            
            // Resize handles: a two-point line gets two at start/end; a guide is move-only
            // so it gets none; text gets horizontal handles; everything else gets 8 on the rect.
            if case .guide = annotation.type {
                // No handles.
            } else if isTwoPointLine(annotation.type), let start = annotation.startPoint, let end = annotation.endPoint {
                drawResizeHandles(for: [start, end])
            } else if case .text = annotation.type {
                drawHorizontalResizeHandles(for: rect)
            } else {
                drawResizeHandles(for: rect)
            }
            context.restoreGState()
        }
    }
    

    /// Next number for a freshly placed badge: one more than the highest existing badge
    /// number, starting at 1. Copy/paste keeps the original number (duplicates are allowed).
    static func nextBadgeNumber(in annotations: [Annotation]) -> Int {
        let highest = annotations.compactMap { annotation -> Int? in
            if case .numberBadge = annotation.type { return annotation.badgeNumber }
            return nil
        }.max() ?? 0
        return highest + 1
    }

    /// Mosaic of the pixels beneath a redaction frame, sampled from the appropriate
    /// source for the current mode (static screenshot, or the frozen desktop in live mode).
    /// Baked blocky so it stays illegible even if drawn with smoothing. Nil if no source.
    private func mosaicRegionImage(forFrame frame: NSRect) -> NSImage? {
        guard frame.width >= 1, frame.height >= 1 else { return nil }
        if let shot = screenshot {
            // Static mode: the screenshot image fills screenshotRect; annotation frames are
            // in that displayed-rect coordinate space (top-left origin).
            let sx = shot.size.width / max(1, screenshotRect.width)
            let sy = shot.size.height / max(1, screenshotRect.height)
            let src = NSRect(x: frame.minX * sx, y: frame.minY * sy, width: frame.width * sx, height: frame.height * sy)
            return AnnotationRenderer.bakedMosaic(of: shot, sourceRect: src, outSize: frame.size)
        }
        // Live mode: composite the frozen desktop region under this frame.
        guard !frozenDisplaySnaps.isEmpty else { return nil }
        let ref = annotationSpaceRect
        let globalX = ref.origin.x + frame.minX + liveHoleScreenOrigin.x
        let globalMinY = ref.maxY - frame.maxY + liveHoleScreenOrigin.y
        let globalRect = NSRect(x: globalX, y: globalMinY, width: frame.width, height: frame.height)
        guard let region = MultiMonitorHelper.compositeFrozenGlobalRect(
            globalRect,
            snapshots: frozenDisplaySnaps.map { (image: $0.image, frame: $0.frame) }
        ) else { return nil }
        return AnnotationRenderer.bakedMosaic(of: region, sourceRect: NSRect(origin: .zero, size: region.size), outSize: frame.size)
    }

    /// Draws a small arrow emanating from the sticker in the given direction (screenshot coordinates).
    
    // MARK: - Redaction (mosaic) + numbered badge rendering

    /// Target on-screen size of one mosaic block, in points. Small enough to hug the region,
    /// large enough that text underneath is destroyed.

    /// Produce a chunky mosaic of `sourceRect` (in `source` image POINTS, top-left origin).
    /// The result is baked (pre-blocked) at 2x so it stays illegible even if later drawn with
    /// interpolation. Downsampling averages each block, so the original pixels are unrecoverable.

    /// Test hook: replace the annotation list (export-render regression tests).
    func _setAnnotationsForTesting(_ newAnnotations: [Annotation]) {
        annotations = newAnnotations
    }

    /// Enlarge/shrink the selection hole (and optionally freeze the annotation
    /// reference) so tests can assert guides re-span the visible canvas.
    func _setSelectionRectForTesting(_ rect: NSRect, freezeReferenceAt reference: NSRect? = nil) {
        if let reference {
            annotationReferenceRect = reference
        }
        screenshotRect = rect
        setNeedsDisplay(bounds)
    }

    func _effectiveFrameForTesting(of id: UUID) -> NSRect? {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return nil }
        return effectiveFrame(for: annotation)
    }

    /// Test hooks: exercise select → copy → paste so the copy/paste regression is covered
    /// without driving real mouse/keyboard events.
    func _annotationsForTesting() -> [Annotation] { annotations }
    func _selectForTesting(_ id: UUID) { selectedAnnotationId = id }
    func _copySelectedForTesting() { copySelectedAnnotations() }
    @discardableResult func _deleteSelectedForTesting() -> Bool { deleteSelectedAnnotation() }
    @discardableResult func _pasteForTesting() -> Bool { pasteAnnotations() }
    func _contextBarOriginForTesting() -> NSPoint? { contextBar?.frame.origin }
    func _applyContextBarSliderForTesting(_ control: AnnotationContextBar.Control, value: CGFloat) {
        applyContextBarSlider(control, value: value)
    }
    /// Test hooks: the editor slider row's right cluster, for order and chrome checks.
    var _editorColorButtonForTesting: NSButton? { colorButton }
    var _editorRainbowButtonForTesting: NSButton? { editorRainbowButton }
    var _editorOpacityButtonForTesting: NSButton? { editorOpacityButton }
    var _editorSliderRowForTesting: NSView? { sliderContainer }
    var _isRainbowModeForTesting: Bool { currentColorMode == .rainbow }

    /// Test hooks: drive a grid's dimension readout without a real click or field editor.
    func _gridLabelHitForTesting(at point: NSPoint) -> AnnotationRenderer.GridLabel? {
        gridLabelHit(at: point)?.label
    }
    func _beginGridSizeEditForTesting(_ id: UUID, label: AnnotationRenderer.GridLabel) {
        beginGridSizeEdit(annotationId: id, label: label)
    }
    var _isEditingGridSizeForTesting: Bool { gridSizeField != nil }
    /// Exposed so tests can post a synthetic `controlTextDidEndEditing` against the
    /// live field without depending on a real field editor.
    var _gridSizeFieldForTesting: NSTextField? { gridSizeField }
    func _commitGridSizeForTesting(_ typed: String, commit: Bool = true) {
        gridSizeField?.stringValue = typed
        finishGridSizeEdit(commit: commit)
    }

    /// Drives the numbered-badge size slider action (secondary-bar size control).
    func _changeBadgeSizeForTesting(_ size: CGFloat) {
        let slider = NSSlider()
        slider.minValue = Double(badgeSizeMin)
        slider.maxValue = Double(badgeSizeMax)
        slider.doubleValue = Double(size)
        badgeSizeChanged(slider)
    }

    /// Renders screenshot + annotations at full pixel resolution (Retina) so exported images stay sharp.
    func renderAnnotatedImage() -> NSImage {
        guard let screenshot = screenshot else {
            return NSImage(size: screenshotRect.size)
        }
        let size = screenshot.size
        guard let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return renderAnnotatedImageLegacy()
        }
        let pixelW = cgImage.width
        let pixelH = cgImage.height
        // Annotations are stored in *displayed-rect* coordinates (the aspect-fit
        // rect on screen), which can be smaller than the image itself — e.g. a
        // fullscreen window capture is scaled down to fit under the toolbar. Scale
        // by pixels / displayed size, NOT pixels / image points, or every mark
        // drifts towards the top-left in the saved file.
        let scaleX = CGFloat(pixelW) / max(1, screenshotRect.width)
        let scaleY = CGFloat(pixelH) / max(1, screenshotRect.height)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixelW * 4,
            bitsPerPixel: 32
        ) else {
            return renderAnnotatedImageLegacy()
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.shouldAntialias = true

        // Draw screenshot at 1:1 pixels
        screenshot.draw(in: NSRect(x: 0, y: 0, width: pixelW, height: pixelH), from: .zero, operation: .sourceOver, fraction: 1.0)

        // Draw annotations in displayed-rect coords; transform to pixel space (flip Y, scale)
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(pixelH))
            context.scaleBy(x: 1, y: -1)
            context.scaleBy(x: scaleX, y: scaleY)
            for annotation in annotations {
                // No grid labels: the dimension readouts are an editing affordance and
                // must not be burned into the exported image.
                AnnotationRenderer.draw(annotation, in: context, using: rendererContext())
            }
            context.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: size)
        rep.size = size
        result.addRepresentation(rep)
        return result
    }

    private func renderAnnotatedImageLegacy() -> NSImage {
        guard let screenshot = screenshot else {
            return NSImage(size: screenshotRect.size)
        }
        let originalSize = screenshot.size
        let image = NSImage(size: originalSize)
        image.lockFocus()
        screenshot.draw(in: NSRect(origin: .zero, size: originalSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        if let context = NSGraphicsContext.current?.cgContext {
            let scaleX = originalSize.width / screenshotRect.width
            let scaleY = originalSize.height / screenshotRect.height
            context.saveGState()
            context.translateBy(x: 0, y: originalSize.height)
            context.scaleBy(x: scaleX, y: -scaleY)
            for annotation in annotations {
                // No grid labels: see `renderAnnotatedImage`.
                AnnotationRenderer.draw(annotation, in: context, using: rendererContext())
            }
            context.restoreGState()
        }
        image.unlockFocus()
        return image
    }
    
    /// Composite annotations onto a captured image. Annotations are in image-local coords (top-left origin).
    /// Renders at full pixel resolution (Retina) so saved screenshots stay crisp.
    static func renderAnnotations(on image: NSImage, annotations: [Annotation]) -> NSImage {
        let size = image.size
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return renderAnnotationsLegacy(on: image, annotations: annotations)
        }
        let pixelW = cgImage.width
        let pixelH = cgImage.height
        let scaleX = CGFloat(pixelW) / size.width
        let scaleY = CGFloat(pixelH) / size.height

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixelW * 4,
            bitsPerPixel: 32
        ) else {
            return renderAnnotationsLegacy(on: image, annotations: annotations)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.shouldAntialias = true

        // Draw image at 1:1 pixels
        let imageRect = NSRect(x: 0, y: 0, width: pixelW, height: pixelH)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(pixelH))
            context.scaleBy(x: 1, y: -1)
            context.scaleBy(x: scaleX, y: scaleY)
            for annotation in annotations {
                let canvas = NSRect(origin: .zero, size: size)
                AnnotationRenderer.draw(annotation, in: context, using: AnnotationRenderer.Context(
                    guideFrame: { a in
                        guard case .guide(let o) = a.type else { return a.frame }
                        return AnnotationRenderer.guideFrame(for: a, orientation: o, spanning: canvas)
                    },
                    mosaic: { ann in
                        AnnotationRenderer.bakedMosaic(of: image, sourceRect: ann.frame, outSize: ann.frame.size)
                    }
                ))
            }
            context.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: size)
        rep.size = size
        result.addRepresentation(rep)
        return result
    }

    private static func renderAnnotationsLegacy(on image: NSImage, annotations: [Annotation]) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            for annotation in annotations {
                let canvas = NSRect(origin: .zero, size: size)
                AnnotationRenderer.draw(annotation, in: context, using: AnnotationRenderer.Context(
                    guideFrame: { a in
                        guard case .guide(let o) = a.type else { return a.frame }
                        return AnnotationRenderer.guideFrame(for: a, orientation: o, spanning: canvas)
                    },
                    mosaic: { ann in
                        AnnotationRenderer.bakedMosaic(of: image, sourceRect: ann.frame, outSize: ann.frame.size)
                    }
                ))
            }
            context.restoreGState()
        }
        result.unlockFocus()
        return result
    }
    

    // MARK: - Grid dimension editing

    private var gridSizeField: NSTextField?
    private var gridSizeAnnotationId: UUID?
    private var gridSizeEditingLabel: AnnotationRenderer.GridLabel?

    /// Topmost grid whose width or height readout contains `point` (annotation space),
    /// searched front to back so the label of an overlapping grid on top wins.
    private func gridLabelHit(at point: NSPoint) -> (id: UUID, label: AnnotationRenderer.GridLabel)? {
        for annotation in annotations.reversed() {
            guard case .grid = annotation.type else { continue }
            let rects = AnnotationRenderer.gridLabelRects(for: annotation.frame)
            if rects.width.contains(point) { return (annotation.id, .width) }
            if rects.height.contains(point) { return (annotation.id, .height) }
        }
        return nil
    }

    /// Annotation space (Y down from the reference rect's top edge) to view
    /// coordinates (Y up), the same mapping the inline text field uses.
    private func viewRect(forAnnotationSpaceRect rect: NSRect) -> NSRect {
        let ref = annotationSpaceRect
        return NSRect(
            x: ref.origin.x + rect.origin.x,
            y: ref.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Swap a grid's dimension readout for an editable field. Styled to match the
    /// label it replaces, so the swap is invisible apart from the caret.
    ///
    /// Focus mirrors the text-tool path: without the creation guard + delayed
    /// `makeFirstResponder`, `controlTextDidEndEditing` fires during the key-window
    /// shuffle and tears the field down before any keystroke lands.
    private func beginGridSizeEdit(annotationId: UUID, label: AnnotationRenderer.GridLabel) {
        guard let annotation = annotations.first(where: { $0.id == annotationId }),
              case .grid = annotation.type else { return }
        finishGridSizeEdit(commit: false)

        gridSizeAnnotationId = annotationId
        gridSizeEditingLabel = label

        let rects = AnnotationRenderer.gridLabelRects(for: annotation.frame)
        let target = label == .width ? rects.width : rects.height
        let value = label == .width ? annotation.frame.width : annotation.frame.height

        let field = EditableTextField(frame: viewRect(forAnnotationSpaceRect: target))
        field.stringValue = "\(Int(value.rounded()))"
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        field.textColor = .white
        field.font = NSFont.systemFont(ofSize: 11)
        field.alignment = .center
        field.focusRingType = .none
        field.refusesFirstResponder = false
        field.delegate = self
        addSubview(field, positioned: .above, relativeTo: nil)
        gridSizeField = field
        // Arm before the focus dance so a premature end-editing notification cannot
        // tear the field down. Cleared in finishGridSizeEdit / after focus succeeds.
        isCreatingTextField = true
        setNeedsDisplay(bounds)

        guard let win = window else {
            // Headless (unit tests): field stays open until finishGridSizeEdit.
            return
        }
        win.ignoresMouseEvents = false

        DispatchQueue.main.async { [weak self] in
            guard let self, self.gridSizeField != nil else {
                self?.isCreatingTextField = false
                return
            }
            self.prepareLiveOverlayWindowForTextEditing()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let field = self.gridSizeField else {
                    self?.isCreatingTextField = false
                    return
                }
                if win.makeFirstResponder(field) {
                    field.selectText(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.isCreatingTextField = false
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self, let field = self.gridSizeField else {
                            self?.isCreatingTextField = false
                            return
                        }
                        _ = win.makeFirstResponder(field)
                        field.selectText(nil)
                        self.isCreatingTextField = false
                    }
                }
            }
        }
    }

    /// Apply or discard the typed dimension. The grid keeps its top-left corner, so
    /// typing a size grows it the same way dragging the bottom-right handle does.
    /// Non-numeric or non-positive input is discarded rather than collapsing the grid.
    private func finishGridSizeEdit(commit: Bool) {
        isCreatingTextField = false
        guard let field = gridSizeField else {
            gridSizeAnnotationId = nil
            gridSizeEditingLabel = nil
            return
        }
        let id = gridSizeAnnotationId
        let label = gridSizeEditingLabel
        gridSizeField = nil
        gridSizeAnnotationId = nil
        gridSizeEditingLabel = nil
        field.removeFromSuperview()

        if commit, let id, let label,
           let index = annotations.firstIndex(where: { $0.id == id }),
           let typed = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
           typed > 0 {
            pushUndo()
            var size = annotations[index].frame.size
            if label == .width {
                size.width = CGFloat(typed)
            } else {
                size.height = CGFloat(typed)
            }
            annotations[index].frame.size = RectangleSizeValidator.clamp(
                size: size,
                toViewport: annotationSpaceRect.size
            )
        }

        releaseLiveOverlayWindowKeyboardIfNeeded()
        setNeedsDisplay(bounds)
    }

    /// Tear down without committing — used when the grid being edited goes away.
    private func cancelGridSizeEditIfNeeded(for id: UUID) {
        guard gridSizeAnnotationId == id else { return }
        finishGridSizeEdit(commit: false)
    }

    /// Discard an open dimension edit. The first rung of the escape cascade: Esc is
    /// grabbed by a global hot key, so the field editor's own `cancelOperation:` never
    /// sees it while a session is running and the manager has to ask instead.
    @discardableResult
    func cancelInlineEditForHost() -> Bool {
        guard gridSizeField != nil else { return false }
        finishGridSizeEdit(commit: false)
        return true
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        // Return, Tab or a lost focus all land here; the grid field commits on each.
        // Skip while the field is still being focused — the key-window shuffle fires
        // this during setup and would otherwise tear the field down immediately.
        if let field = obj.object as? NSTextField, field === gridSizeField {
            guard !isCreatingTextField else { return }
            finishGridSizeEdit(commit: true)
            return
        }
        // Don't finish if we're still in the process of creating the field
        guard !isCreatingTextField else {
            return
        }
        // Finish editing when field loses focus
        finishInlineText()
    }
    
    func controlTextDidBeginEditing(_ obj: Notification) {
        if let tf = obj.object as? NSTextField, tf == inlineTextField {
            applyInlineTextFieldOutlineTypingAttributes()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if let textField = obj.object as? NSTextField, textField == inlineTextField {
            textFieldChanged(textField)
            applyInlineTextFieldOutlineTypingAttributes()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === gridSizeField {
            // Esc reverts the dimension. Only reached when no global escape hot key is
            // registered (the screenshot editor, or while a recording runs); during a
            // live session the manager's cascade calls `cancelInlineEditForHost` first.
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishGridSizeEdit(commit: false)
                return true
            }
            return false
        }
        guard control == inlineTextField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) ||
            commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
            // Field editors treat Return as "end editing" by default — force a literal newline.
            textView.insertLineBreak(nil)
            if let textField = inlineTextField {
                textFieldChanged(textField)
            }
            applyInlineTextFieldOutlineTypingAttributes()
            return true
        }
        return false
    }
    
    private func finishInlineText() {
        guard let textField = inlineTextField,
              let id = inlineTextAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == id }) else {
            inlineTextField?.removeFromSuperview()
            inlineTextField = nil
            inlineTextAnnotationId = nil
            releaseLiveOverlayWindowKeyboardIfNeeded()
            return
        }
        
        var annotation = annotations[index]
        annotation.text = textField.stringValue
        
        // Remove empty text annotations
        if textField.stringValue.isEmpty {
            pushUndo()
            annotations.remove(at: index)
        } else {
            // Tighten frame to text size (same tight padding as elsewhere)
            pushUndo()
            let fontSize = annotation.fontSize ?? currentFontSize
            let topLeft = annotation.frame.origin
            annotation.frame = AnnotationRenderer.textAnnotationFrame(text: annotation.text ?? "", fontSize: fontSize, topLeft: topLeft)
            annotations[index] = annotation
        }
        
        textField.removeFromSuperview()
        inlineTextField = nil
        inlineTextAnnotationId = nil
        
        releaseLiveOverlayWindowKeyboardIfNeeded()
        setNeedsDisplay(bounds)
        notifyIfCanvasEmptied()
    }
}
