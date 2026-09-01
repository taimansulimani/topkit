import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// The grid and the guides came out of the old standalone Guides overlay when Annotate
/// absorbed it. These cover what that move dropped: a rainbow grid whose surface stayed
/// solid, the typed pixel dimensions, and the defaults both tools are meant to start at.
final class GridAndGuideTests: XCTestCase {

    // MARK: - Helpers

    private func overlayView() -> ScreenshotAnnotationView {
        ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                 mode: .liveAnnotate)
    }

    private func grid(_ frame: NSRect, color: NSColor = .red, rainbow: Bool = false,
                      opacity: CGFloat = 1.0) -> Annotation {
        var a = Annotation(id: UUID(), type: .grid, frame: frame, color: color, thickness: 1,
                           text: nil, fontSize: nil, startPoint: nil, endPoint: nil,
                           pathPoints: nil, stickerPointerDirection: nil)
        a.colorMode = rainbow ? .rainbow : .solid
        a.opacity = opacity
        return a
    }

    /// Renders one mark into a white bitmap, set up in annotation space (Y down from the
    /// top edge) exactly as the view's draw does, so label placement is faithful.
    private func render(_ annotation: Annotation,
                        using ctx: AnnotationRenderer.Context,
                        size: Int = 200) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let cg = NSGraphicsContext.current!.cgContext
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat(size))
        cg.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(annotation, in: cg, using: ctx)
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    /// (r, g, b) at a pixel, row 0 being the top edge.
    private func channels(in image: NSImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
        let offset = y * cg.bytesPerRow + x * (cg.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    // MARK: - Rainbow reaches the fill, not just the border

    /// The regression: rainbow used to stroke the grid's perimeter while the surface
    /// stayed the solid base colour, so the toggle looked like it did almost nothing.
    func testRainbowGridPaintsItsSurfaceNotJustItsBorder() {
        let mark = grid(NSRect(x: 20, y: 20, width: 160, height: 160), color: .red, rainbow: true)
        let out = render(mark, using: AnnotationRenderer.Context())

        // Sample well inside the perimeter, along the gradient's axis. A red-based
        // rainbow must show at least one interior pixel where green or blue wins.
        let interior = [(40, 100), (70, 100), (100, 100), (130, 100), (160, 100)]
        let foundNonRed = interior.contains { pt in
            guard let c = channels(in: out, x: pt.0, y: pt.1) else { return false }
            return c.g > c.r + 20 || c.b > c.r + 20
        }
        XCTAssertTrue(foundNonRed, "a rainbow grid's fill must carry the gradient, not just its border")
    }

    /// The control: a solid grid still fills flat, so the fix did not make every grid
    /// a gradient.
    func testSolidGridStillFillsWithItsOwnColour() {
        let mark = grid(NSRect(x: 20, y: 20, width: 160, height: 160), color: .red)
        let out = render(mark, using: AnnotationRenderer.Context())

        for x in [40, 100, 160] {
            guard let c = channels(in: out, x: x, y: 100) else { return XCTFail("unreadable") }
            XCTAssertTrue(c.r > c.g + 40 && c.r > c.b + 40,
                          "solid grid should stay red at x=\(x), got \(c)")
        }
    }

    // MARK: - Dimension labels

    /// The readouts are an editing affordance, like a selection handle: on screen only.
    /// A grid burned into a saved screenshot must not carry "320" across its top edge.
    func testExportOmitsTheDimensionLabels() {
        XCTAssertFalse(AnnotationRenderer.Context.export.showsGridLabels,
                       "the export context must not draw grid labels")

        let mark = grid(NSRect(x: 20, y: 20, width: 160, height: 160), color: .yellow)
        let rects = AnnotationRenderer.gridLabelRects(for: mark.frame)

        let exported = render(mark, using: AnnotationRenderer.Context.export)
        let onScreen = render(mark, using: AnnotationRenderer.Context(showsGridLabels: true))

        // Count dark pixels across the label's row. The pill is near-black and the
        // yellow fill under it is bright, so a count beats a single probe — the centre
        // pixel lands on a white glyph and would read light either way.
        func darkPixels(in image: NSImage) -> Int {
            let y = Int(rects.width.midY)
            return stride(from: Int(rects.width.minX), to: Int(rects.width.maxX), by: 1)
                .compactMap { channels(in: image, x: $0, y: y) }
                .filter { $0.r < 100 && $0.g < 100 }
                .count
        }

        XCTAssertEqual(darkPixels(in: exported), 0,
                       "the exported image must carry no dimension label")
        XCTAssertGreaterThan(darkPixels(in: onScreen), 10,
                             "the on-screen canvas must show the label pill")
    }

    /// Labels stay reachable on a grid too small to hold them: they move outside rather
    /// than vanishing, or a small grid could never be resized by typing.
    func testLabelsMoveOutsideASmallGrid() {
        let small = NSRect(x: 100, y: 100, width: 12, height: 12)
        let rects = AnnotationRenderer.gridLabelRects(for: small)
        XCTAssertFalse(small.intersects(rects.width), "width label should sit above a small grid")
        XCTAssertFalse(small.intersects(rects.height), "height label should sit left of a small grid")

        let large = NSRect(x: 100, y: 100, width: 300, height: 200)
        let big = AnnotationRenderer.gridLabelRects(for: large)
        XCTAssertTrue(large.contains(big.width), "width label belongs inside a roomy grid")
        XCTAssertTrue(large.contains(big.height), "height label belongs inside a roomy grid")
    }

    // MARK: - Typing a dimension

    func testClickingAWidthLabelTypesANewWidth() {
        let view = overlayView()
        let mark = grid(NSRect(x: 40, y: 40, width: 200, height: 120))
        view._setAnnotationsForTesting([mark])

        let rects = AnnotationRenderer.gridLabelRects(for: mark.frame)
        XCTAssertEqual(view._gridLabelHitForTesting(at: NSPoint(x: rects.width.midX, y: rects.width.midY)),
                       .width, "the width readout should be hit-testable")

        view._beginGridSizeEditForTesting(mark.id, label: .width)
        XCTAssertTrue(view._isEditingGridSizeForTesting)
        view._commitGridSizeForTesting("320")

        let frame = view._annotationsForTesting().first!.frame
        XCTAssertEqual(frame.width, 320, "typed width should apply")
        XCTAssertEqual(frame.height, 120, "height should be untouched")
        XCTAssertEqual(frame.origin, NSPoint(x: 40, y: 40), "the grid should grow from its top-left")
    }

    func testClickingAHeightLabelTypesANewHeight() {
        let view = overlayView()
        let mark = grid(NSRect(x: 40, y: 40, width: 200, height: 120))
        view._setAnnotationsForTesting([mark])

        let rects = AnnotationRenderer.gridLabelRects(for: mark.frame)
        XCTAssertEqual(view._gridLabelHitForTesting(at: NSPoint(x: rects.height.midX, y: rects.height.midY)),
                       .height)

        view._beginGridSizeEditForTesting(mark.id, label: .height)
        view._commitGridSizeForTesting("64")

        let frame = view._annotationsForTesting().first!.frame
        XCTAssertEqual(frame.height, 64)
        XCTAssertEqual(frame.width, 200)
    }

    func testEscapeLeavesTheDimensionAlone() {
        let view = overlayView()
        let mark = grid(NSRect(x: 40, y: 40, width: 200, height: 120))
        view._setAnnotationsForTesting([mark])

        view._beginGridSizeEditForTesting(mark.id, label: .width)
        view._commitGridSizeForTesting("999", commit: false)

        XCTAssertEqual(view._annotationsForTesting().first!.frame.width, 200,
                       "cancelling must not resize")
        XCTAssertFalse(view._isEditingGridSizeForTesting, "the field should be gone")
    }

    /// Esc is grabbed by a global hot key during a live session, so the manager drives
    /// the cascade. An open dimension field must be the first thing it closes, ahead of
    /// the selection behind it and the session itself.
    func testEscapeClosesAnOpenDimensionFieldBeforeAnythingElse() {
        let view = overlayView()
        let mark = grid(NSRect(x: 40, y: 40, width: 200, height: 120))
        view._setAnnotationsForTesting([mark])
        view._selectForTesting(mark.id)

        XCTAssertFalse(view.cancelInlineEditForHost(),
                       "nothing to cancel while no field is open, so Esc falls through")

        view._beginGridSizeEditForTesting(mark.id, label: .width)
        XCTAssertTrue(view.cancelInlineEditForHost(), "the open field must absorb Esc")
        XCTAssertFalse(view._isEditingGridSizeForTesting)
        XCTAssertEqual(view._annotationsForTesting().first!.frame.width, 200,
                       "absorbing Esc must not resize")
        XCTAssertFalse(view.cancelInlineEditForHost(),
                       "a second Esc passes through to the rest of the cascade")
    }

    /// Junk input is discarded rather than collapsing the grid to nothing.
    func testNonNumericInputIsIgnored() {
        let view = overlayView()
        let mark = grid(NSRect(x: 40, y: 40, width: 200, height: 120))
        view._setAnnotationsForTesting([mark])

        for junk in ["", "abc", "0", "-40"] {
            view._beginGridSizeEditForTesting(mark.id, label: .width)
            view._commitGridSizeForTesting(junk)
            XCTAssertEqual(view._annotationsForTesting().first!.frame.width, 200,
                           "\"\(junk)\" should leave the width alone")
        }
    }

    /// A typed size larger than the canvas is clamped, matching what dragging can reach.
    func testTypedSizeIsClampedToTheCanvas() {
        let view = overlayView()
        let mark = grid(NSRect(x: 0, y: 0, width: 200, height: 120))
        view._setAnnotationsForTesting([mark])

        view._beginGridSizeEditForTesting(mark.id, label: .width)
        view._commitGridSizeForTesting("99999")

        XCTAssertEqual(view._annotationsForTesting().first!.frame.width, 400,
                       "width should clamp to the canvas")
    }

    /// Labels that sit outside a small grid used to miss `isInteractive`, so the
    /// overlay stayed click-through under the pointer and the field never focused.
    func testDimensionLabelsAreInteractiveEvenOutsideTheGridBody() {
        let view = overlayView()
        view.setArmedTool(nil)
        let mark = grid(NSRect(x: 100, y: 100, width: 12, height: 12))
        view._setAnnotationsForTesting([mark])

        let rects = AnnotationRenderer.gridLabelRects(for: mark.frame)
        XCTAssertFalse(mark.frame.intersects(rects.width))

        // Annotation space is top-anchored; view Y = height − annotation Y.
        let height = view.bounds.height
        let widthLabelView = NSPoint(x: rects.width.midX, y: height - rects.width.midY)
        XCTAssertTrue(view.isInteractive(atViewPoint: widthLabelView),
                      "a click on the external width label must be captured")

        view._beginGridSizeEditForTesting(mark.id, label: .width)
        XCTAssertTrue(view.isInteractive(atViewPoint: NSPoint(x: 1, y: 1)),
                      "an open dimension field must keep the overlay interactive")
        view._commitGridSizeForTesting("12", commit: false)
    }

    /// Focusing the field during setup used to fire `controlTextDidEndEditing` and
    /// tear the field down before any keystroke. The creation guard must keep it open.
    func testFocusShuffleDuringSetupDoesNotCommitTheDimensionField() {
        let view = overlayView()
        let mark = grid(NSRect(x: 40, y: 40, width: 200, height: 120))
        view._setAnnotationsForTesting([mark])

        view._beginGridSizeEditForTesting(mark.id, label: .width)
        XCTAssertTrue(view._isEditingGridSizeForTesting)

        // Simulate the premature end-editing notification that arrives while the
        // overlay is becoming key. The field must survive.
        NotificationCenter.default.post(
            name: NSControl.textDidEndEditingNotification,
            object: view._gridSizeFieldForTesting
        )
        XCTAssertTrue(view._isEditingGridSizeForTesting,
                      "end-editing during setup must not tear the field down")

        view._commitGridSizeForTesting("200", commit: false)
    }

    // MARK: - Defaults

    /// A guide marks an edge precisely, so it starts at the thinnest stroke the slider
    /// offers rather than inheriting the drawing tools' thickness.
    func testAGuideIsPlacedAsATranslucentHairline() {
        let view = overlayView()
        view.setArmedTool(.guide(.horizontal))
        view.handlePointerDown(at: NSPoint(x: 200, y: 200), clickCount: 1)

        guard let placed = view._annotationsForTesting().first else { return XCTFail("no guide placed") }
        XCTAssertEqual(placed.thickness,
                       AnnotationContextBar.range(for: .thickness).lowerBound,
                       "a guide should start at the minimum stroke")
        XCTAssertEqual(placed.opacity, alignmentAidDefaultOpacity, accuracy: 0.0001,
                       "a guide should start at the alignment-aid opacity")
    }

    func testAGridIsPlacedAtTheAlignmentAidOpacity() {
        let view = overlayView()
        view.setArmedTool(.grid)
        view.handlePointerDown(at: NSPoint(x: 60, y: 60), clickCount: 1)
        view.handlePointerDragged(at: NSPoint(x: 260, y: 200), modifierFlags: [])
        view.handlePointerUp()

        guard let placed = view._annotationsForTesting().first else { return XCTFail("no grid placed") }
        XCTAssertEqual(placed.opacity, alignmentAidDefaultOpacity, accuracy: 0.0001,
                       "a grid should start at the alignment-aid opacity")
    }

    /// Both alignment aids share one default, so they read as a set rather than two
    /// tools that happen to be translucent by different amounts.
    func testTheAlignmentAidOpacityIsSeventyPercent() {
        XCTAssertEqual(alignmentAidDefaultOpacity, 0.7, accuracy: 0.0001)
    }

    // MARK: - Guides span the visible canvas

    /// A guide is an infinite line clipped to the selection. Enlarging the hole must
    /// grow the guide with it — not leave a stub of the width it had when placed.
    func testGuideRespansWhenTheSelectionHoleGrows() {
        let view = ScreenshotAnnotationView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            mode: .liveRegion,
            screenshotRect: NSRect(x: 100, y: 100, width: 200, height: 150)
        )
        let original = NSRect(x: 100, y: 100, width: 200, height: 150)
        // Freeze the reference at the original hole, then place a short guide as if
        // it had been drawn before the enlarge (stored frame = original width).
        var mark = Annotation(
            id: UUID(), type: .guide(.horizontal),
            frame: NSRect(x: 0, y: 70, width: 200, height: 2),
            color: .red, thickness: 1,
            text: nil, fontSize: nil, startPoint: nil, endPoint: nil, pathPoints: nil
        )
        mark.opacity = alignmentAidDefaultOpacity
        view._setAnnotationsForTesting([mark])
        view._setSelectionRectForTesting(
            NSRect(x: 50, y: 50, width: 400, height: 300),
            freezeReferenceAt: original
        )

        guard let frame = view._effectiveFrameForTesting(of: mark.id) else {
            return XCTFail("missing effective frame")
        }
        XCTAssertEqual(frame.width, 400, accuracy: 0.5,
                       "guide must span the enlarged hole, not the original 200pt width")
        XCTAssertEqual(frame.midY, mark.frame.midY, accuracy: 0.5,
                       "perpendicular position must be preserved")
    }

    func testGuideFrameHelperSpansTheCanvas() {
        let stub = Annotation(
            id: UUID(), type: .guide(.vertical),
            frame: NSRect(x: 40, y: 0, width: 2, height: 100),
            color: .red, thickness: 1,
            text: nil, fontSize: nil, startPoint: nil, endPoint: nil, pathPoints: nil
        )
        let spanned = AnnotationRenderer.guideFrame(
            for: stub, orientation: .vertical,
            spanning: NSRect(x: -10, y: -20, width: 500, height: 400)
        )
        XCTAssertEqual(spanned.height, 400)
        XCTAssertEqual(spanned.midX, 41, accuracy: 0.5)
        XCTAssertEqual(spanned.minY, -20, accuracy: 0.5)
    }
}
