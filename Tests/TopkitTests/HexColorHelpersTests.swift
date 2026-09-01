import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class HexColorHelpersTests: XCTestCase {
    func testParseHexColorWithLeadingHash() {
        let red = try! XCTUnwrap(HexColorParser.parse("#FF0000")?.usingColorSpace(.sRGB))
        let green = try! XCTUnwrap(HexColorParser.parse("#00FF00")?.usingColorSpace(.sRGB))
        let blue = try! XCTUnwrap(HexColorParser.parse("#0000FF")?.usingColorSpace(.sRGB))

        XCTAssertEqual(red.redComponent, CGFloat(1.0), accuracy: CGFloat(0.0001))
        XCTAssertEqual(green.greenComponent, CGFloat(1.0), accuracy: CGFloat(0.0001))
        XCTAssertEqual(blue.blueComponent, CGFloat(1.0), accuracy: CGFloat(0.0001))
    }

    func testParseHexColorWithoutHash() {
        XCTAssertNotNil(HexColorParser.parse("FF0000"))
        XCTAssertNotNil(HexColorParser.parse("F00"))
    }

    func testParseHexColorInvalidInputs() {
        XCTAssertNil(HexColorParser.parse("#FFFF"))
        XCTAssertNil(HexColorParser.parse("#GGG"))
        XCTAssertNil(HexColorParser.parse("12"))
    }

    func testColorToHexForPrimaryColors() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

        XCTAssertEqual(HexColorConverter.colorToHex(red), "#FF0000")
        XCTAssertEqual(HexColorConverter.colorToHex(green), "#00FF00")
        XCTAssertEqual(HexColorConverter.colorToHex(blue), "#0000FF")
        XCTAssertEqual(HexColorConverter.colorToHex(white), "#FFFFFF")
        XCTAssertEqual(HexColorConverter.colorToHex(black), "#000000")
    }
}

