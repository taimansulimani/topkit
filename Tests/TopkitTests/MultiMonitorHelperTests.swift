import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class MultiMonitorHelperTests: XCTestCase {
    func testQuartzToCocoaConversionWithInjectedPrimaryHeight() {
        let quartzPoint = CGPoint(x: 10, y: 20)
        let primaryHeight: CGFloat = 100

        let cocoa = MultiMonitorHelper.quartzToCocoa(quartzPoint, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(cocoa.x, 10)
        XCTAssertEqual(cocoa.y, 80)
    }

    func testQuartzCaptureRectForGlobalCocoaScreenFrame() {
        let primaryHeight: CGFloat = 900
        let cocoa = NSRect(x: 40, y: 100, width: 200, height: 150)
        let q = MultiMonitorHelper.quartzCaptureRect(forGlobalCocoaScreenFrame: cocoa, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(q.origin.x, 40)
        XCTAssertEqual(q.origin.y, primaryHeight - cocoa.maxY)
        XCTAssertEqual(q.width, 200)
        XCTAssertEqual(q.height, 150)
    }

    func testFrozenHoleBlitPrimaryScreen() {
        let snap = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let hole = NSRect(x: 100, y: 100, width: 200, height: 150)
        let blit = MultiMonitorHelper.frozenHoleBlitRectangles(
            globalHole: hole,
            snapFrame: snap,
            activeScreenOrigin: .zero
        )
        XCTAssertNotNil(blit)
        XCTAssertEqual(blit!.src, NSRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertEqual(blit!.dst, blit!.src)
    }

    func testFrozenHoleBlitOffsetScreen() {
        let snap = NSRect(x: 1720, y: 0, width: 2560, height: 1440)
        let origin = CGPoint(x: 1720, y: 0)
        let hole = NSRect(x: 1800, y: 100, width: 100, height: 100)
        let blit = MultiMonitorHelper.frozenHoleBlitRectangles(
            globalHole: hole,
            snapFrame: snap,
            activeScreenOrigin: origin
        )
        XCTAssertNotNil(blit)
        XCTAssertEqual(blit!.src, NSRect(x: 80, y: 100, width: 100, height: 100))
        XCTAssertEqual(blit!.dst, NSRect(x: 80, y: 100, width: 100, height: 100))
    }

    func testFrozenHoleBlitNoOverlap() {
        let snap = NSRect(x: 2000, y: 0, width: 1000, height: 800)
        let hole = NSRect(x: 0, y: 0, width: 100, height: 100)
        let blit = MultiMonitorHelper.frozenHoleBlitRectangles(
            globalHole: hole,
            snapFrame: snap,
            activeScreenOrigin: .zero
        )
        XCTAssertNil(blit)
    }

    func testCompositeFrozenGlobalRectSingleDisplay() {
        let rep = Self.makeBitmapImageRep(width: 100, height: 80)
        let ns = NSImage(size: NSSize(width: 100, height: 80))
        ns.addRepresentation(rep)
        let global = NSRect(x: 10, y: 10, width: 30, height: 20)
        let out = MultiMonitorHelper.compositeFrozenGlobalRect(
            global,
            snapshots: [(image: ns, frame: NSRect(x: 0, y: 0, width: 100, height: 80))]
        )
        guard let out else {
            XCTFail("expected composite image")
            return
        }
        XCTAssertEqual(out.size.width, 30, accuracy: 0.01)
        XCTAssertEqual(out.size.height, 20, accuracy: 0.01)
    }

    func testCompositeFrozenGlobalRectSpansTwoDisplays() {
        let repA = Self.makeBitmapImageRep(width: 100, height: 100)
        let imgA = NSImage(size: NSSize(width: 100, height: 100))
        imgA.addRepresentation(repA)
        let repB = Self.makeBitmapImageRep(width: 100, height: 100)
        let imgB = NSImage(size: NSSize(width: 100, height: 100))
        imgB.addRepresentation(repB)
        let frameA = NSRect(x: 0, y: 0, width: 100, height: 100)
        let frameB = NSRect(x: 100, y: 0, width: 100, height: 100)
        let global = NSRect(x: 80, y: 0, width: 60, height: 40)
        let out = MultiMonitorHelper.compositeFrozenGlobalRect(
            global,
            snapshots: [(image: imgA, frame: frameA), (image: imgB, frame: frameB)]
        )
        guard let out else {
            XCTFail("expected composite image")
            return
        }
        XCTAssertEqual(out.size.width, 60, accuracy: 0.01)
        XCTAssertEqual(out.size.height, 40, accuracy: 0.01)
    }

    // MARK: - annotationScreenshotRect

    func testAnnotationScreenshotRectPrimaryOnly_centersAndAspectFits() {
        // Single 3840x2160 primary monitor, fullscreen-window capture (image
        // matches the screen size).
        let screen = NSRect(x: 0, y: 0, width: 3840, height: 2160)
        let image = NSSize(width: 3840, height: 2160)
        let rect = MultiMonitorHelper.annotationScreenshotRect(
            imageSize: image,
            targetScreenCocoaFrame: screen,
            viewportCocoaOrigin: .zero,
            reservedTop: 120,
            horizontalPadding: 16
        )
        // Aspect-fit into (W-32) x (H-136). Width is slack; height constrains.
        let scale: CGFloat = (2160 - 136) / 2160
        let expectedW: CGFloat = 3840 * scale
        let expectedH: CGFloat = 2160 * scale
        XCTAssertEqual(rect.width, expectedW, accuracy: 0.5)
        XCTAssertEqual(rect.height, expectedH, accuracy: 0.5)
        // Horizontally centered in the monitor.
        XCTAssertEqual(rect.midX, screen.midX, accuracy: 0.5)
        // Sits above the bottom padding but below the reserved-top band.
        XCTAssertGreaterThanOrEqual(rect.minY, 16)
        XCTAssertLessThanOrEqual(rect.maxY, screen.height - 120)
    }

    func testAnnotationScreenshotRectSecondMonitorToTheRight_centersOnThatMonitor() {
        // Primary (0..3840) + second monitor (3840..5760) to the right.
        let primary = NSRect(x: 0, y: 0, width: 3840, height: 2160)
        let secondary = NSRect(x: 3840, y: 0, width: 1920, height: 1080)
        let viewport = primary.union(secondary)
        let image = NSSize(width: 1500, height: 900)
        let rect = MultiMonitorHelper.annotationScreenshotRect(
            imageSize: image,
            targetScreenCocoaFrame: secondary,
            viewportCocoaOrigin: viewport.origin,
            reservedTop: 120,
            horizontalPadding: 16
        )
        // In view-local coords, the secondary monitor occupies x in [3840, 5760].
        // The screenshot must be centered within that band.
        let localScreenMidX = (secondary.origin.x - viewport.origin.x) + secondary.width / 2
        XCTAssertEqual(rect.midX, localScreenMidX, accuracy: 0.5)
        // Must fit inside the secondary monitor horizontally.
        XCTAssertGreaterThanOrEqual(rect.minX, secondary.origin.x - viewport.origin.x + 16 - 0.5)
        XCTAssertLessThanOrEqual(rect.maxX, secondary.maxX - viewport.origin.x - 16 + 0.5)
    }

    func testAnnotationScreenshotRectSecondMonitorAbovePrimary_usesNegativeViewportOrigin() {
        // Second monitor above primary: viewport origin becomes (0, -800)
        // because Cocoa Y grows upward. The screenshot for a capture on the
        // TOP monitor should appear in the upper half of the local view.
        let primary = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = NSRect(x: 0, y: 1080, width: 1920, height: 1080)
        let viewport = primary.union(secondary)
        XCTAssertEqual(viewport.origin.y, 0)
        let image = NSSize(width: 800, height: 600)
        let rect = MultiMonitorHelper.annotationScreenshotRect(
            imageSize: image,
            targetScreenCocoaFrame: secondary,
            viewportCocoaOrigin: viewport.origin,
            reservedTop: 120,
            horizontalPadding: 16
        )
        // The image fits without scaling (800 < 1920-32, 600 < 1080-136).
        XCTAssertEqual(rect.size, NSSize(width: 800, height: 600))
        // And lands in the UPPER monitor region (y > primary.height).
        XCTAssertGreaterThanOrEqual(rect.minY, primary.height)
    }

    func testAnnotationScreenshotRectFullscreenWindow_usesFullMonitorWidth() {
        // Regression test for the user-reported bug: a fullscreen window
        // captured on the landscape monitor (primary) should NOT land in the
        // bottom-left corner — it should be centered on that monitor with
        // only the reserved-top band free for the toolbar.
        let primary = NSRect(x: 0, y: 0, width: 3840, height: 2160)
        let portrait = NSRect(x: 3840, y: 0, width: 1080, height: 1920)
        let viewport = primary.union(portrait)
        let image = NSSize(width: 3840, height: 2160)
        let rect = MultiMonitorHelper.annotationScreenshotRect(
            imageSize: image,
            targetScreenCocoaFrame: primary,
            viewportCocoaOrigin: viewport.origin,
            reservedTop: 120,
            horizontalPadding: 16
        )
        // Must be horizontally centered on the primary monitor (not on the
        // combined desktop).
        XCTAssertEqual(rect.midX, primary.midX - viewport.origin.x, accuracy: 0.5)
        // And vertically centered within the available band.
        XCTAssertGreaterThan(rect.minY, 0)
        XCTAssertLessThan(rect.maxY, primary.height - 100)
    }

    func testAnnotationScreenshotRectSmallImage_isNotUpscaled() {
        let screen = NSRect(x: 0, y: 0, width: 2000, height: 1200)
        let image = NSSize(width: 400, height: 200)
        let rect = MultiMonitorHelper.annotationScreenshotRect(
            imageSize: image,
            targetScreenCocoaFrame: screen,
            viewportCocoaOrigin: .zero,
            reservedTop: 120,
            horizontalPadding: 16
        )
        XCTAssertEqual(rect.size, image)
        XCTAssertEqual(rect.midX, screen.midX, accuracy: 0.5)
    }

    private static func makeBitmapImageRep(width: Int, height: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

}

