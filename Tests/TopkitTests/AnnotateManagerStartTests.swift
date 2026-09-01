import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Exercises the real start path. If pressing the shortcut appears to do nothing,
/// the failure is either here or in what the overlay draws.
final class AnnotateManagerStartTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // start() reaches for NSApp.delegate; without a real NSApplication instance
        // NSApp is nil and the implicit unwrap traps. The app always has one.
        _ = NSApplication.shared
    }

    override func tearDown() {
        AnnotateManager.shared.stop()
        super.tearDown()
    }

    func testStartBuildsOneVisibleOverlayPerScreenAndArmsTheTool() {
        let manager = AnnotateManager.shared
        XCTAssertFalse(manager.isActive)

        manager.start(tool: .freehand)

        XCTAssertTrue(manager.isActive, "start() must mark the session active")
        XCTAssertEqual(manager.armedTool, .freehand, "the requested tool must be armed")

        let windows = manager.overlayWindows
        XCTAssertEqual(windows.count, NSScreen.screens.count,
                       "one overlay window per screen")
        for w in windows {
            XCTAssertTrue(w.isVisible, "overlay window must be on screen")
            XCTAssertFalse(w.ignoresMouseEvents,
                           "with a tool armed the overlay must capture clicks")
            XCTAssertNotNil(w.contentView as? ScreenshotAnnotationView)
            let view = w.contentView as! ScreenshotAnnotationView
            XCTAssertTrue(view.isAnnotateMode)
            XCTAssertEqual(view.armedTool, .freehand)
            XCTAssertFalse(view.subviews.isEmpty,
                           "the tool strip must be installed as a subview")
        }
    }

    func testStopTearsEverythingDown() {
        let manager = AnnotateManager.shared
        manager.start(tool: .freehand)
        manager.stop()
        XCTAssertFalse(manager.isActive)
        XCTAssertTrue(manager.overlayWindows.isEmpty, "no overlay may survive stop()")
    }
}

extension AnnotateManagerStartTests {
    /// If the strip is off-screen the whole mode looks like nothing happened.
    func testToolStripIsOnScreenAndNonEmpty() {
        _ = NSApplication.shared
        AnnotateManager.shared.start(tool: .freehand)
        defer { AnnotateManager.shared.stop() }

        let views = AnnotateManager.shared.overlayViews
        XCTAssertFalse(views.isEmpty)
        for view in views {
            guard let strip = view.subviews.first(where: { $0 is AnnotateToolStrip }) else {
                XCTFail("no tool strip in the overlay"); continue
            }
            XCTAssertGreaterThan(strip.frame.width, 0)
            XCTAssertGreaterThan(strip.frame.height, 0)
            XCTAssertTrue(view.bounds.contains(strip.frame),
                          "strip \(strip.frame) must lie inside the canvas \(view.bounds)")
            XCTAssertFalse(strip.isHidden)
            XCTAssertEqual(strip.alphaValue, 1.0, accuracy: 0.001)
        }
    }
}
