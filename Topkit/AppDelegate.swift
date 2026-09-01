import Cocoa
import SwiftUI
import CoreGraphics
import ImageIO
import Darwin
import Carbon.HIToolbox

/// Debug-only console logging. Release builds ship silent — nothing lands in Console.app,
/// and the autoclosure means the message string is never even built outside DEBUG.
func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
    print(message())
    fflush(stdout)
#endif
}

/// Preferences window: ESC unfocuses the current field instead of doing nothing.
private final class PreferencesWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        makeFirstResponder(nil)
    }
}

public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private struct MenuBuildSignature: Equatable {
        let historyCount: Int
        let searchQuery: String
        let inlineCount: Int
        let folderCount: Int
        let isDrawingActive: Bool
        /// The Annotate submenu ticks the armed tool, and an "End Annotate" item
        /// appears beneath it, so the menu must rebuild when either changes.
        let annotateArmedTool: AnnotationTool?
        let isColorPickerActive: Bool
        let isMagnifyingActive: Bool
        let isHaloActive: Bool
        let recordingActivity: Int
        let showImagePreview: Bool
        let previewWidth: Int
        let previewHeight: Int
        let markWithNumbers: Bool
        let previewLength: Int
        let showTooltip: Bool
        let tooltipMaxLength: Int
        let tooltipImageSize: Int
    }

    private struct ClipboardFolderRange {
        let start: Int
        let endExclusive: Int
    }

    private static let clipboardFolderMenuIdentifier = NSUserInterfaceItemIdentifier("topkit.clipboard.folder.menu")
    private var clipboardFolderRanges: [ObjectIdentifier: ClipboardFolderRange] = [:]

    /// Live query of the clipboard search field. Shared by the status menu and
    /// the cursor popup. Survives a plain menu dismissal (spec: reopening shows
    /// the field pre-filled and the list pre-filtered); cleared only when a
    /// clipboard item is picked. In-memory only, never persisted.
    private var clipboardSearchQuery = ""
    /// Number of clipboard-section rows currently in each menu (rows between
    /// the search field at index 0 and whatever follows the section), so live
    /// refiltering can splice the section in place while the menu is open.
    private var clipboardSectionCounts: [ObjectIdentifier: Int] = [:]
    private var menuNeedsRebuild = true
    private var lastMenuBuildSignature: MenuBuildSignature?
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let thumbnailPrefetchQueue = DispatchQueue(label: "topkit.clipboard.thumbnail.prefetch", qos: .utility)
    private let thumbnailPrefetchCount = 40

    private func log(_ message: String) {
        debugLog(message)
    }


    /// Called from `main` before the run loop so `UserDefaults` is seeded before any reads.
    public static func registerDefaultUserValues() {
        UserDefaults.standard.register(defaults: [
            "itemsInline": 10,
            "itemsInFolder": 50,
            "charsInMenu": 30,
            "markWithNumbers": true,
            "showClearAlert": true,
            "showTooltip": true,
            "tooltipMaxLength": 200,
            "tooltipImageSize": 240,
            "showImagePreview": true,
            "imagePreviewWidth": 80,
            "imagePreviewHeight": 50,
            "maxHistorySize": 100,
            "playNotificationSounds": true,
            "showToastNotifications": true,
            "recordingDictationSubtitles": true,
            "recordingMicrophoneAudio": false,
            "subtitleColorRed": 0.0,
            "subtitleColorGreen": 0.0,
            "subtitleColorBlue": 0.0,
            "subtitleColorAlpha": 1.0,

            // Off by default: registering a login item without the user asking is a
            // consent smell (and an App Review flag) — the user opts in via Preferences.
            "launchOnLogin": false,
            "inputCmdV": false,
            "magnifyingGlassSize": 160,
            "haloSize": 160,
            "colorPickerSize": 160,
            "haloColorRed": 1.0,
            "haloColorGreen": 1.0,
            "haloColorBlue": 1.0,
            "haloColorAlpha": 1.0,
            "brushColorMode": "mono",
            "brushColorRed": 1.0,
            "brushColorGreen": 0.0,
            "brushColorBlue": 0.0,
            "brushColorAlpha": 1.0,
            "screenshotAnnotationFont": "Helvetica",
            "saveScreenshotsToFolder": false,
            "screenshotSaveFolder": "",
            // Defaults are ⌃⇧ + letter (no ⌥), listed in the same order as the menu and the
            // Shortcuts preferences pane. Letters must stay unique across all of these.
            "shortcutScreenshot": "⌃⇧S",
            "shortcutRecordScreen": "⌃⇧R",
            "shortcutPickColor": "⌃⇧I",
            "shortcutDraw": "⌃⇧D",
            "shortcutAnnotateRectangle": "⌃⇧B",
            "shortcutAnnotateCircle": "⌃⇧C",
            "shortcutAnnotateArrow": "⌃⇧A",
            "shortcutAnnotateText": "⌃⇧T",
            "shortcutAnnotateRedact": "⌃⇧X",
            "shortcutAnnotateSticker": "⌃⇧Y",
            "shortcutAnnotateBadge": "⌃⇧N",
            "shortcutMagnifyingGlass": "⌃⇧Z",
            "shortcutHalo": "⌃⇧H",
            "shortcutMeasure": "⌃⇧M",
            "shortcutAddGuide": "⌃⇧K",
            "shortcutAddVerticalGuide": "⌃⇧L",
            "shortcutAddRectangle": "⌃⇧J",
            "shortcutClipboardMenu": "⌃⇧V",
            "showClipboardMenuNearCursor": false,
            "debugClipboardAnchor": false
        ])
    }

    private func registerDefaults() {
        Self.registerDefaultUserValues()
    }
    var statusItem: NSStatusItem!
    /// Status bar menu; attached to the status item only while it is open
    /// (see statusItemButtonClicked for why).
    private var statusMenu: NSMenu!
    var clipboardManager: ClipboardManager!
    var colorPickerManager: ColorPickerManager!
    var magnifyingGlassManager: MagnifyingGlassManager!
    var haloManager: HaloManager!
    var screenshotManager: ScreenshotManager!
    var screenRecordingManager: ScreenRecordingManager!
    var preferencesWindow: NSWindow?

    /// Windows currently requiring .regular activation policy (prefs, player).
    private var regularActivationCount = 0

    func pushRegularActivation() {
        regularActivationCount += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popRegularActivation() {
        regularActivationCount = max(0, regularActivationCount - 1)
        if regularActivationCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// App that was frontmost when the status menu opened; we reactivate it after copying so Cmd+V works there.
    private var applicationToActivateAfterCopy: NSRunningApplication?

    /// Downloads the SpeechTranscriber model assets in the background when
    /// dictation subtitles are on. Safe to call repeatedly.
    static func preflightCaptionAssetsIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "recordingDictationSubtitles") else { return }
        if #available(macOS 26.0, *) {
            ModernSpeechCaptionEngine.preflightAssets()
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
        
        // Register default preferences
        registerDefaults()

        // Start background permission monitor for screen recording.
        PermissionManager.shared.startScreenRecordingPermissionMonitor()

        // Warm the on-device transcription model so the first recording
        // captions immediately (macOS 26 SpeechAnalyzer path; no-op elsewhere).
        Self.preflightCaptionAssetsIfNeeded()

        // Register global shortcuts (Carbon hotkeys, no permission required).
        setupShortcuts()
        
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        // Configure the button: plain template glyph (no background), matching the other menu bar items
        updateStatusBarIcon()
        
        // Create menu with delegate (rebuilds on every open)
        let menu = NSMenu()
        menu.delegate = self
        // Build initial menu content
        buildMenu(into: menu)
        statusMenu = menu
        // The menu is NOT assigned to statusItem here. With an attached menu,
        // the click starts tracking before our action runs, so we cannot wrap
        // the session with the Return-key monitor (and any mid-tracking
        // NSApp.activate would cancel the session). Detached menu + button
        // action → attach → performClick → detach keeps that wrap reliable.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemButtonClicked)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        
        // Initialize managers
        clipboardManager = ClipboardManager.shared
        colorPickerManager = ColorPickerManager.shared
        magnifyingGlassManager = MagnifyingGlassManager.shared
        haloManager = HaloManager.shared
        screenshotManager = ScreenshotManager.shared
        screenRecordingManager = ScreenRecordingManager.shared

        // Gracefully handle screen recording being revoked mid-session: tear down any active
        // capture tool and warn the user, instead of hard-quitting the app.
        PermissionManager.shared.onScreenRecordingRevoked = { [weak self] in
            guard let self = self else { return }
            self.colorPickerManager?.cancelForPermissionLoss()
            self.magnifyingGlassManager?.cancelForPermissionLoss()
            self.screenshotManager?.abortForPermissionLoss()
            self.screenRecordingManager?.abortForPermissionLoss()
            AnnotateManager.shared.cancelForPermissionLoss()
            self.screenshotManager?.presentForcedToast(
                String(localized: "Screen Recording was turned off — Topkit's capture tools are paused until you re-enable it")
            )
        }

        // Setup drawing state change handler for status bar icon
        AnnotateManager.shared.onAnnotateStateChanged = { [weak self] isActive in
            guard let self = self else { return }
            self.isDrawingActive = isActive
            self.updateStatusBarIcon()
        }
        
        // Setup magnifying state change handler for status bar icon
        magnifyingGlassManager.onMagnifyingStateChanged = { [weak self] isMagnifying in
            guard let self = self else { return }
            self.isMagnifyingActive = isMagnifying
            self.updateStatusBarIcon()
        }
        
        // Setup halo state change handler for status bar icon
        haloManager.onHaloStateChanged = { [weak self] isHaloActive in
            guard let self = self else { return }
            self.isHaloActive = isHaloActive
            self.updateStatusBarIcon()
        }
        
        // Setup color picker state change handler for status bar icon
        colorPickerManager.onPickerStateChanged = { [weak self] isPicking in
            guard let self = self else { return }
            self.isColorPickerActive = isPicking
            self.updateStatusBarIcon()
        }
        
        // Setup screenshot state change handler for status bar icon
        screenshotManager.onScreenshotStateChanged = { [weak self] isAnnotating in
            guard let self = self else { return }
            self.isScreenshotActive = isAnnotating
            self.updateStatusBarIcon()
        }

        // Setup recording state change handler for status bar icon
        screenRecordingManager.onRecordingStateChanged = { [weak self] activity in
            guard let self = self else { return }
            self.recordingActivity = activity
            self.menuNeedsRebuild = true
            self.updateStatusBarIcon()
        }
        
        // Setup Cmd+W to close preferences window
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
                if self?.preferencesWindow?.isKeyWindow == true {
                    self?.preferencesWindow?.close()
                    self?.preferencesWindow = nil
                    return nil // Consume the event
                }
            }
            return event
        }
        
        // Update menu when clipboard changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardChanged),
            name: NSNotification.Name("ClipboardChanged"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        
        // Reload shortcuts when configured
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadShortcuts),
            name: NSNotification.Name("ReloadShortcuts"),
            object: nil
        )
        
        // Apply launch-at-login preference at startup.
        let launchOnLogin = UserDefaults.standard.bool(forKey: "launchOnLogin")
        try? LoginItemManager.setLaunchAtLogin(launchOnLogin)
        thumbnailCache.countLimit = 200
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024 // bound thumbnails to ~64MB of RAM
        lastThumbnailPrefsSignature = currentThumbnailPrefsSignature()
        prewarmRecentImageThumbnails()
        
        log("✅ Topkit started")
    }

    public func applicationDidResignActive(_ notification: Notification) {
        // Remember the app that became frontmost so we can reactivate it after a clipboard copy
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            applicationToActivateAfterCopy = front
        }
    }
    
    private func setupShortcuts() {
        // Global shortcuts now use Carbon RegisterEventHotKey (HotKeyManager), which
        // needs no Accessibility/Input Monitoring permission and is App Sandbox / Mac App
        // Store compatible. The system consumes registered combos for us.
        let bindings: [(key: String, action: () -> Void)] = [
            ("shortcutPickColor", { [weak self] in self?.pickColor() }),
            ("shortcutMagnifyingGlass", { [weak self] in self?.startMagnifyingGlass() }),
            ("shortcutAddGuide", { [weak self] in self?.annotateHorizontalGuide() }),
            ("shortcutAddVerticalGuide", { [weak self] in self?.annotateVerticalGuide() }),
            ("shortcutAddRectangle", { [weak self] in self?.annotateGrid() }),
            ("shortcutDraw", { [weak self] in self?.startDrawing() }),
            ("shortcutAnnotateRectangle", { [weak self] in self?.annotateRectangle() }),
            ("shortcutAnnotateCircle", { [weak self] in self?.annotateCircle() }),
            ("shortcutAnnotateArrow", { [weak self] in self?.annotateArrow() }),
            ("shortcutAnnotateText", { [weak self] in self?.annotateText() }),
            ("shortcutAnnotateRedact", { [weak self] in self?.annotateRedact() }),
            ("shortcutAnnotateSticker", { [weak self] in self?.annotateSticker() }),
            ("shortcutAnnotateBadge", { [weak self] in self?.annotateBadge() }),
            ("shortcutHalo", { [weak self] in self?.startHalo() }),
            ("shortcutMeasure", { [weak self] in self?.annotateMeasure() }),
            ("shortcutScreenshot", { [weak self] in self?.takeScreenshot() }),
            ("shortcutRecordScreen", { [weak self] in self?.toggleRecording() }),
            ("shortcutClearClipboard", { [weak self] in self?.clearClipboard() }),
            ("shortcutOpenPreferences", { [weak self] in self?.showPreferences() }),
            ("shortcutClipboardMenu", { [weak self] in self?.showInlineClipboardMenu() }),
        ]
        HotKeyManager.shared.reload(bindings: bindings)
        log("✅ Global shortcuts registered via Carbon hotkeys")
    }

    @objc func reloadShortcuts() {
        // Re-register hotkeys (HotKeyManager unregisters the old ones first).
        setupShortcuts()
    }

    @objc func clipboardChanged() {
        menuNeedsRebuild = true
        prewarmRecentImageThumbnails()
    }

    /// Preference values that affect cached thumbnails. `UserDefaults.didChangeNotification`
    /// fires on EVERY defaults write — including the history blob saved on each clipboard
    /// change — so the cache is only wiped when one of these actually changed, not on
    /// every copy (which used to re-decode up to 40 images per copy).
    private struct ThumbnailPrefsSignature: Equatable {
        let showImagePreview: Bool
        let width: Int
        let height: Int
    }

    private var lastThumbnailPrefsSignature: ThumbnailPrefsSignature?

    private func currentThumbnailPrefsSignature() -> ThumbnailPrefsSignature {
        let defaults = UserDefaults.standard
        let showImagePreview: Bool = {
            guard defaults.object(forKey: "showImagePreview") != nil else { return true }
            return defaults.bool(forKey: "showImagePreview")
        }()
        return ThumbnailPrefsSignature(
            showImagePreview: showImagePreview,
            width: defaults.integer(forKey: "imagePreviewWidth"),
            height: defaults.integer(forKey: "imagePreviewHeight")
        )
    }

    @objc private func userDefaultsDidChange() {
        menuNeedsRebuild = true
        let signature = currentThumbnailPrefsSignature()
        guard signature != lastThumbnailPrefsSignature else { return }
        lastThumbnailPrefsSignature = signature
        thumbnailCache.removeAllObjects()
        prewarmRecentImageThumbnails()
    }
    
    // MARK: - NSMenuDelegate
    
    public func menuWillOpen(_ menu: NSMenu) {
        if menu.identifier == Self.clipboardFolderMenuIdentifier {
            populateClipboardFolderMenu(menu)
            return
        }

        // (Return-key monitor is armed around the tracking session itself —
        // see runStatusMenuTrackingSession / presentMenuAtCursor.
        // menuWillOpen fires mid-tracking and supermenu state of a status
        // menu is not reliable, so installing here missed the first open.)
        menuCopyHandledThisSession = false

        // Remember which app was frontmost so we can reactivate it after a clipboard copy (so Cmd+V works there)
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            applicationToActivateAfterCopy = front
        }
        guard menu === statusMenu else { return }
        maybeRebuildStatusMenu(menu)
    }

    /// Keyboard navigation highlights view-backed items without drawing
    /// anything — mirror the highlight into the row views so arrow keys light
    /// clipboard rows up like native items.
    public func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            (menuItem.view as? ClipboardRowMenuView)?.isMenuHighlighted = (menuItem === item)
        }
        // AppKit never fires a view-backed item's action on Return, so Enter
        // is handled two ways: a keyDown monitor armed around the tracking
        // session, and — because key equivalents ARE documented to keep
        // working on view-backed items — the highlighted row temporarily
        // carries unmodified Return as its key equivalent. Views draw the
        // rows, so the equivalent never shows visually.
        if let item, item.view is ClipboardRowMenuView {
            menuHighlightedClipboardItem = item
            for menuItem in menu.items where menuItem.view is ClipboardRowMenuView {
                if menuItem === item {
                    menuItem.keyEquivalent = "\r"
                    menuItem.keyEquivalentModifierMask = []
                } else if !menuItem.keyEquivalent.isEmpty {
                    menuItem.keyEquivalent = ""
                }
            }
        } else if item != nil, menu.items.contains(where: { $0.view is ClipboardRowMenuView }) {
            // Highlight moved to a non-row item (folder, tool, …): forget the row.
            menuHighlightedClipboardItem = nil
            for menuItem in menu.items where menuItem.view is ClipboardRowMenuView && !menuItem.keyEquivalent.isEmpty {
                menuItem.keyEquivalent = ""
            }
        }
        // item == nil is NOT cleared: menu teardown fires willHighlight(nil)
        // right BEFORE menuDidClose (probe-verified), and the Return-close
        // fallback there needs the last highlighted row to still be known.
    }

    public func menuDidClose(_ menu: NSMenu) {
        // Strip the transient Return equivalents so nothing outlives the menu.
        for menuItem in menu.items where menuItem.view is ClipboardRowMenuView && !menuItem.keyEquivalent.isEmpty {
            menuItem.keyEquivalent = ""
        }
        if menu.identifier != Self.clipboardFolderMenuIdentifier {
            // Backstop for the row hover tooltip: rows drop it when they leave the
            // menu window, but nothing else guarantees the panel goes with a
            // dismissal. Not for folder submenus — those close while the parent menu
            // stays open, and would cancel the tooltip of the row moved back onto.
            AnnotationTooltip.shared.hide(for: nil)

            // Return-close fallback (probe-verified): AppKit dismisses the menu
            // on Return WITHOUT firing a view-backed item's action, and no key
            // routing (monitors, first responder, key equivalents) reliably
            // sees the event. But NSApp.currentEvent at this callout IS the
            // terminating Return, and the last highlighted row survived the
            // teardown willHighlight(nil) above — so complete the selection here.
            if !menuCopyHandledThisSession,
               let event = NSApp.currentEvent,
               event.type == .keyDown || event.type == .keyUp,
               event.keyCode == 36 || event.keyCode == 76, // Return / keypad Enter
               let item = menuHighlightedClipboardItem,
               let clipboardItem = item.representedObject as? ClipboardItem {
                performCopy(of: clipboardItem)
            }
        }
        guard menu === statusMenu else { return }
        // Give focus back to the app that had it before the menu activated
        // us, so a plain dismissal doesn't strand keyboard focus on Topkit.
        // When an item was picked, copyClipboardItem reactivates the same
        // app right after this, so the handoff stays consistent.
        restorePreviousAppFocus()
    }

    // MARK: - Return key on view-backed clipboard rows

    /// The clipboard row currently highlighted in whichever menu is open.
    private var menuHighlightedClipboardItem: NSMenuItem?
    private var menuReturnKeyMonitor: Any?
    /// True once a copy has been performed during the current menu session —
    /// keeps the Return-close fallback from double-copying when another path
    /// (click, search commit, row keyDown) already fired.
    private var menuCopyHandledThisSession = false

    /// Return on a highlighted clipboard row copies it. Needed because AppKit
    /// only fires a view-backed NSMenuItem's action from mouse tracking —
    /// keyboard Return silently does nothing (regression when the rows gained
    /// custom pin/search views). With no row highlighted the event passes
    /// through, so Enter in the focused search field still commits the top match.
    private func installMenuReturnKeyMonitor() {
        removeMenuReturnKeyMonitor()
        menuReturnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 36 || event.keyCode == 76, // Return / keypad Enter
                  let item = self.menuHighlightedClipboardItem,
                  let clipboardItem = item.representedObject as? ClipboardItem else { return event }
            var root = item.menu
            while let parent = root?.supermenu { root = parent }
            root?.cancelTracking()
            self.performCopy(of: clipboardItem)
            return nil
        }
    }

    private func removeMenuReturnKeyMonitor() {
        if let monitor = menuReturnKeyMonitor {
            NSEvent.removeMonitor(monitor)
            menuReturnKeyMonitor = nil
        }
    }

    /// Opens the status menu immediately. Do NOT call NSApp.activate here —
    /// activation mid-tracking cancels the session (flash shut), and waiting
    /// for a cooperative grant before open is what caused the 1s+ first-click
    /// delay / blink-reopen regression. Search caret is fixed in MenuSearchField
    /// (NSTextInsertionIndicator unsuppress), not by activating the app.
    /// Focus after copy still goes back via performCopy / restorePreviousAppFocus.
    @objc private func statusItemButtonClicked() {
        guard statusItem?.button != nil, statusMenu != nil else { return }
        runStatusMenuTrackingSession()
    }

    private func runStatusMenuTrackingSession() {
        guard let button = statusItem?.button, let statusMenu else { return }
        installMenuReturnKeyMonitor()
        statusItem.menu = statusMenu
        // Runs the menu tracking session; returns once the menu closes.
        button.performClick(nil)
        statusItem.menu = nil
        removeMenuReturnKeyMonitor()
        menuHighlightedClipboardItem = nil
    }

    private func restorePreviousAppFocus() {
        guard NSApp.isActive,
              let app = applicationToActivateAfterCopy,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.isFinishedLaunching else { return }
        app.activate(options: [])
    }

    private func maybeRebuildStatusMenu(_ menu: NSMenu) {
        let signature = currentMenuBuildSignature()
        if menuNeedsRebuild || signature != lastMenuBuildSignature {
            buildMenu(into: menu)
            lastMenuBuildSignature = signature
            menuNeedsRebuild = false
        }
    }

    private func currentMenuBuildSignature() -> MenuBuildSignature {
        let defaults = UserDefaults.standard
        let itemsInline = defaults.integer(forKey: "itemsInline")
        let inlineCount = itemsInline > 0 ? itemsInline : 10
        let itemsInFolder = defaults.integer(forKey: "itemsInFolder")
        let folderCount = itemsInFolder > 0 ? itemsInFolder : 50
        let historyCount = clipboardManager?.clipboardHistory.count ?? 0
        let showTooltip: Bool = {
            guard defaults.object(forKey: "showTooltip") != nil else { return true }
            return defaults.bool(forKey: "showTooltip")
        }()
        let showImagePreview: Bool = {
            guard defaults.object(forKey: "showImagePreview") != nil else { return true }
            return defaults.bool(forKey: "showImagePreview")
        }()

        return MenuBuildSignature(
            historyCount: historyCount,
            searchQuery: clipboardSearchQuery,
            inlineCount: inlineCount,
            folderCount: folderCount,
            isDrawingActive: AnnotateManager.shared.isActive,
            annotateArmedTool: AnnotateManager.shared.armedTool,
            isColorPickerActive: ColorPickerManager.shared.isPicking,
            isMagnifyingActive: MagnifyingGlassManager.shared.isMagnifying,
            isHaloActive: HaloManager.shared.isHaloActive,
            recordingActivity: ScreenRecordingManager.shared.activity.rawValue,
            showImagePreview: showImagePreview,
            previewWidth: defaults.integer(forKey: "imagePreviewWidth"),
            previewHeight: defaults.integer(forKey: "imagePreviewHeight"),
            markWithNumbers: defaults.bool(forKey: "markWithNumbers"),
            previewLength: max(defaults.integer(forKey: "charsInMenu"), 10),
            showTooltip: showTooltip,
            tooltipMaxLength: max(defaults.integer(forKey: "tooltipMaxLength"), 50),
            tooltipImageSize: defaults.integer(forKey: "tooltipImageSize")
        )
    }
    
    func buildMenu(into menu: NSMenu) {
        clipboardFolderRanges.removeAll()
        menu.removeAllItems()
        let defaults = UserDefaults.standard

        // Read preferences
        let itemsInline = defaults.integer(forKey: "itemsInline")
        let inlineCount = itemsInline > 0 ? itemsInline : 10
        let itemsInFolder = defaults.integer(forKey: "itemsInFolder")
        let folderCount = itemsInFolder > 0 ? itemsInFolder : 50

        // Search field above the clipboard history
        menu.addItem(makeSearchMenuItem(for: menu))

        // Clipboard History Section
        let sectionItems = clipboardSectionItems(inlineCount: inlineCount, folderCount: folderCount)
        sectionItems.forEach { menu.addItem($0) }
        clipboardSectionCounts[ObjectIdentifier(menu)] = sectionItems.count

        menu.addItem(NSMenuItem.separator())

        // Tool order below is kept consistent with the Shortcuts preferences list:
        // Screenshot, Record, Pick Color, Magnify, Halo, Annotate (last).

        // Screenshot
        menu.addItem(createMenuItemWithShortcut(
            title: "Screenshot",
            action: #selector(takeScreenshot),
            shortcutKey: "shortcutScreenshot"
        ))

        // Record Screen / Stop Recording. While recording this item IS the
        // stop control (no on-screen bar), drawn in red.
        let recordingActivity = ScreenRecordingManager.shared.activity
        let recordTitle: String
        switch recordingActivity {
        case .idle: recordTitle = String(localized: "Record Screen")
        case .selecting: recordTitle = String(localized: "Cancel Recording")
        case .recording: recordTitle = String(localized: "Stop Recording")
        }
        let recordItem = createMenuItemWithShortcut(
            title: recordTitle,
            action: #selector(toggleRecording),
            shortcutKey: "shortcutRecordScreen"
        )
        if recordingActivity == .recording {
            recordItem.attributedTitle = NSAttributedString(
                string: recordTitle,
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.menuFont(ofSize: 0),
                ]
            )
        }
        menu.addItem(recordItem)

        // Color Picker
        let isColorPickerActive = ColorPickerManager.shared.isPicking
        menu.addItem(createMenuItemWithShortcut(
            title: isColorPickerActive ? String(localized: "End Pick Color") : String(localized: "Pick Color"),
            action: #selector(pickColor),
            shortcutKey: "shortcutPickColor"
        ))

        // Annotate submenu (was the top-level Draw item; same position in the order)
        let annotateActive = AnnotateManager.shared.isActive
        let annotateMenu = NSMenu()
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Freehand", action: #selector(startDrawing), shortcutKey: "shortcutDraw"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Rectangle", action: #selector(annotateRectangle), shortcutKey: "shortcutAnnotateRectangle"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Circle", action: #selector(annotateCircle), shortcutKey: "shortcutAnnotateCircle"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Arrow", action: #selector(annotateArrow), shortcutKey: "shortcutAnnotateArrow"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Text", action: #selector(annotateText), shortcutKey: "shortcutAnnotateText"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Redact", action: #selector(annotateRedact), shortcutKey: "shortcutAnnotateRedact"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Sticker", action: #selector(annotateSticker), shortcutKey: "shortcutAnnotateSticker"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Numbered Badge", action: #selector(annotateBadge), shortcutKey: "shortcutAnnotateBadge"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Measure", action: #selector(annotateMeasure), shortcutKey: "shortcutMeasure"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Vertical Guide", action: #selector(annotateVerticalGuide), shortcutKey: "shortcutAddVerticalGuide"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Horizontal Guide", action: #selector(annotateHorizontalGuide), shortcutKey: "shortcutAddGuide"))
        annotateMenu.addItem(createMenuItemWithShortcut(
            title: "Grid", action: #selector(annotateGrid), shortcutKey: "shortcutAddRectangle"))

        // Tick whichever tool is armed, so the menu reflects the live session.
        if annotateActive, let armed = AnnotateManager.shared.armedTool {
            for item in annotateMenu.items where AppDelegate.annotateTool(forMenuTitle: item.title) == armed {
                item.state = .on
            }
        }

        // Annotate is now the last tool, so build the item here but add it after Halo.
        let annotateItem = NSMenuItem(title: "Annotate", action: nil, keyEquivalent: "")
        annotateItem.submenu = annotateMenu

        // Magnify
        let isMagnifyingActive = MagnifyingGlassManager.shared.isMagnifying
        menu.addItem(createMenuItemWithShortcut(
            title: isMagnifyingActive ? "End Magnify" : "Magnify",
            action: #selector(startMagnifyingGlass),
            shortcutKey: "shortcutMagnifyingGlass"
        ))

        // Halo
        let isHaloActive = HaloManager.shared.isHaloActive
        menu.addItem(createMenuItemWithShortcut(
            title: isHaloActive ? "End Halo" : "Halo",
            action: #selector(startHalo),
            shortcutKey: "shortcutHalo"
        ))

        // Annotate is the last tool. Measure and the guides (Vertical Guide,
        // Horizontal Guide, Grid) now live inside its submenu.
        menu.addItem(annotateItem)

        // Ending the session sits beside Annotate rather than inside it: the other
        // tools swap their own title to "End X", which a submenu parent cannot do
        // while it still has to offer the tool list.
        if annotateActive {
            let end = NSMenuItem(title: "End Annotate", action: #selector(endAnnotate), keyEquivalent: "")
            end.target = self
            menu.addItem(end)
        }

        menu.addItem(NSMenuItem.separator())

        // Clear Clipboard - only show if clipboard history is not empty
        let history = clipboardManager?.clipboardHistory ?? []
        if !history.isEmpty {
            menu.addItem(createMenuItemWithShortcut(
                title: "Clear Clipboard",
                action: #selector(clearClipboard),
                shortcutKey: "shortcutClearClipboard"
            ))
        }

        // Preferences
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ""))

        // Quit
        menu.addItem(NSMenuItem(title: "Quit Topkit", action: #selector(quit), keyEquivalent: ""))
    }

    /// The clipboard rows for the current search query: the normal
    /// inline + folder layout when the query is empty, or a flat list ranked
    /// by fuzzy-match score when the user is searching (folders disappear and
    /// the whole history is searched, not just the inline items).
    private func clipboardSectionItems(inlineCount: Int, folderCount: Int) -> [NSMenuItem] {
        let history = clipboardManager?.clipboardHistory ?? []

        if history.isEmpty {
            let emptyItem = NSMenuItem(title: "No clipboard history", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            return [emptyItem]
        }

        let query = clipboardSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let matches = ClipboardSearchFilter.matches(history: history, query: query)
            guard !matches.isEmpty else {
                let noMatches = NSMenuItem(title: "No matches", action: nil, keyEquivalent: "")
                noMatches.isEnabled = false
                return [noMatches]
            }
            // Numbers stay the item's position in the full history, so a
            // filtered row shows the same number it has unfiltered.
            return matches.map { createClipboardMenuItem(item: history[$0.historyIndex], number: $0.historyIndex + 1) }
        }

        var items: [NSMenuItem] = []

        // First N items at root level.
        for (index, item) in history.prefix(inlineCount).enumerated() {
            items.append(createClipboardMenuItem(item: item, number: index + 1))
        }

        // Remaining items in folders.
        var offset = inlineCount
        while offset < history.count {
            let endIndex = min(offset + folderCount, history.count)
            let folderItem = NSMenuItem(title: "\(offset + 1) - \(endIndex)", action: nil, keyEquivalent: "")
            let folderMenu = NSMenu()
            folderMenu.identifier = Self.clipboardFolderMenuIdentifier
            folderMenu.delegate = self
            clipboardFolderRanges[ObjectIdentifier(folderMenu)] = ClipboardFolderRange(start: offset, endExclusive: endIndex)
            folderItem.submenu = folderMenu
            items.append(folderItem)

            offset += folderCount
        }
        return items
    }

    /// The search NSMenuItem (custom view). One per menu build; both menus
    /// share `clipboardSearchQuery`, so a query typed in one surface is
    /// pre-filled in the other.
    private func makeSearchMenuItem(for menu: NSMenu) -> NSMenuItem {
        let view = ClipboardSearchMenuView(initialQuery: clipboardSearchQuery)
        view.onQueryChanged = { [weak self, weak menu] query in
            guard let self, let menu else { return }
            self.clipboardSearchQuery = query
            self.refilterClipboardSection(in: menu)
        }
        view.onCommit = { [weak self, weak menu] in
            guard let self, let menu else { return }
            self.commitTopSearchMatch(closing: menu)
        }
        let item = NSMenuItem()
        item.view = view
        return item
    }

    /// Splices the clipboard section (rows after the search field at index 0)
    /// in place while the menu is open — NSMenu supports live mutation.
    private func refilterClipboardSection(in menu: NSMenu) {
        guard let count = clipboardSectionCounts[ObjectIdentifier(menu)] else { return }
        let sectionStart = 1 // search field sits at index 0
        guard menu.numberOfItems >= sectionStart + count else { return }

        let defaults = UserDefaults.standard
        let itemsInline = defaults.integer(forKey: "itemsInline")
        let itemsInFolder = defaults.integer(forKey: "itemsInFolder")
        let newItems = clipboardSectionItems(
            inlineCount: itemsInline > 0 ? itemsInline : 10,
            folderCount: itemsInFolder > 0 ? itemsInFolder : 50
        )

        for _ in 0..<count {
            menu.removeItem(at: sectionStart)
        }
        for (offset, item) in newItems.enumerated() {
            menu.insertItem(item, at: sectionStart + offset)
        }
        clipboardSectionCounts[ObjectIdentifier(menu)] = newItems.count
    }

    /// Enter in the search field: copy the best match and dismiss the menu.
    private func commitTopSearchMatch(closing menu: NSMenu) {
        let query = clipboardSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let history = clipboardManager?.clipboardHistory ?? []
        guard let top = ClipboardSearchFilter.matches(history: history, query: query).first else { return }
        menu.cancelTracking()
        performCopy(of: history[top.historyIndex])
    }

    private func populateClipboardFolderMenu(_ menu: NSMenu) {
        guard let range = clipboardFolderRanges[ObjectIdentifier(menu)] else { return }
        let history = clipboardManager?.clipboardHistory ?? []
        let clampedStart = min(max(range.start, 0), history.count)
        let clampedEnd = min(max(range.endExclusive, clampedStart), history.count)

        menu.removeAllItems()
        guard clampedStart < clampedEnd else {
            let empty = NSMenuItem(title: "No items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for (index, item) in history[clampedStart..<clampedEnd].enumerated() {
            let menuItem = createClipboardMenuItem(item: item, number: clampedStart + index + 1)
            menu.addItem(menuItem)
        }
    }

    @objc private func showInlineClipboardMenu() {
        // Clipboard history menu, popped up at the mouse pointer. No accessibility / AX:
        // the menu always shows at NSEvent.mouseLocation.
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if let front = frontmostApp,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            applicationToActivateAfterCopy = front
        }

        let defaults = UserDefaults.standard
        let itemsInline = defaults.integer(forKey: "itemsInline")
        let inlineCount = itemsInline > 0 ? itemsInline : 10
        let itemsInFolder = defaults.integer(forKey: "itemsInFolder")
        let folderCount = itemsInFolder > 0 ? itemsInFolder : 50

        let menu = NSMenu()
        // Delegate wired for menu(_:willHighlight:) so keyboard navigation
        // lights up the custom clipboard rows; the other delegate callbacks
        // guard on statusMenu/folder identity and ignore this menu.
        menu.delegate = self
        menu.addItem(makeSearchMenuItem(for: menu))
        let sectionItems = clipboardSectionItems(inlineCount: inlineCount, folderCount: folderCount)
        sectionItems.forEach { menu.addItem($0) }
        clipboardSectionCounts[ObjectIdentifier(menu)] = sectionItems.count

        presentMenuAtCursor(menu)
    }

    /// Pops `menu` up at the cursor immediately. Same rule as the status item:
    /// never activate-before-track — that race is what flashes the menu shut
    /// or stalls the first open. Caret drawing is handled by MenuSearchField.
    private func presentMenuAtCursor(_ menu: NSMenu) {
        let location = NSEvent.mouseLocation
        // popUp blocks until the menu is dismissed; the menu object is
        // transient, so drop its section bookkeeping afterwards.
        installMenuReturnKeyMonitor()
        menu.popUp(positioning: nil, at: location, in: nil)
        removeMenuReturnKeyMonitor()
        menuHighlightedClipboardItem = nil
        clipboardSectionCounts.removeValue(forKey: ObjectIdentifier(menu))
        restorePreviousAppFocus()
    }

    private struct ClipboardRowContent {
        let title: String
        let image: NSImage?
        let toolTip: String?
        /// Deferred: see `ClipboardRowMenuView.tooltipImageProvider`.
        let tooltipImageProvider: (() -> NSImage?)?
    }

    /// Hover text for a text row. The row title flattens newlines to spaces; the tooltip
    /// keeps them — that's what it is for — but a block copied with blank lines around it
    /// opened a mostly-empty panel, so the ends are trimmed and runs of blank lines
    /// collapse to one. Truncation comes last so the limit is spent on real content.
    static func tooltipText(from content: String, maxLength: Int) -> String {
        var lines: [String] = []
        var pendingBlank = false
        for line in content.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Never open with a blank line; a trailing run is simply never flushed.
                pendingBlank = !lines.isEmpty
                continue
            }
            if pendingBlank { lines.append("") }
            pendingBlank = false
            lines.append(line)
        }
        return String(lines.joined(separator: "\n").prefix(maxLength))
    }

    private func clipboardRowContent(for item: ClipboardItem, number: Int) -> ClipboardRowContent {
        let defaults = UserDefaults.standard
        let markWithNumbers = defaults.bool(forKey: "markWithNumbers")
        let previewLength = max(defaults.integer(forKey: "charsInMenu"), 10)
        let showTooltip: Bool = {
            guard defaults.object(forKey: "showTooltip") != nil else { return true }
            return defaults.bool(forKey: "showTooltip")
        }()
        let maxTooltip = max(defaults.integer(forKey: "tooltipMaxLength"), 50)
        let tooltipImageSize = CGFloat(min(max(defaults.integer(forKey: "tooltipImageSize"), 40), 600))
        let showImagePreview: Bool = {
            guard defaults.object(forKey: "showImagePreview") != nil else { return true }
            return defaults.bool(forKey: "showImagePreview")
        }()
        let rawWidth = defaults.integer(forKey: "imagePreviewWidth")
        let rawHeight = defaults.integer(forKey: "imagePreviewHeight")
        let imgWidth = CGFloat(min(max(rawWidth, 1), 360))
        let imgHeight = CGFloat(min(max(rawHeight, 1), 360))

        var title = ""
        if markWithNumbers { title = "\(number). " }
        switch item.type {
        case .image:
            title += "Image"
        case .file:
            title += String(item.content.prefix(previewLength)) + (item.content.count > previewLength ? "..." : "")
        case .text:
            let cleaned = item.content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let preview = String(cleaned.prefix(previewLength))
            title += preview.isEmpty ? "(empty)" : preview + (cleaned.count > previewLength ? "..." : "")
        }

        var toolTip: String?
        var tooltipImageProvider: (() -> NSImage?)?
        if showTooltip {
            switch item.type {
            case .text:
                toolTip = Self.tooltipText(from: item.content, maxLength: maxTooltip)
            case .image:
                // Deliberately larger than the row's own thumbnail — the point of the
                // hover preview is to see the image without opening it. Decoded on
                // hover, not here: this runs for every row in the menu.
                tooltipImageProvider = { [weak self] in
                    self?.cachedTooltipImage(for: item, maxDimension: tooltipImageSize)
                }
            case .file:
                break
            }
        }

        var image: NSImage?
        if item.type == .image && showImagePreview {
            let size = NSSize(width: imgWidth, height: imgHeight)
            image = cachedThumbnail(for: item, targetSize: size)
        } else if item.type == .text, let color = parseHexColor(item.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let swatchSize: CGFloat = 14
            let swatch = NSImage(size: NSSize(width: swatchSize, height: swatchSize))
            swatch.lockFocus()
            color.setFill()
            let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: swatchSize, height: swatchSize), xRadius: 3, yRadius: 3)
            path.fill()
            NSColor.white.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 1
            path.stroke()
            swatch.unlockFocus()
            image = swatch
        }

        return ClipboardRowContent(title: title, image: image, toolTip: toolTip, tooltipImageProvider: tooltipImageProvider)
    }

    func createClipboardMenuItem(item: ClipboardItem, number: Int) -> NSMenuItem {
        let content = clipboardRowContent(for: item, number: number)

        // Title/image/action stay on the NSMenuItem even though the custom view
        // draws the row: keyboard Return still fires the action, and type-select
        // and accessibility keep working off the title.
        let menuItem = NSMenuItem(title: content.title, action: #selector(copyClipboardItem(_:)), keyEquivalent: "")
        menuItem.representedObject = item
        menuItem.target = self
        menuItem.toolTip = content.toolTip
        menuItem.image = content.image

        let view = ClipboardRowMenuView()
        view.configure(
            title: content.title,
            image: content.image,
            isPinned: item.isPinned == true,
            toolTip: content.toolTip,
            tooltipImageProvider: content.tooltipImageProvider
        )
        view.onSelect = { [weak self, weak menuItem] in
            guard let self, let menuItem,
                  let current = menuItem.representedObject as? ClipboardItem else { return }
            // Dismiss the whole tree (folder rows live in submenus), then copy —
            // same order commitTopSearchMatch uses.
            var root = menuItem.menu
            while let parent = root?.supermenu { root = parent }
            root?.cancelTracking()
            self.performCopy(of: current)
        }
        view.onTogglePin = { [weak self, weak menuItem] in
            guard let self, let menuItem,
                  let current = menuItem.representedObject as? ClipboardItem else { return }
            self.togglePin(of: current, rowMenu: menuItem.menu)
        }
        menuItem.view = view
        return menuItem
    }

    // MARK: - Pinning

    /// Toggles the pin on `item` and refreshes the open menu in place so the
    /// row jumps to (or back from) the top without closing the menu.
    private func togglePin(of item: ClipboardItem, rowMenu: NSMenu?) {
        clipboardManager?.togglePin(itemID: item.id)
        guard let rowMenu else { return }
        var root = rowMenu
        while let parent = root.supermenu { root = parent }

        // Defer the menu refresh out of the pin button's action callout: a
        // resplice releases the clicked row's view while NSControl mouse
        // tracking is still unwinding on that view's stack frame. GCD main
        // queue doesn't drain during menu tracking, so schedule on the run
        // loop in .eventTracking (the menu session's mode) instead.
        RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
            guard let self else { return }
            if rowMenu === root {
                // No submenu is open (hovering a root row closes any folder), so
                // the section can be respliced — this also gets row heights right
                // when image rows move around. Proven live-mutation path (search
                // typing does the same).
                self.refilterClipboardSection(in: root)
            } else {
                // Pin toggled inside a folder submenu: resplicing the root would
                // destroy the folder item mid-tracking and slam the menu shut, so
                // reassign existing rows in place instead (positional ranges are
                // unchanged — only contents shift).
                self.reassignClipboardRows(inRoot: root)
                self.reassignFolderRows(in: rowMenu)
            }
        }
    }

    /// The (item, displayed number) pairs the root menu's clipboard rows should
    /// currently show, mirroring clipboardSectionItems' ordering rules.
    private func clipboardRowAssignments() -> [(item: ClipboardItem, number: Int)] {
        let history = clipboardManager?.clipboardHistory ?? []
        let query = clipboardSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return ClipboardSearchFilter.matches(history: history, query: query)
                .map { (history[$0.historyIndex], $0.historyIndex + 1) }
        }
        let itemsInline = UserDefaults.standard.integer(forKey: "itemsInline")
        let inlineCount = itemsInline > 0 ? itemsInline : 10
        return history.prefix(inlineCount).enumerated().map { ($1, $0 + 1) }
    }

    /// Rewrites the root menu's clipboard rows in place after a pin toggle.
    private func reassignClipboardRows(inRoot menu: NSMenu) {
        guard let count = clipboardSectionCounts[ObjectIdentifier(menu)],
              menu.numberOfItems >= 1 + count else { return }
        let rowItems = (1..<1 + count).compactMap { menu.item(at: $0) }.filter { $0.view is ClipboardRowMenuView }
        let assignments = clipboardRowAssignments()
        guard rowItems.count == assignments.count else {
            // Row set changed shape (possible under an all-digits ordinal query);
            // fall back to a full resplice — search mode has no open submenus.
            refilterClipboardSection(in: menu)
            return
        }
        for (menuItem, assignment) in zip(rowItems, assignments) {
            applyRowContent(to: menuItem, item: assignment.item, number: assignment.number)
        }
    }

    /// Rewrites an open folder submenu's rows in place after a pin toggle.
    private func reassignFolderRows(in menu: NSMenu) {
        guard let range = clipboardFolderRanges[ObjectIdentifier(menu)] else { return }
        let history = clipboardManager?.clipboardHistory ?? []
        let start = min(max(range.start, 0), history.count)
        let end = min(max(range.endExclusive, start), history.count)
        let rowItems = menu.items.filter { $0.view is ClipboardRowMenuView }
        let assignments = history[start..<end].enumerated().map { (item: $1, number: start + $0 + 1) }
        guard rowItems.count == assignments.count else {
            populateClipboardFolderMenu(menu)
            return
        }
        for (menuItem, assignment) in zip(rowItems, assignments) {
            applyRowContent(to: menuItem, item: assignment.item, number: assignment.number)
        }
    }

    private func applyRowContent(to menuItem: NSMenuItem, item: ClipboardItem, number: Int) {
        let content = clipboardRowContent(for: item, number: number)
        menuItem.title = content.title
        menuItem.representedObject = item
        menuItem.toolTip = content.toolTip
        menuItem.image = content.image
        (menuItem.view as? ClipboardRowMenuView)?.configure(
            title: content.title,
            image: content.image,
            isPinned: item.isPinned == true,
            toolTip: content.toolTip,
            tooltipImageProvider: content.tooltipImageProvider
        )
    }

    private func cachedThumbnail(for item: ClipboardItem, targetSize: NSSize) -> NSImage? {
        let key = "\(item.id.uuidString):\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
        if let existing = thumbnailCache.object(forKey: key) {
            return existing
        }
        guard let imageData = item.imageData ?? clipboardManager?.fullImageData(for: item) else { return nil }
        let thumbnail = makeThumbnail(imageData: imageData, targetSize: targetSize)
        if let thumbnail {
            thumbnailCache.setObject(thumbnail, forKey: key, cost: thumbnailCost(targetSize: targetSize))
        }
        return thumbnail
    }

    /// Aspect-FIT hover preview, cached separately from the row thumbnails (those are
    /// aspect-fill crops at a different size).
    private func cachedTooltipImage(for item: ClipboardItem, maxDimension: CGFloat) -> NSImage? {
        let key = "\(item.id.uuidString):tip\(Int(maxDimension))" as NSString
        if let existing = thumbnailCache.object(forKey: key) {
            return existing
        }
        guard let imageData = item.imageData ?? clipboardManager?.fullImageData(for: item) else { return nil }
        guard let preview = ImageHelpers.aspectFitThumbnail(from: imageData, maxDimension: maxDimension) else {
            return nil
        }
        thumbnailCache.setObject(
            preview,
            forKey: key,
            cost: thumbnailCost(targetSize: NSSize(width: maxDimension, height: maxDimension))
        )
        return preview
    }

    private func makeThumbnail(imageData: Data, targetSize: NSSize) -> NSImage? {
        // Downsample straight from the encoded bytes so a hi-res screenshot never gets fully
        // decoded into RAM just to produce a small preview.
        ImageHelpers.aspectFillThumbnail(from: imageData, targetSize: targetSize)
    }

    /// Approximate RAM cost of a cached thumbnail (Retina rep = target size at 2x, RGBA).
    private func thumbnailCost(targetSize: NSSize, scale: CGFloat = 2.0) -> Int {
        Int(targetSize.width * scale) * Int(targetSize.height * scale) * 4
    }

    private func prewarmRecentImageThumbnails() {
        let defaults = UserDefaults.standard
        let showImagePreview: Bool = {
            guard defaults.object(forKey: "showImagePreview") != nil else { return true }
            return defaults.bool(forKey: "showImagePreview")
        }()
        guard showImagePreview else { return }

        let rawWidth = defaults.integer(forKey: "imagePreviewWidth")
        let rawHeight = defaults.integer(forKey: "imagePreviewHeight")
        let size = NSSize(width: CGFloat(min(max(rawWidth, 1), 360)), height: CGFloat(min(max(rawHeight, 1), 360)))
        let history = clipboardManager?.clipboardHistory ?? []
        let itemsToPrefetch = history
            .filter { $0.type == .image }
            .prefix(thumbnailPrefetchCount)
            .map { $0 }
        guard !itemsToPrefetch.isEmpty else { return }

        thumbnailPrefetchQueue.async { [weak self] in
            guard let self else { return }
            var results: [(NSString, NSImage)] = []
            results.reserveCapacity(itemsToPrefetch.count)
            for item in itemsToPrefetch {
                let key = "\(item.id.uuidString):\(Int(size.width))x\(Int(size.height))" as NSString
                if self.thumbnailCache.object(forKey: key) != nil { continue }
                // Full-res bytes are read from disk here transiently and released after thumbnailing.
                guard let data = self.clipboardManager?.fullImageData(for: item) else { continue }
                if let thumb = self.makeThumbnail(imageData: data, targetSize: size) {
                    results.append((key, thumb))
                }
            }
            guard !results.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let cost = self.thumbnailCost(targetSize: size)
                for (key, image) in results {
                    self.thumbnailCache.setObject(image, forKey: key, cost: cost)
                }
            }
        }
    }

    /// Parses a hex color string like "#FF0000", "#F00", "FF0000", or "F00"
    private func parseHexColor(_ string: String) -> NSColor? {
        HexColorParser.parse(string)
    }
    
    @objc func copyClipboardItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? ClipboardItem else { return }
        performCopy(of: item)
    }

    private func performCopy(of item: ClipboardItem) {
        menuCopyHandledThisSession = true
        clipboardManager?.copyToClipboard(item)

        // Picking an item resets the search; a plain dismissal keeps it.
        clipboardSearchQuery = ""
        menuNeedsRebuild = true

        // Reactivate the app that was frontmost when the menu opened so the user can paste
        // straight back into it. This is independent of auto-paste and ships in every build.
        var reactivatedApp: NSRunningApplication?
        if let app = applicationToActivateAfterCopy,
           app.bundleIdentifier != Bundle.main.bundleIdentifier,
           app.isFinishedLaunching {
            app.activate(options: [])
            reactivatedApp = app
        }

#if ALLOW_AUTOPASTE
        // Synthetic ⌘V auto-paste. Compiled into EVERY build, including the sandboxed Mac App
        // Store build (`ALLOW_AUTOPASTE` is set in all app configs in project.pbxproj). Uses the
        // PostEvent TCC service (sandbox-compatible, distinct from the AX API). See
        // APP_STORE_REVIEW_NOTES.md / Guideline 2.4.5 for the justification.
        if UserDefaults.standard.bool(forKey: "inputCmdV") {
            simulateCmdV(afterDelay: reactivatedApp != nil ? 0.2 : 0.15)
        }
#else
        _ = reactivatedApp
#endif
    }

#if ALLOW_AUTOPASTE
    /// Posts a synthetic Cmd+V to the frontmost app so the just-copied item pastes
    /// immediately. Requires PostEvent permission (requested when the user enables the
    /// auto-paste toggle). Silently no-ops if access was never granted or was revoked in
    /// System Settings while the app is running, so the item is still copied either way.
    private func simulateCmdV(afterDelay delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Do NOT gate on CGPreflightPostEventAccess(): it returns a stale `false` right
            // after the user grants access (until the app relaunches), which would silently
            // skip the paste even though the post itself would succeed. The window server
            // enforces the permission at post time, and a post without access is a harmless
            // no-op — so just attempt it. The toggle being on is the user's opt-in.
            guard let src = CGEventSource(stateID: .hidSystemState) else {
                debugLog("⌘V auto-paste: failed to create event source")
                return
            }
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            debugLog("⌘V auto-paste posted (preflight reported \(CGPreflightPostEventAccess()))")
        }
    }
#endif
    
    @objc func clearClipboard() {
        // Check if we should show alert before clearing
        let showAlert = UserDefaults.standard.bool(forKey: "showClearAlert")
        
        if showAlert {
            let alert = NSAlert()
            alert.messageText = "Clear Clipboard History"
            alert.informativeText = "Are you sure you want to clear all clipboard history? This cannot be undone."
            alert.alertStyle = .critical
            // Add buttons in macOS standard order: Cancel (left), Destructive action (right)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Clear")
            // Mark the Clear button as destructive (appears with red styling)
            if let clearButton = alert.buttons.last {
                clearButton.hasDestructiveAction = true
            }
            
            // .alertFirstButtonReturn is Cancel, .alertSecondButtonReturn is Clear
            if alert.runModal() != .alertSecondButtonReturn {
                return
            }
        }
        
        clipboardManager?.clearHistory()
        // Menu will rebuild automatically when next opened
    }
    
    @objc func pickColor() {
        colorPickerManager?.pickColor()
    }
    
    @objc func startMagnifyingGlass() {
        magnifyingGlassManager?.startMagnifyingGlass()
    }
    
    @objc func startDrawing() {
        annotate(with: .freehand)
    }

    /// Single entry point for every annotate tool, from both the hotkeys and the
    /// Annotate submenu.
    ///
    /// A screenshot editor on screen wins: the same key that arms Rectangle on the
    /// desktop arms Rectangle on the region the user just picked, instead of stacking
    /// the standalone overlay on top of it.
    private func annotate(with tool: AnnotationTool) {
        if ScreenshotManager.shared.armAnnotationToolFromShortcut(tool) { return }
        AnnotateManager.shared.toggle(tool: tool)
    }

    /// Maps an Annotate submenu title back to its tool, for the armed-tool tick.
    /// Kept beside the menu builder so adding a tool in one place fails loudly here.
    static func annotateTool(forMenuTitle title: String) -> AnnotationTool? {
        switch title {
        case "Freehand":       return .freehand
        case "Rectangle":      return .rectangle
        case "Circle":         return .circle
        case "Arrow":          return .arrow
        case "Text":           return .text
        case "Redact":         return .blur
        case "Sticker":        return .sticker(.redX)
        case "Numbered Badge": return .numberBadge
        case "Measure":        return .measure
        case "Vertical Guide":   return .guide(.vertical)
        case "Horizontal Guide": return .guide(.horizontal)
        case "Grid":           return .grid
        default:               return nil
        }
    }

    @objc func annotateRectangle() { annotate(with: .rectangle) }
    @objc func annotateCircle()    { annotate(with: .circle) }
    @objc func annotateArrow()     { annotate(with: .arrow) }
    @objc func annotateText()      { annotate(with: .text) }
    @objc func annotateRedact()    { annotate(with: .blur) }
    @objc func annotateSticker()   { annotate(with: .sticker(.redX)) }
    @objc func annotateBadge()     { annotate(with: .numberBadge) }
    @objc func annotateMeasure()   { annotate(with: .measure) }
    @objc func annotateVerticalGuide()   { annotate(with: .guide(.vertical)) }
    @objc func annotateHorizontalGuide() { annotate(with: .guide(.horizontal)) }
    @objc func annotateGrid()      { annotate(with: .grid) }
    @objc func endAnnotate()       { AnnotateManager.shared.stop() }

    @objc func startHalo() {
        haloManager?.startHalo()
    }

    @objc func takeScreenshot() {
        screenshotManager?.takeScreenshot()
    }

    @objc func toggleRecording() {
        screenRecordingManager?.toggle()
    }
    
    private func createMenuItemWithShortcut(title: String, action: Selector, shortcutKey: String) -> NSMenuItem {
        let shortcutString = UserDefaults.standard.string(forKey: shortcutKey) ?? ""
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        
        if !shortcutString.isEmpty {
            let parsed = ShortcutKeyParser.parse(shortcutString: shortcutString)
            if let keyEquivalent = parsed.keyEquivalent {
                menuItem.keyEquivalent = keyEquivalent
                menuItem.keyEquivalentModifierMask = parsed.modifiers
            }
        }
        
        return menuItem
    }
    
    private var isDrawingActive = false
    private var isMagnifyingActive = false
    private var isHaloActive = false
    private var isColorPickerActive = false
    private var isScreenshotActive = false
    private var recordingActivity: ScreenRecordingManager.Activity = .idle
    
    /// Plain template glyph centred in a 22pt canvas, used while idle. Sharing the
    /// canvas size with the active badge keeps vertical positioning identical.
    private static func menuBarIdleImage(glyphSize: NSSize) -> NSImage? {
        let size = NSSize(width: 22, height: 22)
        guard let source = NSImage(named: "MenuBarIcon") else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            // Nudge up: origin is bottom-left, so a positive offset raises the glyph.
            let verticalOffset: CGFloat = 1.5
            let drawRect = NSRect(
                x: (size.width - glyphSize.width) / 2,
                y: (size.height - glyphSize.height) / 2 + verticalOffset,
                width: glyphSize.width,
                height: glyphSize.height
            )
            source.draw(in: drawRect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// White rounded-square badge + black tool glyph, used while a tool is active.
    private static func menuBarActiveImage(iconSize: NSSize) -> NSImage? {
        let size = NSSize(width: 22, height: 22)
        guard let source = NSImage(named: "MenuBarIcon") else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
            let tinted = NSImage(size: iconSize, flipped: false) { tintRect in
                source.draw(in: tintRect)
                NSColor.black.set()
                tintRect.fill(using: .sourceAtop)
                return true
            }
            let drawRect = NSRect(
                x: (size.width - iconSize.width) / 2,
                y: (size.height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            tinted.draw(in: drawRect)
            return true
        }
    }

    /// Red rounded-square badge + white glyph, used while screen recording.
    private static func menuBarRecordingImage(iconSize: NSSize) -> NSImage? {
        let size = NSSize(width: 22, height: 22)
        guard let source = NSImage(named: "MenuBarIcon") else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
            let tinted = NSImage(size: iconSize, flipped: false) { tintRect in
                source.draw(in: tintRect)
                NSColor.white.set()
                tintRect.fill(using: .sourceAtop)
                return true
            }
            let drawRect = NSRect(
                x: (size.width - iconSize.width) / 2,
                y: (size.height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            tinted.draw(in: drawRect)
            return true
        }
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem.button else { return }
        let iconSize = NSSize(width: 16, height: 16)

        if recordingActivity == .recording {
            // Recording wins over everything: red badge, white glyph.
            button.image = Self.menuBarRecordingImage(iconSize: iconSize)
        } else if isDrawingActive || isMagnifyingActive || isHaloActive
                    || isColorPickerActive || isScreenshotActive || recordingActivity == .selecting {
            // Active (incl. drawing the recording hole): white rounded-square
            // badge with black tool glyph.
            button.image = Self.menuBarActiveImage(iconSize: iconSize)
        } else {
            // Idle: plain template glyph, no background. The system draws the standard
            // square highlight when the menu is open, matching the other menu bar items.
            // Draw centred into the same 22pt canvas as the active badge so vertical
            // position stays consistent regardless of glyph size.
            let glyphSize = NSSize(width: 18, height: 18)
            button.image = Self.menuBarIdleImage(glyphSize: glyphSize)
        }
    }
    
    /// Order out the preferences window so tool overlays are created in the user's current space instead of the space where prefs is open.
    func orderOutPreferencesWindowForToolOverlay() {
        preferencesWindow?.orderOut(nil)
    }
    
    @objc func showPreferences() {
        // If prefs is open in another Space, close it so we create a new window in the current Space
        if let existingWindow = preferencesWindow {
            existingWindow.close()
            // preferencesWindow is replaced below; old window's windowWillClose won't clear it
        }
        
        let window = PreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.contentView = NSHostingView(rootView: PreferencesView())
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        preferencesWindow = window
        // While Preferences is visible, behave like a normal app so permission prompts can appear.
        pushRegularActivation()
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
    
    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === preferencesWindow {
            // Close color picker (and any other pickers) so they aren't left open when prefs close
            NSColorPanel.shared.orderOut(nil)
            NSFontPanel.shared.orderOut(nil)
            preferencesWindow = nil
            popRegularActivation()
        }
    }
    
    @objc func quit() {
        NSApp.terminate(nil)
    }
}
