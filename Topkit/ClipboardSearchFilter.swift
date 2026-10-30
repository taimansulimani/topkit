import Foundation

/// Ranks clipboard history against the menu search field's query.
/// Pure: the AppKit layer maps the result onto menu items.
enum ClipboardSearchFilter {

    struct Match: Equatable {
        /// 0-based position in the full history; drives the displayed item number.
        let historyIndex: Int
        let score: Int
    }

    /// Each history item's text prepared for matching, kept across keystrokes.
    /// An item's content never changes under its id, so an entry stays valid
    /// for as long as the item is in history; entries for items that left are
    /// dropped on the next search. Holds roughly 9 bytes per character of
    /// history text, so the owner should let it go when searching stops.
    final class Index {
        fileprivate let table = FuzzyMatcher.CharacterTable()
        fileprivate var prepared: [UUID: FuzzyMatcher.PreparedText] = [:]

        init() {}

        fileprivate func refresh(for history: [ClipboardItem]) -> [FuzzyMatcher.PreparedText] {
            var next: [UUID: FuzzyMatcher.PreparedText] = [:]
            next.reserveCapacity(history.count)
            let texts = history.map { item -> FuzzyMatcher.PreparedText in
                let text = next[item.id]
                    ?? prepared[item.id]
                    ?? FuzzyMatcher.prepare(text: ClipboardSearchFilter.haystack(for: item), table: table)
                next[item.id] = text
                return text
            }
            prepared = next
            return texts
        }

        var _preparedCountForTesting: Int { prepared.count }
    }

    /// Matches ranked best-first (score descending, ties keep history order,
    /// i.e. recency). A whitespace-only query matches everything in history
    /// order. An all-digits query `n` additionally pins history entry number
    /// `n` (1-based) to the top — so typing "42" surfaces entry 42 first,
    /// followed by items whose content matches "42".
    ///
    /// Pass the same `index` on every keystroke so each item's text is
    /// prepared once rather than per keystroke.
    static func matches(history: [ClipboardItem], query: String, index: Index = Index()) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return history.indices.map { Match(historyIndex: $0, score: 0) }
        }

        let texts = index.refresh(for: history)
        let pattern = FuzzyMatcher.prepare(pattern: trimmed, table: index.table)
        var ranked: [Match] = []
        for (historyIndex, text) in texts.enumerated() {
            if let score = FuzzyMatcher.score(pattern, in: text) {
                ranked.append(Match(historyIndex: historyIndex, score: score))
            }
        }
        // Sort is stable in Swift ≥5, so equal scores keep history (recency) order.
        ranked.sort { $0.score > $1.score }

        // Ordinal pin: all-digits query naming a valid 1-based position.
        if trimmed.allSatisfy(\.isNumber), let ordinal = Int(trimmed),
           ordinal >= 1, ordinal <= history.count {
            let pinnedIndex = ordinal - 1
            ranked.removeAll { $0.historyIndex == pinnedIndex }
            ranked.insert(Match(historyIndex: pinnedIndex, score: Int.max), at: 0)
        }

        return ranked
    }

    /// The searchable text for an item: text content, file path string, or the
    /// literal "Image" for images (so "img"/"image" surfaces them).
    fileprivate static func haystack(for item: ClipboardItem) -> String {
        switch item.type {
        case .text, .file:
            return item.content
        case .image:
            return "Image"
        }
    }
}
