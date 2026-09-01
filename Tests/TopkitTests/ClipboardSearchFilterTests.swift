import Foundation
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ClipboardSearchFilterTests: XCTestCase {

    private func text(_ content: String) -> ClipboardItem {
        ClipboardItem(content: content, type: .text)
    }

    private func image() -> ClipboardItem {
        ClipboardItem(content: "Image", type: .image)
    }

    private func file(_ paths: [String]) -> ClipboardItem {
        ClipboardItem(content: paths.joined(separator: ", "), type: .file, filePaths: paths)
    }

    // MARK: - Basic filtering

    func testNonMatchingItemsAreDropped() {
        let history = [text("hello world"), text("apples"), text("hollow")]
        let matches = ClipboardSearchFilter.matches(history: history, query: "hlo")
        XCTAssertEqual(matches.map(\.historyIndex).sorted(), [0, 2])
    }

    func testNoMatchesReturnsEmpty() {
        let history = [text("alpha"), text("beta")]
        XCTAssertTrue(ClipboardSearchFilter.matches(history: history, query: "zzz").isEmpty)
        XCTAssertTrue(ClipboardSearchFilter.matches(history: [], query: "a").isEmpty)
    }

    func testWhitespaceOnlyQueryMatchesEverythingInOrder() {
        let history = [text("alpha"), text("beta"), image()]
        let matches = ClipboardSearchFilter.matches(history: history, query: "   ")
        XCTAssertEqual(matches.map(\.historyIndex), [0, 1, 2])
    }

    func testRankedByScoreDescendingThenRecency() {
        // "car" as a word beats "car" buried mid-word; equal scores keep history order.
        let history = [text("vicarious"), text("car park"), text("car keys")]
        let matches = ClipboardSearchFilter.matches(history: history, query: "car")
        XCTAssertEqual(matches.map(\.historyIndex), [1, 2, 0])
    }

    // MARK: - Item types

    func testImageItemsMatchTheWordImage() {
        let history = [text("no such thing"), image()]
        XCTAssertEqual(ClipboardSearchFilter.matches(history: history, query: "img").map(\.historyIndex), [1])
        XCTAssertEqual(ClipboardSearchFilter.matches(history: history, query: "image").map(\.historyIndex), [1])
    }

    func testFileItemsMatchOnPath() {
        let history = [file(["/Users/tr/Desktop/report.pdf"]), text("unrelated")]
        XCTAssertEqual(ClipboardSearchFilter.matches(history: history, query: "report").map(\.historyIndex), [0])
    }

    // MARK: - Ordinal (numeric) queries

    func testNumericQueryPinsThatHistoryPositionFirst() {
        var history = (1...50).map { text("entry number \($0)") }
        history[10] = text("zzz")           // item 11, no "42" in content
        let matches = ClipboardSearchFilter.matches(history: history, query: "11")
        XCTAssertEqual(matches.first?.historyIndex, 10)
    }

    func testNumericQueryAlsoIncludesContentMatches() {
        let history = [text("call 42 now"), text("bbb"), text("ccc")]
        // "42" is out of ordinal range (only 3 items) but matches content of item 0.
        let matches = ClipboardSearchFilter.matches(history: history, query: "42")
        XCTAssertEqual(matches.map(\.historyIndex), [0])
    }

    func testNumericQueryDedupesOrdinalAndContentMatch() {
        let history = [text("aaa"), text("item 2 of 2")]
        // Item at position 2 also contains "2" — must appear once, pinned first.
        let matches = ClipboardSearchFilter.matches(history: history, query: "2")
        XCTAssertEqual(matches.map(\.historyIndex), [1])
    }

    func testNumericQueryOutOfRangeFallsBackToContentOnly() {
        let history = [text("aaa"), text("bbb")]
        XCTAssertTrue(ClipboardSearchFilter.matches(history: history, query: "99").isEmpty)
    }

    func testOrdinalZeroIsNotValid() {
        let history = [text("0 degrees"), text("bbb")]
        let matches = ClipboardSearchFilter.matches(history: history, query: "0")
        // No ordinal pin (positions are 1-based); content match only.
        XCTAssertEqual(matches.map(\.historyIndex), [0])
    }
}
