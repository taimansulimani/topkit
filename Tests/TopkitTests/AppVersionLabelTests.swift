import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// About shows one line carrying two different numbers: the public version and the
/// build of it this copy is. Tommy reads the build number off a screenshot to know
/// which binary a report came from, so the shape of the line is worth pinning.
final class AppVersionLabelTests: XCTestCase {

    func testTheLineCarriesBothNumbers() {
        XCTAssertEqual(AppVersionLabel.text(short: "1.0", build: "251"), "1.0 (251)")
    }

    /// A build outside a git checkout leaves the stamp off; the line drops the
    /// brackets rather than showing an empty pair.
    func testAMissingBuildNumberLeavesJustTheVersion() {
        XCTAssertEqual(AppVersionLabel.text(short: "1.0", build: nil), "1.0")
        XCTAssertEqual(AppVersionLabel.text(short: "1.0", build: ""), "1.0")
    }

    func testAMissingVersionFallsBackRatherThanShowingNothing() {
        XCTAssertEqual(AppVersionLabel.text(short: nil, build: "251"), "1.0 (251)")
        XCTAssertEqual(AppVersionLabel.text(short: "", build: nil), "1.0")
    }

    /// The real plist values, whatever they are, must produce a usable line.
    func testTheBundleReadsAsAVersionLine() {
        XCTAssertFalse(AppVersionLabel.current.isEmpty)
    }
}
