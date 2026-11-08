import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// TEC-234: ⌘A in an annotation's text field did nothing but beep, and ⌘C / ⌘V / ⌘X
/// shared the cause. Topkit had no main menu, and AppKit text fields only get these
/// keys through main-menu key equivalents.
final class StandardEditMenuTests: XCTestCase {

    private func item(for key: String, in menu: NSMenu) -> NSMenuItem? {
        for top in menu.items {
            guard let sub = top.submenu else { continue }
            if let match = sub.items.first(where: {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command
            }) {
                return match
            }
        }
        return nil
    }

    func testEditMenuSendsTheTextActionsForCommandACVX() {
        let menu = StandardEditMenu.makeMainMenu()
        let expected: [(key: String, action: Selector)] = [
            ("a", #selector(NSText.selectAll(_:))),
            ("c", #selector(NSText.copy(_:))),
            ("v", #selector(NSText.paste(_:))),
            ("x", #selector(NSText.cut(_:))),
        ]
        for entry in expected {
            guard let found = item(for: entry.key, in: menu) else {
                XCTFail("no ⌘\(entry.key.uppercased()) item in the main menu")
                continue
            }
            XCTAssertEqual(found.action, entry.action, "⌘\(entry.key.uppercased())")
            XCTAssertNil(found.target, "⌘\(entry.key.uppercased()) must go to the first responder (the field editor)")
            XCTAssertEqual(found.menu?.title, StandardEditMenu.editMenuTitle)
        }
    }

    /// AppKit shows the first main-menu item as the application menu, so Edit must not
    /// be first or its items would sit under "Topkit" whenever the menu bar shows.
    func testEditIsNotTheApplicationMenu() {
        let menu = StandardEditMenu.makeMainMenu()
        XCTAssertGreaterThanOrEqual(menu.items.count, 2)
        XCTAssertNotEqual(menu.items.first?.submenu?.title, StandardEditMenu.editMenuTitle)
        let appMenuItems = menu.items.first?.submenu?.items ?? []
        XCTAssertFalse(appMenuItems.isEmpty, "the application menu is not left empty")
        XCTAssertTrue(appMenuItems.allSatisfy { $0.keyEquivalent.isEmpty },
                      "the application menu carries no key equivalents")
        XCTAssertTrue(appMenuItems.contains { $0.action == #selector(NSApplication.terminate(_:)) })
    }

    /// ⌘Z belongs to the canvas's own undo, and ⌘Q mid-annotation would lose the marks.
    func testNoUndoRedoOrQuitKeyEquivalents() {
        let menu = StandardEditMenu.makeMainMenu()
        XCTAssertNil(item(for: "z", in: menu))
        XCTAssertNil(item(for: "q", in: menu))
        let allItems = menu.items.flatMap { $0.submenu?.items ?? [] }
        XCTAssertFalse(allItems.contains { $0.action == Selector(("undo:")) || $0.action == Selector(("redo:")) })
    }

    func testInstallSetsTheAppMainMenu() {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }

        StandardEditMenu.install(in: app)
        XCTAssertNotNil(app.mainMenu.flatMap { item(for: "a", in: $0) },
                        "⌘A must be reachable from NSApp.mainMenu")
    }

    /// The menu items reach the text field's field editor, which does the work.
    func testSelectAllSentToTheAnnotationFieldEditorSelectsAllText() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let field = EditableTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 30))
        field.stringValue = "Hello annotation"
        window.contentView?.addSubview(field)
        defer { window.contentView = nil }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard let editor = field.currentEditor() as? NSTextView else {
            return XCTFail("precondition: the field is being edited")
        }
        editor.setSelectedRange(NSRange(location: 3, length: 0))

        guard let selectAll = item(for: "a", in: StandardEditMenu.makeMainMenu())?.action else {
            return XCTFail("no ⌘A item")
        }
        XCTAssertTrue(editor.tryToPerform(selectAll, with: nil))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: ("Hello annotation" as NSString).length))
    }

    /// The canvas's app-wide key monitor must leave these keys to the text field while
    /// a text mark is being typed, or the Edit menu never sees them.
    func testCanvasKeyMonitorLeavesCommandACVXToAnOpenTextField() {
        _ = NSApplication.shared
        let window = LiveAnnotationOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), mode: .liveAnnotate)
        window.contentView = view
        defer { window.contentView = nil }

        view.setArmedTool(.text)
        view.handlePointerDown(at: NSPoint(x: 200, y: 200), clickCount: 1)
        XCTAssertTrue(view._isEditingTextForTesting, "precondition: a text field is open")

        let keys: [(code: UInt16, char: String)] = [(0, "a"), (8, "c"), (9, "v"), (7, "x")]
        for key in keys {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: key.char, charactersIgnoringModifiers: key.char,
                isARepeat: false, keyCode: key.code
            )!
            XCTAssertFalse(view._keyMonitorConsumesForTesting(event),
                           "⌘\(key.char.uppercased()) must reach the text field")
        }
    }
}
