import AppKit
import CoreMedia
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Show clicks in recordings (TEC-248): timing, coordinate mapping, drawing, toolbar toggle.
final class ClickIndicatorTests: XCTestCase {

    // MARK: - Animation timing

    func testProgressOnlyInsideRipple() {
        XCTAssertNil(ClickIndicator.progress(elapsed: -0.01))
        XCTAssertEqual(ClickIndicator.progress(elapsed: 0), 0)
        XCTAssertEqual(ClickIndicator.progress(elapsed: ClickIndicator.duration / 2) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ClickIndicator.progress(elapsed: ClickIndicator.duration), 1)
        XCTAssertNil(ClickIndicator.progress(elapsed: ClickIndicator.duration + 0.01))
    }

    func testRadiusGrowsFromStartToEnd() {
        XCTAssertEqual(ClickIndicator.radius(progress: 0), ClickIndicator.startRadius)
        XCTAssertEqual(ClickIndicator.radius(progress: 1), ClickIndicator.endRadius, accuracy: 1e-9)
        // Ease-out: past the halfway size by half time.
        let mid = ClickIndicator.radius(progress: 0.5)
        XCTAssertGreaterThan(mid, (ClickIndicator.startRadius + ClickIndicator.endRadius) / 2)
        XCTAssertLessThan(ClickIndicator.radius(progress: 0.3), ClickIndicator.radius(progress: 0.6))
    }

    func testOpacityHoldsThenFadesToZero() {
        XCTAssertEqual(ClickIndicator.opacity(progress: 0), 1)
        XCTAssertEqual(ClickIndicator.opacity(progress: 0.2), 1)
        XCTAssertEqual(ClickIndicator.opacity(progress: 1), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(ClickIndicator.opacity(progress: 0.5), ClickIndicator.opacity(progress: 0.8))
    }

    func testRecordedClickVisibility() {
        let start = CMTime(seconds: 10, preferredTimescale: 600)
        let click = RecordedClick(center: .zero, time: start, kind: .left, color: CGColor(gray: 1, alpha: 1), scale: 2)
        XCTAssertFalse(click.isVisible(at: CMTime(seconds: 9.9, preferredTimescale: 600)))
        XCTAssertTrue(click.isVisible(at: CMTime(seconds: 10.2, preferredTimescale: 600)))
        XCTAssertFalse(click.isVisible(at: CMTime(seconds: 10 + ClickIndicator.duration + 0.05, preferredTimescale: 600)))
    }

    // MARK: - Coordinates

    func testVideoPointMapsGlobalPointIntoPixels() {
        // 400×300 pt region at (100, 50) on a 2× display → 800×600 px.
        let rect = CGRect(x: 100, y: 50, width: 400, height: 300)
        let p = ClickIndicator.videoPoint(globalPoint: CGPoint(x: 150, y: 80), captureRect: rect, pixelSize: (800, 600))
        XCTAssertEqual(p, CGPoint(x: 100, y: 60))
    }

    func testVideoPointHandlesNegativeOriginDisplays() {
        // Secondary display left of / below the primary.
        let rect = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let p = ClickIndicator.videoPoint(globalPoint: CGPoint(x: -720, y: 250), captureRect: rect, pixelSize: (1440, 900))
        XCTAssertEqual(p, CGPoint(x: 720, y: 450))
    }

    func testVideoPointRejectsClicksOutsideRecordedArea() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(ClickIndicator.videoPoint(globalPoint: CGPoint(x: 150, y: 50), captureRect: rect, pixelSize: (200, 200)))
        XCTAssertNil(ClickIndicator.videoPoint(globalPoint: CGPoint(x: 50, y: 50), captureRect: .zero, pixelSize: (200, 200)))
    }

    func testPixelScale() {
        XCTAssertEqual(ClickIndicator.pixelScale(captureRect: CGRect(x: 0, y: 0, width: 400, height: 300), pixelWidth: 800), 2)
        XCTAssertEqual(ClickIndicator.pixelScale(captureRect: .zero, pixelWidth: 800), 1)
    }

    func testColorFollowsHaloPreference() {
        let defaults = UserDefaults(suiteName: "ClickIndicatorTests-\(UUID().uuidString)")!
        defaults.set(1.0, forKey: "haloColorRed")
        defaults.set(0.0, forKey: "haloColorGreen")
        defaults.set(0.0, forKey: "haloColorBlue")
        defaults.set(0.0, forKey: "haloColorAlpha") // unset alpha must not hide the ring
        let c = ClickIndicator.color(from: defaults).components ?? []
        XCTAssertEqual(c.count, 4)
        XCTAssertEqual(c[0], 1, accuracy: 0.001)
        XCTAssertEqual(c[1], 0, accuracy: 0.001)
        XCTAssertEqual(c[3], 1, accuracy: 0.001)
    }

    // MARK: - Drawing

    private func makeContext(size: Int) -> CGContext {
        CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
    }

    private func alpha(in context: CGContext, x: Int, y: Int) -> UInt8 {
        // CG bottom-left drawing; memory rows are top-down. BGRA little-endian: alpha at +3.
        let row = context.height - 1 - y
        let ptr = context.data!.assumingMemoryBound(to: UInt8.self)
        return ptr[row * context.bytesPerRow + x * 4 + 3]
    }

    func testRendererDrawsRingAtClickPointOnlyWhileVisible() {
        let start = CMTime(seconds: 5, preferredTimescale: 600)
        let click = RecordedClick(center: CGPoint(x: 50, y: 50), time: start, kind: .left, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), scale: 1)

        let visible = makeContext(size: 100)
        ClickIndicatorRenderer.draw([click], at: start, in: visible)
        // Ring at startRadius (8 pt) to the right of the centre.
        XCTAssertGreaterThan(alpha(in: visible, x: 50 + Int(ClickIndicator.startRadius), y: 50), 100)
        // Far corner untouched.
        XCTAssertEqual(alpha(in: visible, x: 2, y: 2), 0)

        let finished = makeContext(size: 100)
        ClickIndicatorRenderer.draw([click], at: CMTime(seconds: 5 + ClickIndicator.duration + 0.1, preferredTimescale: 600), in: finished)
        XCTAssertEqual(alpha(in: finished, x: 50 + Int(ClickIndicator.startRadius), y: 50), 0)
    }

    func testRightClickAddsInnerRing() {
        let start = CMTime(seconds: 1, preferredTimescale: 600)
        let color = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let left = makeContext(size: 120)
        let right = makeContext(size: 120)
        let p = 0.0
        ClickIndicatorRenderer.draw(RecordedClick(center: CGPoint(x: 60, y: 60), time: start, kind: .left, color: color, scale: 3), progress: p, in: left)
        ClickIndicatorRenderer.draw(RecordedClick(center: CGPoint(x: 60, y: 60), time: start, kind: .right, color: color, scale: 3), progress: p, in: right)
        let innerX = 60 + Int(ClickIndicator.startRadius * 3 * 0.55)
        XCTAssertGreaterThan(alpha(in: right, x: innerX, y: 60), alpha(in: left, x: innerX, y: 60))
    }

    func testCompositorStampsOverlayOntoCopiedFrame() throws {
        func makeBuffer() -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            return buffer!
        }
        let source = makeBuffer()
        let dest = makeBuffer()
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddress(source), 0, CVPixelBufferGetBytesPerRow(source) * 64)
        CVPixelBufferUnlockBaseAddress(source, [])

        var overlayRan = false
        let ok = CaptionPixelCompositor.copyAndBurn(source: source, into: dest, caption: nil) { context in
            overlayRan = true
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        XCTAssertTrue(ok)
        XCTAssertTrue(overlayRan)
        CVPixelBufferLockBaseAddress(dest, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dest, .readOnly) }
        let px = CVPixelBufferGetBaseAddress(dest)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(px[3], 255, "overlay must be drawn onto the destination frame")
    }

    // MARK: - Recording toolbar

    private func findCheckbox(in view: NSView, title: String) -> NSButton? {
        for sub in view.subviews {
            if let button = sub as? NSButton, button.title == title { return button }
            if let found = findCheckbox(in: sub, title: title) { return found }
        }
        return nil
    }

    private func makeToolbarView(showsRecordingOptions: Bool) -> SelectionConfirmView {
        SelectionConfirmView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            selectionRect: NSRect(x: 100, y: 100, width: 200, height: 200),
            primaryTitle: "Start Recording",
            primaryIsDestructive: true,
            allowsResize: true,
            showsRecordingOptions: showsRecordingOptions
        )
    }

    func testClicksToggleIsOffByDefaultAndPersists() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: ClickIndicator.defaultsKey)
        defer { defaults.set(saved, forKey: ClickIndicator.defaultsKey) }
        defaults.removeObject(forKey: ClickIndicator.defaultsKey)

        let view = makeToolbarView(showsRecordingOptions: true)
        guard let toggle = findCheckbox(in: view, title: "Clicks") else {
            return XCTFail("Recording toolbar must show a Clicks toggle")
        }
        XCTAssertEqual(toggle.state, .off, "Show clicks must be off by default")

        toggle.state = .on
        _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        XCTAssertTrue(defaults.bool(forKey: ClickIndicator.defaultsKey))

        // A fresh toolbar reflects the saved choice.
        XCTAssertEqual(findCheckbox(in: makeToolbarView(showsRecordingOptions: true), title: "Clicks")?.state, .on)
    }

    func testNonRecordingToolbarHidesClicksToggle() {
        XCTAssertNil(findCheckbox(in: makeToolbarView(showsRecordingOptions: false), title: "Clicks"))
    }
}
