import Foundation

/// Turns one ordered list into another in place with as few removals and
/// insertions as possible. Used to refilter the open clipboard menu: rows that
/// still match and keep their relative order stay in the menu untouched, so a
/// keystroke only pays for the rows that actually change.
enum OrderedSplice {

    /// The elements of `old` that can stay where they are: the longest run of
    /// elements shared with `new` that are already in `new`'s order. Every
    /// other element of `old` has to be removed, every other element of `new`
    /// inserted. Elements are expected to be unique within each list.
    static func unmoved<ID: Hashable>(from old: [ID], to new: [ID]) -> Set<ID> {
        var positionInNew: [ID: Int] = [:]
        for (index, id) in new.enumerated() where positionInNew[id] == nil {
            positionInNew[id] = index
        }
        let shared: [(id: ID, position: Int)] = old.compactMap { id in
            positionInNew[id].map { (id, $0) }
        }

        // Longest strictly increasing run of positions (patience sorting).
        // tails[k] indexes the shared element ending the best run of length k + 1.
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: shared.count)
        for (index, element) in shared.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if shared[tails[mid]].position < element.position {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count {
                tails.append(index)
            } else {
                tails[low] = index
            }
        }

        var result = Set<ID>()
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            result.insert(shared[cursor].id)
            cursor = previous[cursor]
        }
        return result
    }

    /// Edits a list showing `old` until it shows `new`: `remove` is called with
    /// indices into the list as it stands (highest first), then `insert` with
    /// each new element and the index it must land at (lowest first).
    static func apply<ID: Hashable>(
        from old: [ID],
        to new: [ID],
        remove: (Int) -> Void,
        insert: (ID, Int) -> Void
    ) {
        let staying = unmoved(from: old, to: new)
        for index in old.indices.reversed() where !staying.contains(old[index]) {
            remove(index)
        }
        // What is left is exactly the staying elements, in `new`'s order, so
        // inserting the others at their final index front to back lands every
        // element where it belongs.
        for (index, id) in new.enumerated() where !staying.contains(id) {
            insert(id, index)
        }
    }
}
