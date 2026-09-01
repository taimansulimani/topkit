# Annotate Phase 1: Model Lift and Renderer Unification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare `ScreenshotAnnotationView.swift` for the live Annotate overlay by lifting the annotation model into its own file, collapsing the two drifted annotation renderers into one, deleting two dead coordinate converters, and registering the four test files CI currently skips — with no user-visible change except one deliberate text-export fix.

**Architecture:** The annotation model (`AnnotationTool`, `StickerType`, `StickerPointerDirection`, `Annotation`) moves to `Topkit/Models/Annotation.swift` unchanged. All drawing primitives and both `switch annotation.type` renderers collapse into a new stateless `AnnotationRenderer` enum in `Topkit/AnnotationRenderer.swift`. The two renderers differ in exactly two places — which frame text renders into, and where the redaction mosaic comes from — so `AnnotationRenderer` takes a small `Context` struct of closures supplying those. `ScreenshotAnnotationView` keeps thin forwarders for the three static members the tests use.

**Tech Stack:** Swift 5, AppKit, CoreGraphics, XCTest. Two build systems over the same sources: SwiftPM (`Package.swift`, auto-globs `Topkit/`) and Xcode (`Topkit.xcodeproj`, manual file registration).

**Spec:** `docs/superpowers/specs/2026-07-19-live-annotate-overlay-design.md`, phase 1.

---

## Context the engineer needs

**This repo has two build systems over one source tree.** `Package.swift` declares a `TopkitCore` library target with `path: "Topkit"`, which auto-globs every `.swift` file. `Topkit.xcodeproj` is `objectVersion = 56` with no `PBXFileSystemSynchronizedRootGroup`, so it needs every file registered by hand in four places. Consequence: **`swift test` passes on a file Xcode never compiles.** Four test files are in this state today and are silently skipped by CI's `xcode-test` job. Task 1 fixes that first, so the rest of the plan is actually gated.

**Never run `xcodebuild … test` locally.** The test target is hosted inside the menu-bar app, so the runner launches Topkit and hangs ("test runner hung before establishing connection"). Use `swift test` for tests and `xcodebuild … build-for-testing` for the Xcode compile gate. Both `scripts/run-test-gates.sh` and `fastlane/Fastfile` document this.

**Do not launch the app.** Verification in this repo is `swift test` plus the Xcode build gate; runtime testing happens through TestFlight.

**Baseline:** `swift test` currently reports `Executed 161 tests, with 0 failures`.

**Coordinate convention:** annotation drawing happens in a Y-flipped (top-left origin) CGContext. Text and stickers un-flip locally with a `translate / scale(1,-1) / translate` sandwich before drawing, then restore. Preserve those sandwiches verbatim when moving code — getting one wrong renders content upside down.

---

## The one deliberate behaviour change

The two renderers have drifted for `.text`:

- On screen, `drawAnnotation` `:3167` renders into `effectiveFrame(for: annotation)`, which recomputes the frame from the current text and font size via `textAnnotationFrame`, keeping only the stored origin (`:1521-1531`).
- On export, `drawOneAnnotation` `:3647` renders into the raw stored `annotation.frame`.

So a text annotation whose stored frame is stale renders in one place on screen and another in the saved file. Unifying on `effectiveFrame` — the screen behaviour — fixes that, and is the reason this refactor is worth doing before a third caller is added. Task 5 locks it in with a test.

Everything else in this plan is behaviour-preserving.

---

## File structure

| File | Responsibility |
|---|---|
| `Topkit/Models/Annotation.swift` | **new.** The annotation model: `AnnotationTool`, `StickerType`, `StickerPointerDirection`, `Annotation`. No drawing, no AppKit views. |
| `Topkit/AnnotationRenderer.swift` | **new.** Stateless rendering of one annotation into a CGContext, plus every drawing and text-metrics primitive. Injected `Context` supplies the two call-site-specific behaviours. |
| `Topkit/Views/ScreenshotAnnotationView.swift` | Loses the model, the primitives, and both renderers. Keeps view state, hit-testing, toolbar, mouse/keyboard, and thin static forwarders for `renderAnnotations`, `nextBadgeNumber`, `drawRedaction`. |
| `Topkit.xcodeproj/project.pbxproj` | Gains 6 file registrations (2 new sources, 4 orphaned tests). |
| `Tests/TopkitTests/AnnotationRendererTests.swift` | **new.** Locks the screen/export agreement for text. |

---

## Task 1: Register the four orphaned test files in the Xcode project

CI's `xcode-test` job currently compiles a stale source set that omits four test files, so any regression they would catch goes unnoticed. Fix this before touching code, so the rest of the plan is genuinely gated.

**Files:**
- Modify: `Topkit.xcodeproj/project.pbxproj`

- [ ] **Step 1: Confirm the four files are unregistered**

Run:
```bash
cd /Users/tr/Projects/Topkit
for f in $(ls Tests/TopkitTests/*.swift | xargs -n1 basename); do
  grep -q "$f" Topkit.xcodeproj/project.pbxproj || echo "MISSING $f"
done
```

Expected, exactly:
```
MISSING AnnotationExportRenderTests.swift
MISSING AnnotationToolsFeatureTests.swift
MISSING CaptionModelTests.swift
MISSING RecordingConfirmToolbarTests.swift
```

If the list differs, stop and reconcile with the spec before continuing.

- [ ] **Step 2: Understand the four insertion points**

Every registered test file appears exactly four times. `GuideTests.swift` is the template:

```
line 45   D127770A6DDB43D78616E5CA /* GuideTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 35917E5DD4964C9B9A933B6B /* GuideTests.swift */; };
line 111  35917E5DD4964C9B9A933B6B /* GuideTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GuideTests.swift; sourceTree = "<group>"; };
line 269  35917E5DD4964C9B9A933B6B /* GuideTests.swift */,
line 567  D127770A6DDB43D78616E5CA /* GuideTests.swift in Sources */,
```

Each file needs two fresh 24-character uppercase-hex IDs: one build-file ID, one file-reference ID. They must be unique across the whole file.

- [ ] **Step 3: Generate eight unique IDs**

Run:
```bash
cd /Users/tr/Projects/Topkit
for i in $(seq 1 8); do
  while :; do
    id=$(hexdump -n 12 -e '"%08X"' /dev/urandom)
    grep -q "$id" Topkit.xcodeproj/project.pbxproj || { echo "$id"; break; }
  done
done
```

Expected: 8 lines of 24 hex characters, none already present in the project file. Record which pair goes with which file.

- [ ] **Step 4: Add the four PBXBuildFile entries**

Insert immediately after the `GuideTests.swift in Sources` line in the `PBXBuildFile` section (around line 45), using your generated IDs — `<BUILD_n>` is the first of each pair, `<REF_n>` the second:

```
		<BUILD_1> /* AnnotationExportRenderTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <REF_1> /* AnnotationExportRenderTests.swift */; };
		<BUILD_2> /* AnnotationToolsFeatureTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <REF_2> /* AnnotationToolsFeatureTests.swift */; };
		<BUILD_3> /* CaptionModelTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <REF_3> /* CaptionModelTests.swift */; };
		<BUILD_4> /* RecordingConfirmToolbarTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <REF_4> /* RecordingConfirmToolbarTests.swift */; };
```

Indentation is two tab characters. The file uses tabs, not spaces.

- [ ] **Step 5: Add the four PBXFileReference entries**

Insert after the `GuideTests.swift` file-reference line (around line 111):

```
		<REF_1> /* AnnotationExportRenderTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AnnotationExportRenderTests.swift; sourceTree = "<group>"; };
		<REF_2> /* AnnotationToolsFeatureTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AnnotationToolsFeatureTests.swift; sourceTree = "<group>"; };
		<REF_3> /* CaptionModelTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CaptionModelTests.swift; sourceTree = "<group>"; };
		<REF_4> /* RecordingConfirmToolbarTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RecordingConfirmToolbarTests.swift; sourceTree = "<group>"; };
```

- [ ] **Step 6: Add the four group children**

Insert after the `GuideTests.swift` line inside the `TopkitTests` `PBXGroup` children array (around line 269):

```
				<REF_1> /* AnnotationExportRenderTests.swift */,
				<REF_2> /* AnnotationToolsFeatureTests.swift */,
				<REF_3> /* CaptionModelTests.swift */,
				<REF_4> /* RecordingConfirmToolbarTests.swift */,
```

Indentation is four tabs.

- [ ] **Step 7: Add the four Sources build-phase entries**

Insert after the `GuideTests.swift in Sources` line inside the `TopkitTests` `PBXSourcesBuildPhase` files array (around line 567):

```
				<BUILD_1> /* AnnotationExportRenderTests.swift in Sources */,
				<BUILD_2> /* AnnotationToolsFeatureTests.swift in Sources */,
				<BUILD_3> /* CaptionModelTests.swift in Sources */,
				<BUILD_4> /* RecordingConfirmToolbarTests.swift in Sources */,
```

- [ ] **Step 8: Verify all four are now registered four times each**

Run:
```bash
cd /Users/tr/Projects/Topkit
for f in AnnotationExportRenderTests AnnotationToolsFeatureTests CaptionModelTests RecordingConfirmToolbarTests; do
  echo "$f: $(grep -c "$f.swift" Topkit.xcodeproj/project.pbxproj)"
done
```

Expected: each reports `4`.

- [ ] **Step 9: Verify the project file still parses**

Run:
```bash
cd /Users/tr/Projects/Topkit
plutil -lint Topkit.xcodeproj/project.pbxproj
```

Expected: `Topkit.xcodeproj/project.pbxproj: OK`

If this fails, the edit broke the syntax — most likely a missing semicolon or a space where a tab belongs. Fix before continuing.

- [ ] **Step 10: Verify the Xcode target compiles with the new files**

Run:
```bash
cd /Users/tr/Projects/Topkit
xcodebuild -project Topkit.xcodeproj -scheme Topkit -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build-for-testing 2>&1 | tail -5
```

Expected: `** TEST BUILD SUCCEEDED **`

If it fails with "cannot find X in scope" inside one of the newly registered test files, that is a real pre-existing bug those files were hiding. Report it rather than deleting the registration.

- [ ] **Step 11: Commit**

```bash
cd /Users/tr/Projects/Topkit
git add Topkit.xcodeproj/project.pbxproj
git commit -m "fix(ci): register the four test files Xcode was silently skipping

AnnotationExportRenderTests, AnnotationToolsFeatureTests, CaptionModelTests
and RecordingConfirmToolbarTests exist on disk and run under swift test, but
were never added to project.pbxproj, so the xcode-test CI job compiled a
stale source set and never ran them."
```

---

## Task 2: Lift the annotation model into its own file

Pure move. `AnnotationTool`, `StickerType`, `StickerPointerDirection`, and `Annotation` are all top-level types, so this is a cut and paste with no signature changes.

**Files:**
- Create: `Topkit/Models/Annotation.swift`
- Modify: `Topkit/Views/ScreenshotAnnotationView.swift:56-130` (delete)
- Modify: `Topkit.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the model file**

Create `Topkit/Models/Annotation.swift` with exactly the types currently at `ScreenshotAnnotationView.swift:56-130`, unchanged:

```swift
import AppKit
import Foundation

// MARK: - Annotation Types

enum AnnotationTool: Equatable {
    case freehand
    case rectangle
    case circle
    case arrow
    case text
    case sticker(StickerType)
    /// Mosaic redaction: drag a rectangle; the pixels underneath are pixelated so they are illegible.
    case blur
    /// Numbered badge: a filled circle with an auto-incrementing number inside.
    case numberBadge
}

enum StickerType: Equatable {
    case redX
    case greenCheck
    case yellowExclamation
}

/// Direction of the small pointer arrow emanating from a sticker (8 cardinal + diagonal).
enum StickerPointerDirection: Int, CaseIterable, Equatable {
    case up = 0
    case upRight = 1
    case right = 2
    case downRight = 3
    case down = 4
    case downLeft = 5
    case left = 6
    case upLeft = 7
    /// Unit vector in screenshot coordinates (x, y); Y increases downward in drawing context.
    var unitVector: (dx: CGFloat, dy: CGFloat) {
        switch self {
        case .up:        return (0, -1)
        case .upRight:   return (1/sqrt(2), -1/sqrt(2))
        case .right:     return (1, 0)
        case .downRight: return (1/sqrt(2), 1/sqrt(2))
        case .down:      return (0, 1)
        case .downLeft:  return (-1/sqrt(2), 1/sqrt(2))
        case .left:      return (-1, 0)
        case .upLeft:    return (-1/sqrt(2), -1/sqrt(2))
        }
    }
    var menuTitle: String {
        switch self {
        case .up:        return "↑ Up"
        case .upRight:   return "↗ Up-right"
        case .right:     return "→ Right"
        case .downRight: return "↘ Down-right"
        case .down:      return "↓ Down"
        case .downLeft:  return "↙ Down-left"
        case .left:      return "← Left"
        case .upLeft:    return "↖ Up-left"
        }
    }
}

struct Annotation {
    let id: UUID
    let type: AnnotationTool
    var frame: NSRect
    var color: NSColor
    var thickness: CGFloat
    var text: String?
    var fontSize: CGFloat?
    var startPoint: NSPoint?
    var endPoint: NSPoint?
    /// Points for freehand path (in screenshot coordinates).
    var pathPoints: [NSPoint]?
    /// For stickers: optional small arrow pointing in one of 8 directions.
    var stickerPointerDirection: StickerPointerDirection?
    /// For numbered badges: the number displayed inside the circle.
    var badgeNumber: Int? = nil
}
```

- [ ] **Step 2: Delete the originals from the view**

In `Topkit/Views/ScreenshotAnnotationView.swift`, delete lines 56 through 130 inclusive — from the `// MARK: - Annotation Types` comment through the closing brace of `struct Annotation`. Leave the `// MARK: - Main Annotation View` comment and everything after it in place.

Do **not** delete lines 134-158 (the layout constants and `kScreenshotDimOverlayAlpha`). They stay in the view file for now; `kScreenshotDimOverlayAlpha` is referenced by `ScreenshotManager`, `ScreenRecordingManager`, and `SelectionConfirmView`.

- [ ] **Step 3: Register the new file in the Xcode project**

Same four-point recipe as Task 1, but the group is the app's `Models` group, not `TopkitTests`, and the sources phase is the `Topkit` target's, not `TopkitTests`'.

Find the existing `Guide.swift` entries as your template:
```bash
cd /Users/tr/Projects/Topkit
grep -n "Guide.swift" Topkit.xcodeproj/project.pbxproj
```

Generate two fresh IDs with the Step 3 command from Task 1, then add the `PBXBuildFile`, `PBXFileReference`, `Models` group child, and `Topkit` target `PBXSourcesBuildPhase` entries for `Annotation.swift`, with `path = Annotation.swift`.

- [ ] **Step 4: Verify the project file parses and both build systems compile**

Run:
```bash
cd /Users/tr/Projects/Topkit
plutil -lint Topkit.xcodeproj/project.pbxproj && swift build 2>&1 | tail -3
```

Expected: `OK`, then `Build complete!`

- [ ] **Step 5: Run the tests**

Run:
```bash
cd /Users/tr/Projects/Topkit
swift test 2>&1 | grep "Executed 161 tests"
```

Expected: a line containing `Executed 161 tests, with 0 failures`. A pure move changes no behaviour, so the count and result must be identical to baseline.

- [ ] **Step 6: Verify the Xcode gate**

Run:
```bash
cd /Users/tr/Projects/Topkit
xcodebuild -project Topkit.xcodeproj -scheme Topkit -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build-for-testing 2>&1 | tail -5
```

Expected: `** TEST BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
cd /Users/tr/Projects/Topkit
git add Topkit/Models/Annotation.swift Topkit/Views/ScreenshotAnnotationView.swift Topkit.xcodeproj/project.pbxproj
git commit -m "refactor: lift the annotation model into Models/Annotation.swift

Pure move, no signature changes. Separates the model from the 3773-line
view ahead of the live Annotate overlay work."
```

---

## Task 3: Move the drawing primitives into AnnotationRenderer

Create the new file and move the leaf helpers first, so Task 4's renderer unification is a small diff rather than a large one. Everything moved here is currently `private static` or `static` on `ScreenshotAnnotationView` and holds no view state.

**Files:**
- Create: `Topkit/AnnotationRenderer.swift`
- Modify: `Topkit/Views/ScreenshotAnnotationView.swift` (delete moved members, add forwarders)
- Modify: `Topkit.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the renderer file with the moved primitives**

Create `Topkit/AnnotationRenderer.swift`. Move these members from `ScreenshotAnnotationView` **verbatim**, changing only `private static func` / `static func` to `static func` on the new enum, and dropping the `Self.` / `ScreenshotAnnotationView.` prefixes on internal calls between them:

- `textOutlineStrokeWidth(for:)` `:2904`
- `textOutlineExtent(for:)` `:2909`
- `textVerticalPad(for:)` `:2915`
- `textFillAttributes(font:color:)` `:2919`
- `textContentLineHeight(for:)` `:2924`
- `centeredTextRect(in:text:font:color:)` `:2929`
- `drawOutlinedAnnotationText(_:font:fillColor:in:)` `:2956`
- `drawStickerPointer(direction:stickerFrame:color:in:)` `:3275`
- `bakedMosaic(of:sourceRect:outSize:)` `:3319`
- `drawRedaction(_:mosaic:in:)` `:3373`
- `drawNumberBadge(_:in:)` `:3394`

```swift
import AppKit
import CoreGraphics
import Foundation

/// Stateless rendering of annotations into a CGContext.
///
/// Both the on-screen path (`ScreenshotAnnotationView.draw`) and the export path
/// (`ScreenshotAnnotationView.renderAnnotations`) go through here, so the two can
/// no longer drift apart. Call-site-specific behaviour is injected via `Context`.
enum AnnotationRenderer {

    // Moved verbatim from ScreenshotAnnotationView. Bodies unchanged.
    // (Copy each body exactly; do not retype from memory.)

    static func textOutlineStrokeWidth(for font: NSFont) -> CGFloat { /* body from :2904 */ }
    static func textOutlineExtent(for font: NSFont) -> CGFloat { /* body from :2909 */ }
    static func textVerticalPad(for font: NSFont) -> CGFloat { /* body from :2915 */ }
    static func textFillAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] { /* body from :2919 */ }
    static func textContentLineHeight(for font: NSFont) -> CGFloat { /* body from :2924 */ }
    static func centeredTextRect(in annotationFrame: NSRect, text: String, font: NSFont, color: NSColor) -> NSRect { /* body from :2929 */ }
    static func drawOutlinedAnnotationText(_ text: String, font: NSFont, fillColor: NSColor, in textRect: NSRect) { /* body from :2956 */ }
    static func drawStickerPointer(direction: StickerPointerDirection, stickerFrame: NSRect, color: NSColor, in context: CGContext) { /* body from :3275 */ }
    static func bakedMosaic(of source: NSImage, sourceRect: NSRect, outSize: NSSize) -> NSImage? { /* body from :3319 */ }
    static func drawRedaction(_ annotation: Annotation, mosaic: NSImage?, in context: CGContext) { /* body from :3373 */ }
    static func drawNumberBadge(_ annotation: Annotation, in context: CGContext) { /* body from :3394 */ }
}
```

The `/* body from :NNNN */` markers mean: open `ScreenshotAnnotationView.swift` at that line and copy the existing body across character for character. Do not reimplement.

- [ ] **Step 2: Delete the moved members from the view and add forwarders**

Delete all eleven members listed above from `ScreenshotAnnotationView`.

Three of them are referenced by tests or by other files, so add thin forwarders on `ScreenshotAnnotationView` to keep the existing call sites compiling:

```swift
    // MARK: - Renderer forwarders (kept so existing call sites and tests keep working)

    static func bakedMosaic(of source: NSImage, sourceRect: NSRect, outSize: NSSize) -> NSImage? {
        AnnotationRenderer.bakedMosaic(of: source, sourceRect: sourceRect, outSize: outSize)
    }

    static func drawRedaction(_ annotation: Annotation, mosaic: NSImage?, in context: CGContext) {
        AnnotationRenderer.drawRedaction(annotation, mosaic: mosaic, in: context)
    }

    static func drawNumberBadge(_ annotation: Annotation, in context: CGContext) {
        AnnotationRenderer.drawNumberBadge(annotation, in: context)
    }
```

- [ ] **Step 3: Fix the remaining internal call sites**

Within `ScreenshotAnnotationView`, several methods still call the moved helpers by their old names. Update each to use `AnnotationRenderer.`:

Run this to find them:
```bash
cd /Users/tr/Projects/Topkit
grep -n "Self\.centeredTextRect\|Self\.drawOutlinedAnnotationText\|Self\.drawStickerPointer\|Self\.textOutline\|Self\.textVerticalPad\|Self\.textFillAttributes\|Self\.textContentLineHeight" Topkit/Views/ScreenshotAnnotationView.swift
```

Replace each `Self.<name>` with `AnnotationRenderer.<name>`. The bodies of `textAnnotationFrame`, `textEditingHeight`, `inlineTextEditingHeight`, `configureInlineTextFieldAppearance`, and `applyInlineTextFieldOutlineTypingAttributes` are the likely callers; they stay in the view because they are about the live `NSTextField`, not about rendering a committed annotation.

- [ ] **Step 4: Register the new file in the Xcode project**

Same recipe as Task 2 Step 3, with `path = AnnotationRenderer.swift`, added to the app's top-level source group and the `Topkit` target's sources phase.

- [ ] **Step 5: Verify both build systems**

Run:
```bash
cd /Users/tr/Projects/Topkit
plutil -lint Topkit.xcodeproj/project.pbxproj && swift build 2>&1 | tail -3
```

Expected: `OK`, then `Build complete!`

- [ ] **Step 6: Run the tests**

Run:
```bash
cd /Users/tr/Projects/Topkit
swift test 2>&1 | grep "Executed 161 tests"
```

Expected: `Executed 161 tests, with 0 failures`. Still a pure move.

- [ ] **Step 7: Commit**

```bash
cd /Users/tr/Projects/Topkit
git add Topkit/AnnotationRenderer.swift Topkit/Views/ScreenshotAnnotationView.swift Topkit.xcodeproj/project.pbxproj
git commit -m "refactor: move annotation drawing primitives into AnnotationRenderer

Pure move of eleven stateless helpers. ScreenshotAnnotationView keeps
forwarders for the three static members tests and other files call."
```

---

## Task 4: Collapse the two renderers into one

The payload. `drawAnnotation` `:3108` (instance, on-screen) and `drawOneAnnotation` `:3606` (static, export) are near-identical `switch annotation.type` blocks. They differ in exactly two cases:

| Case | On-screen | Export |
|---|---|---|
| `.text` | frame = `effectiveFrame(for:)`; skips `centeredTextRect` while inline-editing | frame = `annotation.frame`; always centres |
| `.blur` | mosaic from `mosaicRegionImage(forFrame:)` | mosaic from `bakedMosaic(of: sourceImage, …)` |

A `Context` struct of closures supplies both.

**Files:**
- Modify: `Topkit/AnnotationRenderer.swift`
- Modify: `Topkit/Views/ScreenshotAnnotationView.swift:3108-3236` (delete), `:3606-3697` (delete)

- [ ] **Step 1: Add the Context struct to AnnotationRenderer**

```swift
extension AnnotationRenderer {
    /// The two behaviours that differ between the on-screen and export render paths.
    struct Context {
        /// Frame to render a text annotation into. On screen this recomputes from the
        /// current text and font so a stale stored height cannot leave a gap.
        var textFrame: (Annotation) -> NSRect = { $0.frame }

        /// True while this text annotation is being edited inline, in which case the
        /// raw frame is used as-is rather than being re-centred under the caret.
        var isInlineEditing: (Annotation) -> Bool = { _ in false }

        /// Pixels to pixelate for a redaction, or nil to fall back to a solid fill.
        var mosaic: (Annotation) -> NSImage? = { _ in nil }

        static let export = Context()
    }
}
```

- [ ] **Step 2: Add the unified draw function**

Take the body of the on-screen `drawAnnotation` `:3108-3236` verbatim, and make exactly three substitutions: `effectiveFrame(for: annotation)` → `ctx.textFrame(annotation)`, `annotation.id == inlineTextAnnotationId` → `ctx.isInlineEditing(annotation)`, and the `.blur` mosaic lookup → `ctx.mosaic(annotation)`. Drop the `Self.` prefixes.

```swift
extension AnnotationRenderer {
    static func draw(_ annotation: Annotation, in context: CGContext, using ctx: Context) {
        context.saveGState()
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.thickness)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.type {
        case .freehand:
            // body from :3117-3124, unchanged
        case .rectangle:
            context.stroke(annotation.frame)
        case .circle:
            // Must match the export path: strokeEllipse over the full frame. An arc with
            // min-dimension radius shrinks non-square ovals (see AnnotationExportRenderTests).
            context.strokeEllipse(in: annotation.frame)
        case .arrow:
            // body from :3130-3162, unchanged
        case .text:
            if let text = annotation.text, !text.isEmpty, let fontSize = annotation.fontSize {
                let fontName = UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica"
                let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
                let renderFrame = ctx.textFrame(annotation)
                let textRect: NSRect
                if ctx.isInlineEditing(annotation) {
                    textRect = renderFrame
                } else {
                    textRect = centeredTextRect(in: renderFrame, text: text, font: font, color: annotation.color)
                }
                // Draw text right-side up: context is Y-flipped, so unflip for text only
                context.saveGState()
                context.translateBy(x: textRect.midX, y: textRect.midY)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: -textRect.midX, y: -textRect.midY)
                drawOutlinedAnnotationText(text, font: font, fillColor: annotation.color, in: textRect)
                context.restoreGState()
            }
        case .sticker(let stickerType):
            // body from :3183-3227, with Self.drawStickerPointer -> drawStickerPointer
        case .blur:
            drawRedaction(annotation, mosaic: ctx.mosaic(annotation), in: context)
        case .numberBadge:
            drawNumberBadge(annotation, in: context)
        }

        context.restoreGState()
    }
}
```

- [ ] **Step 3: Point the on-screen path at the unified renderer**

Delete `drawAnnotation(_:in:)` `:3108-3236` from `ScreenshotAnnotationView`. Find its caller in `drawAnnotationLayers` `:3040` and replace the call with:

```swift
                AnnotationRenderer.draw(annotation, in: context, using: AnnotationRenderer.Context(
                    textFrame: { [weak self] in self?.effectiveFrame(for: $0) ?? $0.frame },
                    isInlineEditing: { [weak self] in $0.id == self?.inlineTextAnnotationId },
                    mosaic: { [weak self] in self?.mosaicRegionImage(forFrame: $0.frame) }
                ))
```

- [ ] **Step 4: Point the export path at the unified renderer**

Delete `drawOneAnnotation(_:in:sourceImage:)` `:3606-3697`. Find its callers — `renderAnnotations` `:3535`, `renderAnnotationsLegacy` `:3588`, and `renderAnnotatedImage` `:3449` — and replace each call with:

```swift
            AnnotationRenderer.draw(annotation, in: context, using: AnnotationRenderer.Context(
                mosaic: { ann in
                    sourceImage.flatMap {
                        AnnotationRenderer.bakedMosaic(of: $0, sourceRect: ann.frame, outSize: ann.frame.size)
                    }
                }
            ))
```

where `sourceImage` is whatever the enclosing function already passed as `drawOneAnnotation`'s `sourceImage:` argument. Where it passed nothing, use `AnnotationRenderer.Context.export`.

Note this leaves `textFrame` at its default of `{ $0.frame }`, preserving today's export behaviour. Task 5 changes it deliberately.

- [ ] **Step 5: Build**

Run:
```bash
cd /Users/tr/Projects/Topkit
swift build 2>&1 | tail -3
```

Expected: `Build complete!`

- [ ] **Step 6: Run the tests**

Run:
```bash
cd /Users/tr/Projects/Topkit
swift test 2>&1 | grep "Executed 161 tests"
```

Expected: `Executed 161 tests, with 0 failures`. Behaviour is still identical — the circle regression test in `AnnotationExportRenderTests` is the one that would catch a mistake here, and it now actually runs in Xcode CI too thanks to Task 1.

- [ ] **Step 7: Commit**

```bash
cd /Users/tr/Projects/Topkit
git add Topkit/AnnotationRenderer.swift Topkit/Views/ScreenshotAnnotationView.swift
git commit -m "refactor: collapse the two annotation renderers into AnnotationRenderer.draw

drawAnnotation (on-screen) and drawOneAnnotation (export) were near-identical
switch blocks that had already drifted. They now share one implementation,
with the two call-site-specific behaviours injected via Context."
```

---

## Task 5: Fix the text export drift

With one renderer, the drift becomes a one-line change: give the export path the same `textFrame` resolver the screen uses.

**Files:**
- Create: `Tests/TopkitTests/AnnotationRendererTests.swift`
- Modify: `Topkit/AnnotationRenderer.swift`
- Modify: `Topkit.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing test**

Create `Tests/TopkitTests/AnnotationRendererTests.swift`:

```swift
import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// The on-screen renderer derives a text annotation's frame from its current text and
/// font size (`effectiveFrame`), while the export renderer used the raw stored frame.
/// A stale stored height therefore put the text in one place on screen and another in
/// the saved file. Both paths must now agree.
final class AnnotationRendererTests: XCTestCase {

    private func textAnnotation(storedFrame: NSRect) -> Annotation {
        Annotation(
            id: UUID(),
            type: .text,
            frame: storedFrame,
            color: .red,
            thickness: 2,
            text: "Hello",
            fontSize: 24,
            startPoint: nil,
            endPoint: nil,
            pathPoints: nil,
            stickerPointerDirection: nil
        )
    }

    /// A stored frame far taller than the rendered text is exactly the stale-height case.
    func testExportUsesTheRenderedTextFrameNotTheStoredOne() {
        let stale = NSRect(x: 20, y: 20, width: 400, height: 300)
        let annotation = textAnnotation(storedFrame: stale)

        let resolved = AnnotationRenderer.Context.export.textFrame(annotation)

        XCTAssertEqual(resolved.origin, stale.origin,
                       "The origin is authoritative and must be preserved")
        XCTAssertLessThan(resolved.height, stale.height,
                          "Height must be recomputed from the rendered text, not taken from the stale stored frame")
    }

    /// Guards against the default silently reverting to { $0.frame }.
    func testExportContextResolvesNonTextAnnotationsToTheirStoredFrame() {
        let frame = NSRect(x: 5, y: 5, width: 50, height: 50)
        let rect = Annotation(
            id: UUID(),
            type: .rectangle,
            frame: frame,
            color: .blue,
            thickness: 3,
            text: nil,
            fontSize: nil,
            startPoint: nil,
            endPoint: nil,
            pathPoints: nil,
            stickerPointerDirection: nil
        )

        XCTAssertEqual(AnnotationRenderer.Context.export.textFrame(rect), frame)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd /Users/tr/Projects/Topkit
swift test --filter AnnotationRendererTests 2>&1 | tail -20
```

Expected: `testExportUsesTheRenderedTextFrameNotTheStoredOne` FAILS with "Height must be recomputed…", because `Context.export.textFrame` is still the `{ $0.frame }` default. `testExportContextResolvesNonTextAnnotationsToTheirStoredFrame` should PASS already.

- [ ] **Step 3: Move the text frame computation into the renderer**

`effectiveFrame(for:)` `:1521` delegates to `textAnnotationFrame(text:fontSize:topLeft:)` `:2798`, which is an instance method but uses no instance state. Move `textAnnotationFrame` to `AnnotationRenderer` as a static, copying the body verbatim, and add the shared resolver:

```swift
extension AnnotationRenderer {
    /// Bounding frame for a text annotation, derived from the rendered content.
    /// Only the origin of the stored frame is authoritative; the size is recomputed so a
    /// stale stored height cannot leave a gap on screen or displace the text on export.
    static func textFrame(for annotation: Annotation) -> NSRect {
        guard case .text = annotation.type,
              let text = annotation.text,
              !text.isEmpty,
              let fontSize = annotation.fontSize else {
            return annotation.frame
        }
        return textAnnotationFrame(text: text, fontSize: fontSize, topLeft: annotation.frame.origin)
    }

    static func textAnnotationFrame(text: String, fontSize: CGFloat, topLeft: NSPoint) -> NSRect {
        // body moved verbatim from ScreenshotAnnotationView.textAnnotationFrame :2798,
        // with the `Self.` prefixes dropped (those helpers already live here).
    }
}
```

`textAnnotationFrame`'s body also reads two file-private constants declared at
`ScreenshotAnnotationView.swift:139-140`. Move both to `AnnotationRenderer.swift`,
since after this task the view no longer uses them:

```swift
/// Minimal padding around text annotations so the bounding box fits text tightly.
private let textAnnotationPadding: CGFloat = 2
private let textAnnotationMinWidth: CGFloat = 40
```

Leave `textOutlineMinWidth` `:142` and `kScreenshotDimOverlayAlpha` `:158` where they
are — the first is used by the view's inline text field, the second by
`ScreenshotManager`, `ScreenRecordingManager`, and `SelectionConfirmView`.

Verify the view has no remaining references before deleting them:
```bash
cd /Users/tr/Projects/Topkit
grep -n "textAnnotationPadding\|textAnnotationMinWidth" Topkit/Views/ScreenshotAnnotationView.swift
```
Expected after the move: no output.

Then change the `Context` default and the `export` preset to use it:

```swift
        var textFrame: (Annotation) -> NSRect = { AnnotationRenderer.textFrame(for: $0) }
```

- [ ] **Step 4: Point the view's effectiveFrame at the shared resolver**

Replace the body of `effectiveFrame(for:)` `:1521-1531` in `ScreenshotAnnotationView` so there is one implementation:

```swift
    private func effectiveFrame(for annotation: Annotation) -> NSRect {
        AnnotationRenderer.textFrame(for: annotation)
    }
```

Delete the now-duplicated `textAnnotationFrame` instance method from the view, and update its other callers to `AnnotationRenderer.textAnnotationFrame`. There are five, at `:1037`, `:1528`, `:1941`, `:2825`, and `:3762` in the original numbering. Find them with:
```bash
cd /Users/tr/Projects/Topkit
grep -n "textAnnotationFrame" Topkit/Views/ScreenshotAnnotationView.swift
```
Expected after the update: five `AnnotationRenderer.textAnnotationFrame(` call sites and no declaration.

- [ ] **Step 5: Register the new test file in the Xcode project**

Same four-point recipe as Task 1, with `path = AnnotationRendererTests.swift`, in the `TopkitTests` group and the `TopkitTests` target's sources phase.

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
cd /Users/tr/Projects/Topkit
swift test --filter AnnotationRendererTests 2>&1 | tail -20
```

Expected: both tests PASS.

- [ ] **Step 7: Run the full suite**

Run:
```bash
cd /Users/tr/Projects/Topkit
swift test 2>&1 | tail -5
```

Expected: `Executed 163 tests, with 0 failures`. Two more than baseline, from the new file.

If an existing text-related test now fails, that is the deliberate behaviour change surfacing. Read the failing assertion: if it was asserting the stale-frame export behaviour, update it and note the change in the commit message. If it is asserting something else, stop and report.

- [ ] **Step 8: Verify the Xcode gate**

Run:
```bash
cd /Users/tr/Projects/Topkit
plutil -lint Topkit.xcodeproj/project.pbxproj && xcodebuild -project Topkit.xcodeproj -scheme Topkit -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build-for-testing 2>&1 | tail -5
```

Expected: `OK`, then `** TEST BUILD SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
cd /Users/tr/Projects/Topkit
git add Topkit/AnnotationRenderer.swift Topkit/Views/ScreenshotAnnotationView.swift Tests/TopkitTests/AnnotationRendererTests.swift Topkit.xcodeproj/project.pbxproj
git commit -m "fix: exported text annotations use the rendered frame, matching the screen

The on-screen renderer derived a text annotation's frame from its current
text and font size; the export renderer used the raw stored frame. A stale
stored height put the text in one place on screen and another in the saved
file. Both now share AnnotationRenderer.textFrame(for:)."
```

---

## Task 6: Delete the two dead coordinate converters

`convertPointFromAnnotationSpace` `:1412` and `convertRectToAnnotationSpace` `:1425` have zero callers anywhere in the repo. `convertPointFromAnnotationSpace` is also actively misleading: despite the name it returns a `screenshotRect`-local, Y-down point rather than a view point, and when `screenshotRect == bounds` it is the identity function. The phase 2 spec originally reached for it to position the contextual toolbar, which would have rendered the bar mirrored about screen centre. Delete both now so it cannot be picked again.

**Files:**
- Modify: `Topkit/Views/ScreenshotAnnotationView.swift:1411-1435`

- [ ] **Step 1: Confirm both are genuinely unreferenced**

Run:
```bash
cd /Users/tr/Projects/Topkit
grep -rn "convertPointFromAnnotationSpace\|convertRectToAnnotationSpace" Topkit/ Tests/
```

Expected: exactly two lines, both the declarations themselves at `Topkit/Views/ScreenshotAnnotationView.swift:1412` and `:1425`. If anything else appears, stop — the premise is wrong.

- [ ] **Step 2: Delete both functions**

Delete lines 1411 through 1435 inclusive: the doc comment and body of `convertPointFromAnnotationSpace`, and the doc comment and body of `convertRectToAnnotationSpace`.

Keep `convertPointToAnnotationSpace` `:1399` — it has real callers.

- [ ] **Step 3: Build**

Run:
```bash
cd /Users/tr/Projects/Topkit
swift build 2>&1 | tail -3
```

Expected: `Build complete!` If the compiler reports an unresolved reference, Step 1's grep missed a call site — restore and investigate.

- [ ] **Step 4: Run the full suite**

Run:
```bash
cd /Users/tr/Projects/Topkit
swift test 2>&1 | grep "Executed 163 tests"
```

Expected: `Executed 163 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
cd /Users/tr/Projects/Topkit
git add Topkit/Views/ScreenshotAnnotationView.swift
git commit -m "refactor: delete two dead coordinate converters

convertPointFromAnnotationSpace and convertRectToAnnotationSpace had no
callers. The former is a trap: despite the name it returns a screenshotRect-
local Y-down point, not a view point, and degenerates to the identity when
screenshotRect == bounds."
```

---

## Task 7: Final verification

- [ ] **Step 1: Run the full gate script**

Run:
```bash
cd /Users/tr/Projects/Topkit
export LANG=UTF-8
scripts/run-test-gates.sh 2>&1 | tail -20
```

Expected: the script completes without error. It runs metadata validation, `swift test`, and `build-for-testing` — the same three gates as the pre-push hook.

- [ ] **Step 2: Confirm the phase-1 file structure landed**

Run:
```bash
cd /Users/tr/Projects/Topkit
wc -l Topkit/Views/ScreenshotAnnotationView.swift Topkit/Models/Annotation.swift Topkit/AnnotationRenderer.swift
```

Expected: `ScreenshotAnnotationView.swift` is meaningfully shorter than its starting 3773 lines; the two new files exist and are non-empty.

- [ ] **Step 3: Confirm every file is registered in both build systems**

Run:
```bash
cd /Users/tr/Projects/Topkit
for f in Annotation.swift AnnotationRenderer.swift AnnotationRendererTests.swift \
         AnnotationExportRenderTests.swift AnnotationToolsFeatureTests.swift \
         CaptionModelTests.swift RecordingConfirmToolbarTests.swift; do
  echo "$f: $(grep -c "$f" Topkit.xcodeproj/project.pbxproj) refs"
done
```

Expected: each reports `4 refs`.

- [ ] **Step 4: Review the diff**

Run:
```bash
cd /Users/tr/Projects/Topkit
git log --oneline main..HEAD
git diff --stat $(git merge-base HEAD main)..HEAD
```

Confirm six commits, and that the only behaviour change in the diff is the text export frame.

---

## Self-review notes

**Spec coverage.** Phase 1 of the spec lists four items: lift the model (Task 2), unify the renderers (Tasks 3–4), delete the dead converters (Task 6), register the orphaned test files (Task 1). Task 5 implements the drift fix the spec gives as the *reason* for unifying, and Task 7 is verification. All covered.

**Deferred to phase 2 deliberately:** `CanvasMode`, the 15-site gate classification, `setFrameSize`, `viewPointFromAnnotationSpace` (Task 6 only deletes the wrong converter; the correct one arrives with its first real caller), `bakedMosaic` on `Annotation`, key-monitor ownership. None are needed for phase 1 and all carry behaviour risk.

**Known ordering constraint:** Task 1 must run first. Tasks 2–6 are strictly sequential — each builds on the previous file layout.

**Line numbers drift.** Every `:NNNN` reference is against the state of the file at the start of this plan. After Task 2 deletes 75 lines, later references shift by roughly that amount. Locate code by symbol name, using the line number only as a hint.
