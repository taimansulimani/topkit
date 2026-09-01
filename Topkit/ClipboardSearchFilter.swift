import Foundation

/// Ranks clipboard history against the menu search field's query.
/// Pure: the AppKit layer maps the result onto menu items.
enum ClipboardSearchFilter {

    struct Match: Equatable {
        /// 0-based position in the full history; drives the displayed item number.
        let historyIndex: Int
        let score: Int
    }

    /// Matches ranked best-first (score descending, ties keep history order,
    /// i.e. recency). A whitespace-only query matches everything in history
    /// order. An all-digits query `n` additionally pins history entry number
    /// `n` (1-based) to the top — so typing "42" surfaces entry 42 first,
    /// followed by items whose content matches "42".
    static func matches(history: [ClipboardItem], query: String) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return history.indices.map { Match(historyIndex: $0, score: 0) }
        }

        var ranked: [Match] = []
        for (index, item) in history.enumerated() {
            if let score = FuzzyMatcher.score(pattern: trimmed, text: haystack(for: item)) {
                ranked.append(Match(historyIndex: index, score: score))
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
    private static func haystack(for item: ClipboardItem) -> String {
        switch item.type {
        case .text, .file:
            return item.content
        case .image:
            return "Image"
        }
    }
}
