import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Rainbow now applies to every colourable tool, opacity applies to all of them, and
/// both must survive the value-type copies used by undo and paste.
final class AnnotationColorModeRenderTests: XCTestCase {

    private func makeWhiteImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// (r, g, b) at a pixel, or nil if unreadable.
    private func channels(in image: NSImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
        let offset = y * cg.bytesPerRow + x * (cg.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func rectangle(_ frame: NSRect, color: NSColor, rainbow: Bool = false, opacity: CGFloat = 1.0) -> Annotation {
        var a = Annotation(id: UUID(), type: .rectangle, frame: frame, color: color, thickness: 8,
                           text: nil, fontSize: nil, startPoint: nil, endPoint: nil,
                           pathPoints: nil, stickerPointerDirection: nil)
        a.colorMode = rainbow ? .rainbow : .solid
        a.opacity = opacity
        return a
    }

    /// A solid red rectangle is red everywhere on its stroke; a rainbow one must paint
    /// hues other than the base colour, so somewhere a non-red channel dominates.
    func testRainbowRectangleIsNotUniformlyItsBaseColour() {
        let image = makeWhiteImage(width: 200, height: 200)
        let mark = rectangle(NSRect(x: 20, y: 20, width: 160, height: 160), color: .red, rainbow: true)
        let out = ScreenshotAnnotationView.renderAnnotations(on: image, annotations: [mark])

        // Walk the four edge midpoints and corners; a rainbow must show at least one
        // pixel where green or blue clearly beats red.
        let samples = [(100, 20), (180, 100), (100, 180), (20, 100), (20, 20), (180, 180)]
        let foundNonRed = samples.contains { pt in
            guard let c = channels(in: out, x: pt.0, y: pt.1) else { return false }
            // Ignore near-white (unpainted) pixels.
            let painted = !(c.r > 200 && c.g > 200 && c.b > 200)
            return painted && (c.g > c.r + 30 || c.b > c.r + 30)
        }
        XCTAssertTrue(foundNonRed, "a rainbow rectangle must not render as solid red")
    }

    /// Opacity must blend the mark with what is behind it. A 30%-opaque red stroke over
    /// white lifts the green/blue channels well above an opaque red stroke's near-zero.
    func testOpacityBlendsTheStrokeWithTheBackground() {
        let frame = NSRect(x: 20, y: 20, width: 160, height: 60)
        let opaque = ScreenshotAnnotationView.renderAnnotations(
            on: makeWhiteImage(width: 200, height: 100),
            annotations: [rectangle(frame, color: .red, opacity: 1.0)])
        let faint = ScreenshotAnnotationView.renderAnnotations(
            on: makeWhiteImage(width: 200, height: 100),
            annotations: [rectangle(frame, color: .red, opacity: 0.3)])

        // Top edge midpoint sits on the stroke in both images.
        guard let o = channels(in: opaque, x: 100, y: 20),
              let f = channels(in: faint, x: 100, y: 20) else {
            return XCTFail("could not read stroke pixels")
        }
        XCTAssertLessThan(o.g, 90, "opaque red stroke should have little green")
        XCTAssertGreaterThan(f.g, 120, "a faint stroke should let the white background through")
    }

    /// Measure renders a coloured line; its midpoint (which the diagonals share
    /// regardless of any Y-flip) must be painted, not left white.
    func testMeasureRendersItsLine() {
        let image = makeWhiteImage(width: 200, height: 200)
        var m = Annotation(id: UUID(), type: .measure,
                           frame: NSRect(x: 20, y: 20, width: 160, height: 160),
                           color: .red, thickness: 6, text: nil, fontSize: nil,
                           startPoint: NSPoint(x: 20, y: 20), endPoint: NSPoint(x: 180, y: 180),
                           pathPoints: nil, stickerPointerDirection: nil)
        m.colorMode = .solid
        let out = ScreenshotAnnotationView.renderAnnotations(on: image, annotations: [m])
        guard let c = channels(in: out, x: 100, y: 100) else { return XCTFail("unreadable") }
        XCTAssertTrue(c.r > 150 && c.g < 120, "measure line should paint its colour along the diagonal")
    }

    /// Opacity is a new stored field, so the value-type copies behind paste/undo must
    /// carry it (the same class of bug the redaction pixels once hit).
    func testOpacitySurvivesCopyAndPaste() {
        let view = ScreenshotAnnotationView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                            mode: .liveAnnotate)
        let mark = rectangle(NSRect(x: 40, y: 40, width: 80, height: 60), color: .red, opacity: 0.4)
        view._setAnnotationsForTesting([mark])
        view._selectForTesting(mark.id)
        view._copySelectedForTesting()
        XCTAssertTrue(view._pasteForTesting())

        let all = view._annotationsForTesting()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.last?.opacity ?? -1, 0.4, accuracy: 0.0001,
                       "a pasted mark must keep its opacity")
    }
}
