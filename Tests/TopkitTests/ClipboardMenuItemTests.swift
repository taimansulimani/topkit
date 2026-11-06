import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Stands in for the tooltip panel so the hover → tooltip wiring is testable without
/// a tracking menu on screen.
private final class TooltipSpy: HoverTooltipPresenting {
    private(set) var shown: [NSView] = []
    private(set) var images: [NSImage?] = []
    private(set) var hidden: [NSView?] = []

    func scheduleShow(for view: NSView, placement: AnnotationTooltip.Placement, maxWidth: CGFloat?, image: NSImage?) {
        shown.append(view)
        images.append(image)
    }

    func hide(for view: NSView?) {
        hidden.append(view)
    }
}

private final class HitTestCountingView: NSView {
    var hitTests = 0
    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTests += 1
        return super.hitTest(point)
    }
}

final class ClipboardMenuItemTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppDelegate.registerDefaultUserValues()
    }

    func testCreateClipboardMenuItemCreatesHexSwatchImageForText() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "showImagePreview")
        defaults.set(false, forKey: "showTooltip")

        let appDelegate = AppDelegate()
        let item = ClipboardItem(content: "#FF0000", type: .text)

        let menuItem = appDelegate.createClipboardMenuItem(item: item, number: 1)
        XCTAssertEqual(menuItem.title.isEmpty, false)
        XCTAssertNotNil(menuItem.image)
    }

    func testCreateClipboardMenuItemUsesRowViewReflectingPinState() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "showImagePreview")

        let appDelegate = AppDelegate()
        let unpinned = appDelegate.createClipboardMenuItem(item: ClipboardItem(content: "plain", type: .text), number: 2)
        let pinned = appDelegate.createClipboardMenuItem(item: ClipboardItem(content: "kept", type: .text, isPinned: true), number: 1)

        let unpinnedView = try? XCTUnwrap(unpinned.view as? ClipboardRowMenuView)
        let pinnedView = try? XCTUnwrap(pinned.view as? ClipboardRowMenuView)
        XCTAssertEqual(unpinnedView?.isPinned, false)
        XCTAssertEqual(pinnedView?.isPinned, true)
        XCTAssertEqual(unpinnedView?.titleText, unpinned.title)
        XCTAssertNotNil(unpinned.representedObject as? ClipboardItem)
    }

    /// A tall menu scrolls rows under a stationary pointer, and AppKit sends no
    /// enter/exit while it tracks — so the rows must re-derive hover from geometry,
    /// or every row that passes under the pointer stays highlighted.
    func testHoverFollowsTheRowUnderThePointerWhenTheMenuScrolls() {
        _ = NSApplication.shared
        let (window, rows) = makeStackedRowsInWindow(count: 2)
        defer { window.close() }

        // Pointer parked over the upper row.
        let pointerInWindow = NSPoint(x: 100, y: rows[0].frame.midY)
        let pointer = NSPoint(x: window.frame.minX + pointerInWindow.x,
                              y: window.frame.minY + pointerInWindow.y)
        rows.forEach { $0._recomputeHoverForTesting(atScreenPoint: pointer) }
        XCTAssertTrue(rows[0]._isHoveredForTesting)
        XCTAssertFalse(rows[1]._isHoveredForTesting)

        // Scroll: the rows slide up, the pointer does not move.
        for row in rows { row.frame.origin.y += 30 }
        rows.forEach { $0._recomputeHoverForTesting(atScreenPoint: pointer) }

        XCTAssertFalse(rows[0]._isHoveredForTesting, "the row that scrolled away must drop its highlight")
        XCTAssertTrue(rows[1]._isHoveredForTesting, "the row now under the pointer takes it")
        XCTAssertEqual(rows.filter(\._isHoveredForTesting).count, 1, "never more than one hovered row")
    }

    func testRowWatchesGeometryOnlyWhileItIsInAMenuWindow() {
        _ = NSApplication.shared
        let (window, rows) = makeStackedRowsInWindow(count: 1)
        defer { window.close() }
        let row = rows[0]
        XCTAssertGreaterThan(row._geometryObserverCountForTesting, 0,
                             "a row in a window must watch its ancestors for scroll-driven moves")

        row.removeFromSuperview()
        XCTAssertEqual(row._geometryObserverCountForTesting, 0, "and drop them when the menu goes away")
    }

    /// Regression: rows became view-backed when the pin button arrived, and AppKit
    /// shows no tooltip for a view-backed menu item — not the item's, not the view's.
    /// The row has to present one itself, off its own hover state.
    func testHoveringARowShowsItsTooltipAndLeavingHidesIt() {
        _ = NSApplication.shared
        let (window, rows) = makeStackedRowsInWindow(count: 2)
        defer { window.close() }
        let row = rows[0]

        // Park hover off the row first: the tester's real pointer may already sit
        // inside this window, and hover only reacts to a change.
        row._recomputeHoverForTesting(atScreenPoint: NSPoint(x: -10_000, y: -10_000))
        let spy = TooltipSpy()
        row.tooltipPresenter = spy
        row.configure(title: "row 0", image: nil, isPinned: false, toolTip: "the whole clipboard entry", tooltipImageProvider: nil)

        let onRow = NSPoint(x: window.frame.minX + 100, y: window.frame.minY + row.frame.midY)
        row._recomputeHoverForTesting(atScreenPoint: onRow)
        XCTAssertEqual(spy.shown.count, 1, "hovering a row must arm its tooltip")
        XCTAssertTrue(spy.shown.first === row)

        let offRow = NSPoint(x: window.frame.minX + 100, y: window.frame.minY + rows[1].frame.midY)
        row._recomputeHoverForTesting(atScreenPoint: offRow)
        XCTAssertEqual(spy.hidden.count, 1, "and leaving it must take the tooltip with it")
    }

    /// The menu closing has to take the tooltip with it, or the panel is stranded
    /// on screen after the rows are gone.
    func testARowLeavingItsMenuHidesTheTooltip() {
        _ = NSApplication.shared
        let (window, rows) = makeStackedRowsInWindow(count: 1)
        defer { window.close() }
        let row = rows[0]
        // As above: settle hover before watching, so the tester's real pointer
        // sitting inside this window can't add a hide of its own.
        row._recomputeHoverForTesting(atScreenPoint: NSPoint(x: -10_000, y: -10_000))
        let spy = TooltipSpy()
        row.tooltipPresenter = spy

        row.removeFromSuperview()
        XCTAssertEqual(spy.hidden.count, 1)
    }

    // MARK: - Hover text shaping
    //
    // The row title flattens newlines to spaces; the tooltip keeps them, which is the
    // point of it. But a copied block that opens with blank lines then opened a
    // mostly-empty panel, so the ends are trimmed and blank runs collapsed.

    func testTooltipTextDropsLeadingBlankLinesAndCollapsesRuns() {
        let content = "\n\n\nior\n\n\n\nLayer order: z-order\n\n"

        XCTAssertEqual(
            AppDelegate.tooltipText(from: content, maxLength: 200),
            "ior\n\nLayer order: z-order"
        )
    }

    func testTooltipTextKeepsIndentationInsideLines() {
        let content = "func f() {\n    return 1\n}"

        XCTAssertEqual(AppDelegate.tooltipText(from: content, maxLength: 200), content)
    }

    /// Truncation is of real content, so trimming can't be spent on blank lines.
    func testTooltipTextTruncatesAfterTrimming() {
        let content = "\n\n\nabcdefghij"

        XCTAssertEqual(AppDelegate.tooltipText(from: content, maxLength: 5), "abcde")
    }

    /// Image rows carry no hover text, so they get a preview instead — one big enough
    /// to actually see, sized by the "Tooltip size" preference.
    func testImageRowsCarryALargerTooltipPreview() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "showTooltip")
        defaults.set(true, forKey: "showImagePreview")
        defaults.set(60, forKey: "imagePreviewWidth")
        defaults.set(40, forKey: "imagePreviewHeight")
        defaults.set(240, forKey: "tooltipImageSize")
        let appDelegate = AppDelegate()
        let item = ClipboardItem(content: "Image", type: .image, imageData: makeTestPNGData(width: 640, height: 480))

        let row = appDelegate.createClipboardMenuItem(item: item, number: 1).view as? ClipboardRowMenuView
        let preview = row?.tooltipImage
        XCTAssertNotNil(preview)
        XCTAssertEqual(preview?.size.width ?? 0, 240, accuracy: 0.5, "sized by the preference, not the row thumbnail")
        XCTAssertGreaterThan(preview?.size.width ?? 0, 60)

        defaults.set(false, forKey: "showTooltip")
        let off = appDelegate.createClipboardMenuItem(item: item, number: 1).view as? ClipboardRowMenuView
        XCTAssertNil(off?.tooltipImage)
    }

    /// An image row has no `toolTip` string at all, so the presenter must not treat
    /// missing text as "nothing to show".
    func testHoveringAnImageRowShowsItsPreview() {
        _ = NSApplication.shared
        let (window, rows) = makeStackedRowsInWindow(count: 2)
        defer { window.close() }
        let row = rows[0]
        row._recomputeHoverForTesting(atScreenPoint: NSPoint(x: -10_000, y: -10_000))
        let spy = TooltipSpy()
        row.tooltipPresenter = spy
        let preview = NSImage(size: NSSize(width: 200, height: 120))
        row.configure(title: "1. Image", image: nil, isPinned: false, toolTip: nil, tooltipImageProvider: { preview })

        let onRow = NSPoint(x: window.frame.minX + 100, y: window.frame.minY + row.frame.midY)
        row._recomputeHoverForTesting(atScreenPoint: onRow)

        XCTAssertEqual(spy.shown.count, 1)
        XCTAssertTrue(spy.images.first.flatMap { $0 } === preview)
    }

    /// What the user actually toggles in Preferences: no "Show tooltip on hover",
    /// no hover text on the row.
    func testTheTooltipPreferenceDecidesWhetherARowCarriesHoverText() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "showImagePreview")
        defaults.set(200, forKey: "tooltipMaxLength")
        let appDelegate = AppDelegate()
        let item = ClipboardItem(content: "the whole clipboard entry", type: .text)

        defaults.set(true, forKey: "showTooltip")
        let on = appDelegate.createClipboardMenuItem(item: item, number: 1).view as? ClipboardRowMenuView
        XCTAssertEqual(on?.toolTip, "the whole clipboard entry")

        defaults.set(false, forKey: "showTooltip")
        let off = appDelegate.createClipboardMenuItem(item: item, number: 1).view as? ClipboardRowMenuView
        XCTAssertNil(off?.toolTip)
    }

    /// Rows stacked bottom-up, 22pt each, in a visible window so hit-testing works.
    private func makeStackedRowsInWindow(count: Int) -> (NSWindow, [ClipboardRowMenuView]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView = container

        let rows: [ClipboardRowMenuView] = (0..<count).map { index in
            let row = ClipboardRowMenuView()
            row.configure(title: "row \(index)", image: nil, isPinned: false, toolTip: nil, tooltipImageProvider: nil)
            // Index 0 on top, matching a menu's reading order.
            row.frame = NSRect(x: 0, y: CGFloat(60 - index * 22), width: 300, height: 22)
            container.addSubview(row)
            return row
        }
        return (window, rows)
    }

    func testCreateClipboardMenuItemCachesImagePreview() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "showImagePreview")
        defaults.set(60, forKey: "imagePreviewWidth")
        defaults.set(40, forKey: "imagePreviewHeight")

        let appDelegate = AppDelegate()
        let imageData = makeTestPNGData(width: 64, height: 48)
        let item = ClipboardItem(content: "Image", type: .image, imageData: imageData)

        let first = appDelegate.createClipboardMenuItem(item: item, number: 1)
        let second = appDelegate.createClipboardMenuItem(item: item, number: 1)

        XCTAssertNotNil(first.image)
        XCTAssertNotNil(second.image)
        XCTAssertTrue(first.image === second.image)
    }

    func testLargeHistoryUsesLazyFolderMenus() {
        let defaults = UserDefaults.standard
        defaults.set(3, forKey: "itemsInline")
        defaults.set(2, forKey: "itemsInFolder")
        defaults.set(false, forKey: "showImagePreview")

        let appDelegate = AppDelegate()
        let manager = ClipboardManager.shared
        manager.clipboardHistory = [
            ClipboardItem(content: "1", type: .text),
            ClipboardItem(content: "2", type: .text),
            ClipboardItem(content: "3", type: .text),
            ClipboardItem(content: "4", type: .text),
            ClipboardItem(content: "5", type: .text),
            ClipboardItem(content: "6", type: .text)
        ]
        appDelegate.clipboardManager = manager

        let menu = NSMenu()
        appDelegate.buildMenu(into: menu)

        let folderItem = menu.items.first(where: { $0.title == "4 - 5" })
        XCTAssertNotNil(folderItem)
        XCTAssertNotNil(folderItem?.submenu)
        XCTAssertEqual(folderItem?.submenu?.items.count, 0)

        if let folderMenu = folderItem?.submenu {
            appDelegate.menuWillOpen(folderMenu)
            XCTAssertEqual(folderMenu.items.count, 2)
            XCTAssertEqual(folderMenu.items.first?.title.contains("4"), true)
        }
    }

    func testBuildMenuPerformanceWithLargeHistory() {
        let defaults = UserDefaults.standard
        defaults.set(10, forKey: "itemsInline")
        defaults.set(50, forKey: "itemsInFolder")
        defaults.set(false, forKey: "showImagePreview")

        let appDelegate = AppDelegate()
        let manager = ClipboardManager.shared
        manager.clipboardHistory = (0..<500).map { ClipboardItem(content: "Item \($0)", type: .text) }
        appDelegate.clipboardManager = manager

        measure {
            let menu = NSMenu()
            appDelegate.buildMenu(into: menu)
            XCTAssertGreaterThan(menu.items.count, 0)
        }
    }

    // MARK: - Search with a big history (TEC-354)

    /// Builds the status-style menu over `history` and returns it with its search view.
    private func makeSearchableMenu(history: [ClipboardItem]) -> (AppDelegate, NSMenu, ClipboardSearchMenuView) {
        let defaults = UserDefaults.standard
        defaults.set(10, forKey: "itemsInline")
        defaults.set(50, forKey: "itemsInFolder")
        defaults.set(false, forKey: "showImagePreview")
        let appDelegate = AppDelegate()
        let manager = ClipboardManager.shared
        let saved = manager.clipboardHistory
        // The search callbacks hold the app delegate weakly; keep it alive for the test.
        addTeardownBlock { manager.clipboardHistory = saved; _ = appDelegate }
        manager.clipboardHistory = history
        appDelegate.clipboardManager = manager
        let menu = NSMenu()
        appDelegate.buildMenu(into: menu)
        let search = menu.item(at: 0)?.view as! ClipboardSearchMenuView
        return (appDelegate, menu, search)
    }

    /// The clipboard section: everything between the search field and the first separator.
    private func sectionItems(of menu: NSMenu) -> [NSMenuItem] {
        Array(menu.items.dropFirst().prefix { !$0.isSeparatorItem })
    }

    private func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func testSearchShowsEveryMatchInRankedOrderOnceTheFillCompletes() {
        let history = (0..<130).map { ClipboardItem(content: $0 % 3 == 0 ? "carrot \($0)" : "car \($0)", type: .text) }
        let (_, menu, search) = makeSearchableMenu(history: history)

        search.onQueryChanged?("car")
        // A screenful first, so the keystroke doesn't wait on every row…
        XCTAssertLessThan(sectionItems(of: menu).count, 130)
        XCTAssertGreaterThan(sectionItems(of: menu).count, 0)

        // …then the rest, giving exactly what the filter ranks.
        spinRunLoop()
        let expected = ClipboardSearchFilter.matches(history: history, query: "car").map { history[$0.historyIndex].id }
        let shown = sectionItems(of: menu).compactMap { ($0.representedObject as? ClipboardItem)?.id }
        XCTAssertEqual(shown, expected)
        XCTAssertEqual(sectionItems(of: menu).map(\.tag), ClipboardSearchFilter.matches(history: history, query: "car").map { $0.historyIndex + 1 })
    }

    func testNextKeystrokeReusesTheRowsThatStillMatch() {
        let history = (0..<30).map { ClipboardItem(content: $0 % 2 == 0 ? "carrot \($0)" : "car \($0)", type: .text) }
        let (_, menu, search) = makeSearchableMenu(history: history)

        search.onQueryChanged?("car")
        spinRunLoop()
        let before = Dictionary(uniqueKeysWithValues: sectionItems(of: menu).map {
            (($0.representedObject as! ClipboardItem).id, ObjectIdentifier($0))
        })

        search.onQueryChanged?("carr")
        spinRunLoop()
        let after = sectionItems(of: menu)
        XCTAssertEqual(after.count, 15)
        for row in after {
            XCTAssertEqual(before[(row.representedObject as! ClipboardItem).id], ObjectIdentifier(row),
                           "a row that still matches must be the same menu item, not a rebuilt one")
        }
    }

    func testNoMatchesThenClearingRestoresTheNormalLayout() {
        let history = (0..<25).map { ClipboardItem(content: "entry \($0)", type: .text) }
        let (_, menu, search) = makeSearchableMenu(history: history)
        let normalTitles = sectionItems(of: menu).map(\.title)

        search.onQueryChanged?("zzz")
        XCTAssertEqual(sectionItems(of: menu).map(\.title), ["No matches"])

        search.onQueryChanged?("")
        XCTAssertEqual(sectionItems(of: menu).map(\.title), normalTitles)
        XCTAssertEqual(menu.items.first(where: { $0.title == "11 - 25" })?.submenu != nil, true)
    }

    /// The pin button is the costly part of a row, so it is only built once
    /// the row is pinned or hovered.
    func testPinButtonIsBuiltOnlyWhenTheRowNeedsIt() {
        _ = NSApplication.shared
        let (window, rows) = makeStackedRowsInWindow(count: 2)
        defer { window.close() }
        let row = rows[0]
        row._recomputeHoverForTesting(atScreenPoint: NSPoint(x: -10_000, y: -10_000))
        func pinButtons(_ view: NSView) -> [NSButton] { view.subviews.compactMap { $0 as? NSButton } }
        XCTAssertTrue(pinButtons(row).isEmpty)

        let onRow = NSPoint(x: window.frame.minX + 100, y: window.frame.minY + row.frame.midY)
        row._recomputeHoverForTesting(atScreenPoint: onRow)
        XCTAssertEqual(pinButtons(row).count, 1)
        XCTAssertEqual(pinButtons(row).first?.isHidden, false)

        let pinned = ClipboardRowMenuView()
        pinned.configure(title: "kept", image: nil, isPinned: true, toolTip: nil, tooltipImageProvider: nil)
        XCTAssertEqual(pinButtons(pinned).first?.isHidden, false)
        XCTAssertEqual(pinButtons(pinned).first?.toolTip, String(localized: "Unpin Item"))
    }

    /// Every row re-derives hover on any geometry change; only the row under
    /// the pointer may pay for a window hit-test, or a tall menu does rows² work.
    func testOnlyTheRowUnderThePointerHitTestsTheWindow() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = HitTestCountingView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = container
        let rows: [ClipboardRowMenuView] = (0..<10).map { index in
            let row = ClipboardRowMenuView()
            row.configure(title: "row \(index)", image: nil, isPinned: false, toolTip: nil, tooltipImageProvider: nil)
            row.frame = NSRect(x: 0, y: CGFloat(index * 22), width: 300, height: 22)
            container.addSubview(row)
            return row
        }

        container.hitTests = 0
        let onRow3 = NSPoint(x: window.frame.minX + 100, y: window.frame.minY + rows[3].frame.midY)
        rows.forEach { $0._recomputeHoverForTesting(atScreenPoint: onRow3) }
        XCTAssertLessThanOrEqual(container.hitTests, 1, "rows the pointer isn't over must not hit-test")
        XCTAssertEqual(rows.map(\._isHoveredForTesting), (0..<10).map { $0 == 3 })
    }

    private func makeTestPNGData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}

