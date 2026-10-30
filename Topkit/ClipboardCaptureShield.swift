import AppKit

/// Keeps the clipboard history out of Topkit's own screenshots and screen recordings.
///
/// The history shows in two NSMenus, the status menu and the cursor popup, whose rows
/// are custom views, plus the hover preview those rows open (`AnnotationTooltip`).
///
/// Why `NSWindow.sharingType` and not the capture filter: the menu windows belong to
/// AppKit (`NSPopupMenuWindow`) and are made when a menu opens, so the window list an
/// `SCContentFilter` gets when a recording starts can never name a menu opened halfway
/// through it. Leaving Topkit out as a whole application would also drop the Annotate,
/// Halo and magnifier windows people record on purpose. A window whose `sharingType` is
/// `.none` is left out of every ScreenCaptureKit capture (checked on device: a display
/// capture shows what is under the menu) and still works normally on screen. So the
/// menu still opens during a recording; it just never reaches the file.
///
/// It only hides while a Topkit capture is running, so other tools (and App Store
/// screenshots of the menu itself) still see the menu the rest of the time.
///
/// Main thread only.
final class ClipboardCaptureShield {
    static let shared = ClipboardCaptureShield()

    /// What is reading the screen.
    enum Source: Hashable {
        /// The frozen full-display grab a screenshot takes before its region picker.
        case screenshot
        /// A recording flow, from region picking until it stops.
        case recording
    }

    /// The sharing type clipboard windows get: hidden from capture only while one runs.
    static func sharingType(isCaptureActive: Bool) -> NSWindow.SharingType {
        isCaptureActive ? .none : .readOnly
    }

    /// Recording activity → whether the recording side of the shield is up. Covers the
    /// region picker and confirm step too, so a menu opened there is already hidden
    /// when the stream starts.
    static func isCaptureActive(recordingActivity: ScreenRecordingManager.Activity) -> Bool {
        recordingActivity != .idle
    }

    private(set) var activeSources: Set<Source> = []
    var isCaptureActive: Bool { !activeSources.isEmpty }

    /// Windows that have shown clipboard history. Weak: AppKit owns menu windows.
    private let windows = NSHashTable<NSWindow>.weakObjects()
    /// Root menus holding clipboard history, closed when a capture starts.
    private let menus = NSHashTable<NSMenu>.weakObjects()
    private let closeMenu: (NSMenu) -> Void

    init(closeMenu: @escaping (NSMenu) -> Void = { $0.cancelTrackingWithoutAnimation() }) {
        self.closeMenu = closeMenu
    }

    /// Marks a clipboard menu item (a history row or the search field) as clipboard
    /// history. Its menu window is shielded the moment AppKit puts the item's view in
    /// it, before it draws. The item needs its `view` set.
    func attach(to item: NSMenuItem) {
        guard let view = item.view,
              !view.subviews.contains(where: { $0 is WindowAnchor }) else { return }
        view.addSubview(WindowAnchor(shield: self, item: item))
    }

    /// Turns `source` on or off. A capture starting closes any open clipboard menu
    /// (spec: it must not be on screen, and an open menu would hold the selection's
    /// input) and hides its windows first, so a menu still fading out can't land in
    /// the screenshot's frozen grab.
    func setActive(_ active: Bool, for source: Source) {
        if active {
            let isNew = activeSources.insert(source).inserted
            applySharingType()
            if isNew {
                for menu in menus.allObjects { closeMenu(menu) }
            }
        } else {
            guard activeSources.remove(source) != nil else { return }
            applySharingType()
        }
    }

    /// Called by the anchor when its item's view enters a window (the menu opened).
    func itemDidEnterWindow(_ item: NSMenuItem, window: NSWindow) {
        windows.add(window)
        window.sharingType = Self.sharingType(isCaptureActive: isCaptureActive)
        if let menu = item.menu {
            var root = menu
            while let parent = root.supermenu { root = parent }
            menus.add(root)
        }
    }

    /// Re-applied on every change rather than only to new windows: AppKit can keep a
    /// menu window between openings, and one hidden for a capture must come back for
    /// other tools afterwards.
    private func applySharingType() {
        let type = Self.sharingType(isCaptureActive: isCaptureActive)
        for window in windows.allObjects where window.sharingType != type {
            window.sharingType = type
        }
    }

    var _shieldedWindowsForTesting: [NSWindow] { windows.allObjects }
    var _menusForTesting: [NSMenu] { menus.allObjects }

    /// Zero-size subview that reports its host's window. A subview rather than a hook
    /// in the row and search views, so those views stay unaware of capture.
    final class WindowAnchor: NSView {
        private weak var shield: ClipboardCaptureShield?
        private weak var item: NSMenuItem?

        init(shield: ClipboardCaptureShield, item: NSMenuItem) {
            self.shield = shield
            self.item = item
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let item else { return }
            shield?.itemDidEnterWindow(item, window: window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}
