import Foundation

/// fzf-style fuzzy matcher: a Swift port of fzf's FuzzyMatchV2 algorithm
/// (junegunn/fzf, src/algo/algo.go) — Smith-Waterman-style dynamic programming
/// with affine gap penalties and position bonuses, so it always finds the
/// optimal-scoring placement of the pattern, not the first greedy one.
///
/// Used to rank clipboard history entries as the user types in the menu
/// search field. Pure and synchronous; scoring 500 short strings per
/// keystroke is well under a millisecond.
enum FuzzyMatcher {

    // fzf's scoring constants, verbatim.
    private static let scoreMatch = 16
    private static let scoreGapStart = -3
    private static let scoreGapExtension = -1
    private static let bonusBoundary = 8            // word char after a non-word char
    private static let bonusBoundaryWhite = 10      // word char after whitespace (or start of string)
    private static let bonusBoundaryDelimiter = 9   // word char after / , : ; |
    private static let bonusNonWord = 8
    private static let bonusCamel123 = 7            // lower→Upper or letter→digit transition
    private static let bonusConsecutive = 4
    private static let bonusFirstCharMultiplier = 2

    private static let minScore = Int.min / 2

    private enum CharClass {
        case white, delimiter, nonWord, lower, upper, number
    }

    /// Score of the best fuzzy match of `pattern` within `text`, or nil if
    /// `pattern` is not a subsequence of `text`. Empty pattern matches
    /// everything with score 0. Smart-case: an all-lowercase pattern matches
    /// case-insensitively; any uppercase in the pattern forces case-sensitivity.
    static func score(pattern: String, text: String) -> Int? {
        if pattern.isEmpty { return 0 }

        let caseSensitive = pattern.contains { $0.isUppercase }
        let patternChars = Array(pattern)
        let textChars = Array(text)
        let n = textChars.count
        let m = patternChars.count
        if m > n { return nil }

        // Per-position bonus from the class transition with the previous char.
        // Start of string counts as whitespace, as in fzf.
        var bonus = [Int](repeating: 0, count: n)
        var prevClass = CharClass.white
        for j in 0..<n {
            let cls = charClass(textChars[j])
            bonus[j] = bonusFor(prev: prevClass, curr: cls)
            prevClass = cls
        }

        // Smart-case: pattern is all-lowercase here iff case-insensitive, so
        // folding the text once makes every comparison a plain ==.
        let foldedText: [Character]
        if caseSensitive {
            foldedText = textChars
        } else {
            foldedText = textChars.map { ch in
                let lower = ch.lowercased()
                return lower.count == 1 ? Character(lower) : ch
            }
        }

        // D[j]: best score with pattern[i] matched exactly at text[j].
        // G[j]: best score for pattern[0...i] with its last match strictly
        //       before j, gap penalties (affine: start -3, extend -1) included.
        // C[j]: length of the consecutive run ending at j on the D path.
        // F[j]: bonus earned by the first char of that run (a run that starts
        //       at a word boundary keeps its boundary bonus for every
        //       subsequent char, per fzf).
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
                        // Extend a consecutive run from the diagonal.
                        var consecutiveScore = minScore
                        if prevD[j - 1] > minScore {
                            var b = max(bonus[j], bonusConsecutive)
                            if prevF[j - 1] >= bonusBoundary {
                                b = max(b, prevF[j - 1])
                            }
                            consecutiveScore = prevD[j - 1] + scoreMatch + b
                        }
                        // Or start fresh after a gap.
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

                // Best "last match before or at j, trailing gap open" for this row.
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

    // MARK: - Character classification (fzf's charClass + bonus tables)

    private static func charClass(_ c: Character) -> CharClass {
        if c.isWhitespace { return .white }
        if "/,:;|".contains(c) { return .delimiter }
        if c.isNumber { return .number }
        if c.isLowercase { return .lower }
        if c.isUppercase { return .upper }
        if c.isLetter { return .lower } // caseless letters (CJK etc.) rank as word chars
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
