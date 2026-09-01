import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// The Annotate tool strip must look exactly like the screenshot editor's toolbar.
/// Both go through AnnotationToolbarChrome; these lock that in so a change to one
/// surface cannot silently diverge from the other.
final class AnnotationToolbarChromeTests: XCTestCase {

    private func container(dark: Bool) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: AnnotationToolbarChrome.height))
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        AnnotationToolbarChrome.applyContainerChrome(v)
        return v
    }

    func testStripUsesTheSameMetricsAsTheEditorToolbar() {
        let strip = AnnotateToolStrip(items: [.init(tool: .freehand, icon: "pencil.tip", title: "Freehand")])
        XCTAssertEqual(strip.frame.height, AnnotationToolbarChrome.height,
                       "strip height must match the editor toolbar")
        XCTAssertEqual(strip.layer?.cornerRadius, AnnotationToolbarChrome.cornerRadius)
    }

    func testStripButtonsMatchEditorButtonMetrics() {
        let strip = AnnotateToolStrip(items: [.init(tool: .freehand, icon: "pencil.tip", title: "Freehand")])
        let buttons = strip.subviews.compactMap { $0 as? HoverStateButton }
        XCTAssertFalse(buttons.isEmpty)
        for b in buttons {
            XCTAssertEqual(b.frame.width, AnnotationToolbarChrome.buttonSize)
            XCTAssertEqual(b.frame.height, AnnotationToolbarChrome.buttonSize)
            XCTAssertEqual(b.layer?.cornerRadius, AnnotationToolbarChrome.buttonCornerRadius)
            XCTAssertFalse(b.isBordered)
        }
    }

    /// Light and dark must produce different chrome, and dark must be borderless
    /// while light carries the hairline border — the editor toolbar's exact rule.
    func testContainerChromeIsThemeAware() {
        let light = container(dark: false)
        let dark = container(dark: true)
        XCTAssertNotEqual(light.layer?.backgroundColor, dark.layer?.backgroundColor,
                          "light and dark must not render the same background")
        XCTAssertEqual(dark.layer?.borderWidth, 0, "dark chrome is borderless")
        XCTAssertEqual(light.layer?.borderWidth, 0.5, "light chrome carries a hairline border")
        XCTAssertNotNil(light.layer?.borderColor)
    }

    func testArmedButtonGetsTheSelectedBackgroundAndDisarmedDoesNot() {
        let strip = AnnotateToolStrip(items: [.init(tool: .freehand, icon: "pencil.tip", title: "Freehand")])
        let button = strip.subviews.compactMap { $0 as? HoverStateButton }.first!

        strip.setArmed(.freehand)
        let armedBackground = button.layer?.backgroundColor

        strip.setArmed(nil)
        let disarmedBackground = button.layer?.backgroundColor

        XCTAssertNotEqual(armedBackground, disarmedBackground,
                          "the armed tool must be visually distinct")
        XCTAssertEqual(disarmedBackground, NSColor.clear.cgColor)
    }

    func testStripAndEditorToolbarAreIndistinguishableByGeometry() {
        // Precisely why the tests now identify toolbars by identifier.
        let strip = AnnotateToolStrip(items: [.init(tool: .freehand, icon: "pencil.tip", title: "Freehand")])
        XCTAssertEqual(strip.frame.height, 36)
        XCTAssertEqual(strip.layer?.cornerRadius, 5)
        XCTAssertEqual(strip.identifier, AnnotationToolbarChrome.Identifier.annotateToolStrip)
    }
}

/// Both toolbars sit in windows at `kScreenshotOverlayBaseLevel`, where the system
/// tooltip panel opens *underneath* and is never seen. These lock the replacement.
final class AnnotationTooltipTests: XCTestCase {

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 120, height: 20)

    /// The whole point: a tooltip below the overlay is an invisible tooltip.
    func testTooltipSitsAboveTheAnnotationOverlayLevel() {
        XCTAssertGreaterThan(
            AnnotationTooltip.windowLevel.rawValue,
            kScreenshotOverlayBaseLevel.rawValue,
            "the tooltip must outrank the overlay it annotates"
        )
    }

    func testTooltipHangsBelowTheButtonAndIsCentredOnIt() {
        // A toolbar button near the top of the screen: room below, as in the editor.
        let anchor = NSRect(x: 700, y: 820, width: 28, height: 28)
        let frame = AnnotationTooltip.frame(anchor: anchor, size: size, screen: screen)
        XCTAssertEqual(frame.maxY, anchor.minY - AnnotationTooltip.gap, accuracy: 0.001)
        XCTAssertEqual(frame.midX, anchor.midX, accuracy: 0.001)
    }

    /// A tool strip parked at the bottom of the screen must flip its tooltip above the
    /// button rather than push it off the display.
    func testTooltipFlipsAboveWhenThereIsNoRoomBelow() {
        let anchor = NSRect(x: 700, y: 8, width: 28, height: 28)
        let frame = AnnotationTooltip.frame(anchor: anchor, size: size, screen: screen)
        XCTAssertEqual(frame.minY, anchor.maxY + AnnotationTooltip.gap, accuracy: 0.001)
    }

    func testTooltipStaysOnScreenAtBothHorizontalEdges() {
        let left = AnnotationTooltip.frame(
            anchor: NSRect(x: 2, y: 820, width: 28, height: 28), size: size, screen: screen
        )
        XCTAssertGreaterThanOrEqual(left.minX, screen.minX)

        let right = AnnotationTooltip.frame(
            anchor: NSRect(x: screen.maxX - 30, y: 820, width: 28, height: 28), size: size, screen: screen
        )
        XCTAssertLessThanOrEqual(right.maxX, screen.maxX)
    }

    /// Screens don't start at the origin once a second monitor is involved; the frame
    /// has to be in that screen's coordinates, not clamped to (0, 0).
    func testTooltipRespectsAnOffsetScreen() {
        let secondary = NSRect(x: -1920, y: 300, width: 1920, height: 1080)
        let anchor = NSRect(x: -1910, y: 320, width: 28, height: 28)
        let frame = AnnotationTooltip.frame(anchor: anchor, size: size, screen: secondary)
        XCTAssertGreaterThanOrEqual(frame.minX, secondary.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, secondary.minY)
        XCTAssertLessThanOrEqual(frame.maxY, secondary.maxY)
    }

    // MARK: - Displays and Spaces

    /// The panel is placed against the display the anchor is really on. `window.screen`
    /// can't answer that for a window spanning two displays — it names one of them, and
    /// clamping to it drags the tooltip onto the wrong monitor.
    func testTheTooltipPicksTheDisplayTheAnchorIsActuallyOn() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            AnnotationTooltip.screenIndex(
                for: NSRect(x: 2000, y: 500, width: 28, height: 28), in: [primary, secondary]
            ),
            1
        )
        XCTAssertEqual(
            AnnotationTooltip.screenIndex(
                for: NSRect(x: 700, y: 820, width: 28, height: 28), in: [primary, secondary]
            ),
            0
        )
    }

    /// A display can be unplugged between arming and firing; the caller falls back
    /// rather than being handed a display the anchor isn't on.
    func testAnAnchorOnNoDisplayPicksNone() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertNil(
            AnnotationTooltip.screenIndex(
                for: NSRect(x: -5000, y: 0, width: 28, height: 28), in: [primary]
            )
        )
    }

    /// Hover text comes from `toolTip`, so the shortcut suffix the toolbars already
    /// write there is what the user reads — no second source to keep in sync.
    func testAButtonWithNoTooltipTextShowsNothing() {
        let button = HoverStateButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.toolTip = nil
        AnnotationTooltip.shared.scheduleShow(for: button)
        XCTAssertFalse(AnnotationTooltip.shared.isVisible)
        XCTAssertFalse(AnnotationTooltip.shared._isArmedForTesting, "nothing to say, nothing armed")
    }

    /// A clipboard image row has no `toolTip` string at all — it shows a preview. Empty
    /// text must not be read as "nothing to show".
    func testAnImagePreviewArmsEvenWithNoText() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 22))
        row.toolTip = nil

        AnnotationTooltip.shared.scheduleShow(
            for: row,
            placement: .trailing,
            image: NSImage(size: NSSize(width: 120, height: 80))
        )

        XCTAssertTrue(AnnotationTooltip.shared._isArmedForTesting)
        AnnotationTooltip.shared.hide(for: nil)
    }

    // MARK: - Menu rows
    //
    // Clipboard rows are view-backed menu items, which AppKit never gives a tooltip,
    // so they present this panel too. A row spans the whole menu: hanging the tooltip
    // below it would cover the rows underneath, hence `.trailing`.

    private let row = NSRect(x: 300, y: 600, width: 260, height: 22)

    func testAMenuRowTooltipSitsBesideTheRowInsteadOfOverTheRowsBelow() {
        let frame = AnnotationTooltip.frame(anchor: row, size: size, screen: screen, placement: .trailing)
        XCTAssertEqual(frame.minX, row.maxX + AnnotationTooltip.gap, accuracy: 0.001)
        XCTAssertEqual(frame.midY, row.midY, accuracy: 0.001)
    }

    /// A status item near the right end of the menu bar drops its menu against that
    /// edge, so the tooltip has to go on the other side of it.
    func testAMenuRowTooltipFlipsToTheLeftWhenThereIsNoRoomBeside() {
        let hugging = NSRect(x: screen.maxX - 260, y: 600, width: 260, height: 22)
        let frame = AnnotationTooltip.frame(anchor: hugging, size: size, screen: screen, placement: .trailing)
        XCTAssertEqual(frame.maxX, hugging.minX - AnnotationTooltip.gap, accuracy: 0.001)
    }

    func testAMenuRowTooltipStaysOnScreenAtTheBottomOfALongMenu() {
        let lastRow = NSRect(x: 300, y: 2, width: 260, height: 22)
        let frame = AnnotationTooltip.frame(anchor: lastRow, size: size, screen: screen, placement: .trailing)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    /// Clipboard previews run to the user's tooltip limit — 200 characters by default,
    /// which on a single line is a panel wider than the display.
    func testLongTooltipTextWrapsInsteadOfRunningOffTheDisplay() {
        let text = String(repeating: "clipboard ", count: 40)
        let unwrapped = AnnotationTooltip.textSize(text, maxWidth: nil)
        let wrapped = AnnotationTooltip.textSize(text, maxWidth: 320)
        XCTAssertGreaterThan(unwrapped.width, screen.width, "precondition: one line really is too wide")
        XCTAssertLessThanOrEqual(wrapped.width, 320)
        XCTAssertGreaterThan(wrapped.height, unwrapped.height, "wrapping trades width for lines")
    }
}
