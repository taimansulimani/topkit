import AppKit
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// Coverage for the three annotation/guide features added in this change:
///   1. Split guide shortcuts (horizontal keeps ⌃⌥⇧L, vertical defaults to ⌃⌥⇧K)
///   2. Redaction (mosaic) tool — must render the underlying pixels illegibly
///   3. Numbered-badge tool — auto-incrementing number, colourable, copy keeps the number
final class AnnotationToolsFeatureTests: XCTestCase {

    // MARK: - Pixel helpers

    private func makeSolidImage(width: Int, height: Int, color: NSColor) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// Image of tight 2px vertical black/white stripes — stands in for fine, text-like detail
    /// that a working redaction must destroy.
    private func makeStripedImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for x in 0..<width {
            (((x / 2) % 2) == 0 ? NSColor.black : NSColor.white).setFill()
            NSRect(x: x, y: 0, width: 1, height: height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private func pixel(in image: NSImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
        let offset = y * cg.bytesPerRow + x * (cg.bitsPerPixel / 8)
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    private func hasColorPixel(in image: NSImage, around x: Int, _ y: Int, box: Int,
                               where match: (UInt8, UInt8, UInt8) -> Bool) -> Bool {
        for py in (y - box)...(y + box) {
            for px in (x - box)...(x + box) {
                if let p = pixel(in: image, x: px, y: py), match(p.r, p.g, p.b) { return true }
            }
        }
        return false
    }

    private func annotation(type: AnnotationTool, frame: NSRect, color: NSColor = .red,
                            badgeNumber: Int? = nil) -> Annotation {
        Annotation(
            id: UUID(), type: type, frame: frame, color: color, thickness: 4,
            text: nil, fontSize: nil, startPoint: nil, endPoint: nil, pathPoints: nil,
            stickerPointerDirection: nil, badgeNumber: badgeNumber
        )
    }

    // MARK: - Feature 1: split guide shortcut

    /// Shortcut defaults are ⌃⇧ + letter (no ⌥). Letters must stay unique — R moved from
    /// Add Rectangle to Record Screen, and Rectangle took J.
    private static let expectedShortcutDefaults: [String: String] = [
        "shortcutScreenshot": "⌃⇧S",
        "shortcutRecordScreen": "⌃⇧R",
        "shortcutPickColor": "⌃⇧I",
        "shortcutDraw": "⌃⇧D",
        "shortcutMagnifyingGlass": "⌃⇧Z",
        "shortcutHalo": "⌃⇧H",
        "shortcutMeasure": "⌃⇧M",
        "shortcutAddGuide": "⌃⇧K",
        "shortcutAddVerticalGuide": "⌃⇧L",
        "shortcutAddRectangle": "⌃⇧J",
        "shortcutClipboardMenu": "⌃⇧V",
        // Annotate tools. Freehand reuses shortcutDraw.
        // Free letters remaining: E F G O P Q U W.
        "shortcutAnnotateRectangle": "⌃⇧B",
        "shortcutAnnotateCircle": "⌃⇧C",
        "shortcutAnnotateArrow": "⌃⇧A",
        "shortcutAnnotateText": "⌃⇧T",
        "shortcutAnnotateRedact": "⌃⇧X",
        "shortcutAnnotateSticker": "⌃⇧Y",
        "shortcutAnnotateBadge": "⌃⇧N",
    ]

    func testShortcutDefaultsMatchSpec() {
        AppDelegate.registerDefaultUserValues()
        for (key, glyphs) in Self.expectedShortcutDefaults {
            XCTAssertEqual(UserDefaults.standard.string(forKey: key), glyphs, "default for \(key)")
        }
    }

    func testShortcutDefaultsAreUnique() {
        let values = Self.expectedShortcutDefaults.values
        XCTAssertEqual(
            Set(values).count, values.count,
            "No two tools may share a default shortcut"
        )
    }

    func testShortcutDefaultsAreParseableHotkeys() {
        // A default that HotKeyManager can't parse silently never registers.
        for (key, glyphs) in Self.expectedShortcutDefaults {
            XCTAssertNotNil(HotKeyManager.parse(glyphs), "\(key) default '\(glyphs)' must parse")
        }
    }

    func testUnboundShortcutsHaveNoDefault() {
        AppDelegate.registerDefaultUserValues()
        // These show "Click to set" in Preferences — they must stay unbound by default.
        for key in ["shortcutClearClipboard", "shortcutOpenPreferences"] {
            XCTAssertNil(UserDefaults.standard.string(forKey: key), "\(key) must have no default")
        }
    }

    // MARK: - Feature 3: numbered-badge numbering

    func testNextBadgeNumberStartsAtOne() {
        XCTAssertEqual(ScreenshotAnnotationView.nextBadgeNumber(in: []), 1)
    }

    func testNextBadgeNumberIncrementsFromHighest() {
        let badges = [
            annotation(type: .numberBadge, frame: .zero, badgeNumber: 1),
            annotation(type: .numberBadge, frame: .zero, badgeNumber: 2),
        ]
        XCTAssertEqual(ScreenshotAnnotationView.nextBadgeNumber(in: badges), 3)
    }

    func testNextBadgeNumberIgnoresOtherAnnotationTypes() {
        let mixed = [
            annotation(type: .rectangle, frame: .zero),
            annotation(type: .numberBadge, frame: .zero, badgeNumber: 5),
            annotation(type: .sticker(.redX), frame: .zero),
        ]
        XCTAssertEqual(ScreenshotAnnotationView.nextBadgeNumber(in: mixed), 6)
    }

    // MARK: - Feature 3: copy/paste keeps the badge number (the "two number ones" case)

    func testCopyPasteDuplicatesBadgeKeepingItsNumber() {
        let view = ScreenshotAnnotationView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            screenshot: makeSolidImage(width: 200, height: 200, color: .white),
            screenshotRect: NSRect(x: 0, y: 0, width: 200, height: 200)
        )
        let badge = annotation(type: .numberBadge, frame: NSRect(x: 20, y: 20, width: 34, height: 34), badgeNumber: 1)
        view._setAnnotationsForTesting([badge])
        view._selectForTesting(badge.id)
        view._copySelectedForTesting()
        XCTAssertTrue(view._pasteForTesting(), "Paste should succeed after copying a badge")

        let badges = view._annotationsForTesting().filter {
            if case .numberBadge = $0.type { return true }
            return false
        }
        XCTAssertEqual(badges.count, 2, "Copy/paste must duplicate the badge")
        XCTAssertEqual(Set(badges.map { $0.badgeNumber }), [1],
                       "Both badges must carry number 1 — copy/paste duplicates the number verbatim")
        XCTAssertNotEqual(badges[0].id, badges[1].id, "The pasted badge must have a fresh id")
    }

    // MARK: - Feature 3: badge size control resizes about the centre

    func testBadgeSizeControlResizesSelectedBadgeAboutCentre() {
        let view = ScreenshotAnnotationView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            screenshot: makeSolidImage(width: 200, height: 200, color: .white),
            screenshotRect: NSRect(x: 0, y: 0, width: 200, height: 200)
        )
        let badge = annotation(type: .numberBadge, frame: NSRect(x: 50, y: 50, width: 34, height: 34), badgeNumber: 1)
        view._setAnnotationsForTesting([badge])
        view._selectForTesting(badge.id)

        view._changeBadgeSizeForTesting(80)

        let updated = view._annotationsForTesting().first { if case .numberBadge = $0.type { return true }; return false }!
        XCTAssertEqual(updated.frame.width, 80, accuracy: 0.5, "Size control must set the badge diameter")
        XCTAssertEqual(updated.frame.height, 80, accuracy: 0.5, "Badge stays square")
        // Original centre was (67, 67); resizing must keep it fixed.
        XCTAssertEqual(updated.frame.midX, 67, accuracy: 0.5, "Badge must resize about its centre")
        XCTAssertEqual(updated.frame.midY, 67, accuracy: 0.5, "Badge must resize about its centre")
    }

    // MARK: - Feature 3: badge renders a coloured disc with a number

    func testBadgeExportRendersColouredDisc() {
        let image = makeSolidImage(width: 200, height: 200, color: .white)
        let badge = annotation(type: .numberBadge,
                               frame: NSRect(x: 80, y: 80, width: 40, height: 40),
                               color: .red, badgeNumber: 1)
        let rendered = ScreenshotAnnotationView.renderAnnotations(on: image, annotations: [badge])
        // Disc fill is red; centre of the badge (image px 100,100) must be strongly red.
        XCTAssertTrue(
            hasColorPixel(in: rendered, around: 100, 100, box: 6) { r, g, b in r > 150 && g < 110 && b < 110 },
            "Numbered badge must render a filled disc in its colour"
        )
        // White number glyph must appear somewhere inside the disc.
        XCTAssertTrue(
            hasColorPixel(in: rendered, around: 100, 100, box: 10) { r, g, b in r > 220 && g > 220 && b > 220 },
            "Numbered badge must render a white number inside the disc"
        )
    }

    // MARK: - Feature 2: redaction destroys fine detail

    func testRedactionMosaicDestroysFineDetail() {
        let striped = makeStripedImage(width: 180, height: 120)
        // Sanity: original has pure black and pure white (legible fine detail).
        XCTAssertTrue(hasColorPixel(in: striped, around: 90, 60, box: 3) { r, _, _ in r < 20 },
                      "Striped source should contain pure-black pixels")
        XCTAssertTrue(hasColorPixel(in: striped, around: 90, 60, box: 3) { r, _, _ in r > 235 },
                      "Striped source should contain pure-white pixels")

        let blur = annotation(type: .blur, frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        let rendered = ScreenshotAnnotationView.renderAnnotations(on: striped, annotations: [blur])

        // After mosaic, the 2px stripes are averaged into blocks: the centre must be mid-grey,
        // i.e. the fine detail is gone (impossible in the pure black/white original).
        guard let p = pixel(in: rendered, x: 90, y: 60) else {
            return XCTFail("Could not read redacted pixel")
        }
        XCTAssertTrue((60...195).contains(Int(p.r)),
                      "Redacted region must be averaged to mid-grey (was \(p.r)); fine detail must be destroyed")
    }

    // MARK: - Redaction never leaks when no source pixels are available

    func testRedactionFallsBackToSolidFillWithoutSource() {
        // drawOneAnnotation is reached via renderAnnotations; force the no-source path by
        // rendering the blur through the static redaction helper directly with a nil mosaic.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 60,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 60 * 4, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 60, height: 60).fill()
        let blur = annotation(type: .blur, frame: NSRect(x: 10, y: 10, width: 40, height: 40))
        AnnotationRenderer.drawRedaction(blur, mosaic: nil, in: ctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: 60, height: 60))
        image.addRepresentation(rep)
        // Middle of the frame must be opaque dark (never the original white) so nothing leaks.
        guard let p = pixel(in: image, x: 30, y: 30) else {
            return XCTFail("Could not read fallback pixel")
        }
        XCTAssertLessThan(Int(p.r), 40, "No-source redaction must fall back to a solid dark fill, not leave pixels visible")
    }
}
