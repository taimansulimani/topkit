import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class StandardAboutPanelTests: XCTestCase {

    func testOptionsPutTheFullLabelInApplicationVersionAndLeaveBuildEmpty() {
        let options = StandardAboutPanel.options(versionLabel: "1.1")
        XCTAssertEqual(options[.applicationVersion] as? String, "1.1")
        XCTAssertEqual(options[.version] as? String, "")
    }

    func testOptionsCarryTestFlightAndDebugLabelsUnchanged() {
        XCTAssertEqual(
            StandardAboutPanel.options(versionLabel: "1.1 (1007)")[.applicationVersion] as? String,
            "1.1 (1007)"
        )
        XCTAssertEqual(
            StandardAboutPanel.options(versionLabel: "1.1 (1007) Debug")[.applicationVersion] as? String,
            "1.1 (1007) Debug"
        )
    }

    func testApplicationMenuAboutUsesCustomPanelNotStockSelector() {
        let appMenu = StandardEditMenu.makeApplicationMenu()
        let about = appMenu.items.first { $0.title.hasPrefix("About ") }
        XCTAssertNotNil(about)
        XCTAssertEqual(about?.action, #selector(StandardAboutPanelTarget.showAboutPanel(_:)))
        XCTAssertIdentical(about?.target as AnyObject?, StandardAboutPanelTarget.shared)
    }
}
