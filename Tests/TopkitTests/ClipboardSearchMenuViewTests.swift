import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ClipboardSearchMenuViewTests: XCTestCase {

    /// A typed character reaches the view twice (text-did-change, then the
    /// search action), and every report refilters the whole history — so each
    /// change must be reported once (TEC-354).
    func testEachTypedCharacterIsReportedOnce() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = ClipboardSearchMenuView(initialQuery: "")
        window.contentView = view
        var reports: [String] = []
        view.onQueryChanged = { reports.append($0) }

        view.searchField.selectText(nil)
        let editor = try XCTUnwrap(view.searchField.currentEditor() as? NSTextView)
        editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(reports, ["a", "ab"])
    }

    func testClearButtonAndEscapeStillReportTheEmptyQuery() {
        _ = NSApplication.shared
        let view = ClipboardSearchMenuView(initialQuery: "abc")
        var reports: [String] = []
        view.onQueryChanged = { reports.append($0) }

        // The clear (x) button only sends the action.
        view.searchField.stringValue = ""
        _ = view.searchField.sendAction(view.searchField.action, to: view.searchField.target)
        XCTAssertEqual(reports, [""])

        view.searchField.stringValue = "x"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.searchField))
        let handled = view.control(view.searchField, textView: NSTextView(),
                                   doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(handled)
        XCTAssertEqual(reports, ["", "x", ""])
    }
}
