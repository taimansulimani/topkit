import AppKit

/// Window level for every full-screen overlay that draws annotation chrome: the
/// screenshot flow's frozen region picker and annotate step, and the standalone
/// Annotate overlay. Sits above Guides (`.screenSaver`) and level with Halo.
let kScreenshotOverlayBaseLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

/// Frozen-hole region+annotate step. Must be able to become key so `NSCursor` and `mouseMoved` work reliably (macOS ignores them for background apps).
/// `allowsKeyboardFocus` is toggled when inline text editing needs the field as first responder; it no longer gates `canBecomeKey`.
final class LiveAnnotationOverlayWindow: NSWindow {
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
