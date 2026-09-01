import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Regression: the export path (`renderAnnotations` → `drawOneAnnotation`) used to
/// draw circles as an arc with radius `min(width, height) / 2`, so any non-square
/// oval collapsed to the smaller dimension in the saved image while looking correct
/// on screen (which uses `strokeEllipse(in:)`). Lock down that the exported ellipse
/// actually reaches the edges of its annotation frame.
final class AnnotationExportRenderTests: XCTestCase {
    private func makeWhiteImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
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

    /// True if any pixel in a small box around (x, y) is strongly red.
    private func hasRedPixel(in image: NSImage, around x: Int, _ y: Int, boxRadius: Int = 4) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            XCTFail("Could not read rendered image pixels")
            return false
        }
        let bytesPerPixel = cg.bitsPerPixel / 8
        let bytesPerRow = cg.bytesPerRow
        for py in max(0, y - boxRadius)...min(cg.height - 1, y + boxRadius) {
            for px in max(0, x - boxRadius)...min(cg.width - 1, x + boxRadius) {
                let offset = py * bytesPerRow + px * bytesPerPixel
                let r = bytes[offset]
                let g = bytes[offset + 1]
                let b = bytes[offset + 2]
                if r > 180 && g < 100 && b < 100 {
                    return true
                }
            }
        }
        return false
    }

    func testExportedCircleFillsItsFrameInsteadOfShrinkingToMinDimension() {
        let image = makeWhiteImage(width: 200, height: 100)
        let frame = NSRect(x: 10, y: 10, width: 180, height: 80)
        let circle = Annotation(
            id: UUID(),
            type: .circle,
            frame: frame,
            color: .red,
            thickness: 6,
            text: nil,
            fontSize: nil,
            startPoint: nil,
            endPoint: nil,
            pathPoints: nil,
            stickerPointerDirection: nil
        )

        let rendered = ScreenshotAnnotationView.renderAnnotations(on: image, annotations: [circle])

        // Leftmost point of the ellipse: (frame.minX, frame.midY). With the old
        // min-dimension arc bug the stroke would only start at x = 60.
        XCTAssertTrue(
            hasRedPixel(in: rendered, around: 10, 50),
            "Exported circle stroke must reach the left edge of its frame (ellipse, not min-radius arc)"
        )
        // Rightmost point of the ellipse.
        XCTAssertTrue(
            hasRedPixel(in: rendered, around: 190, 50),
            "Exported circle stroke must reach the right edge of its frame"
        )
        // Sanity: centre stays unpainted (stroke only, no fill).
        XCTAssertFalse(
            hasRedPixel(in: rendered, around: 100, 50, boxRadius: 2),
            "Circle centre should not be painted"
        )
    }

    /// Regression: capturing a fullscreen window aspect-fits the image *smaller* on
    /// screen, so annotations (stored in displayed-rect coordinates) must be scaled
    /// by image-size / displayed-size on export. The retina export path only applied
    /// the pixel/point factor, so everything drifted towards the top-left — a square
    /// drawn on the right-hand side "moved left" in the saved image.
    func testExportScalesAnnotationsFromDisplayedRectToImagePixels() {
        let image = makeWhiteImage(width: 400, height: 200)
        let view = ScreenshotAnnotationView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            screenshot: image,
            // Displayed at half the image size (as with a downscaled fullscreen grab).
            screenshotRect: NSRect(x: 50, y: 50, width: 200, height: 100)
        )
        // Square on the right-hand side of the *displayed* screenshot
        // (annotation space: top-left origin, Y down, displayed-rect units).
        let square = Annotation(
            id: UUID(),
            type: .rectangle,
            frame: NSRect(x: 150, y: 25, width: 40, height: 50),
            color: .red,
            thickness: 4,
            text: nil,
            fontSize: nil,
            startPoint: nil,
            endPoint: nil,
            pathPoints: nil,
            stickerPointerDirection: nil
        )
        view._setAnnotationsForTesting([square])

        let rendered = view.renderAnnotatedImage()

        // Exported at 2x: square must span x 300–380, y 50–150 in image pixels.
        XCTAssertTrue(
            hasRedPixel(in: rendered, around: 380, 100),
            "Right edge of the square must land at scaled-up coordinates, not drift left"
        )
        XCTAssertTrue(
            hasRedPixel(in: rendered, around: 300, 100),
            "Left edge of the square must land at scaled-up coordinates"
        )
        XCTAssertFalse(
            hasRedPixel(in: rendered, around: 190, 50),
            "Square must not render at unscaled displayed-rect coordinates (the moved-left bug)"
        )
    }
}
