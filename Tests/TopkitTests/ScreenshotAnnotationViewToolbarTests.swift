import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Regression: when the live-hole annotation view is detached from a window and
/// re-attached (which the multi-monitor screen-swap used to do), `setupToolbar()`
/// was being called a second time without tearing down the prior toolbar
/// subviews. The old toolbar stayed in the view hierarchy at its last position
/// and appeared as a "printed" ghost toolbar on the other monitor. Lock the
/// invariant down: regardless of how many times the view is re-parented, there
/// must be exactly one toolbar subview.
final class ScreenshotAnnotationViewToolbarTests: XCTestCase {
    // Identified by identifier, not geometry: the Annotate overlay's tool strip is
    // deliberately styled identically to this toolbar, so corner radius and height no
    // longer distinguish them.
    private func toolbarCandidateCount(in view: NSView) -> Int {
        view.subviews.filter { $0.identifier == AnnotationToolbarChrome.Identifier.editorToolbar }.count
    }

    private func sliderContainerCount(in view: NSView) -> Int {
        view.subviews.filter { $0.identifier == AnnotationToolbarChrome.Identifier.editorSliderRow }.count
    }

    func testToolbarIsNotDuplicatedWhenViewIsReattachedToWindow() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let view = ScreenshotAnnotationView(
            frame: screenFrame,
            screenshot: nil,
            screenshotRect: NSRect(x: 200, y: 200, width: 400, height: 300)
        )

        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        XCTAssertEqual(toolbarCandidateCount(in: view), 1, "Initial attach should create exactly one toolbar")
        XCTAssertEqual(sliderContainerCount(in: view), 1, "Initial attach should create exactly one slider row")

        // Simulate what the old screen-swap code did: detach the view from the
        // window, then re-attach it. This used to build a second orphan toolbar.
        view.removeFromSuperview()
        window.contentView = view

        XCTAssertEqual(toolbarCandidateCount(in: view), 1, "Re-attach must not leave an orphan toolbar subview")
        XCTAssertEqual(sliderContainerCount(in: view), 1, "Re-attach must not leave an orphan slider subview")

        // And again, to be sure.
        view.removeFromSuperview()
        window.contentView = view
        XCTAssertEqual(toolbarCandidateCount(in: view), 1)
        XCTAssertEqual(sliderContainerCount(in: view), 1)
    }

    func testRelocateForScreenSwapKeepsSingleToolbarAndUpdatesPosition() {
        let screenAFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let screenBFrame = NSRect(x: 1920, y: 0, width: 2560, height: 1440)
        let combined = NSRect(x: 0, y: 0, width: 4480, height: 1440)

        let view = ScreenshotAnnotationView(
            frame: screenAFrame,
            screenshot: nil,
            screenshotRect: NSRect(x: 100, y: 100, width: 500, height: 400)
        )
        view.allowedSelectionBounds = combined

        let window = NSWindow(
            contentRect: screenAFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        XCTAssertEqual(toolbarCandidateCount(in: view), 1)

        // Simulate a swap to screen B (the *right* monitor). The window moves
        // first, then the view is asked to relocate; we must still end up with
        // exactly one toolbar (no ghost).
        window.setFrame(screenBFrame, display: false)
        let newAllowed = NSRect(
            x: combined.origin.x - screenBFrame.origin.x,
            y: combined.origin.y - screenBFrame.origin.y,
            width: combined.width,
            height: combined.height
        )
        view.relocateForScreenSwap(
            newScreenshotRect: NSRect(x: 200, y: 200, width: 500, height: 400),
            newScreenOrigin: screenBFrame.origin,
            newAllowedBounds: newAllowed
        )

        XCTAssertEqual(toolbarCandidateCount(in: view), 1, "Screen swap must leave exactly one toolbar")
        XCTAssertEqual(sliderContainerCount(in: view), 1, "Screen swap must leave exactly one slider")
        XCTAssertEqual(view.frame.size, screenBFrame.size, "View should resize to new screen size")
    }
}
