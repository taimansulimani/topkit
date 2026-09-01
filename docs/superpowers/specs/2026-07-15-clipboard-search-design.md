# Clipboard menu fuzzy search — design

2026-07-15

## What

A search field at the top of Topkit's clipboard menus, above the first clipboard entry. Typing filters the clipboard entries below it live, fzf-style fuzzy matching. Applies to both surfaces:

- the menu bar status item dropdown
- the shortcut-triggered clipboard popup (`showInlineClipboardMenu`)

Both share one query state and identical behaviour.

## UI

- First menu item is a custom-view `NSMenuItem` hosting an `NSSearchField` (fixed width matching menu content, standard height). Not focused on menu open: click to focus, then type. Native menu type-select keeps working until the field is focused.
- `NSSearchField` provides the built-in clear (x) button whenever there is input. No result counter, no extra chrome.
- While the query is non-empty:
  - the "N - M" folder submenus are hidden
  - the entire history (up to the 500 cap) is shown as one flat list, ranked by match score
  - zero matches → single disabled "No matches" row
- Query empty → normal layout (inline items + folder submenus), unchanged from today.
- Esc with text in the focused field clears the query; Esc with empty field closes the menu.
- Enter in the field with matches present picks the top match.

## Matching

Own Swift implementation, no dependency (fzf is a Go binary; Swift fuzzy libs are unmaintained). New file `FuzzyMatcher.swift`, pure functions, unit-tested. Port of fzf's FuzzyMatchV2 (junegunn/fzf `src/algo/algo.go`) — Smith-Waterman-style DP over pattern × text, guarantees the optimal-scoring match, O(nm) per item which is trivial at our scale:

- fzf's exact scoring constants: match +16, gap start −3, gap extension −1, boundary bonus +8 (+10 after whitespace, +9 after delimiter), camelCase/letter-to-digit bonus +7, non-word bonus +8, consecutive bonus +4, first-pattern-char bonus ×2.
- Character classes (white / non-word / delimiter / lower / upper / letter / number) drive the boundary bonuses via class transitions, as in fzf.
- Smart-case: query all-lowercase → case-insensitive; any uppercase in query → case-sensitive.
- Matched against the item's display content: text items match their content (full content, not just the truncated menu title), file items match their path string, image items match the literal string "Image" (so "img"/"image" surfaces them).
- Ordinal match: if the query is all digits, the item whose 1-based history position equals the number also matches, ranked above content matches (typing `42` surfaces entry 42 first, plus any items containing "42").

Performance: 500 short strings scored per keystroke on the main thread is trivial; no async needed.

## Query lifecycle

- In-memory only (`AppDelegate` property), never persisted across relaunch.
- Picking a clipboard item → query resets to empty.
- Any other way the menu goes away (click outside, click status icon, picking Draw/Preferences/etc.) → query survives; next open shows the field pre-filled and the list pre-filtered.

## Implementation shape

- `FuzzyMatcher.swift` + `Tests/TopkitTests/FuzzyMatcherTests.swift` — scoring and ranking, pure.
- `ClipboardSearchMenuView.swift` — NSView wrapping the `NSSearchField`, text-change callback, Esc/Enter handling.
- `AppDelegate`:
  - insert the search item at the top of both menus
  - on text change while a menu is open, remove and re-insert the clipboard section items in place (`NSMenu` supports mutation while open); section boundary tracked by item count
  - `MenuBuildSignature` gains the query so the cached-rebuild logic stays correct
  - `copyClipboardItem` resets the query

## Out of scope

- Persisting query across app relaunch
- Search over tooltips/timestamps/types beyond the above
- Any changes to history storage or capture
