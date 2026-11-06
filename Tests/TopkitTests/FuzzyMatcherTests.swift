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

    // MARK: - Same scores as the original matcher (TEC-354)
    //
    // The matcher was rebuilt for speed: prepared integer codes, a DP bounded
    // to the matching window and stored sparsely. Results must not move, so
    // every score is checked against the original dense implementation.

    func testCanonicallyEqualCharactersStillMatch() {
        // Character == is canonical equivalence: precomposed vs decomposed é,
        // and the Kelvin sign vs "K".
        XCTAssertEqual(FuzzyMatcher.score(pattern: "e\u{301}", text: "caf\u{E9}"),
                       ReferenceFuzzyMatcher.score(pattern: "e\u{301}", text: "caf\u{E9}"))
        XCTAssertNotNil(FuzzyMatcher.score(pattern: "e\u{301}", text: "caf\u{E9}"))
        XCTAssertNotNil(FuzzyMatcher.score(pattern: "K", text: "300 \u{212A}"))
        XCTAssertEqual(FuzzyMatcher.score(pattern: "k", text: "300 \u{212A}"),
                       ReferenceFuzzyMatcher.score(pattern: "k", text: "300 \u{212A}"))
    }

    func testRandomisedScoresMatchTheOriginalMatcher() {
        let alphabet: [String] = [
            "a", "b", "c", "e", "s", "x", "A", "B", "E", "S", "0", "4", "2",
            " ", " ", "\n", "\t", "\r\n", "/", ",", ":", "-", "_", ".", "(",
            "\u{E9}", "e\u{301}", "\u{C9}", "\u{212A}", "k", "K", "\u{DF}", "\u{130}", "\u{3A3}", "\u{3C3}",
            "猫", "☕️", "👍🏽", "Ǆ", "ǅ"
        ]
        // Pure-ASCII text takes a separate fast path when prepared (CR LF is
        // still one Character there), so half the cases stay ASCII.
        let asciiAlphabet = alphabet.filter { $0.utf8.allSatisfy { $0 < 0x80 } } + ["\r", "\n\r"]
        var rng = SeededGenerator(seed: 354)
        var letters = alphabet
        func randomString(length: Int) -> String {
            (0..<length).map { _ in letters[Int(rng.next() % UInt64(letters.count))] }.joined()
        }

        for round in 0..<4000 {
            letters = round % 2 == 0 ? alphabet : asciiAlphabet
            let text = randomString(length: Int(rng.next() % 40))
            let pattern: String
            if rng.next() % 2 == 0, !text.isEmpty {
                // A scattered subsequence of the text, so most of these match.
                let chars = Array(text)
                pattern = String(chars.enumerated().filter { _ in rng.next() % 4 == 0 }.prefix(6).map(\.element))
            } else {
                pattern = randomString(length: 1 + Int(rng.next() % 4))
            }
            XCTAssertEqual(
                FuzzyMatcher.score(pattern: pattern, text: text),
                ReferenceFuzzyMatcher.score(pattern: pattern, text: text),
                "pattern \(pattern.debugDescription) text \(text.debugDescription)"
            )
        }
    }

    func testLongTextScoresMatchTheOriginalMatcher() {
        let words = ["select", "Const", "useCallback", "seek", "ratio", "/Users/tr", "42", "item42", "a_b", "x:y"]
        var rng = SeededGenerator(seed: 42)
        let text = (0..<1500).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ")
        for pattern in ["s", "sel", "select", "useCallback", "uCb", "42", "trx", "Const", "zzz", "kcabllaCesu"] {
            XCTAssertEqual(FuzzyMatcher.score(pattern: pattern, text: text),
                           ReferenceFuzzyMatcher.score(pattern: pattern, text: text), pattern)
        }
    }

    func testPreparedTextReusedAcrossPatternsGivesTheSameScores() {
        let table = FuzzyMatcher.CharacterTable()
        let text = "Rebuild the seek drag as a controlled gesture — caf\u{E9} 猫 /Users/tr"
        let prepared = FuzzyMatcher.prepare(text: text, table: table)
        for pattern in ["seek", "Seek", "caf\u{E9}", "猫", "utr", "q"] {
            XCTAssertEqual(FuzzyMatcher.score(FuzzyMatcher.prepare(pattern: pattern, table: table), in: prepared),
                           ReferenceFuzzyMatcher.score(pattern: pattern, text: text), pattern)
        }
    }
}

/// Deterministic xorshift so the randomised comparison is reproducible.
private struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// The matcher as it shipped before TEC-354, verbatim: the dense m × n DP over
/// Characters. Kept only as the oracle the optimised matcher is checked against.
private enum ReferenceFuzzyMatcher {
    private static let scoreMatch = 16
    private static let scoreGapStart = -3
    private static let scoreGapExtension = -1
    private static let bonusBoundary = 8
    private static let bonusBoundaryWhite = 10
    private static let bonusBoundaryDelimiter = 9
    private static let bonusNonWord = 8
    private static let bonusCamel123 = 7
    private static let bonusConsecutive = 4
    private static let bonusFirstCharMultiplier = 2
    private static let minScore = Int.min / 2

    private enum CharClass {
        case white, delimiter, nonWord, lower, upper, number
    }

    static func score(pattern: String, text: String) -> Int? {
        if pattern.isEmpty { return 0 }

        let caseSensitive = pattern.contains { $0.isUppercase }
        let patternChars = Array(pattern)
        let textChars = Array(text)
        let n = textChars.count
        let m = patternChars.count
        if m > n { return nil }

        var bonus = [Int](repeating: 0, count: n)
        var prevClass = CharClass.white
        for j in 0..<n {
            let cls = charClass(textChars[j])
            bonus[j] = bonusFor(prev: prevClass, curr: cls)
            prevClass = cls
        }

        let foldedText: [Character]
        if caseSensitive {
            foldedText = textChars
        } else {
            foldedText = textChars.map { ch in
                let lower = ch.lowercased()
                return lower.count == 1 ? Character(lower) : ch
            }
        }

        var prevD = [Int](repeating: minScore, count: n)
        var prevG = [Int](repeating: minScore, count: n)
        var prevF = [Int](repeating: 0, count: n)

        for i in 0..<m {
            var currD = [Int](repeating: minScore, count: n)
            var currG = [Int](repeating: minScore, count: n)
            var currF = [Int](repeating: 0, count: n)

            for j in 0..<n {
                if patternChars[i] == foldedText[j] {
                    if i == 0 {
                        currD[j] = scoreMatch + bonus[j] * bonusFirstCharMultiplier
                        currF[j] = bonus[j]
                    } else if j > 0 {
                        var consecutiveScore = minScore
                        if prevD[j - 1] > minScore {
                            var b = max(bonus[j], bonusConsecutive)
                            if prevF[j - 1] >= bonusBoundary {
                                b = max(b, prevF[j - 1])
                            }
                            consecutiveScore = prevD[j - 1] + scoreMatch + b
                        }
                        var gapScore = minScore
                        if prevG[j - 1] > minScore {
                            gapScore = prevG[j - 1] + scoreMatch + bonus[j]
                        }
                        if consecutiveScore >= gapScore {
                            currD[j] = consecutiveScore
                            currF[j] = prevF[j - 1]
                        } else {
                            currD[j] = gapScore
                            currF[j] = bonus[j]
                        }
                    }
                }

                if j > 0 {
                    let openGap = currD[j - 1] > minScore ? currD[j - 1] + scoreGapStart : minScore
                    let extendGap = currG[j - 1] > minScore ? currG[j - 1] + scoreGapExtension : minScore
                    currG[j] = max(openGap, extendGap)
                }
            }

            prevD = currD
            prevG = currG
            prevF = currF
        }

        let best = prevD.max() ?? minScore
        return best > minScore ? best : nil
    }

    private static func charClass(_ c: Character) -> CharClass {
        if c.isWhitespace { return .white }
        if "/,:;|".contains(c) { return .delimiter }
        if c.isNumber { return .number }
        if c.isLowercase { return .lower }
        if c.isUppercase { return .upper }
        if c.isLetter { return .lower }
        return .nonWord
    }

    private static func bonusFor(prev: CharClass, curr: CharClass) -> Int {
        switch curr {
        case .lower, .upper, .number:
            switch prev {
            case .white: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
            if curr == .upper && prev == .lower { return bonusCamel123 }
            if curr == .number && prev != .number { return bonusCamel123 }
            return 0
        case .nonWord, .delimiter:
            return bonusNonWord
        case .white:
            return bonusBoundaryWhite
        }
    }
}
