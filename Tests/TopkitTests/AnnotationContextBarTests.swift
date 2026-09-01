import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// The per-selection options bar. Which controls appear is a pure function of the
/// annotation type, and placement is pure geometry — both testable without a screen.
final class AnnotationContextBarTests: XCTestCase {

    // MARK: - Control selection

    /// Colour mode and opacity are now session-wide, so every shape carries the
    /// rainbow toggle and the opacity dropdown alongside colour and thickness.
    func testShapeToolsGetColourRainbowThicknessAndOpacity() {
        for tool in [AnnotationTool.rectangle, .circle, .arrow] {
            XCTAssertEqual(AnnotationContextBar.Control.controls(for: tool),
                           [.color, .rainbow, .thickness, .opacity],
                           "\(tool) should offer colour, rainbow, thickness and opacity")
        }
    }

    func testFreehandGetsColourRainbowThicknessAndOpacity() {
        XCTAssertEqual(AnnotationContextBar.Control.controls(for: .freehand),
                       [.color, .rainbow, .thickness, .opacity])
    }

    func testTextGetsColourRainbowFontSizeAndOpacity() {
        XCTAssertEqual(AnnotationContextBar.Control.controls(for: .text),
                       [.color, .rainbow, .fontSize, .opacity])
    }

    func testBadgeGetsColourRainbowBadgeSizeAndOpacity() {
        XCTAssertEqual(AnnotationContextBar.Control.controls(for: .numberBadge),
                       [.color, .rainbow, .badgeSize, .opacity])
    }

    /// Stickers take their colour from their type, so a colour well would be a lie —
    /// but they still get sizing and opacity.
    func testStickerGetsTypeSizeAndOpacityButNoColourWell() {
        let controls = AnnotationContextBar.Control.controls(for: .sticker(.redX))
        XCTAssertEqual(controls, [.stickerType, .stickerSize, .opacity])
        XCTAssertFalse(controls.contains(.color))
    }

    /// Redaction stays optionless: opacity would let the hidden pixels bleed through.
    func testRedactHasNoControls() {
        XCTAssertTrue(AnnotationContextBar.Control.controls(for: .blur).isEmpty)
    }

    func testOpacityIsOfferedEverywhereExceptRedaction() {
        for tool in [AnnotationTool.freehand, .rectangle, .circle, .arrow, .text, .numberBadge, .sticker(.redX)] {
            XCTAssertTrue(AnnotationContextBar.Control.controls(for: tool).contains(.opacity),
                          "\(tool) should offer opacity")
        }
        XCTAssertFalse(AnnotationContextBar.Control.controls(for: .blur).contains(.opacity),
                       "redaction must not be made translucent")
    }

    // MARK: - Slider ranges match the editor's

    func testSliderRangesMatchTheScreenshotEditor() {
        XCTAssertEqual(AnnotationContextBar.range(for: .thickness), 1...20)
        XCTAssertEqual(AnnotationContextBar.range(for: .fontSize), 8...72)
        XCTAssertEqual(AnnotationContextBar.range(for: .badgeSize), 16...120)
    }

    // MARK: - Placement

    private let canvas = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let barSize = NSSize(width: 160, height: 36)

    func testBarSitsAboveTheSelectionByDefault() {
        let selection = NSRect(x: 600, y: 400, width: 200, height: 100)
        let origin = AnnotationContextBar.origin(forSelection: selection, barSize: barSize, in: canvas, avoiding: nil)
        XCTAssertGreaterThan(origin.y, selection.maxY, "bar should float above the element")
        XCTAssertEqual(origin.x + barSize.width / 2, selection.midX, accuracy: 0.5, "and be centred on it")
    }

    func testBarFlipsBelowWhenTheSelectionIsNearTheTop() {
        let selection = NSRect(x: 600, y: 860, width: 200, height: 30)
        let origin = AnnotationContextBar.origin(forSelection: selection, barSize: barSize, in: canvas, avoiding: nil)
        XCTAssertLessThan(origin.y, selection.minY, "no room above, so it must flip below")
        XCTAssertGreaterThanOrEqual(origin.y, canvas.minY)
    }

    func testBarIsClampedHorizontallyAtTheScreenEdges() {
        let leftEdge = NSRect(x: 0, y: 400, width: 20, height: 20)
        let left = AnnotationContextBar.origin(forSelection: leftEdge, barSize: barSize, in: canvas, avoiding: nil)
        XCTAssertGreaterThanOrEqual(left.x, canvas.minX, "must not run off the left edge")

        let rightEdge = NSRect(x: 1430, y: 400, width: 20, height: 20)
        let right = AnnotationContextBar.origin(forSelection: rightEdge, barSize: barSize, in: canvas, avoiding: nil)
        XCTAssertLessThanOrEqual(right.x + barSize.width, canvas.maxX, "must not run off the right edge")
    }

    /// An element larger than the screen must still produce an on-screen bar.
    func testOversizedSelectionStillYieldsAnOnScreenBar() {
        let huge = NSRect(x: -500, y: -500, width: 3000, height: 2000)
        let origin = AnnotationContextBar.origin(forSelection: huge, barSize: barSize, in: canvas, avoiding: nil)
        let rect = NSRect(origin: origin, size: barSize)
        XCTAssertTrue(canvas.contains(rect), "bar \(rect) must stay inside \(canvas)")
    }

    func testBarDoesNotCoverTheToolStrip() {
        let strip = NSRect(x: 620, y: 48, width: 300, height: 36)
        // A selection just above the strip would otherwise put the bar on top of it.
        let selection = NSRect(x: 700, y: 90, width: 120, height: 40)
        let origin = AnnotationContextBar.origin(forSelection: selection, barSize: barSize, in: canvas, avoiding: strip)
        let rect = NSRect(origin: origin, size: barSize)
        XCTAssertFalse(rect.intersects(strip), "bar \(rect) overlaps the strip \(strip)")
    }

    // MARK: - Construction

    func testBuiltBarMatchesToolbarChromeHeight() {
        let bar = AnnotationContextBar(controls: [.color, .thickness], color: .red, value: 4, stickerType: nil)
        XCTAssertEqual(bar.frame.height, AnnotationToolbarChrome.height)
        XCTAssertEqual(bar.layer?.cornerRadius, AnnotationToolbarChrome.cornerRadius)
        XCTAssertGreaterThan(bar.frame.width, 0)
    }

    func testStickerBarOffersAllThreeTypes() {
        let bar = AnnotationContextBar(controls: [.stickerType, .stickerSize], color: .red, value: 40, stickerType: .redX)
        // Sticker buttons carry tags 10...12; the bar also has a delete button, which
        // does not, so filter to the sticker tags rather than counting every button.
        let stickerButtons = bar.subviews
            .compactMap { $0 as? HoverStateButton }
            .filter { (10...12).contains($0.tag) }
        XCTAssertEqual(stickerButtons.count, 3, "one button per sticker type")
    }

    /// Every selection's bar ends in a delete button, mirroring Backspace.
    func testEveryBarHasADeleteButton() {
        var fired = false
        let bar = AnnotationContextBar(controls: [.color, .thickness], color: .red, value: 4, stickerType: nil)
        bar.onDelete = { fired = true }
        let delete = bar.subviews
            .compactMap { $0 as? HoverStateButton }
            .first { $0.toolTip == "Delete" }
        XCTAssertNotNil(delete, "the bar must expose a delete button")
        delete?.performClick(nil)
        XCTAssertTrue(fired, "clicking delete must fire onDelete")
    }
}

/// End-to-end: selecting an element on the overlay must reveal its options, and
/// selecting must not disarm the tool the user has ready for the next mark.
final class AnnotationContextBarIntegrationTests: XCTestCase {

    private func overlayView() -> ScreenshotAnnotationView {
        ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), mode: .liveAnnotate)
    }

    private func rect(_ frame: NSRect) -> Annotation {
        Annotation(id: UUID(), type: .rectangle, frame: frame, color: .red, thickness: 4,
                   text: nil, fontSize: nil, startPoint: nil, endPoint: nil,
                   pathPoints: nil, stickerPointerDirection: nil)
    }

    private func contextBar(in view: NSView) -> AnnotationContextBar? {
        view.subviews.compactMap { $0 as? AnnotationContextBar }.first
    }

    func testSelectingAnAnnotationRevealsTheBarAndDeselectingHidesIt() {
        let view = overlayView()
        let a = rect(NSRect(x: 200, y: 200, width: 120, height: 80))
        view._setAnnotationsForTesting([a])
        XCTAssertNil(contextBar(in: view), "nothing selected, no bar")

        view._selectForTesting(a.id)
        XCTAssertNotNil(contextBar(in: view), "selecting must reveal the options bar")

        view.deselectForHost()
        XCTAssertNil(contextBar(in: view), "deselecting must remove it")
    }

    func testSelectingDoesNotDisarmTheTool() {
        let view = overlayView()
        let a = rect(NSRect(x: 200, y: 200, width: 120, height: 80))
        view._setAnnotationsForTesting([a])
        view.setArmedTool(.arrow)

        view._selectForTesting(a.id)

        XCTAssertEqual(view.armedTool, .arrow,
                       "clicking an existing element must not steal the armed tool")
    }

    func testTheBarLandsInsideTheCanvas() {
        let view = overlayView()
        let a = rect(NSRect(x: 20, y: 20, width: 40, height: 40))
        view._setAnnotationsForTesting([a])
        view._selectForTesting(a.id)

        guard let bar = contextBar(in: view) else { return XCTFail("no bar") }
        XCTAssertTrue(view.bounds.contains(bar.frame), "bar \(bar.frame) outside \(view.bounds)")
    }

    /// The screenshot editor must keep its old behaviour, where one toolbar serves both.
    func testScreenshotEditorStillGetsNoContextBar() {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                            mode: .staticImage(image))
        let a = rect(NSRect(x: 10, y: 10, width: 40, height: 40))
        view._setAnnotationsForTesting([a])
        view._selectForTesting(a.id)
        XCTAssertNil(contextBar(in: view), "the editor uses its own toolbar, not the context bar")
    }
}

/// Redaction on the live overlay. There is no source to re-sample at draw time — the
/// overlay is in the way — so pixels are baked once at placement and re-baked on move.
final class LiveRedactionTests: XCTestCase {

    private func solidImage(_ colour: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        colour.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func redaction(_ frame: NSRect) -> Annotation {
        Annotation(id: UUID(), type: .blur, frame: frame, color: .black, thickness: 1,
                   text: nil, fontSize: nil, startPoint: nil, endPoint: nil,
                   pathPoints: nil, stickerPointerDirection: nil)
    }

    func testRedactionGetsBakedWhenTheSourceArrives() {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                            mode: .liveAnnotate)
        let mark = redaction(NSRect(x: 20, y: 20, width: 80, height: 60))
        view._setAnnotationsForTesting([mark])
        XCTAssertNil(view._annotationsForTesting().first?.bakedMosaic, "nothing to bake from yet")

        view.redactionSource = solidImage(.systemBlue, size: NSSize(width: 400, height: 400))

        XCTAssertNotNil(view._annotationsForTesting().first?.bakedMosaic,
                        "the mark must bake once the desktop capture lands")
    }

    /// Carrying the image would show the pixels from where it was copied — wrong
    /// content, and a privacy bug, since redaction exists to hide those pixels.
    func testPasteDoesNotCarryTheBakedPixels() {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                            mode: .liveAnnotate)
        let mark = redaction(NSRect(x: 20, y: 20, width: 80, height: 60))
        view._setAnnotationsForTesting([mark])
        view.redactionSource = solidImage(.systemBlue, size: NSSize(width: 400, height: 400))
        view._selectForTesting(mark.id)

        view._copySelectedForTesting()
        XCTAssertTrue(view._pasteForTesting())

        let all = view._annotationsForTesting()
        XCTAssertEqual(all.count, 2)
        XCTAssertNil(all.last?.bakedMosaic,
                     "a pasted redaction must re-bake at its new position, not reuse the old pixels")
    }

    /// Undo/redo goes through a field-by-field copy, which silently drops new fields.
    func testBakedPixelsSurviveTheUndoSnapshot() {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                            mode: .liveAnnotate)
        let mark = redaction(NSRect(x: 20, y: 20, width: 80, height: 60))
        view._setAnnotationsForTesting([mark])
        view.redactionSource = solidImage(.systemBlue, size: NSSize(width: 400, height: 400))
        view._selectForTesting(mark.id)

        // A copy/paste pushes an undo snapshot of the pre-paste state.
        view._copySelectedForTesting()
        XCTAssertTrue(view._pasteForTesting())

        XCTAssertNotNil(view._annotationsForTesting().first?.bakedMosaic,
                        "the original's pixels must survive the snapshot copy")
    }

    func testRedactIsInTheContextBarWithNoControlsYet() {
        // Redact has no adjustable options in this pass; it must not crash or
        // produce an empty floating bar.
        XCTAssertTrue(AnnotationContextBar.Control.controls(for: .blur).isEmpty)
    }
}

/// Idle Annotate must show the marks and nothing else, and a freehand stroke's
/// options must reflect whether it is a rainbow stroke.
final class AnnotateChromeVisibilityTests: XCTestCase {

    private func overlay() -> ScreenshotAnnotationView {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                            mode: .liveAnnotate)
        view.installAnnotateChrome(tools: [.init(tool: .freehand, icon: "pencil.tip", title: "Freehand")])
        return view
    }

    private func strip(_ view: NSView) -> AnnotateToolStrip? {
        view.subviews.compactMap { $0 as? AnnotateToolStrip }.first
    }

    private func stroke(rainbow: Bool) -> Annotation {
        Annotation(id: UUID(), type: .freehand,
                   frame: NSRect(x: 100, y: 100, width: 100, height: 100),
                   color: .red, thickness: 4, text: nil, fontSize: nil,
                   startPoint: nil, endPoint: nil,
                   pathPoints: [NSPoint(x: 100, y: 100), NSPoint(x: 200, y: 200)],
                   stickerPointerDirection: nil, badgeNumber: nil,
                   colorMode: rainbow ? .rainbow : .solid)
    }

    func testStripIsHiddenWhenNothingIsArmedOrSelected() {
        let view = overlay()
        view.setArmedTool(nil)
        XCTAssertEqual(strip(view)?.isHidden, true,
                       "idle Annotate must not park a toolbar over the user's screen")
    }

    func testStripAppearsWhenAToolIsArmed() {
        let view = overlay()
        view.setArmedTool(.freehand)
        XCTAssertEqual(strip(view)?.isHidden, false)
    }

    func testStripAppearsWhenAnAnnotationIsSelected() {
        let view = overlay()
        view.setArmedTool(nil)
        let a = stroke(rainbow: false)
        view._setAnnotationsForTesting([a])
        view._selectForTesting(a.id)
        XCTAssertEqual(strip(view)?.isHidden, false,
                       "a selected layer counts as active chrome")
    }

    func testStripHidesAgainOnDeselect() {
        let view = overlay()
        view.setArmedTool(nil)
        let a = stroke(rainbow: false)
        view._setAnnotationsForTesting([a])
        view._selectForTesting(a.id)
        view.deselectForHost()
        XCTAssertEqual(strip(view)?.isHidden, true)
    }

    /// A hidden strip must not eat clicks that belong to the app underneath.
    func testHiddenStripIsNotInteractive() {
        let view = overlay()
        view.setArmedTool(nil)
        guard let s = strip(view) else { return XCTFail("no strip") }
        let insideStrip = NSPoint(x: s.frame.midX, y: s.frame.midY)
        XCTAssertFalse(view.isInteractive(atViewPoint: insideStrip),
                       "a hidden strip must pass clicks through")
    }

    // MARK: - Rainbow

    func testFreehandOffersARainbowToggle() {
        XCTAssertEqual(AnnotationContextBar.Control.controls(for: .freehand),
                       [.color, .rainbow, .thickness, .opacity])
    }

    /// Rainbow is a session-wide mode now, so every colourable tool offers the toggle.
    func testColourableToolsOfferRainbow() {
        for tool in [AnnotationTool.freehand, .rectangle, .circle, .arrow, .text, .numberBadge] {
            XCTAssertTrue(AnnotationContextBar.Control.controls(for: tool).contains(.rainbow),
                          "\(tool) should offer a rainbow toggle")
        }
    }

    /// Stickers colour themselves and redaction has no colour, so neither gets rainbow.
    func testStickerAndRedactDoNotOfferRainbow() {
        XCTAssertFalse(AnnotationContextBar.Control.controls(for: .sticker(.redX)).contains(.rainbow))
        XCTAssertFalse(AnnotationContextBar.Control.controls(for: .blur).contains(.rainbow))
    }

    func testRainbowStrokeBuildsABarMarkedAsRainbow() {
        let bar = AnnotationContextBar(controls: [.color, .rainbow, .thickness],
                                       color: .red, value: 4, stickerType: nil, isRainbow: true)
        let buttons = bar.subviews.compactMap { $0 as? HoverStateButton }
        XCTAssertGreaterThanOrEqual(buttons.count, 2, "colour well plus rainbow toggle")
    }

    func testRainbowSwatchIsNotASolidColour() {
        let swatch = AnnotationContextBar.rainbowSwatch(diameter: 14)
        XCTAssertEqual(swatch.size.width, 14)
        XCTAssertFalse(swatch.isTemplate, "a template image would be tinted flat, defeating the point")
    }

    /// Turning rainbow off must restore the annotation's real colour, not fall
    /// back to red — the well's tint is cleared while a rainbow swatch is shown.
    func testTurningRainbowOffRestoresTheSolidColour() {
        let bar = AnnotationContextBar(controls: [.color, .rainbow],
                                       color: .systemBlue, value: 4,
                                       stickerType: nil, isRainbow: true)
        // Simulate the toggle: call the same path updateColorSwatch uses after a pick,
        // then flip rainbow off via updateColorSwatch(isRainbow:).
        bar.updateColorSwatch(.systemBlue, isRainbow: false)
        let well = bar.subviews.compactMap { $0 as? HoverStateButton }.first
        XCTAssertEqual(well?.contentTintColor, .systemBlue,
                       "solid swatch must keep the annotation's colour, not default to red")
    }

    /// Deselected rainbow must clear its selected wash. Without hover-exit refresh
    /// the blue background used to stick until the next unrelated redraw.
    func testDeselectedRainbowButtonClearsSelectedBackground() {
        let bar = AnnotationContextBar(controls: [.color, .rainbow],
                                       color: .red, value: 4,
                                       stickerType: nil, isRainbow: true)
        let selected = NSColor.systemBlue.withAlphaComponent(0.3).cgColor
        XCTAssertEqual(bar._rainbowButtonBackgroundColorForTesting, selected)

        bar.updateColorSwatch(.red, isRainbow: false)
        let bg = bar._rainbowButtonBackgroundColorForTesting
        XCTAssertEqual(bg, NSColor.clear.cgColor,
                       "deselected rainbow must not keep a selected wash")
    }
}

/// Font-size (and badge/sticker size) changes grow the selection. Re-anchoring the
/// context bar on every slider tick moved the thumb out from under the cursor and
/// produced severe flicker — keep the bar pinned until mouse-up.
final class ContextBarSliderStabilityTests: XCTestCase {

    func testFontSizeSliderDoesNotMoveTheBarMidDrag() {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                            mode: .liveAnnotate)
        let a = Annotation(id: UUID(), type: .text,
                           frame: NSRect(x: 400, y: 400, width: 120, height: 40),
                           color: .red, thickness: 2, text: "Hello", fontSize: 24,
                           startPoint: nil, endPoint: nil, pathPoints: nil,
                           stickerPointerDirection: nil)
        view._setAnnotationsForTesting([a])
        view._selectForTesting(a.id)

        guard let originBefore = view._contextBarOriginForTesting() else {
            return XCTFail("no context bar")
        }
        // No currentEvent → treated as mid-drag (not leftMouseUp).
        view._applyContextBarSliderForTesting(.fontSize, value: 64)
        XCTAssertEqual(view._contextBarOriginForTesting(), originBefore,
                       "bar must stay put while the font-size slider is dragged")
    }
}

/// Colour panel must not outlive the selection / tool / Annotate session that opened it.
final class ColorPanelDismissTests: XCTestCase {

    override func tearDown() {
        NSColorPanel.shared.orderOut(nil)
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        super.tearDown()
    }

    func testDismissColorPanelHidesTheSharedPanel() {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                            mode: .liveAnnotate)
        let panel = NSColorPanel.shared
        panel.setTarget(view)
        panel.orderFront(nil)
        XCTAssertTrue(panel.isVisible)

        view.dismissColorPanel()
        XCTAssertFalse(panel.isVisible)
    }

    func testDeselectDismissesColorPanel() {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                            mode: .liveAnnotate)
        let a = Annotation(id: UUID(), type: .rectangle,
                           frame: NSRect(x: 200, y: 200, width: 80, height: 60),
                           color: .red, thickness: 4, text: nil, fontSize: nil,
                           startPoint: nil, endPoint: nil, pathPoints: nil,
                           stickerPointerDirection: nil)
        view._setAnnotationsForTesting([a])
        view._selectForTesting(a.id)

        let panel = NSColorPanel.shared
        panel.setTarget(view)
        panel.orderFront(nil)

        view.deselectForHost()
        XCTAssertFalse(panel.isVisible, "deselect must close the colour panel")
    }
}

/// The context bar floats away from the annotation it belongs to, so it needs its own
/// entry in the hit-test — otherwise the overlay goes pass-through under the pointer
/// and every control on the bar is dead.
final class ContextBarHitTestTests: XCTestCase {

    func testPointOverTheContextBarIsInteractive() {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                            mode: .liveAnnotate)
        let a = Annotation(id: UUID(), type: .rectangle,
                           frame: NSRect(x: 400, y: 400, width: 120, height: 80),
                           color: .red, thickness: 4, text: nil, fontSize: nil,
                           startPoint: nil, endPoint: nil, pathPoints: nil,
                           stickerPointerDirection: nil)
        view._setAnnotationsForTesting([a])
        view.setArmedTool(nil)
        view._selectForTesting(a.id)

        guard let bar = view.subviews.compactMap({ $0 as? AnnotationContextBar }).first else {
            return XCTFail("no context bar")
        }
        let onBar = NSPoint(x: bar.frame.midX, y: bar.frame.midY)
        XCTAssertTrue(view.isInteractive(atViewPoint: onBar),
                      "with no tool armed, the bar must still claim its own clicks")
    }
}
