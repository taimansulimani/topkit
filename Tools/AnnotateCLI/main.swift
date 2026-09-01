import AppKit
import Foundation
@testable import TopkitCore

// Dev tool: composites annotations onto a PNG using Topkit's real AnnotationRenderer,
// so generated marketing/demo images match the app's actual annotate output exactly
// instead of an approximation. Not part of the app target.
//
// Usage: AnnotateCLI <spec.json>
//
// spec.json:
// {
//   "input": "/path/to/source.png",
//   "output": "/path/to/annotated.png",
//   "annotations": [
//     { "tool": "arrow", "from": [x, y], "to": [x, y], "color": "#FF0000", "thickness": 4 },
//     { "tool": "rectangle", "frame": [x, y, w, h], "color": "#FF0000", "thickness": 3 },
//     { "tool": "circle", "frame": [x, y, w, h], "color": "#FF0000", "thickness": 3 },
//     { "tool": "sticker", "frame": [x, y, w, h], "pointer": "downLeft" },
//     { "tool": "text", "text": "...", "origin": [x, y], "fontSize": 24, "color": "#FF0000" },
//     { "tool": "guide", "orientation": "horizontal", "position": 400, "thickness": 3, "opacity": 0.7 }
//   ]
// }
//
// Coordinates are top-left origin, Y down, in the source image's own point space —
// same convention Topkit's own annotation frames use.

struct AnnotationSpec: Decodable {
    let tool: String
    let from: [CGFloat]?
    let to: [CGFloat]?
    let frame: [CGFloat]?
    let origin: [CGFloat]?
    let text: String?
    let fontSize: CGFloat?
    let color: String?
    let thickness: CGFloat?
    let opacity: CGFloat?
    let pointer: String?
    let orientation: String?
    let position: CGFloat?
}

struct RenderSpec: Decodable {
    let input: String
    let output: String
    let annotations: [AnnotationSpec]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func nsColor(fromHex hex: String) -> NSColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    var value: UInt64 = 0
    Scanner(string: s).scanHexInt64(&value)
    return NSColor(
        red: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

func pointerDirection(from name: String?) -> StickerPointerDirection? {
    switch name {
    case "up": return .up
    case "upRight": return .upRight
    case "right": return .right
    case "downRight": return .downRight
    case "down": return .down
    case "downLeft": return .downLeft
    case "left": return .left
    case "upLeft": return .upLeft
    default: return nil
    }
}

guard CommandLine.arguments.count > 1 else {
    fail("usage: AnnotateCLI <spec.json>")
}

let specURL = URL(fileURLWithPath: CommandLine.arguments[1])
let spec: RenderSpec
do {
    spec = try JSONDecoder().decode(RenderSpec.self, from: try Data(contentsOf: specURL))
} catch {
    fail("could not read spec: \(error)")
}

guard let sourceImage = NSImage(contentsOfFile: spec.input) else {
    fail("could not load input image: \(spec.input)")
}
// Annotation coordinates in the spec are pixel coordinates of the source PNG. NSImage.size
// reports *points*, which halves for an @2x-tagged (144 DPI) screenshot — normalize so
// 1 unit here always means 1 pixel, regardless of the source's embedded DPI metadata.
if let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    sourceImage.size = NSSize(width: cgImage.width, height: cgImage.height)
}

let defaultColor = NSColor.red
var annotations: [Annotation] = []

for a in spec.annotations {
    let color = a.color.map(nsColor(fromHex:)) ?? defaultColor
    let thickness = a.thickness ?? 3.0

    switch a.tool {
    case "arrow":
        guard let from = a.from, from.count == 2, let to = a.to, to.count == 2 else {
            fail("arrow needs from/to")
        }
        let start = NSPoint(x: from[0], y: from[1])
        let end = NSPoint(x: to[0], y: to[1])
        annotations.append(Annotation(
            id: UUID(), type: .arrow,
            frame: NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)),
            color: color, thickness: thickness, text: nil, fontSize: nil,
            startPoint: start, endPoint: end, pathPoints: nil, stickerPointerDirection: nil
        ))

    case "rectangle", "circle":
        guard let f = a.frame, f.count == 4 else { fail("\(a.tool) needs frame") }
        annotations.append(Annotation(
            id: UUID(), type: a.tool == "rectangle" ? .rectangle : .circle,
            frame: NSRect(x: f[0], y: f[1], width: f[2], height: f[3]),
            color: color, thickness: thickness, text: nil, fontSize: nil,
            startPoint: nil, endPoint: nil, pathPoints: nil, stickerPointerDirection: nil
        ))

    case "sticker":
        guard let f = a.frame, f.count == 4 else { fail("sticker needs frame") }
        annotations.append(Annotation(
            id: UUID(), type: .sticker(.redX),
            frame: NSRect(x: f[0], y: f[1], width: f[2], height: f[3]),
            color: color, thickness: thickness, text: nil, fontSize: nil,
            startPoint: nil, endPoint: nil, pathPoints: nil,
            stickerPointerDirection: pointerDirection(from: a.pointer)
        ))

    case "text":
        guard let origin = a.origin, origin.count == 2, let text = a.text else {
            fail("text needs origin/text")
        }
        annotations.append(Annotation(
            id: UUID(), type: .text,
            frame: NSRect(x: origin[0], y: origin[1], width: 0, height: 0),
            color: color, thickness: thickness, text: text, fontSize: a.fontSize ?? 16,
            startPoint: nil, endPoint: nil, pathPoints: nil, stickerPointerDirection: nil
        ))

    case "guide":
        guard let position = a.position else { fail("guide needs position") }
        let orientation: GuideOrientation = (a.orientation == "vertical") ? .vertical : .horizontal
        let frame = orientation == .horizontal
            ? NSRect(x: 0, y: position - thickness / 2, width: 1, height: thickness)
            : NSRect(x: position - thickness / 2, y: 0, width: thickness, height: 1)
        var annotation = Annotation(
            id: UUID(), type: .guide(orientation),
            frame: frame, color: color, thickness: thickness, text: nil, fontSize: nil,
            startPoint: nil, endPoint: nil, pathPoints: nil, stickerPointerDirection: nil
        )
        annotation.opacity = a.opacity ?? alignmentAidDefaultOpacity
        annotations.append(annotation)

    default:
        fail("unknown tool: \(a.tool)")
    }
}

let result = ScreenshotAnnotationView.renderAnnotations(on: sourceImage, annotations: annotations)

guard let tiff = result.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fail("failed to encode output PNG")
}

do {
    try png.write(to: URL(fileURLWithPath: spec.output))
    print("wrote \(spec.output)")
} catch {
    fail("failed to write output: \(error)")
}
