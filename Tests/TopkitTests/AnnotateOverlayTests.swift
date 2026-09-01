import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Phase 2 of the live Annotate overlay: `.liveAnnotate` canvas mode.
///
/// The load-bearing claim is that setting `screenshotRect = bounds` neutralises the
/// screenshot editor's "click must land inside the screenshot" gates, so the whole
/// screen becomes the canvas. These lock that in, plus the invariant that keeps it
/// true after a resize.
final class AnnotateOverlayTests: XCTestCase {

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private func annotateView() -> ScreenshotAnnotationView {
        ScreenshotAnnotationView(frame: screen, mode: .liveAnnotate)
    }

    // MARK: - Mode

    func testAnnotateModeReportsItself() {
        XCTAssertTrue(annotateView().isAnnotateMode)
    }

    func testScreenshotEditorAndRegionModesAreNotAnnotateMode() {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        XCTAssertFalse(ScreenshotAnnotationView(frame: screen, mode: .staticImage(image)).isAnnotateMode)
        XCTAssertFalse(ScreenshotAnnotationView(frame: screen, mode: .liveRegion).isAnnotateMode)
    }

    /// The screenshot flow's convenience init must keep mapping the old way round.
    func testConvenienceInitStillMapsImageToStaticAndNilToRegion() {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        XCTAssertFalse(ScreenshotAnnotationView(frame: screen, screenshot: image).isAnnotateMode)
        XCTAssertFalse(ScreenshotAnnotationView(frame: screen, screenshot: nil).isAnnotateMode)
    }

    // MARK: - The screenshotRect == bounds invariant

    /// Annotation space is top-left anchored and flips about `screenshotRect.maxY`.
    /// If bounds moves and screenshotRect does not, that flip origin goes stale and
    /// every mark and hit-test is displaced by the height delta.
    ///
    /// The invariant is that an annotation stays at a fixed offset from the TOP of the
    /// screen, so its view-space Y tracks the new height. That is what is asserted
    /// here: the mapped point still hits, and the stale point does not.
    func testResizeKeepsAnnotationSpacePinnedToBounds() {
        let view = annotateView()
        let placed = NSRect(x: 100, y: 100, width: 80, height: 40)
        view._setAnnotationsForTesting([makeRect(frame: placed)])
        view.setArmedTool(nil)

        // Annotation-space y 120 sits 120 down from the top, so view y = height - 120.
        let centreOfAnnotation = { (height: CGFloat) in NSPoint(x: 140, y: height - 120) }
        XCTAssertTrue(view.isInteractive(atViewPoint: centreOfAnnotation(900)),
                      "Sanity: the annotation hit-tests before the resize")

        let stalePoint = centreOfAnnotation(900)
        view.setFrameSize(NSSize(width: 1920, height: 1080))

        XCTAssertEqual(view._annotationsForTesting().first?.frame, placed,
                       "A resize must not rewrite stored annotation frames")
        XCTAssertTrue(view.isInteractive(atViewPoint: centreOfAnnotation(1080)),
                      "The annotation must still hit-test at its top-anchored position")
        XCTAssertFalse(view.isInteractive(atViewPoint: stalePoint),
                       "The pre-resize view point must no longer hit — annotations are anchored to the top, not the bottom")
    }

    // MARK: - Click-through predicate

    func testEmptyCanvasWithNoToolArmedIsNotInteractive() {
        let view = annotateView()
        view.setArmedTool(nil)
        XCTAssertFalse(view.isInteractive(atViewPoint: NSPoint(x: 700, y: 400)),
                       "With nothing armed and nothing under the cursor, clicks belong to the app underneath")
    }

    func testArmedToolCapturesEverywhere() {
        let view = annotateView()
        view.setArmedTool(.freehand)
        XCTAssertTrue(view.isInteractive(atViewPoint: NSPoint(x: 700, y: 400)),
                      "An armed tool must capture, or a mark could never be started")
    }

    func testPointOverAnAnnotationIsInteractive() {
        let view = annotateView()
        view.setArmedTool(nil)
        view._setAnnotationsForTesting([makeRect(frame: NSRect(x: 200, y: 200, width: 100, height: 100))])
        XCTAssertTrue(view.isInteractive(atViewPoint: NSPoint(x: 250, y: 650)))
    }

    // MARK: - Host-owned model

    /// The manager owns the list so a hotplug-driven view rebuild does not wipe it.
    func testAnnotationsRoundTripThroughTheHostProperty() {
        let view = annotateView()
        let annotations = [
            makeRect(frame: NSRect(x: 10, y: 10, width: 20, height: 20)),
            makeRect(frame: NSRect(x: 50, y: 50, width: 20, height: 20)),
        ]
        view.annotationsForHost = annotations
        XCTAssertEqual(view.annotationsForHost.count, 2)
        XCTAssertEqual(view.annotationsForHost.map(\.frame), annotations.map(\.frame))
    }

    // MARK: - Arming

    func testArmedToolIsReadableBack() {
        let view = annotateView()
        view.setArmedTool(.freehand)
        XCTAssertEqual(view.armedTool, .freehand)
        view.setArmedTool(nil)
        XCTAssertNil(view.armedTool)
    }

    // MARK: - Helpers

    private func makeRect(frame: NSRect) -> Annotation {
        Annotation(
            id: UUID(),
            type: .rectangle,
            frame: frame,
            color: .red,
            thickness: 4,
            text: nil,
            fontSize: nil,
            startPoint: nil,
            endPoint: nil,
            pathPoints: nil,
            stickerPointerDirection: nil
        )
    }
}

/// The rainbow brush carried over from the Draw tool. It is captured per stroke now
/// rather than resolved from the preference at render time, so it must survive every
/// path that copies an Annotation — all of which are field-by-field memberwise inits
/// that silently drop a defaulted field.
final class AnnotationColorModeTests: XCTestCase {

    private func rainbowStroke() -> Annotation {
        Annotation(
            id: UUID(),
            type: .freehand,
            frame: NSRect(x: 0, y: 0, width: 100, height: 100),
            color: .red,
            thickness: 4,
            text: nil,
            fontSize: nil,
            startPoint: nil,
            endPoint: nil,
            pathPoints: [NSPoint(x: 0, y: 0), NSPoint(x: 100, y: 100)],
            stickerPointerDirection: nil,
            badgeNumber: nil,
            colorMode: .rainbow
        )
    }

    /// Every existing construction site omits colorMode, so the default must be solid
    /// or the screenshot editor's marks would all turn into rainbows.
    func testAnnotationsBuiltWithoutAColorModeDefaultToSolid() {
        let a = Annotation(
            id: UUID(),
            type: .rectangle,
            frame: NSRect(x: 0, y: 0, width: 10, height: 10),
            color: .red,
            thickness: 2,
            text: nil,
            fontSize: nil,
            startPoint: nil,
            endPoint: nil,
            pathPoints: nil,
            stickerPointerDirection: nil
        )
        XCTAssertEqual(a.colorMode, .solid)
    }

    func testRainbowSurvivesUndoSnapshotAndCopyPaste() {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                            mode: .liveAnnotate)
        let stroke = rainbowStroke()
        view._setAnnotationsForTesting([stroke])
        view._selectForTesting(stroke.id)

        view._copySelectedForTesting()
        XCTAssertTrue(view._pasteForTesting(), "Paste should succeed")

        let modes = view._annotationsForTesting().map(\.colorMode)
        XCTAssertEqual(modes, [.rainbow, .rainbow],
                       "A pasted rainbow stroke must stay rainbow — the copy paths are memberwise and drop defaulted fields")
    }

    func testRainbowColourCyclesAcrossTheStroke() {
        let start = AnnotationRenderer.rainbowColor(at: 0)
        let quarter = AnnotationRenderer.rainbowColor(at: 0.25)
        XCTAssertNotEqual(start.redComponent, quarter.redComponent, accuracy: 0.0,
                          "Hue must advance along the stroke")
        // Full cycle returns to the start.
        let full = AnnotationRenderer.rainbowColor(at: 1.0)
        XCTAssertEqual(start.redComponent, full.redComponent, accuracy: 0.001)
        XCTAssertEqual(start.greenComponent, full.greenComponent, accuracy: 0.001)
        XCTAssertEqual(start.blueComponent, full.blueComponent, accuracy: 0.001)
    }
}

/// The Annotate submenu, its shortcuts, and the strip must stay in step: adding a
/// tool in one place and forgetting the others is the obvious failure mode here.
final class AnnotateToolCoverageTests: XCTestCase {

    private static let expectedTools: [AnnotationTool] = [
        .freehand, .rectangle, .circle, .arrow, .text, .blur, .sticker(.redX), .numberBadge,
        .measure, .guide(.vertical), .guide(.horizontal), .grid
    ]

    func testEveryMenuTitleMapsBackToATool() {
        let titles = [
            "Freehand", "Rectangle", "Circle", "Arrow", "Text", "Redact", "Sticker",
            "Numbered Badge", "Measure", "Vertical Guide", "Horizontal Guide", "Grid"
        ]
        let mapped = titles.compactMap { AppDelegate.annotateTool(forMenuTitle: $0) }
        XCTAssertEqual(mapped.count, titles.count, "every submenu title must resolve to a tool")
        XCTAssertEqual(mapped, Self.expectedTools, "and in the editor toolbar's order")
    }

    func testUnknownMenuTitleMapsToNil() {
        XCTAssertNil(AppDelegate.annotateTool(forMenuTitle: "End Annotate"))

    }

    /// The strip is built from the manager's list; if a tool is in the menu but not
    /// the strip the user can arm it and then have no way to see it is armed.
    func testStripCarriesEveryMenuTool() {
        _ = NSApplication.shared
        AnnotateManager.shared.start(tool: .freehand)
        defer { AnnotateManager.shared.stop() }

        guard let view = AnnotateManager.shared.overlayViews.first,
            let strip = view.subviews.first(where: { $0 is AnnotateToolStrip }) as? AnnotateToolStrip else {
            return XCTFail("no tool strip")
        }
        // tool buttons + divider + exit
        let buttons = strip.subviews.compactMap { $0 as? HoverStateButton }
        XCTAssertEqual(buttons.count, Self.expectedTools.count + 1,
                       "one button per tool plus the exit button")
    }

    /// The session outlives its armed tool so guides can sit over other apps. Delete
    /// the last one and there is nothing left to keep the overlay alive.
    func testDeletingTheLastAnnotationEndsAnIdleSession() {
        _ = NSApplication.shared
        let manager = AnnotateManager.shared
        manager.start(tool: .guide(.vertical))
        defer { manager.stop() }

        guard let view = manager.overlayViews.first else { return XCTFail("no overlay") }
        let guideMark = Self.makeMark()
        view._setAnnotationsForTesting([guideMark])
        view._selectForTesting(guideMark.id)
        manager.arm(nil)
        XCTAssertTrue(manager.isActive, "a guide on screen keeps the session alive with no tool armed")

        view._deleteSelectedForTesting()
        waitForAnnotateToEnd(manager)
        XCTAssertFalse(manager.isActive, "the last annotation going away ends the session")
    }

    /// Undoing the only mark while a tool is still armed is mid-work, not an exit.
    func testDeletingTheLastAnnotationKeepsAnArmedSessionAlive() {
        _ = NSApplication.shared
        let manager = AnnotateManager.shared
        manager.start(tool: .rectangle)
        defer { manager.stop() }

        guard let view = manager.overlayViews.first else { return XCTFail("no overlay") }
        let mark = Self.makeMark()
        view._setAnnotationsForTesting([mark])
        view._selectForTesting(mark.id)

        view._deleteSelectedForTesting()
        waitForAnnotateToEnd(manager, timeout: 0.3)
        XCTAssertTrue(manager.isActive, "a live tool must survive deleting the last mark")
    }

    private static func makeMark() -> Annotation {
        Annotation(id: UUID(), type: .rectangle,
                   frame: NSRect(x: 40, y: 40, width: 80, height: 50),
                   color: .red, thickness: 3, text: nil, fontSize: nil,
                   startPoint: nil, endPoint: nil, pathPoints: nil,
                   stickerPointerDirection: nil)
    }

    /// The auto-end hop is async (it fires from inside a view mutation that `stop()`
    /// would tear down), so spin until it lands rather than asserting immediately.
    private func waitForAnnotateToEnd(_ manager: AnnotateManager, timeout: TimeInterval = 1) {
        let deadline = Date().addingTimeInterval(timeout)
        while manager.isActive && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    func testArmingEachToolRoundTripsThroughTheManager() {
        _ = NSApplication.shared
        let manager = AnnotateManager.shared
        manager.start(tool: .freehand)
        defer { manager.stop() }

        for tool in Self.expectedTools {
            manager.arm(tool)
            XCTAssertEqual(manager.armedTool, tool)
            let views = manager.overlayViews
            for v in views {
                XCTAssertEqual(v.armedTool, tool, "every screen must follow the armed tool")
            }
        }
    }
}
