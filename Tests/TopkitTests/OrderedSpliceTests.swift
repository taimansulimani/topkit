import Foundation
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class OrderedSpliceTests: XCTestCase {

    /// Runs `apply` on a plain array, the way the menu section is edited.
    private func splice(_ old: [Int], into new: [Int]) -> (result: [Int], removed: Int, inserted: Int) {
        var list = old
        var removed = 0
        var inserted = 0
        OrderedSplice.apply(
            from: old,
            to: new,
            remove: { list.remove(at: $0); removed += 1 },
            insert: { list.insert($0, at: $1); inserted += 1 }
        )
        return (list, removed, inserted)
    }

    func testNarrowingAQueryOnlyRemovesTheRowsThatDropOut() {
        let outcome = splice([1, 2, 3, 4, 5], into: [1, 3, 5])
        XCTAssertEqual(outcome.result, [1, 3, 5])
        XCTAssertEqual(outcome.removed, 2)
        XCTAssertEqual(outcome.inserted, 0)
    }

    func testGrowingTheListOnlyAppends() {
        let outcome = splice([1, 2, 3], into: [1, 2, 3, 4, 5])
        XCTAssertEqual(outcome.result, [1, 2, 3, 4, 5])
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertEqual(outcome.inserted, 2)
    }

    func testAReorderedRowMovesAloneWhileTheRestStay() {
        // 5 jumps to the top; 1-4 keep their order and stay put.
        let outcome = splice([1, 2, 3, 4, 5], into: [5, 1, 2, 3, 4])
        XCTAssertEqual(outcome.result, [5, 1, 2, 3, 4])
        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(outcome.inserted, 1)
    }

    func testDisjointListsAreFullyReplaced() {
        let outcome = splice([1, 2], into: [3, 4, 5])
        XCTAssertEqual(outcome.result, [3, 4, 5])
        XCTAssertEqual(outcome.removed, 2)
        XCTAssertEqual(outcome.inserted, 3)
        XCTAssertEqual(splice([], into: [7]).result, [7])
        XCTAssertEqual(splice([7], into: []).result, [])
    }

    /// Lands on the target every time, and keeps as many rows as any edit
    /// could: the longest common subsequence of the two lists.
    func testRandomEditsLandOnTheTargetKeepingAsManyRowsAsPossible() {
        var rng = SeededGenerator(seed: 354)
        for _ in 0..<500 {
            let old = Array(Set((0..<Int.random(in: 0..<30, using: &rng)).map { _ in Int.random(in: 0..<40, using: &rng) }))
                .shuffled(using: &rng)
            let new = Array(Set((0..<Int.random(in: 0..<30, using: &rng)).map { _ in Int.random(in: 0..<40, using: &rng) }))
                .shuffled(using: &rng)
            let outcome = splice(old, into: new)
            XCTAssertEqual(outcome.result, new, "old \(old) new \(new)")
            let kept = old.count - outcome.removed
            XCTAssertEqual(kept, longestCommonSubsequence(old, new), "old \(old) new \(new)")
            XCTAssertEqual(outcome.inserted, new.count - kept)
        }
    }

    private func longestCommonSubsequence(_ a: [Int], _ b: [Int]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table[a.count][b.count]
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 29)
    }
}
