import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// The tool shortcuts have to mean the same thing in three places: the hotkey
/// bindings, the toolbar tooltips, and the screenshot editor's own tool arming.
/// These lock the mapping and both of the surfaces that read it.
final class AnnotationToolShortcutsTests: XCTestCase {

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - The mapping

    /// The defaults keys are historical and shared with Preferences and the hotkey
    /// bindings in AppDelegate — renaming one silently orphans a user's shortcut.
    func testDefaultsKeysMatchThePreferenceKeys() {
        let expected: [(AnnotationTool, String)] = [
            (.freehand, "shortcutDraw"),
            (.rectangle, "shortcutAnnotateRectangle"),
            (.circle, "shortcutAnnotateCircle"),
            (.arrow, "shortcutAnnotateArrow"),
            (.text, "shortcutAnnotateText"),
            (.blur, "shortcutAnnotateRedact"),
            (.sticker(.redX), "shortcutAnnotateSticker"),
            (.numberBadge, "shortcutAnnotateBadge"),
            (.measure, "shortcutMeasure"),
            (.guide(.vertical), "shortcutAddVerticalGuide"),
            (.guide(.horizontal), "shortcutAddGuide"),
            (.grid, "shortcutAddRectangle"),
        ]
        for (tool, key) in expected {
            XCTAssertEqual(AnnotationToolShortcuts.defaultsKey(for: tool), key, "\(tool)")
        }
    }

    /// Every sticker type shares one shortcut — the toolbar button places whichever
    /// type is currently showing.
    func testAllStickerTypesShareOneKey() {
        let keys = [StickerType.redX, .greenCheck, .yellowExclamation]
            .map { AnnotationToolShortcuts.defaultsKey(for: .sticker($0)) }
        XCTAssertEqual(Set(keys), ["shortcutAnnotateSticker"])
    }

    func testTooltipShowsTheAssignedCombo() {
        let defaults = UserDefaults(suiteName: "AnnotationToolShortcutsTests")!
        defaults.set("⌥⌘R", forKey: "shortcutAnnotateRectangle")
        XCTAssertEqual(
            AnnotationToolShortcuts.tooltip("Rectangle", tool: .rectangle, defaults: defaults),
            "Rectangle (⌥⌘R)"
        )
    }

    /// A cleared shortcut must read as a plain name, not as empty brackets.
    ///
    /// Cleared, not absent: `AppDelegate` registers a default combo for every one of
    /// these keys, so "no value written" still resolves to `⌃⇧`-something. A suite
    /// `UserDefaults` does not isolate you from that — the registration domain is last
    /// in every search list — so the empty value has to be written explicitly.
    func testTooltipFallsBackToThePlainTitleWhenCleared() {
        let defaults = UserDefaults(suiteName: "AnnotationToolShortcutsTests.unset")!
        defaults.set("", forKey: "shortcutAnnotateCircle")
        XCTAssertEqual(
            AnnotationToolShortcuts.tooltip("Circle", tool: .circle, defaults: defaults),
            "Circle"
        )
        defaults.set("   ", forKey: "shortcutAnnotateCircle")
        XCTAssertEqual(
            AnnotationToolShortcuts.tooltip("Circle", tool: .circle, defaults: defaults),
            "Circle",
            "Whitespace is not a shortcut"
        )
    }

    // MARK: - Tooltips on the two toolbars
    //
    // The toolbars read `UserDefaults.standard` as they build, so these set every key
    // they assert on. Nothing here may lean on the ambient value: under `swift test`
    // the keys are empty, but CI runs the same tests hosted inside Topkit.app, where
    // `AppDelegate` has registered a default combo for all of them.

    private func toolbarButtons(in view: NSView) -> [NSButton] {
        let toolbar = view.subviews.first { $0.identifier == AnnotationToolbarChrome.Identifier.editorToolbar }
        return (toolbar?.subviews ?? []).compactMap { $0 as? NSButton }
    }

    /// Value as actually persisted, ignoring the registration domain — restoring a
    /// registered-only key with `set` would promote it into the user's real prefs.
    private func persistedShortcut(_ key: String) -> String? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else { return nil }
        return domain[key] as? String
    }

    private func withShortcuts(_ values: [String: String], _ body: () -> Void) {
        let saved = values.keys.map { ($0, persistedShortcut($0)) }
        for (key, value) in values {
            UserDefaults.standard.set(value, forKey: key)
        }
        defer {
            for (key, previous) in saved {
                if let previous {
                    UserDefaults.standard.set(previous, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        body()
    }

    /// The screenshot editor's toolbar had no tooltips at all.
    func testScreenshotEditorToolbarButtonsCarryTooltipsWithShortcuts() {
        withShortcuts(["shortcutAnnotateText": "⌥⌘T", "shortcutDraw": ""]) {
            let view = ScreenshotAnnotationView(
                frame: screen,
                screenshot: nil,
                screenshotRect: NSRect(x: 200, y: 200, width: 400, height: 300)
            )
            let window = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view

            let tooltips = toolbarButtons(in: view).compactMap(\.toolTip)
            XCTAssertFalse(tooltips.contains(where: { $0.isEmpty }))
            XCTAssertTrue(tooltips.contains("Text (⌥⌘T)"), "Got: \(tooltips)")
            XCTAssertTrue(tooltips.contains("Freehand"), "A cleared shortcut keeps the plain name: \(tooltips)")
            // Close and Save pass `.freehand` only to satisfy the tag helper; they must
            // not advertise the Freehand shortcut.
            XCTAssertTrue(tooltips.contains("Close (⎋)"), "Got: \(tooltips)")
            XCTAssertTrue(tooltips.contains("Save (↩)"), "Got: \(tooltips)")
        }
    }

    func testAnnotateToolStripButtonsCarryTheSameTooltips() {
        withShortcuts(["shortcutMeasure": "⌥⌘M", "shortcutAddRectangle": ""]) {
            let strip = AnnotateToolStrip(items: [
                .init(tool: .measure, icon: "ruler", title: "Measure"),
                .init(tool: .grid, icon: "square.grid.3x3", title: "Grid"),
            ])
            let tooltips = strip.subviews.compactMap { ($0 as? NSButton)?.toolTip }
            XCTAssertTrue(tooltips.contains("Measure (⌥⌘M)"), "Got: \(tooltips)")
            XCTAssertTrue(tooltips.contains("Grid"), "Got: \(tooltips)")
            XCTAssertTrue(tooltips.contains("End Annotate (⎋)"), "Got: \(tooltips)")
        }
    }

    // MARK: - Arming from a shortcut inside the screenshot editor

    private func editorView() -> ScreenshotAnnotationView {
        let view = ScreenshotAnnotationView(
            frame: screen,
            screenshot: nil,
            screenshotRect: NSRect(x: 200, y: 200, width: 400, height: 300)
        )
        let window = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        return view
    }

    func testShortcutArmsAndTogglesTheEditorTool() {
        let view = editorView()
        XCTAssertNil(view.armedTool)

        XCTAssertTrue(view.selectToolFromShortcut(.text))
        XCTAssertEqual(view.armedTool, .text)

        // A different tool swaps.
        XCTAssertTrue(view.selectToolFromShortcut(.rectangle))
        XCTAssertEqual(view.armedTool, .rectangle)

        // The same tool again disarms, matching a second click on the toolbar button.
        XCTAssertTrue(view.selectToolFromShortcut(.rectangle))
        XCTAssertNil(view.armedTool)
    }

    /// The sticker shortcut must place the type the toolbar button is showing, not
    /// whatever the caller happened to pass.
    func testStickerShortcutResolvesToTheSelectedStickerType() {
        let view = editorView()
        XCTAssertTrue(view.selectToolFromShortcut(.sticker(.greenCheck)))
        XCTAssertEqual(view.armedTool, .sticker(.redX))
    }

    /// The Annotate overlay's strip is driven by its host through `setArmedTool`; this
    /// path must decline so the host does not double-handle the key.
    func testAnnotateOverlayDeclinesTheEditorShortcutPath() {
        let view = ScreenshotAnnotationView(frame: screen, mode: .liveAnnotate)
        XCTAssertFalse(view.selectToolFromShortcut(.rectangle))
        XCTAssertNil(view.armedTool)
    }
}
