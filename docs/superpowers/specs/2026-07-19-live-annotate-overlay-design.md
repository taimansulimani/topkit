# Live Annotate overlay — design

Date: 2026-07-19

## Problem

Topkit has eight annotation tools (freehand, rectangle, circle, arrow, text,
redact, sticker, numbered badge). All eight work inside the screenshot editor.
Only one of them — freehand, exposed as "Draw" — works on the live screen
outside a screenshot, and that live version is a separate, cruder
implementation: strokes have no identity, cannot be selected, moved, resized,
or copied.

Goal: every annotation tool works on the live screen, with the same
select / move / resize / copy interactions the screenshot editor already
provides, grouped under one menu and reachable by keyboard.

## Key finding

`ScreenshotAnnotationView` (`Topkit/Views/ScreenshotAnnotationView.swift`) is
already dual-mode. `isLiveMode` is `screenshot == nil`
(`ScreenshotAnnotationView.swift:165`), and
`ScreenshotManager.showLiveFrozenAnnotationOverlay(globalRect:)`
(`ScreenshotManager.swift:339-457`) already hosts it full-screen over live
content inside a `LiveAnnotationOverlayWindow`. In that mode every tool already
supports selection, move, eight-handle resize, `Cmd+C`/`Cmd+V`, delete, and
undo/redo.

So this work is mostly **hosting**, not building. The gap is that the live
canvas only exists inside the screenshot flow: gated behind Screen Recording
permission, freezing the screen, dimming everything outside a selection hole,
and terminating in save-to-file.

Three things genuinely do not exist and must be built: a per-selection
contextual toolbar, click-through, and a pixel source for redact on a live
screen.

## Naming

The feature is **Annotate** (verb), consistent with the neighbouring menu items
Measure, Record Screen, Pick Color. The top-level menu item replaces Draw and
keeps Draw's position in the menu order.

## Architecture

### Canvas mode

Replace the `isLiveMode` boolean with an explicit mode on
`ScreenshotAnnotationView`:

```swift
enum CanvasMode {
    case staticImage(NSImage)   // screenshot editor
    case liveRegion             // today's frozen selection-hole flow
    case liveAnnotate           // new: full-screen live annotation
}
```

`isLiveMode` survives as a computed shim (`true` for both live cases) so the
existing branch sites do not all move at once. There are **15** `isLiveMode`
sites; every one must be classified deliberately. Three-way, not two-way — some
sites want `.liveAnnotate` to behave like `.staticImage`, not like
`.liveRegion`:

| Site | Today | `.liveAnnotate` should |
|---|---|---|
| `:349` `viewDidMoveToWindow` — `makeKey` + `makeFirstResponder` | skipped when live | **behave like `.staticImage`** — the overlay must be key or no keyboard works |
| `:1106` `saveScreenshot` → `onSaveRequested` | region save | be unreachable (see below) |
| `:1258`, `:1263` text-editing keyboard focus toggle | live only | **keep** — needed by the text tool |
| `:1368` `ensureAnnotationReferenceRect` | live only | **keep** |
| `:1580` cursor during `draggingSelectionRect` | region | `isRegionMode` |
| `:1596` selection-edge resize cursor | region | `isRegionMode` |
| `:1626` cursor inside/outside the hole | region | `isRegionMode` — replaced by the annotate cursor policy |
| `:1716` `updateToolbarPosition` | region geometry | new `.liveAnnotate` placement |
| `:1988` `handlePointerDown` selection resize / hole drag | region | `isRegionMode` |
| `:2204` `rebasePointAfterWindowMoveIfNeeded` | region screen-swap | `isRegionMode` |
| `:2281`, `:2287` drag → `onSelectionRectChanged` | region | `isRegionMode` (guards are at `:2279`/`:2287`) |
| `:2479`, `:2487` up → `onSelectionDragEnded` | region | `isRegionMode` |
| `:2993` `draw(_:)` | region backdrop | `isRegionMode` — **whole branch**, see below |
| `clampSelectionRect()` `:1744` | region | `isRegionMode` |

**The black-screen trap.** The `isLiveMode` branch in `draw(_:)` is:

```swift
if !frozenDisplaySnaps.isEmpty { drawFrozenBackdropTiled() }
else { NSColor.black.setFill(); bounds.fill() }
```

`frozenDisplaySnaps` is empty by construction in `.liveAnnotate` —
`configureLiveHoleFrozenSources` is only ever called from
`ScreenshotManager.swift:422`. Gating only "the frozen backdrop" leaves the
`else`, which fills the entire screen opaque black. Gate the **entire** block
`:2993-3005` on `isRegionMode`, black fallback included. In `.liveAnnotate`,
`draw(_:)` paints no backdrop at all and falls straight through to
`drawAnnotationLayers`.

**Two gates are neutralised, two invert.** Setting `screenshotRect = bounds`
turns the hard `return` gates at `:2110` (shapes) and `:2082` (text) into
no-ops as intended. But at `:2145` (badge) and `:2175` (sticker) the
`screenshotRect.contains` check selects between clamped and unclamped
placement, so it flips from never-taken to always-taken: badges and stickers
dropped within half their size of a screen edge now slide inward instead of
centring on the click. Acceptable behaviour, but it must be tested for, not
assumed away.

**The invariant needs enforcing.** `screenshotRect = bounds` is set once at
construction and nothing maintains it. The view has no `setFrameSize` override,
and `convertPointToScreenshotCoordinates` `:1359` flips about
`screenshotRect.maxY`, not `bounds.maxY` — so if the view resizes and
`screenshotRect` does not, every mark and every hit-test is displaced by the
height delta. Override `setFrameSize` to re-set `screenshotRect` and
`annotationReferenceRect` to the new bounds in `.liveAnnotate`, then reposition
the chrome.

**Annotations must be owned by the manager, not the view.** The mandated
Guides-style hotplug handling tears down and rebuilds windows and views
(`GuidesManager.swift:152-192`). Guides survives this because the manager owns
the model and re-pushes it; `annotations` lives inside the view, so a rebuild
would silently wipe the canvas on every display change, resolution change, or
wake. `AnnotateManager` holds the per-screen annotation arrays and re-seeds a
rebuilt view.

**Save and export.** `renderAnnotatedImage()` `:3449` and
`renderAnnotatedImageLegacy()` `:3510` both guard on `screenshot` and are
unreachable. There are **two** Return→save bindings, not one:
`handleAnnotationKeyMonitorEvent` `:1296` and the `keyDown` override `:390`.
They are coupled — the local monitor only swallows an event when the handler
returns `true`, so disabling only the first lets the event reach `keyDown` and
save anyway. Both route through one `canSave` predicate on the mode. Likewise
there are two ESC bindings, `:1293` and `:387`.

Suppressing `onSaveRequested` is **not** sufficient on its own:
`setupToolbar()` is called unconditionally from `viewDidMoveToWindow` `:348`
with no mode gate, so `.liveAnnotate` would render the full screenshot-editor
toolbar — Save button included and clickable — on top of the new tool strip,
positioned top-centre *inside* the canvas (both `spaceAboveSelection` and
`spaceBelowSelection` evaluate to 0, so the last-resort branch at `:521`
fires), where `handlePointerDown` `:1978` makes it a permanent dead zone. That
stale toolbar also matches the toolbar tests' `cornerRadius == 5 &&
height == 36` predicate, masking tool-strip regressions. `setupToolbar` must be
mode-gated: editor toolbar for `.staticImage`/`.liveRegion`, tool strip for
`.liveAnnotate`.

There is no export from the live overlay — annotations are on screen, so an
ordinary screenshot captures them.

### Coordinate conversion for the contextual bar

`convertPointFromAnnotationSpace` `:1412` is **not** a view-space converter,
despite the name. It computes the view point internally and then discards it,
converting on to `screenshotRect`-local, top-left-origin, Y-down space. When
`screenshotRect == bounds` it degenerates to the identity function, so
positioning an AppKit subview with its result mirrors the bar vertically about
screen centre.

It and `convertRectToAnnotationSpace` `:1425` have **zero callers** anywhere in
the repo, so nothing currently catches this.

Add a real converter and anchor the contextual bar off it:

```swift
private func viewPointFromAnnotationSpace(_ p: NSPoint) -> NSPoint {
    let ref = annotationSpaceRect
    return NSPoint(x: ref.origin.x + p.x, y: ref.maxY - p.y)
}
```

This is the intermediate that `beginEditingTextAnnotation` `:2629` and
`textFieldChanged` `:2829` already compute inline. Delete the two dead
converters so the wrong one cannot be picked again.

### Host: AnnotateManager

New file `Topkit/AnnotateManager.swift`. Modelled on `GuidesManager`, **not**
`DrawingManager`. Guides is the only overlay in the repo that handles
multi-monitor hotplug, click-through, and key-window correctly. Draw gets all
three wrong: `MultiMonitorWindow` never overrides `canBecomeKey`
(`MultiMonitorHelper.swift:5-10`), so its window is never key and
`DrawingOverlayView.keyDown` (`DrawingManager.swift:364-370`) is dead code.

```swift
final class AnnotateManager: ObservableObject {
    static let shared: AnnotateManager
    @Published private(set) var isActive: Bool
    @Published private(set) var armedTool: AnnotationTool?
    var onAnnotateStateChanged: ((Bool) -> Void)?
    func toggle(tool: AnnotationTool)  // same tool = exit, different tool = swap
    func stop()
    func cancelForPermissionLoss()
}
```

One `AnnotateScreenOverlay { screen, window, view }` per `NSScreen`, mirroring
`GuidesManager.swift:35-41`.

Window class: `LiveAnnotationOverlayWindow`, moved out of
`ScreenshotManager.swift:128-135` into its own file and made internal. It
already overrides `canBecomeKey { true }`, `canBecomeMain { false }`, and
`constrainFrameRect` to return the rect unchanged.

Window level: `.screenSaver + 1`, matching the screenshot overlay
(`kScreenshotOverlayBaseLevel`, `ScreenshotManager.swift:7`). This places
Annotate above Guides (`.screenSaver`, `GuidesManager.swift:174`) and level with
Halo (`HaloManager.swift:141`). Draw and Measure sit at `.floating`
(`DrawingManager.swift:157`, `MeasureManager.swift:157`); the repo has no
documented level policy, so this choice is recorded here deliberately.

`kScreenshotOverlayBaseLevel` is `private` to `ScreenshotManager.swift`. It moves
into the new `LiveAnnotationOverlayWindow.swift` alongside the window class and
becomes internal, rather than being duplicated.

Copied verbatim from Guides:

- Display reconfiguration resilience — `GuidesManager.swift:84-150`
  (`didChangeScreenParametersNotification` + `didWakeNotification` +
  `screenConfigurationChanged()` with 0.5pt epsilon diff at `:111-126`).
  Without it, hotplug leaves orphan windows on removed screens and no window on
  new ones, which is the current state of Draw, Measure, Halo, Magnifier, and
  the colour picker.
- `orderOutPreferencesWindowForToolOverlay()` (`AppDelegate.swift:1452-1455`)
  as the first statement of start, or overlays spawn on the preferences
  window's Space.

New in `AnnotateManager`, absent from Draw: capture the frontmost
`NSRunningApplication` on start and reactivate it on stop. `DrawingManager`
steals focus via `NSApp.activate(ignoringOtherApps: true)` and never gives it
back (`cleanup()` `DrawingManager.swift:220-236`). Pattern to follow:
`applicationToActivateAfterCopy` (`AppDelegate.swift:170-171`).

Also copy `focusLiveAnnotationOverlayForInteraction` from
`ScreenshotManager.swift:451`, including the fact that it is called **twice** —
once synchronously and once on the next runloop turn (`:452-457`) — because a
single call does not reliably take.

### Click-through

With no tool armed and the pointer not over an existing annotation, a resize
handle, or a toolbar, clicks pass through to the application underneath. Arming
a tool makes the overlay capture unconditionally.

Mechanism: the Guides pattern at `GuidesManager.swift:235-289`. A passive
global + local mouse monitor toggles `window.ignoresMouseEvents`.

This is non-obvious and is the single most likely way the feature ships broken:
`ignoresMouseEvents` is evaluated by the window server **before** `hitTest`
runs, so overriding `hitTest` alone does nothing across applications (see the
comment at `GuidesManager.swift:226-233`). Global *mouse* monitors need no
permission; global *keyboard* monitors do, and never fire in this sandbox.

Supporting requirements:

- New `func isInteractive(atViewPoint:) -> Bool` on `ScreenshotAnnotationView`,
  fed by `findAnnotation(at:)` `:2593`, `resizeEdgeAtAnnotationSpace` `:1470`,
  and toolbar frame containment.
- `acceptsFirstMouse = true` (as `GuidesOverlayView.swift:105`) so the first
  click after a focus change is not swallowed.
- Teardown must force-restore `ignoresMouseEvents = true`
  (`GuidesManager.removeMouseTracking()` `:263-276`). Without this, a stranded
  overlay locks the user out of the machine.

### Menu

An Annotate submenu replaces the top-level Draw item at
`AppDelegate.swift:680-685`, cloning the Add Guides submenu pattern at
`AppDelegate.swift:711-730` — plain `NSMenu`, parent item with `action: nil`,
responder-chain dispatch, rebuilt on every `buildMenu`.

Items, ordered to match the screenshot editor toolbar (`:432-480`):

| Item | Shortcut key | Action |
|---|---|---|
| Freehand | `shortcutDraw` | `annotateFreehand()` |
| Rectangle | `shortcutAnnotateRectangle` | `annotateRectangle()` |
| Circle | `shortcutAnnotateCircle` | `annotateCircle()` |
| Arrow | `shortcutAnnotateArrow` | `annotateArrow()` |
| Text | `shortcutAnnotateText` | `annotateText()` |
| Redact | `shortcutAnnotateRedact` | `annotateRedact()` |
| Sticker | `shortcutAnnotateSticker` | `annotateSticker()` |
| Numbered Badge | `shortcutAnnotateBadge` | `annotateBadge()` |
| — separator — | | |
| End Annotate (only while active) | — | `endAnnotate()` |

The armed tool carries `.state = .on`.

Menu-state gotcha: the menu only rebuilds when its inputs change, via
`maybeRebuildStatusMenu` (`AppDelegate.swift:567-574`) comparing a
`MenuBuildSignature` (`:25-44`, computed at `:576-613`). The armed tool must be
added as a field to **both** the struct and the computer, or the checkmark and
the End Annotate item go stale. `hasGuides` (`:583`, `:733`) is the precedent.

### Shortcuts

Currently taken, all `⌃⇧`: D H I J K L M R S V Z.

| Key | Tool |
|---|---|
| `⌃⇧D` | Freehand (existing `shortcutDraw`, remapped to Annotate) |
| `⌃⇧B` | Rectangle |
| `⌃⇧C` | Circle |
| `⌃⇧A` | Arrow |
| `⌃⇧T` | Text |
| `⌃⇧X` | Redact |
| `⌃⇧Y` | Sticker |
| `⌃⇧N` | Numbered Badge |

Leaves E F G O P Q U W free. `⌃⇧Y` for Sticker has no mnemonic; it is the least
bad free letter and is user-changeable in Preferences.

Adding one shortcut touches five places:

1. `AppDelegate.registerDefaultUserValues()` `:118-130`
2. the `bindings` array in `setupShortcuts()` `:349-364` (Carbon
   `RegisterEventHotKey`; the menu key-equivalent is display-only)
3. the menu item, via `createMenuItemWithShortcut` `:1312-1325`
4. `PreferencesView.ShortcutsTab` — an `@AppStorage` property at `:1371-1384`
   and a `ShortcutRow` at `:1397-1410`, in menu order per the contract comment
   at `:1395-1396`; that comment and the one at `AppDelegate.swift:636-637`
   both need updating. Eight new rows takes the tab to ~22, so the annotate
   rows get a section header.
5. `expectedShortcutDefaults` in
   `Tests/TopkitTests/AnnotationToolsFeatureTests.swift:85-97`, which asserts
   exact values, uniqueness, and parseability.

Both parsers must accept the string: `HotKeyManager.parse`
(`HotKeyManager.swift:157-212`) and `ShortcutKeyParser.parse`
(`ShortcutKeyParser.swift:6-54`). Plain letters satisfy both.

Constraints: `⌥`-only and `⌥⇧` combinations fail to register on macOS 15+ under
sandbox — `RegisterEventHotKey` returns -9868 (`HotKeyManager.swift:100-101`)
— and registration failure is silent (`:102`). Avoid `⌃⇧Space` (input-source
switching) and any `⌘` combination (Carbon consumes it system-wide, breaking
the frontmost app's own menu equivalent).

### Toolbars

Two bars with distinct roles.

**Tool strip** — pinned bottom-centre of the screen the pointer is on, visible
for the whole session, armed tool highlighted. Lets the user switch tools
without reopening the status menu. Reuses `createToolButton` `:638`,
`createStickerButton` `:716`, `applyAnnotationToolbarChrome()` `:600`, and the
`HoverStateButton` at `:20-54`. Close and Save buttons from the editor toolbar
(`:487-501`) are omitted; the strip ends with a divider and an exit button.

**Contextual bar** — new file
`Topkit/Views/ScreenshotAnnotationView+ContextBar.swift`. Appears when
`selectedAnnotationId` becomes non-nil, anchored above `effectiveFrame(for:)`
`:1521` converted out of annotation space via `convertPointFromAnnotationSpace`
`:1412`, flipping below the element when near the top of the screen. Dies on
deselect.

| Selection | Controls |
|---|---|
| freehand / rectangle / circle / arrow | colour, thickness |
| text | colour, font size, font family |
| numbered badge | colour, badge size |
| sticker | type, size, pointer direction — **all new** |
| redact | mosaic block size — **new** |

Thickness (1–20), font size (8–72), and badge size (16–120) reuse the existing
sliders at `:542`, `:553`, `:564` and their actions `thicknessChanged` `:1011`,
`fontSizeChanged` `:1025`, `badgeSizeChanged` `:1060`, `colorChanged` `:986`,
all of which already check `selectedAnnotationId` and already coalesce undo via
`ContinuousEditKind` `:1224`.

Sticker and redact currently show **no** options row at all
(`updateSliderVisibility()` `:953-970`) and the mosaic block size is a hardcoded
constant, so those controls are genuinely new. Sticker type reuses the tag map
at `:879` and pointer direction reuses `buildStickerPointerMenu()` `:2230`.

`updateUIForSelectedAnnotation(_:)` `:1081` must stop assigning
`currentTool = annotation.type`. Today the editor deliberately conflates
"options for the selection" with "options for the next thing you draw"; on the
live overlay that would reset the armed tool every time the user clicks an
existing element.

Do not touch the `NSColorPanel` handling in `showColorPicker()` `:976` or
`menuWillOpen` `:833` — both force their windows above the overlay level for
exactly this reason.

### Redact on a live screen

Redact is the only tool that needs pixels from underneath the overlay.
`mosaicRegionImage(forFrame:)` `:3251-3272` reads either the static screenshot
or the frozen display snapshots; on a live overlay neither exists and
`drawRedaction` `:3373` degrades to a solid black fill.

Approach: **capture once per session, crop per annotation.** Not per-commit.

1. Add `var bakedMosaic: NSImage?` to `Annotation` `:114-130`.
2. When the Redact tool is first armed in a session, `AnnotateManager` takes one
   `ScreenCaptureHelper.captureAllDisplays` (`ScreenCaptureHelper.swift:15`) and
   caches the per-display images.
3. On `handlePointerUp` for a `.blur`, crop the cached image to the
   annotation's rect and run the existing static
   `bakedMosaic(of:sourceRect:outSize:)` `:3319`. Synchronous, so there is no
   window in which the annotation renders as black.
4. Re-crop from the same cached image on move or resize, so dragging does not
   stretch stale pixels. There are **three** `handlePointerUp` exits that can
   end a redaction interaction — resize `:2497`, drag `:2514`, create `:2560` —
   so this goes in one `rebakeIfNeeded(id:)` called from all three.

Per-commit capture was rejected: `captureAllDisplays` is asynchronous
(`SCShareableContent.getExcludingDesktopWindows` plus a per-display
`SCScreenshotManager.captureImage` inside a `DispatchGroup`), which leaves a
multi-frame window where the committed annotation paints opaque black, and it
would need a hide/restore cycle per commit.

**The overlay must be excluded from the capture, via the filter, not by hiding
the windows.** `orderOut` on a key `LiveAnnotationOverlayWindow` drops key
status and first responder — which the key monitor, the inline-text focus
dance, and cursor updates all depend on — and it exposes the live pixels that
already-committed redactions exist to hide. `ScreenCaptureHelper.swift:32`
currently passes `excludingWindows: []`; it needs a new parameter, and the
screenshot flow must explicitly **not** pass it, or Topkit's own screenshots
silently lose every annotation and the "no export needed" rationale collapses.

**Call-site change only.** `drawRedaction` `:3373` is a static function taking
`mosaic` as a parameter, with two callers that pass different sources. Change
the instance call site `:3229` to
`isRegionMode ? mosaicRegionImage(forFrame:) : annotation.bakedMosaic` and
leave the signature and the export path `:3689` untouched, so the black
fallback remains the export-time guarantee.

**`bakedMosaic` must be threaded through every copy path.** `Annotation` is
copied by explicit field-by-field memberwise init in three places —
`snapshotAnnotations` `:1167`, `copyAnnotation` `:1192`,
`convertAnnotationToCaptureRect` `:1380`. A field with a default value compiles
clean at all three and is silently dropped, so every undo, redo, copy and paste
would turn a redaction back into a solid black rectangle with no warning. Add
it to `:1167` and `:1380`. In `copyAnnotation` `:1192` deliberately set it to
`nil` and mark the annotation for re-bake at its new position — carrying the
image to a new location is both a correctness bug and a privacy bug, since it
would show the pixels from where it was copied. Better still: route all three
through one copy helper so the next added field cannot be dropped either.

**`liveHoleScreenOrigin` is never seeded in `.liveAnnotate`** — only
`configureLiveHoleFrozenSources` and `relocateForScreenSwap` assign it. Without
seeding, a crop that treats view-local coordinates as global bakes the wrong
display's pixels on any monitor not at the origin. `AnnotateManager` seeds it
per screen.

Consequences: the Redact menu item routes through `PermissionManager`, using
the live `SCShareableContent` check rather than cached preflight (the reason is
documented at `ScreenshotManager.swift:190` — `CGPreflightScreenCaptureAccess`
keeps returning true after a mid-session revoke). `AnnotateManager` must be
added to the permission-revoked handler at `AppDelegate.swift:231-240`, where
`DrawingManager` is correctly absent today. Capture paths must respect
`backingScaleFactor` (see the pixel-space note at
`MultiMonitorHelper.swift:132-143`).

If the capture fails or permission is revoked mid-session, arming Redact shows
the permission prompt and the tool refuses to place; it does not place a black
rectangle.

### Keyboard ownership

`setupKeyMonitor()` `:1330` installs an app-wide
`NSEvent.addLocalMonitorForEvents(matching: .keyDown)` **per view instance**,
and is called twice per view (`:272` init and `:355` `viewDidMoveToWindow`).
With one view per screen, an N-monitor session gets N monitors all seeing every
keyDown. `Cmd+Z` `:1309` and `Cmd+C` `:1317` return `true` unconditionally even
when `performUndo`/`copySelectedAnnotations` did nothing, and returning `true`
makes the monitor swallow the event — so on a multi-monitor session the first
monitor to run eats undo and copy, and they do nothing on the other screen.
Delete `:1300` and paste `:1321` already guard this correctly, which makes the
omission look accidental.

Fix: `AnnotateManager` owns a single monitor and dispatches to the view whose
window is key. Failing that, make the `z` and `c` handlers return `false` when
they did nothing.

**Escape is unreachable in the mode's most common state.** With click-through
active and no tool armed, the overlay is not key, so no local monitor fires and
Escape does nothing — the documented way to exit the session is dead exactly
when the user is most likely to want it. `AnnotateManager` therefore registers
Escape as a Carbon hotkey (`HotKeyManager`) for the duration of the session:
global, no permission required, consistent with every other shortcut in the
app. It is unregistered on stop.

### Draw is removed

`DrawingManager.swift` is deleted. `shortcutDraw` is remapped to
`AnnotateManager.shared.toggle(tool: .freehand)`.

Two behaviours port across:

- **Rainbow brush.** Today `DrawingOverlayView.drawPath`
  (`DrawingManager.swift:483-557`) resolves colour at render time from
  `brushColorMode` in `UserDefaults`, so existing strokes retroactively
  recolour when the preference changes. In the new model, `Annotation` gains a
  colour mode captured at creation. A stroke drawn in rainbow stays rainbow.
  This is a deliberate behaviour change. The renderer is also rewritten:
  today it issues one `strokePath()` per ~2pt subsegment and redraws the whole
  canvas on every drag event.
- **Auto-close.** The 10-second inactivity timer gated on `autoCloseDrawMode`
  (`DrawingManager.swift:39-42`, `:207-218`) moves to `AnnotateManager` and
  applies to the whole Annotate session.

### Multi-monitor

Each screen gets its own `ScreenshotAnnotationView` with its own `annotations`
array. Copy/paste and undo are therefore per-screen: copying on one display and
pasting on another does nothing.

Rationale: the existing cross-screen mirroring
(`drawAnnotationsForOverlay(in:overlayScreenOrigin:)` `:3028` and its consumer
`ScreenshotManager.swift:736`) exists only to service a selection hole that
spans displays, and adopting it drags in the whole `relocateForScreenSwap`
`:287` machinery. Not worth it here. Recorded as a known limitation.

### Interaction rules

Decisions the implementer would otherwise have to invent.

**Armed tool is sticky.** Placing an element does not disarm. This matches the
editor, where `currentTool` is never nilled after a commit. Consequence: while
a tool is armed the overlay captures all clicks, so the user must disarm to get
click-through back. The tool strip's armed button is the disarm affordance —
clicking the armed tool again disarms without ending the session.

**Toggle semantics differ by entry point, deliberately.** A shortcut or menu
item for the already-armed tool **ends the session**; the same tool clicked on
the strip only **disarms**. The strip must not be wired straight to the view's
existing `selectTool` `:897`, which does the latter.

**Escape is three-level**, in order: finish inline text editing if active
(existing behaviour `:1281`); else deselect if something is selected; else
disarm if a tool is armed; else end the session.

**Arming a different tool keeps the current selection** and its contextual bar.
The armed tool governs the *next* placement only. This is the reason
`updateUIForSelectedAnnotation` `:1095` must stop assigning `currentTool` — but
gate that change on `.liveAnnotate`, since the same assignment drives slider
visibility and button state in the screenshot editor and changing it there
would break `ScreenshotAnnotationViewToolbarTests`.

**Cursor policy.** Non-trivial, because with `ignoresMouseEvents = true` the
view receives no `mouseMoved` and `updateCursorForLocalPoint` `:1558` never
runs; the hook is the existing `synchronizeCursorFromScreenPoint` `:1648`,
driven from the same global monitor as click-through.

| State | Cursor |
|---|---|
| no tool armed, empty canvas under pointer | leave the underlying app's cursor untouched |
| tool armed | crosshair |
| over an element | open hand |
| over a resize handle | `cursorForResizeEdge` |
| over the strip or contextual bar | pointing hand |

Teardown restores the arrow, as `DrawingManager.swift:230` does today.

**The tool strip is the mode indicator.** It is visible for the whole session
including when no tool is armed. The status-bar icon is not sufficient: it ORs
across Guides, Halo, and Measure (`AppDelegate.swift:1411`), so with two
overlays live it indicates nothing.

**The strip lives on the screen the pointer is on** and migrates on screen
change, driven by the click-through monitor. A selection and its contextual bar
stay on their own screen when the pointer leaves.

**Contextual bar placement**: above the element by default; flips below when
within its own height plus 8pt of the screen top; clamped horizontally to the
screen with an 8pt inset; anchored to the visible intersection when the element
is larger than or partly off the screen; nudged up if it would overlap the tool
strip.

**Deselect on pass-through click.** Guides' global mouse-down handler
(`GuidesManager.swift:245`) deselects on any observed click. Keep that, but
exclude clicks in the menu-bar rect, or opening the status menu kills the
contextual bar for the element the user is about to act on.

**Arming a tool captures on every screen**, not just the pointer's, so a stroke
can be started after moving to another display.

**`isInteractive` is evaluated per screen.** Guides ORs across all overlays and
sets the same flag on every window (`GuidesManager.swift:283`); that is a bug
not to inherit, since it makes every screen opaque to clicks when the pointer is
over an element on one of them. Each window's flag is set independently.

**Undo/redo** is `Cmd+Z` / `Cmd+Shift+Z`, per screen and per session, and
survives disarm. Draw's backspace-to-undo is not carried over.

**Screenshot region pick takes precedence.** Annotate and the screenshot
overlay both sit at `.screenSaver + 1`, and ordering between same-level windows
is undefined — so triggering a screenshot mid-session would be a coin flip over
which one receives clicks. `AnnotateManager` sets `ignoresMouseEvents = true`
on all its windows for the duration of a region pick and restores afterwards.
Recording is unaffected. No other mutual exclusion is added.

### Session end

Escape (see the three-level rule above) ends the mode and discards all
annotations, matching Draw today. There is no persistence layer anywhere in the
app — not for strokes, guides, or annotations — and `Annotation` holds a
non-`Codable` `NSColor`, so persistence would be greenfield. Out of scope.

A "Clear Annotations" item is not added; Escape covers it and the tool strip
carries an exit button.

## Refactors folded in

Two, both load-bearing rather than opportunistic.

**Unify the renderers.** The file has two full annotation renderers that have
already drifted: instance `drawAnnotation(_:in:)` `:3108-3236` uses
`effectiveFrame(for:)` for text while static
`drawOneAnnotation(_:in:sourceImage:)` `:3606-3697` uses `annotation.frame`.
The sticker glyph/colour table is duplicated a third time at
`updateStickerButtonIcon` `:755`. Adding a third caller entrenches the bug.
Collapse into one `Topkit/AnnotationRenderer.swift` taking an optional mosaic
source.

**Lift the model out.** `AnnotationTool`, `StickerType`,
`StickerPointerDirection`, `Annotation`, and the layout constants
(`:58-158`) move to `Topkit/Models/Annotation.swift`. The full split of the
3773-line view is explicitly **not** in scope.

The `_ForTesting` shims at `:3428-3446` must survive unchanged — they are the
only handle the annotation tests have.

## Testing

Existing pure-logic tests (`AnnotationToolsFeatureTests`,
`ScreenshotAnnotationViewToolbarTests`, `AnnotationExportRenderTests`) cover
the model, shortcut defaults, and export rendering. New coverage:

- The eight new shortcut defaults, via `expectedShortcutDefaults`
  (`AnnotationToolsFeatureTests.swift:85-97`) — asserts exact value,
  uniqueness, and parseability by both parsers.
- `.liveAnnotate` construction: `screenshotRect == bounds`, and a `.rectangle`
  placed at an arbitrary point commits — proving the `screenshotRect.contains`
  gates at `:2110` are neutralised.
- Redact with no capture source takes the baked-mosaic path, not the black
  fallback.
- Contextual bar control selection: given a selected annotation of each type,
  the expected control set is produced. Pure function over `AnnotationTool`,
  no view instantiation.
- Renderer unification: a golden-image test asserting instance and static
  render paths agree for a text annotation, locking in the drift fix.
- `.liveAnnotate` `draw(_:)` paints no backdrop — asserts the black-fill
  fallback is unreachable in the new mode.
- Badge and sticker placed within half their size of a screen edge clamp
  inward rather than being rejected (the inverted gates at `:2145` / `:2175`).
- `bakedMosaic` survives a snapshot/undo/redo round trip, and is `nil` after a
  copy/paste.
- `viewPointFromAnnotationSpace` round-trips against
  `convertPointToAnnotationSpace` and is **not** the identity when
  `screenshotRect == bounds`.
- Key-monitor handlers return `false` for `Cmd+Z` and `Cmd+C` when there is
  nothing to undo or copy, so a second view's monitor still gets the event.
- `setFrameSize` in `.liveAnnotate` keeps `screenshotRect == bounds`, and a
  hit-test after a resize still finds an annotation placed before it.
- Click-through predicate: `isInteractive(atViewPoint:)` returns false over
  empty canvas with no tool armed, true over an annotation, true over a handle,
  true with a tool armed.

`ScreenshotAnnotationViewToolbarTests` identifies the toolbar by
`layer?.cornerRadius == 5 && frame.height == 36` (`:21`) and the slider row by
`layer?.cornerRadius == 5 && frame.height == 28` (`:27`). The new tool strip and
contextual bar must not collide with either pair, or the test gives false
positives.

### Build and test commands

```bash
swift test                    # real coverage, superset of the Xcode test target
scripts/run-test-gates.sh     # metadata validation + swift test + build-for-testing

xcodebuild -project Topkit.xcodeproj -scheme Topkit -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build-for-testing
```

`xcodebuild … test` is deliberately not run locally: the test target is hosted
in the menu-bar app, so the runner launches the app and hangs. CI runs it
(`.github/workflows/ci.yml`, jobs `swift-test` and `xcode-test`).

### Xcode project registration

`Topkit.xcodeproj/project.pbxproj` is `objectVersion = 56` with no
`PBXFileSystemSynchronizedRootGroup`, so every new `.swift` file needs four
manual entries: `PBXFileReference`, `PBXBuildFile`, `PBXGroup` child,
`PBXSourcesBuildPhase`. There is no script for this.

SwiftPM auto-globs (`Package.swift` uses `path: "Topkit"` plus `exclude:`), so
`swift test` passes on an unregistered file while the Xcode job compiles a
stale source set. Four test files are **already** unregistered and silently
skipped by CI: `AnnotationToolsFeatureTests.swift`,
`AnnotationExportRenderTests.swift`, `CaptionModelTests.swift`,
`RecordingConfirmToolbarTests.swift`. Registering them is part of this work —
otherwise the new tests are skipped too.

## New and changed files

| File | Action |
|---|---|
| `Topkit/AnnotateManager.swift` | new — overlay lifecycle, click-through, hotplug, focus restore, auto-close |
| `Topkit/LiveAnnotationOverlayWindow.swift` | new — moved out of `ScreenshotManager.swift:128-135`, made internal |
| `Topkit/Models/Annotation.swift` | new — model and constants lifted from the view |
| `Topkit/AnnotationRenderer.swift` | new — the two drifted renderers unified |
| `Topkit/Views/ScreenshotAnnotationView+ContextBar.swift` | new — contextual bar and tool strip |
| `Topkit/Views/ScreenshotAnnotationView.swift` | `CanvasMode` + 15-site gate classification; mode-gate `setupToolbar` `:348`; whole-branch `isRegionMode` gate on `draw(_:)` `:2993`; `setFrameSize` invariant; both Return and both ESC bindings behind `canSave`; `viewPointFromAnnotationSpace` added and the two dead converters deleted; `bakedMosaic` threaded through `:1167`/`:1192`/`:1380`; key-monitor handlers return `false` when they no-op; `isInteractive(atViewPoint:)`; `updateUIForSelectedAnnotation` stops clobbering `currentTool` in `.liveAnnotate` only |
| `Topkit/ScreenCaptureHelper.swift` | new `excludingWindows` parameter on the capture entry point (`:32`); screenshot flow deliberately does not pass it |
| `Topkit/DrawingManager.swift` | deleted (phase 6) |
| `Topkit/AppDelegate.swift` | Annotate submenu, 7 new shortcut defaults and bindings, `MenuBuildSignature` gains **both** `isAnnotateActive` and the armed tool, permission-revoked wiring, manager instantiation |
| `Topkit/HotKeyManager.swift` | session-scoped Escape registration/unregistration for `AnnotateManager` |
| `Topkit/Views/PreferencesView.swift` | 7 new shortcut rows under an Annotate section; order comment updated |
| `Topkit.xcodeproj/project.pbxproj` | register 5 new source files, new test files, and the 4 already-unregistered test files |

## Phasing

This is too large for one build, and the click-through failure mode is "locks
the user out of the machine" — that should not land in the same TestFlight
round as everything else. Six phases, each independently shippable.

1. **Pure refactor, no behaviour change.** Lift the model to
   `Models/Annotation.swift`, unify the two drifted renderers into
   `AnnotationRenderer.swift`, delete the two dead coordinate converters,
   register the 4 orphaned test files and the new files in `project.pbxproj`.
   Ships an identical app with the text-rendering drift bug fixed and CI
   actually running the annotation tests. Makes every later diff readable.
2. **`.liveAnnotate` + `AnnotateManager` + click-through, freehand only.**
   `CanvasMode` and the full 15-site gate classification, extracted
   `LiveAnnotationOverlayWindow`, `setFrameSize` invariant, manager-owned
   annotations, hotplug, focus restore, teardown force-restore, keyboard
   ownership, Carbon Escape, `isInteractive`, cursor policy, tool strip with one
   tool. `DrawingManager` stays in the tree but unwired. Ships as "Draw, but
   with select/move/resize/copy". **All the risk lives here** — it deserves its
   own build and its own TestFlight round.
3. **The remaining 6 tools** (rectangle, circle, arrow, text, sticker, badge),
   the Annotate submenu, 7 shortcuts, Preferences rows. Excludes redact. Ships
   the full tool set minus redact.
4. **Contextual bar**, including the new sticker and redact option controls.
   Ships independently: phase 3 already places elements, this makes them
   editable.
5. **Redact**: session capture, bake, `SCContentFilter` exclusion parameter,
   permission wiring. Isolated because it is the only piece touching capture
   and permissions.
6. **Delete `DrawingManager.swift`**, once 2–5 have survived a TestFlight
   round.

Phases 1, 2 and 5 are load-bearing. 3 and 4 can merge if the diff stays
reviewable.

## Risks

- **Click-through is the highest risk.** `ignoresMouseEvents` is evaluated
  before `hitTest`; getting this wrong either makes the overlay inert or locks
  the user out of their machine. Teardown must force-restore it.
- **Inline text editing focus.** Two hard-won mechanisms must be reused:
  `LiveAnnotationOverlayWindow.allowsKeyboardFocus`, toggled around text
  editing at `ScreenshotAnnotationView.swift:1257-1264`; and the Guides
  pattern of an async first-responder hop plus a 300ms `suppressEndEditingUntil`
  guard so menu-dismissal focus churn does not instantly fire
  `controlTextDidEndEditing` (`GuidesOverlayView.swift:947-958`, `:1365-1384`).
  Triggering the text tool from the status menu means being inside a menu
  tracking session, which hits exactly this.
- **Sandbox keyboard.** Global keyDown monitors never fire without Input
  Monitoring. `Cmd+C`, `Cmd+V`, delete, and arrow-nudge only work while the
  overlay window is genuinely key and the app is activated.
- **No mutual exclusion exists** between overlay tools. Annotate, Halo,
  Measure, and Guides can all be live at once, and `updateStatusBarIcon()`
  (`AppDelegate.swift:1411-1412`) simply ORs the flags. Annotate follows the
  existing behaviour; no exclusion logic is added.
- **Verification is TestFlight-only.** There is no local run step. Correctness
  rests on `swift test`, the Xcode build gate, and review.

## Out of scope

- Persisting annotations across sessions
- Exporting or copying the annotated screen to a file or the clipboard
- Multi-select
- Z-order reordering
- Cross-screen shared canvas
- The full split of `ScreenshotAnnotationView.swift`
