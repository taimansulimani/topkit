import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// TEC-241: clipboard history stays out of Topkit's screenshots and recordings.
final class ClipboardCaptureShieldTests: XCTestCase {

    private var closedMenus: [NSMenu] = []
    /// "Hide clipboard from screen sharing" (TEC-356). Off by default here so the
    /// TEC-241 tests below check Topkit's own captures on their own.
    private var hidesFromScreenSharing = false

    private func makeShield() -> ClipboardCaptureShield {
        ClipboardCaptureShield(
            closeMenu: { [unowned self] in self.closedMenus.append($0) },
            hidesFromScreenSharing: { [unowned self] in self.hidesFromScreenSharing }
        )
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A clipboard row inside a folder submenu, its view placed in `window` the way
    /// AppKit places it in the menu window when the menu opens.
    private func showClipboardView(
        in window: NSWindow,
        shield: ClipboardCaptureShield
    ) -> (root: NSMenu, view: NSView) {
        let root = NSMenu()
        let folder = NSMenuItem(title: "11 - 60", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        folder.submenu = submenu
        root.addItem(folder)
        let row = NSMenuItem(title: "secret", action: nil, keyEquivalent: "")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        row.view = view
        submenu.addItem(row)
        shield.attach(to: row)
        window.contentView?.addSubview(view)
        return (root, view)
    }

    // MARK: Policy

    func testSettingOffHidesFromCaptureOnlyWhileATopkitCaptureRuns() {
        XCTAssertEqual(ClipboardCaptureShield.sharingType(isCaptureActive: true, hidesFromScreenSharing: false), .none)
        XCTAssertEqual(ClipboardCaptureShield.sharingType(isCaptureActive: false, hidesFromScreenSharing: false), .readOnly)
    }

    func testSettingOnHidesFromEveryCaptureAllTheTime() {
        XCTAssertEqual(ClipboardCaptureShield.sharingType(isCaptureActive: false, hidesFromScreenSharing: true), .none)
        XCTAssertEqual(ClipboardCaptureShield.sharingType(isCaptureActive: true, hidesFromScreenSharing: true), .none)
    }

    func testRecordingShieldCoversPickingAndRecording() {
        XCTAssertFalse(ClipboardCaptureShield.isCaptureActive(recordingActivity: .idle))
        XCTAssertTrue(ClipboardCaptureShield.isCaptureActive(recordingActivity: .selecting))
        XCTAssertTrue(ClipboardCaptureShield.isCaptureActive(recordingActivity: .recording))
    }

    // MARK: Windows

    func testMenuOpenedOutsideACaptureStaysCapturable() {
        let shield = makeShield()
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)

        XCTAssertEqual(window.sharingType, .readOnly)
        XCTAssertTrue(shield._shieldedWindowsForTesting.contains(window))
    }

    /// The shortcut during a recording: the menu opens for the user but its window is
    /// already hidden from capture when the views land in it, before anything draws.
    func testMenuOpenedDuringARecordingIsHiddenFromCapture() {
        let shield = makeShield()
        shield.setActive(true, for: .recording)
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)

        XCTAssertEqual(window.sharingType, .none)
    }

    func testRecordingEndingMakesTheMenuCapturableAgain() {
        let shield = makeShield()
        shield.setActive(true, for: .recording)
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)

        shield.setActive(false, for: .recording)

        XCTAssertEqual(window.sharingType, .readOnly)
    }

    /// AppKit can keep a menu window between openings, so a window already known
    /// flips when a capture starts, not only windows made after it.
    func testCaptureStartingHidesWindowsAlreadyKnown() {
        let shield = makeShield()
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)

        shield.setActive(true, for: .screenshot)
        XCTAssertEqual(window.sharingType, .none)

        shield.setActive(false, for: .screenshot)
        XCTAssertEqual(window.sharingType, .readOnly)
    }

    /// A screenshot finishing mid-recording must not un-hide the menu.
    func testOverlappingCapturesKeepTheMenuHiddenUntilBothEnd() {
        let shield = makeShield()
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)

        shield.setActive(true, for: .recording)
        shield.setActive(true, for: .screenshot)
        shield.setActive(false, for: .screenshot)
        XCTAssertEqual(window.sharingType, .none)

        shield.setActive(false, for: .recording)
        XCTAssertEqual(window.sharingType, .readOnly)
    }

    // MARK: Screen sharing setting (TEC-356)

    func testSettingIsOnWhenNeverSet() throws {
        let suite = "ClipboardCaptureShieldTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(ClipboardCaptureShield.hidesFromScreenSharing(in: defaults))
        defaults.set(false, forKey: ClipboardCaptureShield.hidesFromScreenSharingKey)
        XCTAssertFalse(ClipboardCaptureShield.hidesFromScreenSharing(in: defaults))
    }

    func testAppRegistersTheSettingOn() {
        AppDelegate.registerDefaultUserValues()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(registered[ClipboardCaptureShield.hidesFromScreenSharingKey] as? Bool, true)
    }

    /// The other app's share (Zoom, Meet, FaceTime…): no Topkit capture is running,
    /// and the menu window is still hidden from it the moment it opens.
    func testSettingOnHidesAMenuOpenedWithNoTopkitCapture() {
        hidesFromScreenSharing = true
        let shield = makeShield()
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)

        XCTAssertFalse(shield.isCaptureActive)
        XCTAssertEqual(window.sharingType, .none)
    }

    /// A Topkit recording ending must not un-hide the menu while the setting is on.
    func testSettingOnKeepsTheMenuHiddenAfterATopkitCaptureEnds() {
        hidesFromScreenSharing = true
        let shield = makeShield()
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)

        shield.setActive(true, for: .recording)
        shield.setActive(false, for: .recording)

        XCTAssertEqual(window.sharingType, .none)
    }

    /// Switching the setting reaches a menu window AppKit kept from an earlier opening.
    func testSwitchingTheSettingUpdatesKnownWindows() {
        let shield = makeShield()
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)
        XCTAssertEqual(window.sharingType, .readOnly)

        hidesFromScreenSharing = true
        shield.settingDidChange()
        XCTAssertEqual(window.sharingType, .none)

        hidesFromScreenSharing = false
        shield.settingDidChange()
        XCTAssertEqual(window.sharingType, .readOnly)
    }

    /// Setting off still hides the menu from Topkit's own recordings (TEC-241).
    func testSettingOffStillHidesFromTopkitRecordings() {
        let shield = makeShield()
        shield.setActive(true, for: .recording)
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)
        shield.settingDidChange()

        XCTAssertEqual(window.sharingType, .none)
    }

    /// Only a capture starting closes an open menu; switching the setting never does.
    func testSwitchingTheSettingDoesNotCloseMenus() {
        let shield = makeShield()
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)

        hidesFromScreenSharing = true
        shield.settingDidChange()

        XCTAssertTrue(closedMenus.isEmpty)
    }

    // MARK: Closing open menus

    func testCaptureStartingClosesTheWholeMenuTree() {
        let shield = makeShield()
        let window = makeWindow()
        let (root, _) = showClipboardView(in: window, shield: shield)

        shield.setActive(true, for: .screenshot)

        XCTAssertEqual(closedMenus.count, 1)
        XCTAssertTrue(closedMenus.first === root, "closes from the root, so a folder submenu takes its parent with it")
    }

    /// recording → selecting → recording keeps one session: the menu the user opens on
    /// purpose mid-recording is not slammed shut by the next state change.
    func testStayingActiveDoesNotCloseAMenuOpenedDuringTheRecording() {
        let shield = makeShield()
        shield.setActive(true, for: .recording)
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)
        closedMenus.removeAll()

        shield.setActive(true, for: .recording)

        XCTAssertTrue(closedMenus.isEmpty)
        XCTAssertEqual(window.sharingType, .none)
    }

    /// A screenshot taken during a recording still closes the menu first.
    func testScreenshotDuringARecordingClosesTheMenu() {
        let shield = makeShield()
        shield.setActive(true, for: .recording)
        let window = makeWindow()
        let (root, _) = showClipboardView(in: window, shield: shield)
        closedMenus.removeAll()

        shield.setActive(true, for: .screenshot)

        XCTAssertTrue(closedMenus.first === root)
    }

    func testEndingACaptureThatNeverStartedIsHarmless() {
        let shield = makeShield()
        let window = makeWindow()
        _ = showClipboardView(in: window, shield: shield)

        shield.setActive(false, for: .recording)

        XCTAssertFalse(shield.isCaptureActive)
        XCTAssertEqual(window.sharingType, .readOnly)
        XCTAssertTrue(closedMenus.isEmpty)
    }

    // MARK: Anchor

    func testAttachingTwiceAddsOneAnchor() {
        let shield = makeShield()
        let view = NSView()
        let item = NSMenuItem()
        item.view = view
        shield.attach(to: item)
        shield.attach(to: item)
        XCTAssertEqual(view.subviews.filter { $0 is ClipboardCaptureShield.WindowAnchor }.count, 1)
    }

    func testAnchorTakesNoClicksAndIsInvisibleToAccessibility() {
        let anchor = ClipboardCaptureShield.WindowAnchor(shield: makeShield(), item: NSMenuItem())
        XCTAssertNil(anchor.hitTest(.zero))
        XCTAssertFalse(anchor.isAccessibilityElement())
        XCTAssertEqual(anchor.frame, .zero)
    }

    /// The real wiring: both clipboard surfaces carry the anchor.
    func testClipboardRowsAndSearchFieldCarryTheAnchor() {
        AppDelegate.registerDefaultUserValues()
        let appDelegate = AppDelegate()
        let row = appDelegate.createClipboardMenuItem(item: ClipboardItem(content: "secret", type: .text), number: 1)
        XCTAssertEqual(row.view?.subviews.contains { $0 is ClipboardCaptureShield.WindowAnchor }, true)

        let menu = NSMenu()
        appDelegate.buildMenu(into: menu)
        let search = menu.items.first?.view
        XCTAssertTrue(search is ClipboardSearchMenuView)
        XCTAssertEqual(search?.subviews.contains { $0 is ClipboardCaptureShield.WindowAnchor }, true)
    }
}
