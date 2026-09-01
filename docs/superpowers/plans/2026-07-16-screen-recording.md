# Screen Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A QuickTime-style screen recorder inside Topkit: pick a region or window exactly like the screenshot tool, record it (red tray icon while recording), auto-save a timestamped .mov to a user-configurable folder (default Desktop), then open a QuickTime-like player with trim-and-overwrite.

**Architecture:** Phase 1 (recording): `ScreenRecordingManager` mirrors `ScreenshotManager`'s flow — live region picker (reusing `ScreenshotSelectionView` with no frozen backdrop) → confirm overlay with Start Recording toolbar (generalised from the currently-unreferenced `ScreenshotConfirmView`) → `ScreenRecorder` engine (SCStream → AVAssetWriter H.264 .mov; `SCRecordingOutput` is macOS 15+, our floor is 14.0) → move file from a sandbox-temp staging path to the destination folder. Phase 2 (player): `RecordingPlayerWindowController` wraps `AVPlayerView`, whose built-in `beginTrimming` shows the exact QuickTime trim UI (yellow handles + filmstrip); trim commits via passthrough `AVAssetExportSession` and atomically replaces the original file.

**Tech Stack:** ScreenCaptureKit (SCStream), AVFoundation (AVAssetWriter, AVAssetExportSession), AVKit (AVPlayerView), AppKit. No new dependencies.

---

## Research findings that shape the design

**QuickTime trim UX (what we replicate):** Edit → Trim (⌘T) shows a yellow trim bar over the full duration filled with frame thumbnails. Drag the left/right yellow handles to set in/out; the playhead scrubs inside; Space previews the kept range; "Trim" commits, "Cancel"/Esc exits. `AVPlayerView.beginTrimming(completionHandler:)` is this same system UI verbatim (macOS 10.9+), and after an `.okButton` result the chosen bounds are readable from the player item's `reversePlaybackEndTime` (start) and `forwardPlaybackEndTime` (end). So we do not build any trim UI — a Trim button + `beginTrimming` + a passthrough export IS QuickTime's behaviour.

**API floor:** deployment target is macOS 14.0. `SCRecordingOutput` (SCK's built-in file writer) is macOS 15+, so we feed `SCStream` sample buffers into `AVAssetWriter` ourselves. This is the standard pre-15 pattern.

**Sandbox / Desktop default:** the app is sandboxed with only `files.user-selected.read-write`. `~/Desktop` is NOT writable without a one-time user grant. Resolution: recordings always write to a staging file in the app container's temp dir; before the FIRST recording ever starts (no saved bookmark), we show an `NSOpenPanel` pre-pointed at the real `~/Desktop` with a "Grant Access" prompt; the chosen folder is stored as a security-scoped bookmark (same mechanism as screenshots). After that it's silent forever. Preferences can change the folder any time.

**Single-display region:** one `SCStream` records one display (`sourceRect` is display-local). The marquee UI spans all monitors like screenshots, but the final selection is clamped to the display containing the selection centre. Window mode uses `SCContentFilter(desktopIndependentWindow:)` (follows the window even when moved/occluded).

**Overlays vs capture:** during recording the outside-of-selection stays dimmed and everything is click-through so the user can interact with the recorded content and use Draw/Measure/Guides (those overlays SHOULD be captured — WYSIWYG). Topkit's own dim windows are excluded from capture via `SCContentFilter(display:excludingWindows:)`, so they never appear in the video even where they overlap the region.

**Recording indicator & stop controls:** there is NO floating control bar. The red tray icon IS the recording indicator. Stopping happens via: (a) the Topkit menu item, which reads "Stop Recording" in red while recording, (b) the record shortcut (toggle), (c) plain Esc — registered as a transient Carbon hotkey (`RegisterEventHotKey`, sandbox-safe, no permissions) only while recording and unregistered on stop. Trade-off, accepted: while recording, Esc is consumed system-wide (other apps don't receive it until recording stops).

**Compression:** H.264 High profile via hardware encoder, tuned for screen content: average bitrate 0.06 bits/pixel/frame clamped to 1.5–14 Mbps (1080p60 ≈ 7.5 Mbps, retina 5K caps at 14), keyframe every 2 s, no B-frames (`AllowFrameReordering` false — realtime-writer friendly), expected source frame rate 60. SCK only delivers frames when pixels change, so mostly-static screens produce very small files. H.264 over HEVC for universal shareability (Slack/browsers/Windows).

**No audio in v1.** Not requested; `capturesAudio` stays false. Easy follow-up later.

**Legacy asset:** `Views/ScreenshotConfirmView.swift` (dim + live hole + resize handles + Capture/Cancel toolbar) is compiled but referenced nowhere — it is almost exactly the pre-record confirm UI. We rename it to `SelectionConfirmView`, generalise the button title, and use it.

**Verification model:** every task verifies with `swift build` / `swift test` (SPM target `TopkitCore` picks up new files automatically). pbxproj registration happens once per phase, then `xcodebuild` verifies the app target. Never launch the app (user tests via TestFlight only).

## File structure

| File | Responsibility |
|---|---|
| Create `Topkit/RecordingSupport.swift` | Pure helpers: filename, coordinate/pixel maths, encoder settings, (Phase 2) trim-range resolution |
| Create `Topkit/ToastPresenter.swift` | Toast extraction from ScreenshotManager so both managers share it |
| Create `Topkit/RecordingDestination.swift` | Save-folder bookmark resolve/grant, staging URL, move/replace with security scope |
| Create `Topkit/ScreenRecorder.swift` | SCStream → AVAssetWriter engine, start/stop, unexpected-stop callback |
| Create `Topkit/ScreenRecordingManager.swift` | State machine: selecting → armed → recording → save; owns all overlay windows |
| Rename `Topkit/Views/ScreenshotConfirmView.swift` → `Topkit/Views/SelectionConfirmView.swift` | Generalised confirm overlay (primary title, resize toggle, external rect updates) |
| Modify `Topkit/HotKeyManager.swift` | Transient hotkey API (plain Esc while recording) that survives `reload(bindings:)` |
| Create `Topkit/Views/RecordingPlayerWindowController.swift` (Phase 2) | Player window: AVPlayerView, fullscreen, Trim → export → overwrite |
| Modify `Topkit/AppDelegate.swift` | Menu item, red tray icon, shortcut, defaults, revoke hook, regular-activation refcount |
| Modify `Topkit/Views/PreferencesView.swift` | Screen Recording section: save folder + shortcut row |
| Modify `Topkit/ScreenshotManager.swift` | Delegate toasts to ToastPresenter |
| Test `Tests/TopkitTests/RecordingSupportTests.swift` | Filename, maths, placement |
| Test `Tests/TopkitTests/TrimRangeTests.swift` (Phase 2) | Trim range resolution |

UserDefaults keys: `recordingSaveFolder`, `recordingSaveFolderBookmark`, `shortcutRecordScreen` (default `⌃⌥⇧E`).

---

# Phase 1 — Recording

### Task 1: Pure helpers (`RecordingSupport`) — TDD

**Files:**
- Create: `Topkit/RecordingSupport.swift`
- Test: `Tests/TopkitTests/RecordingSupportTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/TopkitTests/RecordingSupportTests.swift
import XCTest
import AVFoundation
@testable import TopkitCore

final class RecordingSupportTests: XCTestCase {

    // MARK: RecordingFilename

    func testFilenameFormat() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 16
        comps.hour = 14; comps.minute = 3; comps.second = 9
        let date = Calendar.current.date(from: comps)!
        let name = RecordingFilename.make(date: date, isTaken: { _ in false })
        XCTAssertEqual(name, "Recording_2026-07-16_14-03-09.mov")
    }

    func testFilenameCollisionAppendsSuffix() {
        let date = Date(timeIntervalSince1970: 0)
        var taken: Set<String> = []
        let first = RecordingFilename.make(date: date, isTaken: { taken.contains($0) })
        taken.insert(first)
        let second = RecordingFilename.make(date: date, isTaken: { taken.contains($0) })
        taken.insert(second)
        let third = RecordingFilename.make(date: date, isTaken: { taken.contains($0) })
        XCTAssertTrue(second.hasSuffix("_2.mov"))
        XCTAssertTrue(third.hasSuffix("_3.mov"))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(second, third)
    }

    // MARK: RecordingRegionMath.sourceRect (Cocoa global → display-local top-left origin)

    func testSourceRectOnPrimaryDisplay() {
        // Display 1920x1080 at origin (0,0). Selection 400x300 whose Cocoa
        // origin is (100, 200) → top-left-origin y = 1080 - 200 - 300 = 580.
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: 100, y: 200, width: 400, height: 300)
        let src = RecordingRegionMath.sourceRect(selectionGlobal: selection, displayFrame: display)
        XCTAssertEqual(src, CGRect(x: 100, y: 580, width: 400, height: 300))
    }

    func testSourceRectOnSecondaryDisplayWithNegativeOrigin() {
        // Secondary display to the left: origin (-1440, 0), 1440x900.
        // Selection at global (-1000, 100), 200x200 → local x = 440,
        // top-left y = 900 - 100 - 200 = 600.
        let display = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: -1000, y: 100, width: 200, height: 200)
        let src = RecordingRegionMath.sourceRect(selectionGlobal: selection, displayFrame: display)
        XCTAssertEqual(src, CGRect(x: 440, y: 600, width: 200, height: 200))
    }

    // MARK: RecordingRegionMath.evenPixelSize

    func testEvenPixelSizeRoundsDownToEven() {
        let s = RecordingRegionMath.evenPixelSize(pointSize: CGSize(width: 401.5, height: 303), scale: 2)
        XCTAssertEqual(s.width, 802)   // 803 → 802
        XCTAssertEqual(s.height, 606)
    }

    func testEvenPixelSizeNeverBelowTwo() {
        let s = RecordingRegionMath.evenPixelSize(pointSize: CGSize(width: 1, height: 0.4), scale: 1)
        XCTAssertEqual(s.width, 2)
        XCTAssertEqual(s.height, 2)
    }

    // MARK: RecordingRegionMath.clamped

    func testClampIntersectsWithDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 900, y: 700, width: 400, height: 400) // spills off top-right
        let r = RecordingRegionMath.clamped(selection: selection, toDisplay: display)
        XCTAssertEqual(r, CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    func testClampEnforcesMinimumSizeInsideDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 990, y: 790, width: 300, height: 300) // sliver
        let r = RecordingRegionMath.clamped(selection: selection, toDisplay: display, minSize: 40)
        XCTAssertEqual(r.width, 40)
        XCTAssertEqual(r.height, 40)
        XCTAssertTrue(display.contains(r))
    }

    func testClampReturnsIntegralRect() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 10.3, y: 20.7, width: 100.2, height: 50.6)
        let r = RecordingRegionMath.clamped(selection: selection, toDisplay: display)
        XCTAssertEqual(r, r.integral)
    }

    // MARK: RecordingEncoding

    func testBitrateClampsLow() {
        XCTAssertEqual(RecordingEncoding.averageBitRate(pixelWidth: 100, pixelHeight: 100, frameRate: 60), 1_500_000)
    }

    func testBitrateClampsHigh() {
        // Retina 5K full screen would want ~53 Mbps raw; cap keeps files small.
        XCTAssertEqual(RecordingEncoding.averageBitRate(pixelWidth: 5120, pixelHeight: 2880, frameRate: 60), 14_000_000)
    }

    func testBitrateMidRange() {
        // 1920*1080*60*0.06 = 7,464,960
        XCTAssertEqual(RecordingEncoding.averageBitRate(pixelWidth: 1920, pixelHeight: 1080, frameRate: 60), 7_464_960)
    }

    func testVideoSettingsShape() {
        let s = RecordingEncoding.videoSettings(pixelWidth: 800, pixelHeight: 600)
        XCTAssertEqual(s[AVVideoWidthKey] as? Int, 800)
        XCTAssertEqual(s[AVVideoHeightKey] as? Int, 600)
        XCTAssertEqual(s[AVVideoCodecKey] as? AVVideoCodecType, .h264)
        let props = s[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertNotNil(props?[AVVideoAverageBitRateKey])
        XCTAssertEqual(props?[AVVideoMaxKeyFrameIntervalKey] as? Int, 120)
        XCTAssertEqual(props?[AVVideoAllowFrameReorderingKey] as? Bool, false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RecordingSupportTests`
Expected: FAIL — `cannot find 'RecordingFilename' in scope` (compile error counts as the failing state).

- [ ] **Step 3: Write the implementation**

```swift
// Topkit/RecordingSupport.swift
import Foundation
import CoreGraphics
import AVFoundation

/// Timestamped recording filenames with collision suffixes
/// (Recording_2026-07-16_14-03-09.mov, …_14-03-09_2.mov, …).
enum RecordingFilename {
    static func make(date: Date, isTaken: (String) -> Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "Recording_\(formatter.string(from: date))"
        var candidate = base + ".mov"
        var n = 2
        while isTaken(candidate) {
            candidate = "\(base)_\(n).mov"
            n += 1
        }
        return candidate
    }
}

/// Coordinate maths between Cocoa global rects (bottom-left origin) and
/// ScreenCaptureKit's display-local, top-left-origin point rects.
enum RecordingRegionMath {
    /// `SCStreamConfiguration.sourceRect`: points, relative to the display,
    /// origin at the display's TOP-left (Cocoa rects are bottom-left).
    static func sourceRect(selectionGlobal: CGRect, displayFrame: CGRect) -> CGRect {
        let localX = selectionGlobal.origin.x - displayFrame.origin.x
        let localBottomY = selectionGlobal.origin.y - displayFrame.origin.y
        let topLeftY = displayFrame.height - localBottomY - selectionGlobal.height
        return CGRect(x: localX, y: topLeftY, width: selectionGlobal.width, height: selectionGlobal.height)
    }

    /// Output size in pixels, rounded down to even values (H.264 encoders
    /// reject odd dimensions), floor 2.
    static func evenPixelSize(pointSize: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let w = max(Int(pointSize.width * scale) & ~1, 2)
        let h = max(Int(pointSize.height * scale) & ~1, 2)
        return (w, h)
    }

    /// One SCStream records one display, so the selection is clamped to the
    /// display it (mostly) lives on. Result is integral and at least
    /// `minSize` on each side, kept inside the display.
    static func clamped(selection: CGRect, toDisplay displayFrame: CGRect, minSize: CGFloat = 40) -> CGRect {
        var r = selection.intersection(displayFrame)
        if r.isNull { r = CGRect(x: displayFrame.midX, y: displayFrame.midY, width: 0, height: 0) }
        if r.width < minSize {
            r.size.width = minSize
            r.origin.x = min(r.origin.x, displayFrame.maxX - minSize)
            r.origin.x = max(r.origin.x, displayFrame.minX)
        }
        if r.height < minSize {
            r.size.height = minSize
            r.origin.y = min(r.origin.y, displayFrame.maxY - minSize)
            r.origin.y = max(r.origin.y, displayFrame.minY)
        }
        return r.integral
    }
}

/// H.264 output settings tuned for screen content: hardware encoder, small
/// files (SCK only delivers frames when pixels change), crisp UI text at a
/// bounded bitrate, no B-frames (realtime writer friendly).
enum RecordingEncoding {
    static let frameRate = 60

    /// Average bitrate: 0.06 bits per pixel per frame, clamped to 1.5–14 Mbps.
    static func averageBitRate(pixelWidth: Int, pixelHeight: Int, frameRate: Int = frameRate) -> Int {
        let raw = Double(pixelWidth) * Double(pixelHeight) * Double(frameRate) * 0.06
        return Int(min(max(raw, 1_500_000), 14_000_000))
    }

    static func videoSettings(pixelWidth: Int, pixelHeight: Int, frameRate: Int = frameRate) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate(pixelWidth: pixelWidth, pixelHeight: pixelHeight, frameRate: frameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RecordingSupportTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Topkit/RecordingSupport.swift Tests/TopkitTests/RecordingSupportTests.swift
git commit -m "feat: recording filename, region maths, and control-bar placement helpers"
```

---

### Task 2: Extract `ToastPresenter` (shared toasts)

`ScreenshotManager.showToast` is private; the recording manager needs identical toasts. Move the implementation to a shared type; ScreenshotManager delegates.

**Files:**
- Create: `Topkit/ToastPresenter.swift`
- Modify: `Topkit/ScreenshotManager.swift` (showToast body → delegate; keep `presentForcedToast` API)

- [ ] **Step 1: Create ToastPresenter with the moved implementation**

```swift
// Topkit/ToastPresenter.swift
import AppKit

/// Passive toast chrome (no key); shared by the screenshot and recording flows.
private final class PassiveToastWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Centralised toast presentation (was private to ScreenshotManager).
/// Honours the "showToastNotifications" preference unless `force` is true.
final class ToastPresenter {
    static let shared = ToastPresenter()
    private var toastWindow: NSWindow?
    private init() {}

    func show(message: String, windowLevel: NSWindow.Level? = nil, force: Bool = false) {
        let showToasts = UserDefaults.standard.bool(forKey: "showToastNotifications")
        if !force && !showToasts { return }

        toastWindow?.orderOut(nil)
        toastWindow = nil

        let tempLabel = NSTextField(labelWithString: message)
        tempLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textSize = tempLabel.sizeThatFits(NSSize(width: 1000, height: 18))
        let horizontalPadding: CGFloat = 12
        let actualTextWidth = textSize.width
        let toastWidth: CGFloat = horizontalPadding + actualTextWidth + horizontalPadding
        let toastHeight: CGFloat = 36

        guard let screen = MultiMonitorHelper.screenWithMouse else { return }
        let toastX = screen.frame.midX - toastWidth / 2
        let toastY = screen.frame.maxY - 80

        let toast = PassiveToastWindow(
            contentRect: NSRect(x: toastX, y: toastY, width: toastWidth, height: toastHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.level = windowLevel ?? .floating
        toast.collectionBehavior = [.canJoinAllSpaces, .stationary]
        toast.ignoresMouseEvents = true
        toast.appearance = NSApp.effectiveAppearance
        toast.animationBehavior = .none

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight))
        ToastChrome.styleContainer(contentView)

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = ToastChrome.primaryLabelColor()
        label.frame = NSRect(x: horizontalPadding, y: 9, width: actualTextWidth, height: 18)
        contentView.addSubview(label)

        toast.contentView = contentView
        toast.alphaValue = 0
        toast.orderFrontRegardless()
        toastWindow = toast

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            toast.animator().alphaValue = 1
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                toast.animator().alphaValue = 0
            }) {
                toast.orderOut(nil)
            }
        }
    }
}
```

- [ ] **Step 2: Delegate in ScreenshotManager**

In `Topkit/ScreenshotManager.swift`:
- Delete the `private var toastWindow: NSWindow?` property, the whole body of `showToast`, and the now-unused `ScreenshotPassiveToastWindow` class.
- Replace `showToast` with:

```swift
    private func showToast(message: String, windowLevel: NSWindow.Level? = nil, force: Bool = false) {
        ToastPresenter.shared.show(message: message, windowLevel: windowLevel, force: force)
    }
```

`presentForcedToast` stays as is (it calls `showToast(force: true)`).

- [ ] **Step 3: Build and run full test suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Topkit/ToastPresenter.swift Topkit/ScreenshotManager.swift
git commit -m "refactor: extract shared ToastPresenter from ScreenshotManager"
```

---

### Task 3: `RecordingDestination` (folder grant, staging, move/replace)

**Files:**
- Create: `Topkit/RecordingDestination.swift`

No unit tests: everything here touches NSOpenPanel, security scopes, or the filesystem. Directory validation reuses the already-tested `ScreenshotDirectoryValidator`.

- [ ] **Step 1: Write the implementation**

```swift
// Topkit/RecordingDestination.swift
import AppKit

/// Where recordings land. Sandboxed: ~/Desktop (the default) needs a one-time
/// user grant via NSOpenPanel; the chosen folder is kept as a security-scoped
/// bookmark, mirroring the screenshot save-folder mechanism.
enum RecordingDestinationKeys {
    static let folder = "recordingSaveFolder"
    static let folderBookmark = "recordingSaveFolderBookmark"
}

enum RecordingDestination {

    /// Staging file inside the app container — always writable, no grant
    /// needed. The recording is written here and moved on stop (crash-safe:
    /// a dead recording never litters the destination folder).
    static func makeStagingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Recording_inprogress_\(UUID().uuidString).mov")
    }

    /// True when a save folder has already been granted (bookmark stored).
    static var hasSaveFolder: Bool {
        UserDefaults.standard.data(forKey: RecordingDestinationKeys.folderBookmark) != nil
    }

    /// The real ~/Desktop (NSHomeDirectory() points at the sandbox container;
    /// getpwuid gives the true home). Used only to point the grant panel.
    static func realDesktopURL() -> URL? {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { return nil }
        let homePath = FileManager.default.string(withFileSystemRepresentation: home, length: strlen(home))
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    /// One-time grant: open panel pre-pointed at the real Desktop. Stores the
    /// bookmark on success. Calls back with whether a folder is now available.
    /// Present BEFORE any overlay windows exist (the panel must be frontmost).
    static func requestSaveFolderGrant(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = realDesktopURL()
        panel.title = String(localized: "Choose Recording Save Folder")
        panel.message = String(localized: "Topkit needs one-time permission to save screen recordings here. Desktop is the default — click Grant Access, or pick another folder.")
        panel.prompt = String(localized: "Grant Access")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            store(folderURL: url)
            completion(true)
        }
    }

    /// Persist a chosen folder (also used by Preferences).
    static func store(folderURL: URL) {
        if let bookmark = try? folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: RecordingDestinationKeys.folderBookmark)
        }
        UserDefaults.standard.set(folderURL.path, forKey: RecordingDestinationKeys.folder)
    }

    /// Resolve the stored folder and run `body` with its security scope
    /// active. Refreshes a stale bookmark in place (same gotcha as
    /// screenshots: refresh must happen while the scope is started).
    /// Returns nil when no folder is stored or `body` throws.
    static func withSaveFolderAccess<T>(_ body: (URL) throws -> T) -> T? {
        let defaults = UserDefaults.standard
        guard let bookmarkData = defaults.data(forKey: RecordingDestinationKeys.folderBookmark) else { return nil }
        var isStale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let started = folderURL.startAccessingSecurityScopedResource()
        defer { if started { folderURL.stopAccessingSecurityScopedResource() } }
        if isStale, started,
           let refreshed = try? folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
           ) {
            defaults.set(refreshed, forKey: RecordingDestinationKeys.folderBookmark)
        }
        guard let validated = ScreenshotDirectoryValidator.validatedScreenshotSaveDirectory(folderURL) else { return nil }
        return try? body(validated)
    }

    /// Move a finished staging file into the destination folder with a
    /// timestamped name. Returns the final URL, or nil on failure (the
    /// staging file is left in place so nothing is lost).
    static func moveIntoSaveFolder(stagingURL: URL, date: Date = Date()) -> URL? {
        withSaveFolderAccess { folder in
            let name = RecordingFilename.make(date: date) { candidate in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
            }
            let destination = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: stagingURL, to: destination)
            return destination
        }
    }

    /// Atomically replace `originalURL` (inside the granted folder) with
    /// `newContentURL` — used by trim-and-save. Returns the (possibly new)
    /// URL of the replaced file, or nil on failure.
    static func replaceRecording(at originalURL: URL, with newContentURL: URL) -> URL? {
        withSaveFolderAccess { _ in
            let result = try FileManager.default.replaceItemAt(originalURL, withItemAt: newContentURL)
            return result ?? originalURL
        }
    }
}
```

Note: `withSaveFolderAccess` uses a nested optional flatten (`T?` from `try?` of `T`) — the two generic uses above return non-optional `URL` from `body`, so the flattened result is `URL?`. If the compiler produces `URL??`, add `?? nil` at the call sites (`moveIntoSaveFolder` / `replaceRecording`) — `swift build` in Step 2 catches it.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Topkit/RecordingDestination.swift
git commit -m "feat: recording save-folder grant, staging, and move/replace helpers"
```

---

### Task 4: `ScreenRecorder` engine (SCStream → AVAssetWriter)

**Files:**
- Create: `Topkit/ScreenRecorder.swift`

- [ ] **Step 1: Write the implementation**

```swift
// Topkit/ScreenRecorder.swift
import Foundation
import AVFoundation
import ScreenCaptureKit

/// One-shot SCStream → AVAssetWriter (H.264/.mov) recording engine.
/// macOS 14-compatible (SCRecordingOutput needs 15+). Create, start, stop, discard.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    enum RecorderError: LocalizedError {
        case writerSetupFailed(String)
        case noFramesCaptured
        var errorDescription: String? {
            switch self {
            case .writerSetupFailed(let reason): return "Recording writer failed: \(reason)"
            case .noFramesCaptured: return "Recording captured no frames"
            }
        }
    }

    let outputURL: URL
    /// Fires on main if the stream dies without stop() being called
    /// (display disconnect, recorded window closed, permission revoked).
    var onStreamStoppedUnexpectedly: ((Error?) -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var stopping = false
    private let sampleQueue = DispatchQueue(label: "topkit.recording.samples")

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        pixelWidth: Int,
        pixelHeight: Int,
        completion: @escaping (Error?) -> Void
    ) {
        do {
            try? FileManager.default.removeItem(at: outputURL)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let settings = RecordingEncoding.videoSettings(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.writerSetupFailed("cannot add video input")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw RecorderError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
            }
            self.writer = writer
            self.input = input
        } catch {
            completion(error)
            return
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            completion(error)
            return
        }
        stream.startCapture { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// Stops capture and finalises the file. Completion on main; nil error
    /// means outputURL holds a playable movie.
    func stop(completion: @escaping (Error?) -> Void) {
        stopping = true
        let finalizeWriter: (Error?) -> Void = { [weak self] stopError in
            guard let self, let writer = self.writer, let input = self.input else {
                DispatchQueue.main.async { completion(stopError) }
                return
            }
            // Hop to the sample queue so no append races finishWriting.
            self.sampleQueue.async {
                guard self.sessionStarted, writer.status == .writing else {
                    writer.cancelWriting()
                    DispatchQueue.main.async { completion(stopError ?? RecorderError.noFramesCaptured) }
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    let error: Error? = writer.status == .completed ? nil : (writer.error ?? stopError)
                    DispatchQueue.main.async { completion(error) }
                }
            }
        }
        if let stream {
            stream.stopCapture { error in finalizeWriter(error) }
        } else {
            finalizeWriter(nil)
        }
    }

    // MARK: - SCStreamOutput (called on sampleQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let writer, let input, writer.status == .writing else { return }
        // Only .complete frames carry displayable pixels (SCK also delivers
        // .idle/.blank status frames).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopping else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onStreamStoppedUnexpectedly?(error)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Topkit/ScreenRecorder.swift
git commit -m "feat: SCStream to AVAssetWriter screen recording engine"
```

---

### Task 5: Confirm overlay view + transient hotkey API

**Files:**
- Rename: `Topkit/Views/ScreenshotConfirmView.swift` → `Topkit/Views/SelectionConfirmView.swift`
- Modify: `Topkit/HotKeyManager.swift`

- [ ] **Step 1: Rename and generalise the confirm view**

```bash
git mv Topkit/Views/ScreenshotConfirmView.swift Topkit/Views/SelectionConfirmView.swift
sed -i '' 's/ScreenshotConfirmView/SelectionConfirmView/g' Topkit/Views/SelectionConfirmView.swift Topkit.xcodeproj/project.pbxproj
```

Then edit `Topkit/Views/SelectionConfirmView.swift`:

Replace the class doc comment and the init/toolbar section (`init(frame:selectionRect:)` through the end of `setupToolbar()`) with:

```swift
/// Full-screen overlay shown after the user draws a selection rect. Dimmed with a
/// live "hole" at the selection; resize handles; a primary-action + Cancel toolbar.
/// Used by the recording flow (Start Recording); originally built for screenshots.
class SelectionConfirmView: NSView {
    private let kResizeHandleSize: CGFloat = 12
    private let kResizeEdgeThickness: CGFloat = 10
    private let minSelectionSize: CGFloat = 40

    var selectionRect: NSRect
    var onConfirm: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    /// False for window-mode recording: the hole follows the window, the user can't resize it.
    let allowsResize: Bool
    private let primaryTitle: String
    private let primaryIsDestructive: Bool

    private var resizingEdge: ResizeEdge = .none
    private var resizeStartPoint: NSPoint?
    private var resizeOriginalRect: NSRect?

    private var toolbarView: NSView?

    override var isFlipped: Bool { false }

    init(frame: NSRect, selectionRect: NSRect, primaryTitle: String, primaryIsDestructive: Bool = false, allowsResize: Bool = true) {
        self.selectionRect = selectionRect
        self.primaryTitle = primaryTitle
        self.primaryIsDestructive = primaryIsDestructive
        self.allowsResize = allowsResize
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Reposition the hole from outside (window-mode recording tracks the
    /// target window's live frame).
    func updateSelectionRect(_ rect: NSRect) {
        selectionRect = rect
        updateToolbarPosition()
        setNeedsDisplay(bounds)
    }

    private func setupToolbar() {
        let toolbarHeight: CGFloat = 36
        let buttonHeight: CGFloat = 28
        let spacing: CGFloat = 4
        var x: CGFloat = 6
        let y: CGFloat = 4

        let toolbar = NSView(frame: .zero)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 5

        let primaryButton = NSButton(title: primaryTitle, target: self, action: #selector(confirmTapped))
        primaryButton.bezelStyle = .rounded
        if primaryIsDestructive {
            primaryButton.bezelColor = .systemRed
        }
        primaryButton.sizeToFit()
        primaryButton.frame = NSRect(x: x, y: y, width: max(primaryButton.frame.width + 16, 90), height: buttonHeight)
        toolbar.addSubview(primaryButton)
        x += primaryButton.frame.width + spacing

        let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.sizeToFit()
        cancelButton.frame = NSRect(x: x, y: y, width: max(cancelButton.frame.width + 16, 70), height: buttonHeight)
        toolbar.addSubview(cancelButton)
        x += cancelButton.frame.width + spacing

        let toolbarWidth = x
        let gapAboveSelection: CGFloat = 16
        let toolbarY = selectionRect.origin.y + selectionRect.height + gapAboveSelection
        let toolbarX = selectionRect.origin.x + (selectionRect.width - toolbarWidth) / 2
        toolbar.frame = NSRect(x: toolbarX, y: toolbarY, width: toolbarWidth, height: toolbarHeight)
        addSubview(toolbar)
        toolbarView = toolbar
        applyConfirmToolbarChrome()
    }
```

Rename the old callbacks/actions in the rest of the file:
- `@objc private func captureTapped()` → `@objc private func confirmTapped()` with body `onConfirm?(selectionRect)`.
- In `draw(_:)`, wrap the `drawResizeHandles(for: selectionRect)` call: `if allowsResize { drawResizeHandles(for: selectionRect) }`.
- In `mouseDown`, `mouseMoved`: guard resize paths with `allowsResize` (`let edge = allowsResize ? resizeEdgeAt(point: point) : .none`).
- Keep `updateToolbarPosition()` clamped on-screen — replace its body with:

```swift
    private func updateToolbarPosition() {
        guard let toolbar = toolbarView else { return }
        let gapAboveSelection: CGFloat = 16
        var toolbarY = selectionRect.origin.y + selectionRect.height + gapAboveSelection
        if toolbarY + toolbar.frame.height > bounds.maxY - 8 {
            toolbarY = selectionRect.origin.y - gapAboveSelection - toolbar.frame.height
        }
        var toolbarX = selectionRect.origin.x + (selectionRect.width - toolbar.frame.width) / 2
        toolbarX = max(8, min(toolbarX, bounds.maxX - 8 - toolbar.frame.width))
        toolbar.frame.origin = NSPoint(x: toolbarX, y: max(8, toolbarY))
    }
```

Also call `updateToolbarPosition()` at the end of `setupToolbar()` (after `toolbarView = toolbar`) so a selection near the top edge starts with the toolbar below it.

- [ ] **Step 2: Transient hotkey API in HotKeyManager**

Plain Esc must stop a recording system-wide. `RegisterEventHotKey` accepts an unmodified key, needs no permissions, and is sandbox-safe — but the registration must live outside `reload(bindings:)` (which calls `unregisterAll()` on every preferences change). Add to `Topkit/HotKeyManager.swift`:

After `private var registrations: [UInt32: Registration] = [:]` add:

```swift
    /// One-off hotkeys registered outside the preferences bindings (e.g. plain
    /// Esc while a recording runs). Survive `reload(bindings:)`.
    private var transientRegistrations: [UInt32: Registration] = [:]
```

After `unregisterAll()` add:

```swift
    /// Register a hotkey outside the preferences bindings. Returns an id for
    /// `unregisterTransient`, or nil if registration failed. While registered,
    /// the combo is consumed system-wide — keep the window short.
    @discardableResult
    func registerTransient(keyCode: UInt32, modifiers: UInt32 = 0, action: @escaping () -> Void) -> UInt32? {
        assert(Thread.isMainThread, "HotKeyManager.registerTransient must run on the main thread")
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            debugLog("⚠️ HotKey: transient RegisterEventHotKey failed (status \(status)) keyCode=\(keyCode)")
            return nil
        }
        transientRegistrations[id] = Registration(ref: ref, action: action)
        return id
    }

    func unregisterTransient(id: UInt32) {
        guard let reg = transientRegistrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(reg.ref)
    }
```

In `handleHotKey(id:)` change the lookup line to:

```swift
        guard let reg = registrations[id] ?? transientRegistrations[id] else { return }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success. (The pbxproj sed in Step 1 keeps the Xcode target consistent.)

- [ ] **Step 4: Commit**

```bash
git add -A Topkit/Views Topkit/HotKeyManager.swift Topkit.xcodeproj/project.pbxproj
git commit -m "feat: generalise confirm overlay for recording; transient hotkey API"
```

---

### Task 6: `ScreenRecordingManager`

The state machine and window orchestration. Mirrors ScreenshotManager's structure (selection overlays per screen, screenSaver+1 level, activation dance, permission monitor) but with live (non-frozen) selection and a recording lifecycle.

**Files:**
- Create: `Topkit/ScreenRecordingManager.swift`

- [ ] **Step 1: Write the implementation**

```swift
// Topkit/ScreenRecordingManager.swift
import AppKit
import Combine
import ScreenCaptureKit
import Carbon.HIToolbox

private let kRecordingOverlayLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

/// Key-capable borderless window for the confirm step (Esc, button clicks).
private final class RecordingConfirmWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Dim-with-live-hole view shown on every screen while recording (hole only
/// on the recorded screen). Entire window is click-through.
private final class RecordingDimHoleView: NSView {
    var holeRect: NSRect? {
        didSet { needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(kScreenshotDimOverlayAlpha)
        if let hole = holeRect, !hole.isEmpty, bounds.intersects(hole) {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: hole))
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
        } else {
            dim.setFill()
            bounds.fill()
        }
    }
}

class ScreenRecordingManager: ObservableObject {
    static let shared = ScreenRecordingManager()

    enum Activity: Int {
        case idle
        case selecting   // region picker / confirm step showing
        case recording   // stream running
    }

    @Published private(set) var activity: Activity = .idle

    /// Status bar icon + menu title updates.
    var onRecordingStateChanged: ((Activity) -> Void)?

    private enum CaptureTarget {
        case region(screen: NSScreen, globalRect: NSRect)
        case window(windowID: CGWindowID, screen: NSScreen, globalRect: NSRect)
    }

    // Selection phase (live picker, no frozen backdrop)
    private struct SelectionScreenOverlay {
        let screen: NSScreen
        let window: NSWindow
        let view: ScreenshotSelectionView
    }
    private var selectionOverlays: [SelectionScreenOverlay] = []
    private var selectionSharedState: SharedSelectionState?
    private var selectionDragMonitor: Any?

    // Confirm phase
    private var confirmWindow: NSWindow?
    private var confirmView: SelectionConfirmView?
    private var confirmDimWindows: [NSWindow] = []
    private var pendingTarget: CaptureTarget?

    // Recording phase
    private var recorder: ScreenRecorder?
    private var recordingDimWindows: [NSWindow] = []
    private var recordingDimViews: [RecordingDimHoleView] = []
    private var recordingDimScreenFrames: [NSRect] = []
    /// Plain Esc, registered only while the stream runs (stop control).
    private var escHotKeyID: UInt32?
    private var windowTrackingTimer: Timer?
    private var permissionTimer: Timer?
    private var isStopping = false

    private init() {}

    // MARK: - Entry points

    /// Menu/shortcut entry: idle → start flow; selecting → cancel; recording → stop.
    func toggle() {
        switch activity {
        case .idle: startRecordingFlow()
        case .selecting: cancelFlow(toast: String(localized: "Recording canceled"))
        case .recording: stopRecording()
        }
    }

    func startRecordingFlow() {
        guard activity == .idle else { return }
        // Same live permission check as screenshots (preflight lies after revoke).
        PermissionManager.shared.verifyScreenRecordingPermission { [weak self] hasPermission in
            let proceed = { [weak self] in
                DispatchQueue.main.async { self?.ensureDestinationThenSelect() }
            }
            if hasPermission {
                proceed()
            } else {
                PermissionManager.shared.requestScreenRecordingAndWaitForGrant { proceed() }
            }
        }
    }

    func abortForPermissionLoss() {
        switch activity {
        case .idle: return
        case .selecting: cancelFlow(toast: nil)
        case .recording: stopRecording()
        }
    }

    // MARK: - Destination grant (one-time, before any overlay exists)

    private func ensureDestinationThenSelect() {
        guard activity == .idle else { return }
        PermissionManager.shared.markScreenRecordingPermissionGranted()
        if RecordingDestination.hasSaveFolder {
            startSelection()
            return
        }
        RecordingDestination.requestSaveFolderGrant { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.startSelection()
                } else {
                    ToastPresenter.shared.show(message: String(localized: "Recording needs a save folder — canceled"), force: true)
                }
            }
        }
    }

    // MARK: - Selection (live region picker, same UX as screenshots)

    private func startSelection() {
        (NSApp.delegate as? AppDelegate)?.orderOutPreferencesWindowForToolOverlay()
        setActivity(.selecting)
        ToastPresenter.shared.show(
            message: String(localized: "Click a window or drag a region to record"),
            windowLevel: NSWindow.Level(rawValue: kRecordingOverlayLevel.rawValue + 1)
        )

        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let window = MultiMonitorWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = kRecordingOverlayLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.animationBehavior = .none
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.setFrame(screenFrame, display: true)
            let view = ScreenshotSelectionView(frame: NSRect(origin: .zero, size: screenFrame.size))
            view.frozenBackdrop = nil // LIVE picker: the desktop stays visible and running
            view.screenOffset = screenFrame.origin
            view.onSelectionComplete = { [weak self] rect in
                DispatchQueue.main.async { self?.regionSelected(globalRect: rect) }
            }
            view.onWindowSelected = { [weak self] windowID in
                DispatchQueue.main.async { self?.windowSelected(windowID: windowID) }
            }
            view.onCancel = { [weak self] in
                self?.cancelFlow(toast: String(localized: "Recording canceled"))
            }
            window.contentView = view
            selectionOverlays.append(SelectionScreenOverlay(screen: screen, window: window, view: view))
        }
        let shared = SharedSelectionState()
        shared.allViews = selectionOverlays.map(\.view)
        for overlay in selectionOverlays {
            overlay.view.sharedState = shared
        }
        selectionSharedState = shared
        installSelectionDragMonitor()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            for overlay in selectionOverlays { overlay.window.orderFrontRegardless() }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let target = selectionOverlays.first(where: { $0.window.frame.contains(NSEvent.mouseLocation) }) ?? selectionOverlays.first {
            target.window.makeKeyAndOrderFront(nil)
            _ = target.window.makeFirstResponder(target.view)
        }
        NSCursor.crosshair.set()
        startPermissionMonitor()
    }

    /// Cross-monitor drags: same local-monitor trick as ScreenshotManager
    /// (each view only sees events while its window is key).
    private func installSelectionDragMonitor() {
        removeSelectionDragMonitor()
        selectionDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleSelectionDragEvent(event)
            return event
        }
    }

    private func removeSelectionDragMonitor() {
        if let monitor = selectionDragMonitor {
            NSEvent.removeMonitor(monitor)
            selectionDragMonitor = nil
        }
    }

    private func handleSelectionDragEvent(_ event: NSEvent) {
        guard let shared = selectionSharedState, shared.isSelecting,
              let start = shared.globalStartPoint else { return }
        let globalPoint = NSEvent.mouseLocation
        if event.type == .leftMouseUp {
            let rect = shared.globalCurrentRect
            shared.isSelecting = false
            if let rect, rect.width > 10, rect.height > 10 {
                DispatchQueue.main.async { [weak self] in self?.regionSelected(globalRect: rect) }
            } else {
                shared.globalCurrentRect = nil
                shared.redrawAllViews()
            }
            return
        }
        shared.globalCurrentRect = NSRect(
            x: min(start.x, globalPoint.x),
            y: min(start.y, globalPoint.y),
            width: abs(globalPoint.x - start.x),
            height: abs(globalPoint.y - start.y)
        )
        shared.redrawAllViews()
    }

    private func teardownSelectionOverlays() {
        for overlay in selectionOverlays { overlay.window.orderOut(nil) }
        selectionOverlays.removeAll()
        selectionSharedState = nil
        removeSelectionDragMonitor()
    }

    // MARK: - Confirm step

    private func regionSelected(globalRect: NSRect) {
        guard activity == .selecting else { return }
        teardownSelectionOverlays()
        let center = NSPoint(x: globalRect.midX, y: globalRect.midY)
        guard let screen = MultiMonitorHelper.screenContaining(center) ?? NSScreen.main ?? NSScreen.screens.first else {
            cancelFlow(toast: nil)
            return
        }
        // One SCStream = one display: clamp the selection to its display.
        let clamped = RecordingRegionMath.clamped(selection: globalRect, toDisplay: screen.frame)
        showConfirm(target: .region(screen: screen, globalRect: clamped))
    }

    private func windowSelected(windowID: CGWindowID) {
        guard activity == .selecting else { return }
        teardownSelectionOverlays()
        guard let rect = Self.cocoaBounds(windowID: windowID),
              let screen = MultiMonitorHelper.screenContaining(NSPoint(x: rect.midX, y: rect.midY))
                ?? NSScreen.main ?? NSScreen.screens.first else {
            cancelFlow(toast: nil)
            return
        }
        showConfirm(target: .window(windowID: windowID, screen: screen, globalRect: rect))
    }

    private func showConfirm(target: CaptureTarget) {
        pendingTarget = target
        let (screen, globalRect, allowsResize): (NSScreen, NSRect, Bool) = {
            switch target {
            case .region(let s, let r): return (s, r, true)
            case .window(_, let s, let r): return (s, r, false)
            }
        }()
        let screenFrame = screen.frame
        let localRect = NSRect(
            x: globalRect.origin.x - screenFrame.origin.x,
            y: globalRect.origin.y - screenFrame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        let window = RecordingConfirmWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = kRecordingOverlayLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        window.setFrame(screenFrame, display: true)
        let view = SelectionConfirmView(
            frame: NSRect(origin: .zero, size: screenFrame.size),
            selectionRect: localRect,
            primaryTitle: String(localized: "Start Recording"),
            primaryIsDestructive: true,
            allowsResize: allowsResize
        )
        view.onConfirm = { [weak self] finalLocalRect in
            let finalGlobal = NSRect(
                x: finalLocalRect.origin.x + screenFrame.origin.x,
                y: finalLocalRect.origin.y + screenFrame.origin.y,
                width: finalLocalRect.width,
                height: finalLocalRect.height
            )
            self?.beginRecording(finalGlobalRect: finalGlobal)
        }
        view.onCancel = { [weak self] in
            self?.cancelFlow(toast: String(localized: "Recording canceled"))
        }
        window.contentView = view
        confirmWindow = window
        confirmView = view

        // Plain dim on every other screen while confirming.
        for other in NSScreen.screens where other != screen {
            let dim = MultiMonitorWindow(
                contentRect: other.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            dim.level = kRecordingOverlayLevel
            dim.collectionBehavior = [.canJoinAllSpaces, .stationary]
            dim.isOpaque = false
            dim.backgroundColor = NSColor.black.withAlphaComponent(kScreenshotDimOverlayAlpha)
            dim.hasShadow = false
            dim.animationBehavior = .none
            dim.orderFrontRegardless()
            confirmDimWindows.append(dim)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(view)
        NSCursor.arrow.set()
    }

    private func teardownConfirmUI() {
        confirmWindow?.orderOut(nil)
        confirmWindow = nil
        confirmView = nil
        for dim in confirmDimWindows { dim.orderOut(nil) }
        confirmDimWindows.removeAll()
    }

    // MARK: - Recording

    private func beginRecording(finalGlobalRect: NSRect) {
        guard let target = pendingTarget else {
            cancelFlow(toast: nil)
            return
        }
        // Region target may have been resized in the confirm step.
        let effectiveTarget: CaptureTarget = {
            switch target {
            case .region(let screen, _):
                return .region(screen: screen, globalRect: RecordingRegionMath.clamped(selection: finalGlobalRect, toDisplay: screen.frame))
            case .window:
                return target
            }
        }()
        pendingTarget = effectiveTarget
        teardownConfirmUI()

        let (screen, globalRect): (NSScreen, NSRect) = {
            switch effectiveTarget {
            case .region(let s, let r): return (s, r)
            case .window(_, let s, let r): return (s, r)
            }
        }()

        // Recording chrome FIRST, so it exists in shareable content and can
        // be excluded from the capture filter.
        buildRecordingChrome(holeGlobalRect: globalRect)

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let content, error == nil else {
                    self.failRecordingStart(String(localized: "Could not read the screen — check Screen Recording permission for Topkit"))
                    return
                }
                self.startStream(content: content, target: effectiveTarget, screen: screen, globalRect: globalRect)
            }
        }
    }

    private func startStream(content: SCShareableContent, target: CaptureTarget, screen: NSScreen, globalRect: NSRect) {
        let ourWindowIDs = Set(recordingDimWindows.map { CGWindowID($0.windowNumber) })
        let excluded = content.windows.filter { ourWindowIDs.contains($0.windowID) }

        let config = SCStreamConfiguration()
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 8
        config.capturesAudio = false

        let filter: SCContentFilter
        let pixelSize: (width: Int, height: Int)

        switch target {
        case .region:
            guard let displayID = ScreenCapture.displayID(for: screen),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                failRecordingStart(String(localized: "Could not find the display to record"))
                return
            }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            config.sourceRect = RecordingRegionMath.sourceRect(selectionGlobal: globalRect, displayFrame: screen.frame)
            pixelSize = RecordingRegionMath.evenPixelSize(pointSize: globalRect.size, scale: screen.backingScaleFactor)
        case .window(let windowID, _, _):
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                failRecordingStart(String(localized: "The selected window is gone"))
                return
            }
            let windowFilter = SCContentFilter(desktopIndependentWindow: scWindow)
            filter = windowFilter
            let scale = CGFloat(windowFilter.pointPixelScale)
            pixelSize = RecordingRegionMath.evenPixelSize(pointSize: windowFilter.contentRect.size, scale: scale)
        }
        config.width = pixelSize.width
        config.height = pixelSize.height

        let recorder = ScreenRecorder(outputURL: RecordingDestination.makeStagingURL())
        recorder.onStreamStoppedUnexpectedly = { [weak self] _ in
            // Display unplugged / recorded window closed / permission pulled:
            // salvage what was captured.
            self?.stopRecording()
        }
        self.recorder = recorder
        recorder.start(filter: filter, configuration: config, pixelWidth: pixelSize.width, pixelHeight: pixelSize.height) { [weak self] error in
            guard let self else { return }
            if let error {
                self.recorder = nil
                self.failRecordingStart(String(localized: "Could not start recording: ") + error.localizedDescription)
                return
            }
            self.setActivity(.recording)
            // Plain Esc stops the recording. Consumed system-wide while
            // registered, so it lives strictly between start and stop.
            self.escHotKeyID = HotKeyManager.shared.registerTransient(keyCode: UInt32(kVK_Escape)) { [weak self] in
                self?.stopRecording()
            }
            if case .window(let windowID, _, _) = target {
                self.startWindowTracking(windowID: windowID)
            }
            if UserDefaults.standard.bool(forKey: "playNotificationSounds") { NSSound.beep() }
        }
    }

    /// Click-through dim + hole on every screen. No control bar: the red tray
    /// icon is the indicator; the menu item / shortcut / Esc are the stop controls.
    private func buildRecordingChrome(holeGlobalRect: NSRect) {
        for screen in NSScreen.screens {
            let dim = MultiMonitorWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            dim.level = kRecordingOverlayLevel
            dim.collectionBehavior = [.canJoinAllSpaces, .stationary]
            dim.isOpaque = false
            dim.backgroundColor = .clear
            dim.hasShadow = false
            dim.animationBehavior = .none
            dim.ignoresMouseEvents = true // the whole point: record + interact
            dim.setFrame(screen.frame, display: true)
            let view = RecordingDimHoleView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.holeRect = NSRect(
                x: holeGlobalRect.origin.x - screen.frame.origin.x,
                y: holeGlobalRect.origin.y - screen.frame.origin.y,
                width: holeGlobalRect.width,
                height: holeGlobalRect.height
            )
            dim.contentView = view
            dim.orderFrontRegardless()
            recordingDimWindows.append(dim)
            recordingDimViews.append(view)
            recordingDimScreenFrames.append(screen.frame)
        }

    }

    /// Window mode: keep the hole glued to the (movable) recorded window.
    private func startWindowTracking(windowID: CGWindowID) {
        windowTrackingTimer?.invalidate()
        let t = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            guard let self, let rect = Self.cocoaBounds(windowID: windowID) else { return }
            for (i, view) in self.recordingDimViews.enumerated() {
                guard i < self.recordingDimScreenFrames.count else { continue }
                let f = self.recordingDimScreenFrames[i]
                view.holeRect = NSRect(
                    x: rect.origin.x - f.origin.x,
                    y: rect.origin.y - f.origin.y,
                    width: rect.width,
                    height: rect.height
                )
            }
        }
        RunLoop.main.add(t, forMode: .common)
        windowTrackingTimer = t
    }

    func stopRecording() {
        guard activity == .recording, !isStopping, let recorder else { return }
        isStopping = true
        if let escHotKeyID {
            HotKeyManager.shared.unregisterTransient(id: escHotKeyID)
            self.escHotKeyID = nil
        }
        windowTrackingTimer?.invalidate()
        windowTrackingTimer = nil
        recorder.stop { [weak self] error in
            guard let self else { return }
            self.recorder = nil
            self.teardownRecordingChrome()
            self.isStopping = false
            self.setActivity(.idle)
            self.stopPermissionMonitor()
            if let error {
                debugLog("❌ Recording failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: recorder.outputURL)
                ToastPresenter.shared.show(message: String(localized: "Recording failed"), force: true)
                return
            }
            self.saveFinishedRecording(stagingURL: recorder.outputURL)
        }
    }

    private func saveFinishedRecording(stagingURL: URL) {
        if UserDefaults.standard.bool(forKey: "playNotificationSounds") { NSSound.beep() }
        guard let finalURL = RecordingDestination.moveIntoSaveFolder(stagingURL: stagingURL) else {
            debugLog("❌ Could not move recording into save folder; left at \(stagingURL.path)")
            ToastPresenter.shared.show(message: String(localized: "Recording save failed — choose a folder in Preferences"), force: true)
            return
        }
        debugLog("✅ Recording saved to: \(finalURL.path)")
        ToastPresenter.shared.show(message: String(localized: "Recording saved"))
        // Phase 2 opens the player here.
    }

    private func failRecordingStart(_ message: String) {
        teardownRecordingChrome()
        setActivity(.idle)
        stopPermissionMonitor()
        ToastPresenter.shared.show(message: message, force: true)
    }

    private func teardownRecordingChrome() {
        for dim in recordingDimWindows { dim.orderOut(nil) }
        recordingDimWindows.removeAll()
        recordingDimViews.removeAll()
        recordingDimScreenFrames.removeAll()
        if let escHotKeyID {
            HotKeyManager.shared.unregisterTransient(id: escHotKeyID)
            self.escHotKeyID = nil
        }
        pendingTarget = nil
    }

    // MARK: - Cancel / state

    private func cancelFlow(toast: String?) {
        teardownSelectionOverlays()
        teardownConfirmUI()
        teardownRecordingChrome()
        stopPermissionMonitor()
        setActivity(.idle)
        NSCursor.arrow.set()
        if let toast {
            if UserDefaults.standard.bool(forKey: "playNotificationSounds") { NSSound.beep() }
            ToastPresenter.shared.show(message: toast)
        }
    }

    private func setActivity(_ new: Activity) {
        activity = new
        onRecordingStateChanged?(new)
    }

    // MARK: - Permission monitor (selection/confirm phases only; the stream
    // itself reports revocation via didStopWithError while recording)

    private func startPermissionMonitor() {
        stopPermissionMonitor()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.activity == .selecting else { return }
            guard !PermissionManager.shared.hasScreenRecordingPermission() else { return }
            self.cancelFlow(toast: nil)
        }
    }

    private func stopPermissionMonitor() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Window bounds lookup (Quartz → Cocoa)

    static func cocoaBounds(windowID: CGWindowID) -> NSRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let qx = bounds["X"] as? CGFloat,
              let qy = bounds["Y"] as? CGFloat,
              let qw = bounds["Width"] as? CGFloat,
              let qh = bounds["Height"] as? CGFloat else {
            return nil
        }
        let primaryH = MultiMonitorHelper.primaryScreenHeight
        return NSRect(x: qx, y: primaryH - qy - qh, width: qw, height: qh)
    }
}
```

Note: `kScreenshotDimOverlayAlpha` is already internal (defined at file scope in `Topkit/Views/ScreenshotAnnotationView.swift:152`, value 0.88) — use it directly, no change needed.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success. Fix any small mismatches (e.g. `SelectionConfirmView` init labels) rather than redesigning.

- [ ] **Step 3: Commit**

```bash
git add Topkit/ScreenRecordingManager.swift
git commit -m "feat: screen recording manager (live picker, confirm step, record lifecycle, save)"
```

---

### Task 7: AppDelegate wiring — menu item, red tray icon, shortcut, revoke hook

**Files:**
- Modify: `Topkit/AppDelegate.swift`

- [ ] **Step 1: Register the default shortcut**

In `registerDefaultUserValues()`, after `"shortcutScreenshot": "⌃⌥⇧S",` add:

```swift
            "shortcutRecordScreen": "⌃⌥⇧E",
```

- [ ] **Step 2: Manager property + state callback**

After `var screenshotManager: ScreenshotManager!` add:

```swift
    var screenRecordingManager: ScreenRecordingManager!
```

In `applicationDidFinishLaunching`, after `screenshotManager = ScreenshotManager.shared` add:

```swift
        screenRecordingManager = ScreenRecordingManager.shared
```

After the screenshot state-change handler block add:

```swift
        // Setup recording state change handler for status bar icon
        screenRecordingManager.onRecordingStateChanged = { [weak self] activity in
            guard let self = self else { return }
            self.recordingActivity = activity
            self.menuNeedsRebuild = true
            self.updateStatusBarIcon()
        }
```

In the `onScreenRecordingRevoked` closure, after `self.screenshotManager?.abortForPermissionLoss()` add:

```swift
            self.screenRecordingManager?.abortForPermissionLoss()
```

- [ ] **Step 3: State property, action, hotkey binding**

Next to `private var isScreenshotActive = false` add:

```swift
    private var recordingActivity: ScreenRecordingManager.Activity = .idle
```

Next to `@objc func takeScreenshot()` add:

```swift
    @objc func toggleRecording() {
        screenRecordingManager?.toggle()
    }
```

In `setupShortcuts()` bindings array, after the `shortcutScreenshot` entry add:

```swift
            ("shortcutRecordScreen", { [weak self] in self?.toggleRecording() }),
```

- [ ] **Step 4: Menu item below Screenshot**

In `buildMenu(into:)`, directly after the Screenshot menu item block add:

```swift
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
```

- [ ] **Step 5: Menu signature includes recording state**

In `MenuBuildSignature` add field `let recordingActivity: Int` (after `isMeasureActive`), and in `currentMenuBuildSignature()` pass `recordingActivity: ScreenRecordingManager.shared.activity.rawValue`.

- [ ] **Step 6: Red tray icon while recording**

After `menuBarActiveImage(iconSize:)` add:

```swift
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
```

Replace the body of `updateStatusBarIcon()` with:

```swift
        guard let button = statusItem.button else { return }
        let iconSize = NSSize(width: 16, height: 16)

        if recordingActivity == .recording {
            // Recording wins over everything: red badge, white glyph.
            button.image = Self.menuBarRecordingImage(iconSize: iconSize)
        } else if isDrawingActive || isMagnifyingActive || isHaloActive || isMeasureActive
                    || isColorPickerActive || isScreenshotActive || recordingActivity == .selecting {
            // Active (incl. drawing the recording hole): white badge, black glyph.
            button.image = Self.menuBarActiveImage(iconSize: iconSize)
        } else {
            let glyphSize = NSSize(width: 18, height: 18)
            button.image = Self.menuBarIdleImage(glyphSize: glyphSize)
        }
```

- [ ] **Step 7: Build + test**

Run: `swift build && swift test`
Expected: success, all pass.

- [ ] **Step 8: Commit**

```bash
git add Topkit/AppDelegate.swift
git commit -m "feat: recording menu item, red tray icon while recording, record shortcut"
```

---

### Task 8: Preferences — Screen Recording section

**Files:**
- Modify: `Topkit/Views/PreferencesView.swift`

- [ ] **Step 1: Add state + section**

Near `@AppStorage("saveScreenshotsToFolder")` add:

```swift
    @State private var recordingFolderPath: String = ""
```

After the whole Screenshot section (the `SectionHeader(title: "Screenshot")` group), add a Screen Recording section following the exact visual pattern of the screenshot folder row:

```swift
            SectionHeader(title: "Screen Recording")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Save recordings to:")
                    TextField("", text: .constant(recordingFolderPath.isEmpty ? "Desktop (asks once on first recording)" : recordingFolderPath))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Choose...") {
                        chooseRecordingFolder()
                    }
                }
                Text("Recordings are saved as .mov files with a timestamp. They are not copied to the clipboard.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
```

(Adjust the row markup to match whatever container/padding the Screenshot section rows use — copy the screenshot folder row's exact modifiers.)

In `.onAppear` (where `screenshotFolderPath` is initialised) add:

```swift
            recordingFolderPath = displayPathForRecordingFolder()
```

- [ ] **Step 2: Folder chooser + display helpers**

Next to `chooseScreenshotFolder()` add:

```swift
    private func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Recording Save Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RecordingDestination.store(folderURL: url)
        recordingFolderPath = url.path
    }

    private func displayPathForRecordingFolder() -> String {
        if let data = UserDefaults.standard.data(forKey: RecordingDestinationKeys.folderBookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url.path
            }
        }
        return UserDefaults.standard.string(forKey: RecordingDestinationKeys.folder) ?? ""
    }
```

- [ ] **Step 3: Shortcut row**

Next to `@AppStorage("shortcutScreenshot")` add:

```swift
    @AppStorage("shortcutRecordScreen") private var shortcutRecordScreen = ""
```

After `ShortcutRow(label: "Screenshot:", shortcut: $shortcutScreenshot)` add:

```swift
                ShortcutRow(label: "Record Screen:", shortcut: $shortcutRecordScreen)
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Topkit/Views/PreferencesView.swift
git commit -m "feat: recording save folder and shortcut in preferences"
```

---

### Task 9: Register Phase 1 files in the Xcode project + full verify

`swift build` covers SPM; the app target needs the new files in project.pbxproj (test files go in the test target).

**Files:**
- Modify: `Topkit.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add PBXBuildFile entries**

In the `PBXBuildFile` section (alphabetical-ish, style matches existing hand-rolled IDs like `M1E2A3S4U5R6E7M8A9N0A1G2E3`), add:

```
		RECBF000000000000000SUP1 /* RecordingSupport.swift in Sources */ = {isa = PBXBuildFile; fileRef = RECFR000000000000000SUP1 /* RecordingSupport.swift */; };
		RECBF000000000000000TOA1 /* ToastPresenter.swift in Sources */ = {isa = PBXBuildFile; fileRef = RECFR000000000000000TOA1 /* ToastPresenter.swift */; };
		RECBF000000000000000DST1 /* RecordingDestination.swift in Sources */ = {isa = PBXBuildFile; fileRef = RECFR000000000000000DST1 /* RecordingDestination.swift */; };
		RECBF000000000000000ENG1 /* ScreenRecorder.swift in Sources */ = {isa = PBXBuildFile; fileRef = RECFR000000000000000ENG1 /* ScreenRecorder.swift */; };
		RECBF000000000000000MGR1 /* ScreenRecordingManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = RECFR000000000000000MGR1 /* ScreenRecordingManager.swift */; };
		RECBF000000000000000TST1 /* RecordingSupportTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = RECFR000000000000000TST1 /* RecordingSupportTests.swift */; };
```

- [ ] **Step 2: Add PBXFileReference entries**

```
		RECFR000000000000000SUP1 /* RecordingSupport.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RecordingSupport.swift; sourceTree = "<group>"; };
		RECFR000000000000000TOA1 /* ToastPresenter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ToastPresenter.swift; sourceTree = "<group>"; };
		RECFR000000000000000DST1 /* RecordingDestination.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RecordingDestination.swift; sourceTree = "<group>"; };
		RECFR000000000000000ENG1 /* ScreenRecorder.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ScreenRecorder.swift; sourceTree = "<group>"; };
		RECFR000000000000000MGR1 /* ScreenRecordingManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ScreenRecordingManager.swift; sourceTree = "<group>"; };
		RECFR000000000000000TST1 /* RecordingSupportTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RecordingSupportTests.swift; sourceTree = "<group>"; };
```

- [ ] **Step 3: Group membership**

- Add `RECFR000000000000000SUP1`, `…TOA1`, `…DST1`, `…ENG1`, `…MGR1` to the `Topkit` group's children (next to `MeasureManager.swift`).
- Add `RECFR000000000000000TST1` to the tests group children (next to `MultiMonitorHelperTests.swift`).

- [ ] **Step 4: Sources build phases**

- App target Sources phase (the one listing `MeasureManager.swift in Sources`): add the five app `RECBF…` lines (`SUP1 TOA1 DST1 ENG1 MGR1`).
- Test target Sources phase (the one listing `MultiMonitorHelperTests.swift in Sources`): add `RECBF000000000000000TST1`.

- [ ] **Step 5: Full verify**

```bash
swift build && swift test
export LANG=en_US.UTF-8
xcodebuild -project Topkit.xcodeproj -scheme Topkit -configuration Debug build
```

Expected: all succeed. Do NOT launch the app.

- [ ] **Step 6: Commit**

```bash
git add Topkit.xcodeproj/project.pbxproj
git commit -m "chore: register screen recording sources in Xcode project"
```

---

# Phase 2 — Player + trim

### Task 10: `TrimRange` helper — TDD

**Files:**
- Modify: `Topkit/RecordingSupport.swift` (append)
- Test: `Tests/TopkitTests/TrimRangeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/TopkitTests/TrimRangeTests.swift
import XCTest
import CoreMedia
@testable import TopkitCore

final class TrimRangeTests: XCTestCase {
    private let duration = CMTime(seconds: 10, preferredTimescale: 600)

    func testValidSubrange() {
        let r = TrimRange.resolve(
            start: CMTime(seconds: 2, preferredTimescale: 600),
            end: CMTime(seconds: 8, preferredTimescale: 600),
            duration: duration
        )
        XCTAssertEqual(r?.start.seconds, 2)
        XCTAssertEqual(r?.end.seconds, 8)
    }

    func testFullRangeIsNoOp() {
        // Trimming nothing → nil (skip the export entirely).
        let r = TrimRange.resolve(start: .zero, end: duration, duration: duration)
        XCTAssertNil(r)
    }

    func testInvalidTimesFallBackToBounds() {
        // AVPlayerItem defaults: reversePlaybackEndTime/.forwardPlaybackEndTime
        // are .invalid when untouched → treat as 0 / duration → no-op.
        let r = TrimRange.resolve(start: .invalid, end: .invalid, duration: duration)
        XCTAssertNil(r)
    }

    func testStartOnlyTrim() {
        let r = TrimRange.resolve(
            start: CMTime(seconds: 3, preferredTimescale: 600),
            end: .invalid,
            duration: duration
        )
        XCTAssertEqual(r?.start.seconds, 3)
        XCTAssertEqual(r?.end.seconds, 10)
    }

    func testDegenerateRangeIsNil() {
        let t = CMTime(seconds: 5, preferredTimescale: 600)
        XCTAssertNil(TrimRange.resolve(start: t, end: t, duration: duration))
    }

    func testEndClampedToDuration() {
        let r = TrimRange.resolve(
            start: CMTime(seconds: 1, preferredTimescale: 600),
            end: CMTime(seconds: 99, preferredTimescale: 600),
            duration: duration
        )
        XCTAssertEqual(r?.end.seconds, 10)
    }

    func testInvalidDurationIsNil() {
        XCTAssertNil(TrimRange.resolve(start: .zero, end: .zero, duration: .invalid))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TrimRangeTests`
Expected: FAIL — `cannot find 'TrimRange' in scope`.

- [ ] **Step 3: Implement (append to RecordingSupport.swift)**

```swift
import CoreMedia

/// Converts AVPlayerView trim results into an export range.
/// After `beginTrimming` ends with .okButton, the chosen bounds live in the
/// player item's `reversePlaybackEndTime` (start) and `forwardPlaybackEndTime`
/// (end); `.invalid` means "untouched" (0 / duration). Returns nil when the
/// result is a no-op or invalid — callers skip the export.
enum TrimRange {
    static func resolve(start: CMTime, end: CMTime, duration: CMTime) -> CMTimeRange? {
        guard duration.isNumeric, duration > .zero else { return nil }
        let s = start.isNumeric ? max(start, .zero) : .zero
        let e = end.isNumeric ? min(end, duration) : duration
        guard e > s else { return nil }
        if s == .zero && e == duration { return nil }
        return CMTimeRange(start: s, end: e)
    }
}
```

(Add `import CoreMedia` at the top of the file with the other imports, not mid-file.)

- [ ] **Step 4: Run tests**

Run: `swift test --filter TrimRangeTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Topkit/RecordingSupport.swift Tests/TopkitTests/TrimRangeTests.swift
git commit -m "feat: trim range resolution for the recording player"
```

---

### Task 11: `RecordingPlayerWindowController`

QuickTime-style player: AVPlayerView with floating controls, resizable window, fullscreen, Trim (⌘T) via the system trim UI, save overwrites the original file.

**Files:**
- Create: `Topkit/Views/RecordingPlayerWindowController.swift`

- [ ] **Step 1: Write the implementation**

```swift
// Topkit/Views/RecordingPlayerWindowController.swift
import AppKit
import AVKit
import AVFoundation

/// Player + trimmer for recordings Topkit just made. Not a general video
/// player: it only ever opens files produced by ScreenRecordingManager.
/// Trim uses AVPlayerView's built-in QuickTime trim UI; committing a trim
/// passthrough-exports the kept range and atomically overwrites the file.
final class RecordingPlayerWindowController: NSWindowController, NSWindowDelegate {

    private let fileURL: URL
    private let playerView = AVPlayerView()
    private var trimButton: NSButton?
    private var keyMonitor: Any?
    private var onClose: (() -> Void)?

    init(fileURL: URL, onClose: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        playerView.controlsStyle = .floating // QuickTime-style floating controls
        playerView.showsFullScreenToggleButton = true
        playerView.player = AVPlayer(url: fileURL)
        window.contentView = playerView

        // Trim button in the titlebar, like QuickTime's Edit > Trim (⌘T).
        let accessory = NSTitlebarAccessoryViewController()
        let button = NSButton(title: String(localized: "Trim"), target: self, action: #selector(trimTapped))
        button.bezelStyle = .toolbar
        if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Trim") {
            button.image = scissors
            button.imagePosition = .imageLeading
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: button.fittingSize.width + 16, height: 28))
        button.frame = NSRect(x: 0, y: 3, width: button.fittingSize.width + 8, height: 22)
        container.addSubview(button)
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        trimButton = button

        // ⌘T while this window is key.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "t" else { return event }
            self.trimTapped()
            return nil
        }

        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Trim

    @objc private func trimTapped() {
        guard playerView.canBeginTrimming else { return }
        trimButton?.isEnabled = false
        playerView.beginTrimming { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard result == .okButton,
                      let item = self.playerView.player?.currentItem,
                      let range = TrimRange.resolve(
                        start: item.reversePlaybackEndTime,
                        end: item.forwardPlaybackEndTime,
                        duration: item.duration
                      ) else {
                    self.resetTrimState()
                    return
                }
                self.exportTrimmed(range: range)
            }
        }
    }

    /// Clear trim bounds AVPlayerView left on the item so playback covers the
    /// whole (current) file again.
    private func resetTrimState() {
        trimButton?.isEnabled = true
        if let item = playerView.player?.currentItem {
            item.reversePlaybackEndTime = .invalid
            item.forwardPlaybackEndTime = .invalid
        }
    }

    private func exportTrimmed(range: CMTimeRange) {
        trimButton?.title = String(localized: "Trimming…")
        let asset = AVURLAsset(url: fileURL)
        // Passthrough = no re-encode, QuickTime-style instant trim. Falls back
        // to a re-encoding preset if passthrough is unavailable for the asset.
        let preset = AVAssetExportSession.exportPresets(compatibleWith: asset).contains(AVAssetExportPresetPassthrough)
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            finishTrim(success: false)
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Trim_\(UUID().uuidString).mov")
        session.outputURL = tempURL
        session.outputFileType = .mov
        session.timeRange = range
        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard session.status == .completed else {
                    debugLog("❌ Trim export failed: \(session.error?.localizedDescription ?? "unknown")")
                    try? FileManager.default.removeItem(at: tempURL)
                    self.finishTrim(success: false)
                    return
                }
                // Overwrite the original — one file, same name, trimmed.
                self.playerView.player?.replaceCurrentItem(with: nil)
                if RecordingDestination.replaceRecording(at: self.fileURL, with: tempURL) != nil {
                    self.playerView.player = AVPlayer(url: self.fileURL)
                    self.finishTrim(success: true)
                } else {
                    try? FileManager.default.removeItem(at: tempURL)
                    self.playerView.player = AVPlayer(url: self.fileURL)
                    self.finishTrim(success: false)
                }
            }
        }
    }

    private func finishTrim(success: Bool) {
        trimButton?.title = String(localized: "Trim")
        resetTrimState()
        ToastPresenter.shared.show(
            message: success ? String(localized: "Recording trimmed") : String(localized: "Trim failed"),
            force: !success
        )
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        playerView.player = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Topkit/Views/RecordingPlayerWindowController.swift
git commit -m "feat: recording player window with QuickTime-style trim and overwrite"
```

---

### Task 12: Open the player after save + activation policy + registration

**Files:**
- Modify: `Topkit/ScreenRecordingManager.swift`
- Modify: `Topkit/AppDelegate.swift`
- Modify: `Topkit.xcodeproj/project.pbxproj`

- [ ] **Step 1: Regular-activation refcount in AppDelegate**

The player and Preferences both need `.regular` activation policy (fullscreen button, proper focus) from an accessory app; whichever closes last flips back. In `AppDelegate`:

Add near `preferencesWindow`:

```swift
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
```

In `showPreferences()`, replace the two lines `NSApp.setActivationPolicy(.regular)` / `NSApp.activate(ignoringOtherApps: true)` with `pushRegularActivation()`.
In `windowWillClose`, replace `NSApp.setActivationPolicy(.accessory)` with `popRegularActivation()`.

- [ ] **Step 2: Manager opens the player**

In `ScreenRecordingManager`, add property:

```swift
    private var playerController: RecordingPlayerWindowController?
```

In `saveFinishedRecording`, replace the `// Phase 2 opens the player here.` comment with:

```swift
        presentPlayer(for: finalURL)
```

And add:

```swift
    /// The post-recording player. Closing it releases everything; there is no
    /// other way to open a video in Topkit.
    private func presentPlayer(for url: URL) {
        playerController?.close()
        (NSApp.delegate as? AppDelegate)?.pushRegularActivation()
        let controller = RecordingPlayerWindowController(fileURL: url) { [weak self] in
            self?.playerController = nil
            (NSApp.delegate as? AppDelegate)?.popRegularActivation()
        }
        playerController = controller
        controller.present()
    }
```

- [ ] **Step 3: Register Phase 2 files in pbxproj**

Same pattern as Task 9:

```
		RECBF000000000000000PLY1 /* RecordingPlayerWindowController.swift in Sources */ = {isa = PBXBuildFile; fileRef = RECFR000000000000000PLY1 /* RecordingPlayerWindowController.swift */; };
		RECBF000000000000000TST2 /* TrimRangeTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = RECFR000000000000000TST2 /* TrimRangeTests.swift */; };
		RECFR000000000000000PLY1 /* RecordingPlayerWindowController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RecordingPlayerWindowController.swift; sourceTree = "<group>"; };
		RECFR000000000000000TST2 /* TrimRangeTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TrimRangeTests.swift; sourceTree = "<group>"; };
```

- `RECFR000000000000000PLY1` → Views group children + app target Sources (`RECBF…PLY1`).
- `RECFR000000000000000TST2` → tests group children + test target Sources (`RECBF…TST2`).

- [ ] **Step 4: Full verify**

```bash
swift build && swift test
export LANG=en_US.UTF-8
xcodebuild -project Topkit.xcodeproj -scheme Topkit -configuration Debug build
```

Expected: all succeed.

- [ ] **Step 5: Commit**

```bash
git add Topkit/ScreenRecordingManager.swift Topkit/AppDelegate.swift Topkit.xcodeproj/project.pbxproj
git commit -m "feat: open player after recording saves; shared regular-activation refcount"
```

---

## Out of scope (explicitly)

- Audio capture (mic or system) — `capturesAudio` stays false in v1.
- Opening arbitrary video files in the player — it only plays what Topkit records.
- Annotation tools inside the recorder — the existing on-screen tools (Draw, Measure, Guides, Halo) are the annotation story and are captured live.
- Cross-display region recording — clamped to one display (one SCStream per display; multi-stream compositing is a much bigger project).
- GIF/MP4 export, pause/resume mid-recording, camera overlay.

## TestFlight verification checklist (for Tommy, post-ship)

Phase 1 (success = the file lands on disk, playable, sane size):
- Menu shows Record Screen under Screenshot; ⌃⌥⇧E triggers it.
- First run: grant panel pointed at Desktop; after Grant Access the picker appears.
- Region drag → dim + hole + Start Recording/Cancel toolbar; handles resize; Esc cancels.
- Click a window → hole snaps to it, no resize handles.
- Start Recording: tray icon goes red (only now — picker/confirm phases show the white badge), everything outside stays dimmed, clicks pass through, Draw/Measure work and appear in the video, the dim overlays do NOT appear in the video.
- Stop three ways: menu "Stop Recording" (red), ⌃⌥⇧E, plain Esc. Each saves the .mov to Desktop (or chosen folder) with timestamp name; toast fires; icon back to normal.
- File quality: UI text crisp, ~7.5 Mbps ceiling at 1080p60 / 14 Mbps at retina full-screen, mostly-static screens produce small files.
- Prefs: recording folder row + Record Screen shortcut row.

Phase 2:
- Player opens automatically after stop; floating QuickTime-style controls; resize + fullscreen work.
- Trim (button or ⌘T) shows the yellow QuickTime trim bar with thumbnails; Trim commits, file is overwritten in place (same filename); Cancel leaves it untouched.
- Closing the player ends the whole flow; tray icon idle.
