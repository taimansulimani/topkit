import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class RectangleSizeValidatorTests: XCTestCase {
    func testClampToAtLeast1x1() {
        let clamped = RectangleSizeValidator.clamp(size: NSSize(width: -10, height: -5), toViewport: NSSize(width: 100, height: 200))
        XCTAssertEqual(clamped.width, 1)
        XCTAssertEqual(clamped.height, 1)
    }

    func testClampToViewportMax() {
        let clamped = RectangleSizeValidator.clamp(size: NSSize(width: 1000, height: 500), toViewport: NSSize(width: 300, height: 200))
        XCTAssertEqual(clamped.width, 300)
        XCTAssertEqual(clamped.height, 200)
    }

    func testClampSmallValuesToAtLeast1() {
        let clamped = RectangleSizeValidator.clamp(size: NSSize(width: 0.5, height: 0.5), toViewport: NSSize(width: 100, height: 100))
        XCTAssertEqual(clamped.width, 1)
        XCTAssertEqual(clamped.height, 1)
    }
}

