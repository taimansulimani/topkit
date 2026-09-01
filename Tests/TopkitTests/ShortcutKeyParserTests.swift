import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ShortcutKeyParserTests: XCTestCase {
    func testShortcutParseLettersAndModifiers() {
        let parsed = ShortcutKeyParser.parse(shortcutString: "⌃⌥⇧⌘C")
        XCTAssertEqual(parsed.keyEquivalent, "c")
        XCTAssertTrue(parsed.modifiers.contains(.control))
        XCTAssertTrue(parsed.modifiers.contains(.option))
        XCTAssertTrue(parsed.modifiers.contains(.shift))
        XCTAssertTrue(parsed.modifiers.contains(.command))
    }

    func testShortcutParseWhitespace() {
        let parsed = ShortcutKeyParser.parse(shortcutString: "␣")
        XCTAssertEqual(parsed.keyEquivalent, " ")
    }

    func testShortcutParseReturn() {
        let parsed = ShortcutKeyParser.parse(shortcutString: "↩")
        XCTAssertEqual(parsed.keyEquivalent, "\r")
    }
}

