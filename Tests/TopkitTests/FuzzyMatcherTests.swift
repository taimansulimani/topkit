import Foundation
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class FuzzyMatcherTests: XCTestCase {

    // MARK: - Basic matching

    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(pattern: "xyz", text: "hello world"))
        XCTAssertNil(FuzzyMatcher.score(pattern: "worldz", text: "world"))
        XCTAssertNil(FuzzyMatcher.score(pattern: "a", text: ""))
    }

    func testEmptyPatternMatchesEverythingWithZeroScore() {
        XCTAssertEqual(FuzzyMatcher.score(pattern: "", text: "anything"), 0)
        XCTAssertEqual(FuzzyMatcher.score(pattern: "", text: ""), 0)
    }

    func testExactMatchScoresPositive() {
        let score = FuzzyMatcher.score(pattern: "hello", text: "hello")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score!, 0)
    }

    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatcher.score(pattern: "hlo", text: "hello"))
        XCTAssertNotNil(FuzzyMatcher.score(pattern: "obr", text: "one big red dog"))
    }

    // MARK: - Smart-case

    func testLowercasePatternMatchesCaseInsensitively() {
        XCTAssertNotNil(FuzzyMatcher.score(pattern: "hello", text: "HELLO WORLD"))
        XCTAssertNotNil(FuzzyMatcher.score(pattern: "img", text: "Image"))
    }

    func testUppercaseInPatternForcesCaseSensitivity() {
        XCTAssertNotNil(FuzzyMatcher.score(pattern: "Hello", text: "Hello"))
        XCTAssertNil(FuzzyMatcher.score(pattern: "Hello", text: "hello"))
    }

    // MARK: - Ranking properties (higher = better)

    func testWordBoundaryStartBeatsMidWordMatch() {
        // "car" at start of a word vs buried inside another word
        let boundary = FuzzyMatcher.score(pattern: "car", text: "my car key")!
        let midWord = FuzzyMatcher.score(pattern: "car", text: "vicarious")!
        XCTAssertGreaterThan(boundary, midWord)
    }

    func testConsecutiveBeatsScattered() {
        let consecutive = FuzzyMatcher.score(pattern: "abc", text: "xxabcxx")!
        let scattered = FuzzyMatcher.score(pattern: "abc", text: "xaxbxcx")!
        XCTAssertGreaterThan(consecutive, scattered)
    }

    func testCamelCaseHumpsMatchWell() {
        let camel = FuzzyMatcher.score(pattern: "csm", text: "ClipboardSearchMenu")!
        let flat = FuzzyMatcher.score(pattern: "csm", text: "eclipses submenu")!
        XCTAssertGreaterThan(camel, flat)
    }

    func testStartOfStringBeatsLaterOccurrence() {
        let start = FuzzyMatcher.score(pattern: "test", text: "test file")!
        let later = FuzzyMatcher.score(pattern: "test", text: "file test")!
        // Both are boundary matches; start-of-string gets the whitespace-boundary
        // bonus too, so they tie or start wins — never loses.
        XCTAssertGreaterThanOrEqual(start, later)
    }

    func testShorterGapScoresHigher() {
        let tight = FuzzyMatcher.score(pattern: "ab", text: "axb")!
        let wide = FuzzyMatcher.score(pattern: "ab", text: "axxxxxb")!
        XCTAssertGreaterThan(tight, wide)
    }

    func testDigitAfterLetterGetsCamelBonus() {
        let hump = FuzzyMatcher.score(pattern: "4", text: "item42")!
        let plain = FuzzyMatcher.score(pattern: "4", text: "1442")!
        XCTAssertGreaterThan(hump, plain)
    }

    func testOptimalMatchChosenOverGreedyFirstMatch()  {
        // Greedy V1 would anchor on the "o" in "So" and pay a long gap;
        // V2 must find the boundary-start "obj" occurrence instead.
        let score = FuzzyMatcher.score(pattern: "obj", text: "So many objects")!
        let direct = FuzzyMatcher.score(pattern: "obj", text: "xx xxxx objects")!
        XCTAssertEqual(score, direct)
    }

    func testUnicodeTextDoesNotCrashAndMatches() {
        XCTAssertNotNil(FuzzyMatcher.score(pattern: "caffe", text: "caffè latte ☕️"))
        XCTAssertNotNil(FuzzyMatcher.score(pattern: "è", text: "caffè"))
        XCTAssertNil(FuzzyMatcher.score(pattern: "z", text: "caffè ☕️"))
    }
}
