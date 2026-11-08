import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// About's version line. App Store copies show the version as the listing does;
/// TestFlight copies add the build number, which Tommy reads off a tester's
/// screenshot to know which binary a report came from; Debug builds say Debug.
final class AppVersionLabelTests: XCTestCase {

    func testTheAppStoreShowsTheVersionAlone() {
        XCTAssertEqual(AppVersionLabel.text(short: "1.1", build: "1007", channel: .appStore), "1.1")
        XCTAssertEqual(AppVersionLabel.text(short: "1.1.1", build: "1010", channel: .appStore), "1.1.1")
    }

    func testTestFlightCarriesTheBuildNumber() {
        XCTAssertEqual(AppVersionLabel.text(short: "1.1", build: "1007", channel: .testFlight), "1.1 (1007)")
    }

    func testDebugBuildsSayDebug() {
        XCTAssertEqual(AppVersionLabel.text(short: "1.1", build: "1007", channel: .debug), "1.1 (1007) Debug")
        XCTAssertEqual(AppVersionLabel.text(short: "1.1", build: nil, channel: .debug), "1.1 Debug")
    }

    /// A build outside a git checkout leaves the stamp off; the line drops the
    /// brackets rather than showing an empty pair.
    func testAMissingBuildNumberLeavesJustTheVersion() {
        XCTAssertEqual(AppVersionLabel.text(short: "1.0", build: nil, channel: .testFlight), "1.0")
        XCTAssertEqual(AppVersionLabel.text(short: "1.0", build: "", channel: .testFlight), "1.0")
    }

    func testAMissingVersionFallsBackRatherThanShowingNothing() {
        XCTAssertEqual(AppVersionLabel.text(short: nil, build: "251", channel: .testFlight), "1.0 (251)")
        XCTAssertEqual(AppVersionLabel.text(short: "", build: nil, channel: .appStore), "1.0")
    }

    func testTheChannelComesFromTheBuildAndReceipt() {
        let receipts = URL(fileURLWithPath: "/Applications/Topkit.app/Contents/_MASReceipt")
        XCTAssertEqual(AppVersionLabel.channel(isDebug: true, receiptURL: receipts.appendingPathComponent("receipt")), .debug)
        XCTAssertEqual(AppVersionLabel.channel(isDebug: false, receiptURL: receipts.appendingPathComponent("sandboxReceipt")), .testFlight)
        XCTAssertEqual(AppVersionLabel.channel(isDebug: false, receiptURL: receipts.appendingPathComponent("receipt")), .appStore)
    }

    /// The real plist values, whatever they are, must produce a usable line.
    func testTheBundleReadsAsAVersionLine() {
        XCTAssertFalse(AppVersionLabel.current.isEmpty)
    }
}
