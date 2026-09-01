import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ImageHelpersTests: XCTestCase {
    private func makeSolidImage(size: NSSize, color: NSColor = .red) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    func testPngDataFromSmallImagesHasPngSignature() {
        let oneByOne = makeSolidImage(size: NSSize(width: 1, height: 1))
        let twoByTwo = makeSolidImage(size: NSSize(width: 2, height: 2))

        for img in [oneByOne, twoByTwo] {
            let data = ImageHelpers.pngData(from: img)
            XCTAssertNotNil(data)
            XCTAssertGreaterThan((data?.count ?? 0), 8)
            if let sig = data?.prefix(4) {
                XCTAssertEqual(Array(sig), [0x89, 0x50, 0x4E, 0x47])
            }
        }
    }

    /// Pixel-exact PNG: `pngData(from: NSImage)` renders at the screen's backing scale,
    /// so it can't be used where the source's pixel dimensions matter.
    private func makePNGData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// The tooltip preview shows the whole image, not an aspect-fill crop of it, so a
    /// wide screenshot has to come back wide.
    func testAspectFitThumbnailFitsInsideTheMaxDimensionKeepingAspect() {
        let data = makePNGData(width: 640, height: 480)

        let thumb = ImageHelpers.aspectFitThumbnail(from: data, maxDimension: 240)

        XCTAssertNotNil(thumb)
        XCTAssertEqual(thumb!.size.width, 240, accuracy: 0.5)
        XCTAssertEqual(thumb!.size.height, 180, accuracy: 0.5, "aspect ratio must survive")
    }

    /// Menu previews never upscale, and neither does this one.
    func testAspectFitThumbnailLeavesASmallImageAlone() {
        let data = makePNGData(width: 20, height: 10)

        let thumb = ImageHelpers.aspectFitThumbnail(from: data, maxDimension: 240)

        XCTAssertEqual(thumb?.size.width, 20)
        XCTAssertEqual(thumb?.size.height, 10)
    }

    func testAspectFillThumbnailReturnsTargetSize() {
        let source = makeSolidImage(size: NSSize(width: 10, height: 20), color: .blue)
        let targetSize = NSSize(width: 30, height: 40)

        let thumb = ImageHelpers.aspectFillThumbnail(image: source, targetSize: targetSize, scale: 1.0)
        XCTAssertEqual(thumb.size.width, targetSize.width, accuracy: 0.0001)
        XCTAssertEqual(thumb.size.height, targetSize.height, accuracy: 0.0001)
    }

    func testAspectFillThumbnailZeroSizeImageDoesNotCrashAndReturnsOriginal() {
        let zero = NSImage(size: .zero)
        let thumb = ImageHelpers.aspectFillThumbnail(image: zero, targetSize: NSSize(width: 10, height: 10), scale: 1.0)
        XCTAssertEqual(thumb.size.width, zero.size.width)
        XCTAssertEqual(thumb.size.height, zero.size.height)
    }

    func testAspectFillThumbnailFromDataReturnsTargetSize() {
        // Large-ish source so the downsample path actually shrinks it.
        let source = makeSolidImage(size: NSSize(width: 1200, height: 800), color: .green)
        guard let png = ImageHelpers.pngData(from: source) else {
            return XCTFail("expected PNG data from source image")
        }
        let targetSize = NSSize(width: 60, height: 40)

        let thumb = ImageHelpers.aspectFillThumbnail(from: png, targetSize: targetSize, scale: 2.0)
        XCTAssertNotNil(thumb)
        XCTAssertEqual(thumb?.size.width ?? 0, targetSize.width, accuracy: 0.0001)
        XCTAssertEqual(thumb?.size.height ?? 0, targetSize.height, accuracy: 0.0001)
    }

    func testAspectFillThumbnailFromGarbageDataReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        XCTAssertNil(ImageHelpers.aspectFillThumbnail(from: garbage, targetSize: NSSize(width: 10, height: 10)))
    }

    func testAspectFillThumbnailFromDataZeroTargetReturnsNil() {
        let source = makeSolidImage(size: NSSize(width: 10, height: 10))
        guard let png = ImageHelpers.pngData(from: source) else {
            return XCTFail("expected PNG data from source image")
        }
        XCTAssertNil(ImageHelpers.aspectFillThumbnail(from: png, targetSize: .zero))
    }
}

