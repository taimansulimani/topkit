import Foundation

/// Pure ordering rules for pinned clipboard items.
///
/// Invariant maintained everywhere: pinned items occupy the head of the
/// history array (newest pin first), unpinned items follow in recency order.
/// Display numbering, search and folder pagination all read the array
/// directly, so pinning item 7 really does make it item 1 and shifts
/// everything else down — no parallel bookkeeping.
enum ClipboardPinningHelpers {

    /// Number of leading pinned items (the pinned block).
    static func pinnedCount(_ history: [ClipboardItem]) -> Int {
        history.prefix(while: { $0.isPinned == true }).count
    }

    /// Restores the pinned-block-at-head invariant (stable: relative order
    /// within each group is preserved). Run after loading persisted history
    /// so a blob written by any code path still displays correctly.
    static func normalized(_ history: [ClipboardItem]) -> [ClipboardItem] {
        let pinned = history.filter { $0.isPinned == true }
        guard !pinned.isEmpty else { return history }
        return pinned + history.filter { $0.isPinned != true }
    }

    /// Toggles the pin on the item with `id`. Pinning moves the item to the
    /// very top; unpinning slots it back among the unpinned items by recency
    /// (newest first), so it returns to its natural place in the list.
    static func togglingPin(_ history: [ClipboardItem], id: UUID) -> [ClipboardItem] {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return history }
        var updated = history
        var item = updated.remove(at: index)
        if item.isPinned == true {
            item.isPinned = nil
            let unpinnedStart = pinnedCount(updated)
            let insertAt = updated[unpinnedStart...].firstIndex(where: { $0.timestamp < item.timestamp })
                ?? updated.endIndex
            updated.insert(item, at: insertAt)
        } else {
            item.isPinned = true
            updated.insert(item, at: 0)
        }
        return updated
    }

    /// Adds a fresh clipboard capture: dedups against existing entries and
    /// inserts just below the pinned block (pins always stay on top). A
    /// duplicate of a *pinned* entry keeps the pin and its position, only
    /// refreshing the timestamp so a later unpin lands near the top.
    static func addingItem(_ item: ClipboardItem, to history: [ClipboardItem]) -> [ClipboardItem] {
        var updated = history
        if let existing = updated.firstIndex(where: { isDuplicate($0, of: item) }),
           updated[existing].isPinned == true {
            updated[existing].timestamp = item.timestamp
            return updated
        }
        updated.removeAll { isDuplicate($0, of: item) }
        var newItem = item
        newItem.isPinned = nil
        updated.insert(newItem, at: pinnedCount(updated))
        return updated
    }

    /// Duplicate detection, mirroring the pre-pinning dedup rules: images by
    /// stable hash (falling back to raw bytes, then content for legacy items
    /// with neither), text/files by content.
    private static func isDuplicate(_ existing: ClipboardItem, of item: ClipboardItem) -> Bool {
        guard existing.type == item.type else { return false }
        if item.type == .image {
            if let hash = item.imageHash { return existing.imageHash == hash }
            if let data = item.imageData { return existing.imageData == data }
        }
        return existing.content == item.content
    }
}
