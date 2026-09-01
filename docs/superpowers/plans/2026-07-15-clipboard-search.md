# Clipboard menu fuzzy search — implementation plan

> Spec: `docs/superpowers/specs/2026-07-15-clipboard-search-design.md`

**Goal:** fzf-style search field at the top of both clipboard menus, live filtering, shared query state, reset-on-pick.

**Architecture:** pure matching/ranking layer (`FuzzyMatcher` port of fzf FuzzyMatchV2 + `ClipboardSearchFilter`) fully unit-tested via SPM; thin AppKit layer (`ClipboardSearchMenuView` wrapping `NSSearchField`) wired into `AppDelegate`'s existing menu build/rebuild machinery.

**Tech:** Swift, AppKit, no dependencies. New files must be added to `Topkit.xcodeproj/project.pbxproj` by hand (explicit file list, no xcodegen).

---

### Task 1: FuzzyMatcher

Files: create `Topkit/FuzzyMatcher.swift`, `Tests/TopkitTests/FuzzyMatcherTests.swift`.

API:

```swift
enum FuzzyMatcher {
    /// nil = pattern is not a subsequence of text. Higher score = better match.
    static func score(pattern: String, text: String) -> Int?
}
```

Port of fzf FuzzyMatchV2 (`junegunn/fzf src/algo/algo.go`):

- Constants: `scoreMatch 16`, `scoreGapStart -3`, `scoreGapExtension -1`, `bonusBoundary 8`, `bonusBoundaryWhite 10`, `bonusBoundaryDelimiter 9`, `bonusNonWord 8`, `bonusCamel123 7`, `bonusConsecutive 4`, `bonusFirstCharMultiplier 2`.
- Char classes white / delimiter (`/,:;|`) / nonWord / lower / upper / number; per-position bonus from class transition (word char after white/delimiter/nonWord → boundary bonuses; lower→upper and nonNumber→number → camel bonus; nonWord chars → nonWord bonus).
- Affine-gap DP: `D[i][j]` = best score with pattern[i] matched exactly at text[j]; `G[i][j]` = best with last match before j (gap start/extension penalties). Consecutive runs carry `max(bonus[j], bonusConsecutive, runFirstBonus if ≥ bonusBoundary)` so runs that start at a boundary keep the boundary bonus. First pattern char bonus ×2.
- Smart-case: pattern all-lowercase → case-insensitive; else case-sensitive.
- Empty pattern → score 0 (matches everything).

Tests (write first, watch fail, implement, watch pass): boundary-start beats mid-word, consecutive beats scattered, camelCase hump matching, smart-case both ways, non-subsequence → nil, empty pattern → 0, earlier match preferred on ties.

### Task 2: ClipboardSearchFilter

Files: create `Topkit/ClipboardSearchFilter.swift`, `Tests/TopkitTests/ClipboardSearchFilterTests.swift`.

```swift
enum ClipboardSearchFilter {
    struct Match: Equatable {
        let historyIndex: Int   // 0-based position in full history (drives the displayed number)
        let score: Int
    }
    static func matches(history: [ClipboardItem], query: String) -> [Match]
}
```

- Query trimmed; empty → caller shows the normal unfiltered layout (function returns everything, but AppDelegate short-circuits before calling).
- Haystack per item: `.text` → `content`, `.file` → `content` (path display string), `.image` → `"Image"`.
- All-digits query `n` with `1 ≤ n ≤ count` → item n (1-based) is a match pinned to rank 0, deduped against its own content match.
- Everything else ranked by FuzzyMatcher score desc, ties by history order (recency).

Tests: ordinal pin (`"42"` puts item 42 first, still includes items containing "42"), image matched by "img"/"image", ranking order, empty result.

### Task 3: ClipboardSearchMenuView

Files: create `Topkit/Views/ClipboardSearchMenuView.swift`.

NSView (fixed ~250×30, padded) hosting an `NSSearchField`:

- `onQueryChanged: (String) -> Void` via `controlTextDidChange`
- `onCommit: () -> Void` on Enter (`insertNewline:` through `control(_:textView:doCommandBySelector:)`)
- Esc (`cancelOperation:`): text present → clear + fire `onQueryChanged("")`, consume; empty → let the menu close
- `NSSearchField` supplies the clear (x) button natively
- Initialised with the current query so a dismissed-then-reopened menu shows it pre-filled
- No auto-focus: click to focus (per decision)

Not unit-tested (pure AppKit plumbing); logic lives in Tasks 1–2.

### Task 4: AppDelegate integration

Files: modify `Topkit/AppDelegate.swift`, `Topkit.xcodeproj/project.pbxproj` (register the three new sources).

- New state: `private var clipboardSearchQuery = ""`.
- `buildMenu(into:)` and `showInlineClipboardMenu()` insert the search item (custom view) at index 0, above the clipboard section.
- Clipboard section builder gains the query: empty → existing inline+folders path; non-empty → flat ranked rows via `ClipboardSearchFilter.matches` using `createClipboardMenuItem(item:number: historyIndex+1)`; zero matches → disabled "No matches" row.
- Live filtering: track the open menu and its clipboard-section item count; on `onQueryChanged`, remove the section items and re-insert filtered ones in place (NSMenu supports mutation while open).
- Enter commit: top match → `copyClipboardItem` path + cancel menu tracking.
- `MenuBuildSignature` gains `searchQuery` so the cached-rebuild logic stays correct.
- `copyClipboardItem` resets `clipboardSearchQuery` to `""` and flags rebuild. Nothing else clears it (plain dismiss and non-clipboard actions keep it).

### Task 5: Docs

- README: mention search in the Clipboard history feature section.
- This plan + spec committed.

### Task 6: Verify + ship

- `swift test` green (all suites, not just new ones).
- `xcodebuild test` gate runs inside the fire lane's `ci`.
- `export LANG=en_US.UTF-8` then `bundle exec fastlane fire message:"..."` (xcpretty crashes without UTF-8 locale).
- Confirm upload landed (TestFlight) — remember altool can 403 after the binary already landed.
