import Foundation

/// fzf-style fuzzy matcher: a Swift port of fzf's FuzzyMatchV2 algorithm
/// (junegunn/fzf, src/algo/algo.go) — Smith-Waterman-style dynamic programming
/// with affine gap penalties and position bonuses, so it always finds the
/// optimal-scoring placement of the pattern, not the first greedy one.
///
/// Used to rank clipboard history entries as the user types in the menu
/// search field. Pure and synchronous. Texts are prepared once (`prepare`)
/// into integer character codes, case-folded codes and per-position bonuses,
/// so a keystroke only pays for the DP: redoing that per-character work for
/// every entry on every keystroke is what made search lag on a big history
/// with long entries (TEC-354).
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

    fileprivate enum CharClass {
        case white, delimiter, nonWord, lower, upper, number
    }

    /// Maps Characters to integer codes so the DP compares integers instead of
    /// grapheme clusters. Two codes are equal exactly when the Characters are
    /// (Swift compares Characters by canonical equivalence): ASCII is its own
    /// code, a character canonically equal to an ASCII one (the Kelvin sign and
    /// "K") gets that code, and every other Character is interned through a
    /// dictionary, whose hashing follows Character ==. Texts and patterns that
    /// are compared must be prepared with the same table.
    final class CharacterTable {
        fileprivate struct Info {
            let code: UInt32
            /// Code of the smart-case folded character: its lowercase when
            /// that is exactly one Character, otherwise the character itself.
            let foldedCode: UInt32
            let charClass: CharClass
        }

        /// Keyed by exact scalars (not Character ==) so case folding and the
        /// character class always come from the very character the original
        /// matcher saw.
        private var infos: [[UInt32]: Info] = [:]
        private var codes: [Character: UInt32] = [:]
        private var nextCode: UInt32 = 128

        init() {}

        /// Derived with the same Character functions as the slow path, so both
        /// paths agree by construction.
        fileprivate static let asciiInfos: [Info] = (0..<128).map { value in
            let ch = Character(Unicode.Scalar(UInt8(value)))
            let folded = foldedCharacter(ch)
            return Info(
                code: UInt32(value),
                foldedCode: folded.unicodeScalars.count == 1 && folded.unicodeScalars.first!.isASCII
                    ? folded.unicodeScalars.first!.value
                    : UInt32(value),
                charClass: FuzzyMatcher.charClass(ch)
            )
        }

        fileprivate func info(_ ch: Character) -> Info {
            let scalars = ch.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first, scalar.isASCII {
                return Self.asciiInfos[Int(scalar.value)]
            }
            let key = scalars.map(\.value)
            if let known = infos[key] { return known }
            let info = Info(
                code: code(ch),
                foldedCode: code(Self.foldedCharacter(ch)),
                charClass: FuzzyMatcher.charClass(ch)
            )
            infos[key] = info
            return info
        }

        fileprivate func code(_ ch: Character) -> UInt32 {
            let scalars = ch.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first, scalar.isASCII {
                return scalar.value
            }
            if let known = codes[ch] { return known }
            let code: UInt32
            let nfc = String(ch).precomposedStringWithCanonicalMapping.unicodeScalars
            if nfc.count == 1, let scalar = nfc.first, scalar.isASCII {
                code = scalar.value
            } else {
                code = nextCode
                nextCode += 1
            }
            codes[ch] = code
            return code
        }

        private static func foldedCharacter(_ ch: Character) -> Character {
            let lower = ch.lowercased()
            return lower.count == 1 ? Character(lower) : ch
        }
    }

    /// A text ready for repeated scoring.
    struct PreparedText {
        /// Code per Character, for case-sensitive comparisons.
        fileprivate let codes: [UInt32]
        /// Smart-case folded codes, for case-insensitive comparisons. Shares
        /// storage with `codes` when folding changes nothing.
        fileprivate let folded: [UInt32]
        /// Per-position bonus from the class transition with the previous char.
        fileprivate let bonus: [UInt8]
    }

    /// A search pattern encoded with the same table as the texts.
    struct PreparedPattern {
        fileprivate let codes: [UInt32]
        fileprivate let caseSensitive: Bool
    }

    static func prepare(text: String, table: CharacterTable) -> PreparedText {
        var builder = PreparedTextBuilder(capacity: text.utf8.count)

        // Pure-ASCII text skips grapheme breaking: every byte is its own
        // Character except CR LF, which is one.
        let asciiInfos = CharacterTable.asciiInfos
        let handledAsASCII = text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            guard !bytes.contains(where: { $0 >= 0x80 }) else { return false }
            var index = 0
            while index < bytes.count {
                if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    builder.append(table.info("\r\n"))
                    index += 2
                } else {
                    builder.append(asciiInfos[Int(bytes[index])])
                    index += 1
                }
            }
            return true
        } ?? false

        if !handledAsASCII {
            for ch in text {
                builder.append(table.info(ch))
            }
        }
        return builder.finish()
    }

    private struct PreparedTextBuilder {
        private var codes: [UInt32] = []
        private var folded: [UInt32] = []
        private var bonus: [UInt8] = []
        private var foldingChangedSomething = false
        // Start of string counts as whitespace, as in fzf.
        private var prevClass = CharClass.white

        init(capacity: Int) {
            codes.reserveCapacity(capacity)
            folded.reserveCapacity(capacity)
            bonus.reserveCapacity(capacity)
        }

        mutating func append(_ info: CharacterTable.Info) {
            codes.append(info.code)
            folded.append(info.foldedCode)
            if info.foldedCode != info.code { foldingChangedSomething = true }
            bonus.append(UInt8(FuzzyMatcher.bonusFor(prev: prevClass, curr: info.charClass)))
            prevClass = info.charClass
        }

        func finish() -> PreparedText {
            PreparedText(codes: codes, folded: foldingChangedSomething ? folded : codes, bonus: bonus)
        }
    }

    /// Smart-case: an all-lowercase pattern matches case-insensitively; any
    /// uppercase in the pattern forces case-sensitivity.
    static func prepare(pattern: String, table: CharacterTable) -> PreparedPattern {
        PreparedPattern(
            codes: pattern.map { table.code($0) },
            caseSensitive: pattern.contains { $0.isUppercase }
        )
    }

    /// Score of the best fuzzy match of `pattern` within `text`, or nil if
    /// `pattern` is not a subsequence of `text`. Empty pattern matches
    /// everything with score 0. Smart-case: an all-lowercase pattern matches
    /// case-insensitively; any uppercase in the pattern forces case-sensitivity.
    static func score(pattern: String, text: String) -> Int? {
        if pattern.isEmpty { return 0 }
        let table = CharacterTable()
        let preparedText = prepare(text: text, table: table)
        return score(prepare(pattern: pattern, table: table), in: preparedText)
    }

    /// `score(pattern:text:)` on inputs prepared with one shared table.
    static func score(_ pattern: PreparedPattern, in text: PreparedText) -> Int? {
        let patternCodes = pattern.codes
        let m = patternCodes.count
        if m == 0 { return 0 }

        // Smart-case: pattern is all-lowercase here iff case-insensitive, so
        // the folded text makes every comparison a plain ==.
        let textCodes = pattern.caseSensitive ? text.codes : text.folded
        let n = textCodes.count
        if m > n { return nil }

        // Subsequence check first, as fzf does: most entries fail here, in one
        // linear pass. It also bounds the DP to [first, last]: a match can't
        // start before the first pattern[0] or end after the last
        // pattern[m-1], and the DP only flows left to right, so the columns
        // outside that window never change the best score.
        var first = 0
        var matched = 0
        for j in 0..<n where textCodes[j] == patternCodes[matched] {
            if matched == 0 { first = j }
            matched += 1
            if matched == m { break }
        }
        guard matched == m else { return nil }
        var last = n - 1
        while textCodes[last] != patternCodes[m - 1] { last -= 1 }

        return textCodes.withUnsafeBufferPointer { textCodes in
            text.bonus.withUnsafeBufferPointer { bonus in
                bestScore(pattern: patternCodes, text: textCodes, bonus: bonus, first: first, last: last)
            }
        }
    }

    /// fzf's DP, stored sparsely. Per pattern row i, with j a text position:
    /// D[j]: best score with pattern[i] matched exactly at j.
    /// G[j]: best score for pattern[0...i] with its last match strictly before
    ///       j, gap penalties (affine: start -3, extend -1) included.
    /// F[j]: bonus earned by the first char of that run (a run that starts at
    ///       a word boundary keeps its boundary bonus for every subsequent
    ///       char, per fzf).
    /// D is only ever live where text[j] == pattern[i], so a row keeps just
    /// those entries. G is never stored: unrolled, it is the best
    /// `D[k] + gapStart + gapExtension * (j - 1 - k)` over live k < j, i.e. a
    /// running max of `D[k] - gapExtension * k` shifted by j. Same scores as
    /// the dense table, at the cost of the live entries instead of m × n cells.
    private static func bestScore(
        pattern: [UInt32],
        text: UnsafeBufferPointer<UInt32>,
        bonus: UnsafeBufferPointer<UInt8>,
        first: Int,
        last: Int
    ) -> Int? {
        var prevPos: [Int] = []
        var prevD: [Int] = []
        var prevF: [Int] = []

        // Row 0: every occurrence of pattern[0] starts a run.
        let firstCode = pattern[0]
        for j in first...last where text[j] == firstCode {
            let b = Int(bonus[j])
            prevPos.append(j)
            prevD.append(scoreMatch + b * bonusFirstCharMultiplier)
            prevF.append(b)
        }

        var currPos: [Int] = []
        var currD: [Int] = []
        var currF: [Int] = []
        for i in 1..<pattern.count {
            // Nothing in this row can sit at or before the previous row's first entry.
            guard let earliest = prevPos.first else { return nil }
            currPos.removeAll(keepingCapacity: true)
            currD.removeAll(keepingCapacity: true)
            currF.removeAll(keepingCapacity: true)

            let code = pattern[i]
            var k = 0
            // Best D[k] - gapExtension * k over previous-row entries at k <= j - 2.
            var gapCarry = minScore
            var j = earliest + 1
            while j <= last {
                if text[j] == code {
                    while k < prevPos.count && prevPos[k] <= j - 2 {
                        gapCarry = max(gapCarry, prevD[k] - scoreGapExtension * prevPos[k])
                        k += 1
                    }
                    let b = Int(bonus[j])

                    // Extend a consecutive run from the diagonal (an entry at j - 1).
                    var consecutiveScore = minScore
                    var runF = 0
                    if k < prevPos.count && prevPos[k] == j - 1 {
                        var runBonus = max(b, bonusConsecutive)
                        if prevF[k] >= bonusBoundary {
                            runBonus = max(runBonus, prevF[k])
                        }
                        consecutiveScore = prevD[k] + scoreMatch + runBonus
                        runF = prevF[k]
                    }
                    // Or start fresh after a gap: G[j - 1] of the previous row.
                    var gapScore = minScore
                    if gapCarry > minScore {
                        let gap = gapCarry + scoreGapStart + scoreGapExtension * (j - 2)
                        gapScore = gap + scoreMatch + b
                    }

                    if consecutiveScore > minScore || gapScore > minScore {
                        currPos.append(j)
                        if consecutiveScore >= gapScore {
                            currD.append(consecutiveScore)
                            currF.append(runF)
                        } else {
                            currD.append(gapScore)
                            currF.append(b)
                        }
                    }
                }
                j += 1
            }

            swap(&prevPos, &currPos)
            swap(&prevD, &currD)
            swap(&prevF, &currF)
        }

        return prevD.max()
    }

    // MARK: - Character classification (fzf's charClass + bonus tables)

    fileprivate static func charClass(_ c: Character) -> CharClass {
        if c.isWhitespace { return .white }
        if "/,:;|".contains(c) { return .delimiter }
        if c.isNumber { return .number }
        if c.isLowercase { return .lower }
        if c.isUppercase { return .upper }
        if c.isLetter { return .lower } // caseless letters (CJK etc.) rank as word chars
        return .nonWord
    }

    fileprivate static func bonusFor(prev: CharClass, curr: CharClass) -> Int {
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
