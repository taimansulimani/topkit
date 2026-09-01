import AppKit
import Foundation

/// Guides and grids are alignment aids laid over real content rather than marks in
/// their own right, so they default translucent instead of inheriting the session
/// opacity the drawing tools carry between marks.
let alignmentAidDefaultOpacity: CGFloat = 0.7

/// Minimal padding around text annotations so the bounding box fits text tightly.
let textAnnotationPadding: CGFloat = 2
let textAnnotationMinWidth: CGFloat = 40
/// White outline around annotation text.
let textOutlineMinWidth: CGFloat = 3.0

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
    /// Two-point measurement line with a pixel-distance label. Shares arrow's drag,
    /// endpoint handles and hit-test; differs only in how it renders.
    case measure
    /// Full-canvas alignment guide line. The orientation is the tool's identity, so
    /// flipping a placed guide swaps the case rather than mutating a separate field.
    case guide(GuideOrientation)
    /// Translucent region with a 10px pixel grid, for layout alignment (the old
    /// "rectangle guide").
    case grid
}

/// Orientation of a guide line annotation.
enum GuideOrientation: Equatable {
    case horizontal
    case vertical

    var opposite: GuideOrientation { self == .horizontal ? .vertical : .horizontal }
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

/// How a mark is coloured. `rainbow` is the Draw tool's gradient brush, carried over
/// to the live Annotate overlay. Captured at creation rather than resolved at render
/// time, so changing the preference no longer retroactively recolours existing marks.
enum AnnotationColorMode: Equatable {
    case solid
    case rainbow
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
    /// Solid unless this mark uses the rainbow gradient brush.
    var colorMode: AnnotationColorMode = .solid
    /// 0...1 opacity multiplier applied to the whole mark at render time. 1 = opaque.
    /// Redaction ignores it (a translucent mosaic would leak the pixels it hides).
    var opacity: CGFloat = 1.0
    /// Redaction only: the pixelated pixels, baked when the mark was placed.
    ///
    /// On a live screen there is nothing to re-sample at draw time — the overlay is
    /// in the way and the content underneath moves. Baking once at placement keeps
    /// the redaction stable and avoids a capture on every frame.
    var bakedMosaic: NSImage? = nil
}
