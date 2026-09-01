import Foundation
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ClipboardPinningHelpersTests: XCTestCase {

    /// History in recency order: "0" newest ... "n-1" oldest.
    private func makeHistory(_ count: Int) -> [ClipboardItem] {
        (0..<count).map { index in
            ClipboardItem(
                content: "\(index)",
                type: .text,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 60)
            )
        }
    }

    private func contents(_ history: [ClipboardItem]) -> [String] {
        history.map { $0.content }
    }

    // MARK: - togglingPin

    func testPinMovesItemToTopAndSetsFlag() {
        let history = makeHistory(10)
        let pinned = ClipboardPinningHelpers.togglingPin(history, id: history[6].id)

        XCTAssertEqual(contents(pinned), ["6", "0", "1", "2", "3", "4", "5", "7", "8", "9"])
        XCTAssertEqual(pinned[0].isPinned, true)
        XCTAssertEqual(ClipboardPinningHelpers.pinnedCount(pinned), 1)
    }

    func testPinningSecondItemGoesAboveExistingPin() {
        var history = makeHistory(5)
        history = ClipboardPinningHelpers.togglingPin(history, id: history[3].id) // "3" pinned
        let idOfTwo = history.first(where: { $0.content == "2" })!.id
        history = ClipboardPinningHelpers.togglingPin(history, id: idOfTwo)

        XCTAssertEqual(contents(history), ["2", "3", "0", "1", "4"])
        XCTAssertEqual(ClipboardPinningHelpers.pinnedCount(history), 2)
    }

    func testUnpinReturnsItemToRecencyPosition() {
        var history = makeHistory(10)
        let pinnedID = history[6].id
        history = ClipboardPinningHelpers.togglingPin(history, id: pinnedID)
        history = ClipboardPinningHelpers.togglingPin(history, id: pinnedID)

        XCTAssertEqual(contents(history), (0..<10).map(String.init))
        XCTAssertTrue(history.allSatisfy { $0.isPinned != true })
    }

    func testUnpinOldestItemGoesToEnd() {
        var history = makeHistory(4)
        let oldest = history[3].id
        history = ClipboardPinningHelpers.togglingPin(history, id: oldest)
        history = ClipboardPinningHelpers.togglingPin(history, id: oldest)

        XCTAssertEqual(contents(history), ["0", "1", "2", "3"])
    }

    func testUnpinWithOtherPinsKeepsThemOnTop() {
        var history = makeHistory(6)
        let idFive = history[5].id
        let idOne = history[1].id
        history = ClipboardPinningHelpers.togglingPin(history, id: idFive)
        history = ClipboardPinningHelpers.togglingPin(history, id: idOne)
        // Pinned block: ["1", "5"], unpinned: ["0", "2", "3", "4"]
        history = ClipboardPinningHelpers.togglingPin(history, id: idFive)

        XCTAssertEqual(contents(history), ["1", "0", "2", "3", "4", "5"])
        XCTAssertEqual(ClipboardPinningHelpers.pinnedCount(history), 1)
    }

    func testToggleUnknownIDIsNoOp() {
        let history = makeHistory(3)
        let toggled = ClipboardPinningHelpers.togglingPin(history, id: UUID())
        XCTAssertEqual(contents(toggled), contents(history))
    }

    // MARK: - addingItem

    func testNewItemInsertsBelowPinnedBlock() {
        var history = makeHistory(4)
        history = ClipboardPinningHelpers.togglingPin(history, id: history[2].id) // "2" pinned

        let fresh = ClipboardItem(content: "new", type: .text)
        history = ClipboardPinningHelpers.addingItem(fresh, to: history)

        XCTAssertEqual(contents(history), ["2", "new", "0", "1", "3"])
        XCTAssertEqual(ClipboardPinningHelpers.pinnedCount(history), 1)
    }

    func testDuplicateOfPinnedItemKeepsPinAndPositionAndRefreshesTimestamp() {
        var history = makeHistory(4)
        let pinnedID = history[2].id
        history = ClipboardPinningHelpers.togglingPin(history, id: pinnedID)

        let recopied = ClipboardItem(content: "2", type: .text, timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        history = ClipboardPinningHelpers.addingItem(recopied, to: history)

        XCTAssertEqual(contents(history), ["2", "0", "1", "3"])
        XCTAssertEqual(history[0].id, pinnedID)
        XCTAssertEqual(history[0].isPinned, true)
        XCTAssertEqual(history[0].timestamp, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testDuplicateOfUnpinnedItemMovesToTopOfUnpinnedBlock() {
        var history = makeHistory(4)
        history = ClipboardPinningHelpers.togglingPin(history, id: history[1].id) // "1" pinned

        let recopied = ClipboardItem(content: "3", type: .text)
        history = ClipboardPinningHelpers.addingItem(recopied, to: history)

        XCTAssertEqual(contents(history), ["1", "3", "0", "2"])
    }

    func testDuplicateImageOfPinnedItemDedupsByHash() {
        let imageItem = ClipboardItem(content: "Image", type: .image, imageHash: "abc123")
        var history = [imageItem, ClipboardItem(content: "text", type: .text)]
        history = ClipboardPinningHelpers.togglingPin(history, id: imageItem.id)

        let recopied = ClipboardItem(content: "Image", type: .image, imageHash: "abc123")
        history = ClipboardPinningHelpers.addingItem(recopied, to: history)

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].id, imageItem.id)
        XCTAssertEqual(history[0].isPinned, true)
    }

    func testAddedItemNeverCarriesAPinFlag() {
        let pinnedInput = ClipboardItem(content: "sneaky", type: .text, isPinned: true)
        let history = ClipboardPinningHelpers.addingItem(pinnedInput, to: [])
        XCTAssertEqual(history[0].isPinned, nil)
    }

    // MARK: - normalized

    func testNormalizedMovesPinnedItemsToHeadPreservingOrder() {
        var history = makeHistory(5)
        history[2].isPinned = true
        history[4].isPinned = true

        let normalized = ClipboardPinningHelpers.normalized(history)
        XCTAssertEqual(contents(normalized), ["2", "4", "0", "1", "3"])
    }

    func testNormalizedWithNoPinsReturnsHistoryUnchanged() {
        let history = makeHistory(3)
        XCTAssertEqual(contents(ClipboardPinningHelpers.normalized(history)), contents(history))
    }

    // MARK: - Codable compatibility

    func testLegacyJSONWithoutPinFieldDecodesAsUnpinned() throws {
        let item = ClipboardItem(content: "old", type: .text)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        json.removeValue(forKey: "isPinned")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)
        XCTAssertNil(decoded.isPinned)
    }

    func testPinFlagSurvivesCodableRoundTrip() throws {
        let item = ClipboardItem(content: "pinned", type: .text, isPinned: true)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.isPinned, true)
    }
}
