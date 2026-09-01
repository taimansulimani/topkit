import XCTest

final class TopkitUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Menu bar app: verify the process launches without crashing.
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning)
    }
}
