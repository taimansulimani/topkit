import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// The screenshot editor's slider row carries its own colour / rainbow / opacity
/// cluster, separate from the Annotate overlay's context bar. These lock in the order
/// the cluster reads in, and the chrome refresh the row's buttons were missing.
final class EditorSliderRowTests: XCTestCase {

    /// The toolbar and slider row are built on attach to a window, not at init, so the
    /// window has to be kept alive for the row to exist.
    private var window: NSWindow?

    private func editorView() -> ScreenshotAnnotationView {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let view = ScreenshotAnnotationView(
            frame: frame,
            screenshot: nil,
            screenshotRect: NSRect(x: 200, y: 200, width: 600, height: 400)
        )
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        self.window = window
        return view
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func hoverEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        )!
    }

    /// Colour, then rainbow, then opacity: pick a colour, decide whether it is a
    /// gradient, then set how strong it is.
    func testTheRightClusterReadsColourThenRainbowThenOpacity() {
        let view = editorView()
        guard let colour = view._editorColorButtonForTesting,
              let rainbow = view._editorRainbowButtonForTesting,
              let opacity = view._editorOpacityButtonForTesting else {
            return XCTFail("slider row cluster not built")
        }

        XCTAssertLessThan(colour.frame.minX, rainbow.frame.minX,
                          "colour well belongs left of the rainbow toggle")
        XCTAssertLessThan(rainbow.frame.minX, opacity.frame.minX,
                          "rainbow toggle belongs left of the opacity dropdown")
    }

    func testTheClusterSitsRightOfTheSizeSlider() {
        let view = editorView()
        guard let colour = view._editorColorButtonForTesting,
              let slider = view._editorSliderRowForTesting?.subviews.compactMap({ $0 as? NSSlider }).first else {
            return XCTFail("slider row not built")
        }
        XCTAssertLessThan(slider.frame.maxX, colour.frame.minX,
                          "the size slider comes before the cluster")
    }

    /// The regression: these buttons live in the slider row, not the toolbar, so the
    /// toolbar's refresh never repainted them. A hover wash therefore outlived the
    /// pointer and left a switched-off rainbow toggle looking switched on.
    func testDeselectingRainbowClearsItsBackgroundOnceThePointerLeaves() {
        let view = editorView()
        guard let rainbow = view._editorRainbowButtonForTesting as? HoverStateButton else {
            return XCTFail("no rainbow toggle")
        }

        // Drive to a known off state first (default is mono; toggle if somehow on).
        if view._isRainbowModeForTesting { rainbow.performClick(nil) }
        XCTAssertFalse(view._isRainbowModeForTesting)

        // On, with the pointer resting on the button.
        rainbow.performClick(nil)
        rainbow.mouseEntered(with: hoverEvent(.mouseEntered))
        XCTAssertTrue(view._isRainbowModeForTesting, "click should arm rainbow")

        // Off, still hovered, then the pointer leaves.
        rainbow.performClick(nil)
        XCTAssertFalse(view._isRainbowModeForTesting, "click should disarm rainbow")
        rainbow.mouseExited(with: hoverEvent(.mouseExited))

        let background = rainbow.layer?.backgroundColor
        let clear = NSColor.clear.cgColor
        XCTAssertEqual(background?.alpha ?? 0, clear.alpha, accuracy: 0.001,
                       "a deselected rainbow toggle must not keep a blue wash")
    }

    /// The other half of the same contract: while rainbow is on, the toggle stays lit
    /// even after the pointer moves away.
    func testSelectedRainbowStaysLitWithoutHover() {
        let view = editorView()
        guard let rainbow = view._editorRainbowButtonForTesting as? HoverStateButton else {
            return XCTFail("no rainbow toggle")
        }

        if !view._isRainbowModeForTesting { rainbow.performClick(nil) }
        rainbow.mouseEntered(with: hoverEvent(.mouseEntered))
        rainbow.mouseExited(with: hoverEvent(.mouseExited))

        XCTAssertTrue(view._isRainbowModeForTesting)
        XCTAssertGreaterThan(rainbow.layer?.backgroundColor?.alpha ?? 0, 0.2,
                             "an armed rainbow toggle must stay lit")
    }
}
