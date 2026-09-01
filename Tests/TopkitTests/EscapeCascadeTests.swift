import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Esc while recording must dismiss overlay tools before stopping the capture —
/// **most recently opened tool first** (LIFO), not a fixed priority list.
final class EscapeCascadeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EscapeCascade._resetForTesting()
    }

    override func tearDown() {
        AnnotateManager.shared.stop()
        HaloManager.shared.stopHalo()
        _ = ColorPickerManager.shared.consumeEscape()
        _ = MagnifyingGlassManager.shared.consumeEscape()
        EscapeCascade._resetForTesting()
        super.tearDown()
    }

    func testConsumeIsANoOpWhenNothingIsLive() {
        XCTAssertFalse(EscapeCascade.consume(),
                       "with no overlay tools, Esc must fall through to the recording stop path")
    }

    func testAnnotateConsumeEscapeReturnsFalseWhenInactive() {
        XCTAssertFalse(AnnotateManager.shared.isActive)
        XCTAssertFalse(AnnotateManager.shared.consumeEscape())
    }

    func testHaloConsumeEscapeReturnsFalseWhenInactive() {
        XCTAssertFalse(HaloManager.shared.consumeEscape(),
                       "inactive Halo must not claim Esc")
    }

    /// Annotate's internal cascade: selection first, then disarm, then end.
    func testAnnotateEscapeDeselectsBeforeEnding() {
        _ = NSApplication.shared
        let manager = AnnotateManager.shared
        manager.start(tool: .freehand)
        XCTAssertTrue(manager.isActive)

        let view = manager.overlayViews[0]
        let mark = Annotation(id: UUID(), type: .rectangle,
                              frame: NSRect(x: 40, y: 40, width: 80, height: 50),
                              color: .red, thickness: 3, text: nil, fontSize: nil,
                              startPoint: nil, endPoint: nil, pathPoints: nil,
                              stickerPointerDirection: nil)
        view._setAnnotationsForTesting([mark])
        view._selectForTesting(mark.id)
        manager.arm(nil)

        XCTAssertTrue(manager.consumeEscape(), "first Esc deselects")
        XCTAssertTrue(manager.isActive, "session must still be live after deselect")
        XCTAssertFalse(view.deselectForHost(), "nothing left to deselect")

        XCTAssertTrue(manager.consumeEscape(), "second Esc ends the idle session")
        XCTAssertFalse(manager.isActive)
    }

    func testAnnotateEscapeDisarmsBeforeEnding() {
        _ = NSApplication.shared
        let manager = AnnotateManager.shared
        manager.start(tool: .freehand)
        XCTAssertEqual(manager.armedTool, .freehand)

        XCTAssertTrue(manager.consumeEscape())
        XCTAssertTrue(manager.isActive)
        XCTAssertNil(manager.armedTool, "first Esc with a tool armed only disarms")

        XCTAssertTrue(manager.consumeEscape())
        XCTAssertFalse(manager.isActive)
    }

    /// The reported bug: Annotate live → open Halo → Esc must close Halo, not
    /// clear the drawings underneath.
    func testMostRecentlyOpenedToolReceivesEscapeFirst() {
        _ = NSApplication.shared
        let annotate = AnnotateManager.shared
        annotate.start(tool: .freehand)
        annotate.arm(nil)
        XCTAssertEqual(EscapeCascade._stackForTesting, [.annotate])

        // Halo on top of Annotate — same order as the user's recording scenario.
        HaloManager.shared.startHalo()
        XCTAssertEqual(EscapeCascade._stackForTesting, [.annotate, .halo])
        XCTAssertTrue(HaloManager.shared.isHaloActive)
        XCTAssertTrue(annotate.isActive)

        XCTAssertTrue(EscapeCascade.consume(), "Esc must be consumed by Halo")
        XCTAssertFalse(HaloManager.shared.isHaloActive, "Halo was opened last, so it closes first")
        XCTAssertTrue(annotate.isActive, "Annotate / drawings must survive until a later Esc")
        XCTAssertEqual(EscapeCascade._stackForTesting, [.annotate])
    }

    func testReopeningAToolMovesItToTheTopOfTheStack() {
        _ = NSApplication.shared
        HaloManager.shared.startHalo()
        AnnotateManager.shared.start(tool: .rectangle)
        XCTAssertEqual(EscapeCascade._stackForTesting, [.halo, .annotate])

        // Ending and restarting Halo makes it the newest Esc target again.
        HaloManager.shared.stopHalo()
        HaloManager.shared.startHalo()
        XCTAssertEqual(EscapeCascade._stackForTesting, [.annotate, .halo])
    }
}
