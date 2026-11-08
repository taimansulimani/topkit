import AppKit
import CoreGraphics
import XCTest
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

/// TEC-246: frames sliced from a known tall image must stitch back pixel for pixel.
final class ScrollingStitcherTests: XCTestCase {

    // MARK: Synthetic content

    /// RGBA rows, top to bottom.
    private struct Pixels: Equatable {
        let width: Int
        var rows: [[UInt8]]
        var height: Int { rows.count }

        func slice(_ start: Int, _ count: Int) -> [[UInt8]] { Array(rows[start..<(start + count)]) }

        func image() -> CGImage {
            let bytes = rows.flatMap { $0 }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            return CGImage(
                width: width,
                height: rows.count,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!
        }

        static func from(_ image: CGImage) -> Pixels {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { raw in
                let ctx = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                )!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return Pixels(width: width, rows: (0..<height).map { Array(bytes[($0 * width * 4)..<(($0 + 1) * width * 4)]) })
        }
    }

    /// Deterministic generator, so a failure reproduces.
    private struct SeededRandom {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    }

    /// A page of "text": white background, lines of dark glyph blocks with gaps,
    /// like a document or a web page. Every line differs.
    private func documentPage(width: Int, height: Int, seed: UInt64 = 7) -> Pixels {
        var random = SeededRandom(state: seed)
        var rows: [[UInt8]] = []
        let white: [UInt8] = [255, 255, 255, 255]
        while rows.count < height {
            // Gap between lines.
            let gap = 3 + Int(random.next() % 6)
            for _ in 0..<gap where rows.count < height { rows.append(Array(repeating: white, count: width).flatMap { $0 }) }
            // A line of glyphs: random runs of ink, a few rows tall.
            let lineHeight = 5 + Int(random.next() % 5)
            var ink = [Bool](repeating: false, count: width)
            var x = Int(random.next() % 6)
            while x < width {
                let run = 1 + Int(random.next() % 7)
                for i in x..<min(width, x + run) { ink[i] = true }
                x += run + 1 + Int(random.next() % 5)
            }
            let shade = UInt8(20 + random.next() % 60)
            for lineRow in 0..<lineHeight where rows.count < height {
                var row: [UInt8] = []
                for column in 0..<width {
                    // Glyph shapes vary per row too.
                    let on = ink[column] && (column + lineRow) % 3 != 0
                    row += on ? [shade, shade, UInt8(min(255, Int(shade) + 30)), 255] : white
                }
                rows.append(row)
            }
        }
        return Pixels(width: width, rows: rows)
    }

    /// Solid noise: every row unique.
    private func noisePage(width: Int, height: Int, seed: UInt64 = 42) -> Pixels {
        var random = SeededRandom(state: seed)
        return Pixels(width: width, rows: (0..<height).map { _ in
            (0..<width).flatMap { _ in [random.byte(), random.byte(), random.byte(), 255] }
        })
    }

    /// What the screen shows at `offset`: optional static header/footer over the content.
    private func frame(_ content: Pixels, offset: Int, height: Int,
                       header: [[UInt8]] = [], footer: [[UInt8]] = []) -> CGImage {
        let middle = height - header.count - footer.count
        return Pixels(width: content.width, rows: header + content.slice(offset, middle) + footer).image()
    }

    // MARK: Plain scrolling

    func testOverlappingFramesStitchBackPixelExact() throws {
        let page = documentPage(width: 96, height: 900)
        let frameHeight = 160
        let offsets = [0, 23, 70, 71, 140, 230, 231, 300, 420, 555, 640, 740]
        let stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.add(frame(page, offset: 0, height: frameHeight)), .started)
        var last = 0
        for offset in offsets.dropFirst() {
            XCTAssertEqual(stitcher.add(frame(page, offset: offset, height: frameHeight)), .appended(rows: offset - last), "offset \(offset)")
            last = offset
        }
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result.height, last + frameHeight)
        XCTAssertEqual(result, Pixels(width: page.width, rows: page.slice(0, last + frameHeight)))
    }

    func testNoiseContentStitchesPixelExact() throws {
        let page = noisePage(width: 40, height: 400)
        let stitcher = ScrollingStitcher()
        for offset in [0, 1, 50, 99, 180, 250, 300] {
            stitcher.add(frame(page, offset: offset, height: 100))
        }
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 40, rows: page.slice(0, 400)))
    }

    func testSingleFrameIsTheRegion() throws {
        let page = documentPage(width: 64, height: 200)
        let stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.add(frame(page, offset: 0, height: 120)), .started)
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 64, rows: page.slice(0, 120)))
    }

    func testEmptyStitcherHasNoImage() {
        XCTAssertNil(ScrollingStitcher().makeImage())
        XCTAssertEqual(ScrollingStitcher().height, 0)
    }

    // MARK: Sticky header and footer

    func testStickyHeaderIsKeptOnceAtTop() throws {
        let page = documentPage(width: 96, height: 800)
        let header = noisePage(width: 96, height: 24, seed: 3).rows
        let frameHeight = 180
        let stitcher = ScrollingStitcher()
        var last = 0
        for offset in [0, 40, 41, 130, 260, 300, 410] {
            stitcher.add(frame(page, offset: offset, height: frameHeight, header: header))
            last = offset
        }
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        let expected = header + page.slice(0, last + frameHeight - header.count)
        XCTAssertEqual(result, Pixels(width: 96, rows: expected))
    }

    func testStickyHeaderAndFooterAreKeptOnce() throws {
        let page = documentPage(width: 96, height: 800)
        let header = noisePage(width: 96, height: 20, seed: 3).rows
        let footer = noisePage(width: 96, height: 14, seed: 9).rows
        let frameHeight = 200
        let stitcher = ScrollingStitcher()
        var last = 0
        for offset in [0, 35, 90, 91, 200, 320, 420] {
            stitcher.add(frame(page, offset: offset, height: frameHeight, header: header, footer: footer))
            last = offset
        }
        let middle = frameHeight - header.count - footer.count
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        let expected = header + page.slice(0, last + middle) + footer
        XCTAssertEqual(result, Pixels(width: 96, rows: expected))
    }

    /// A frosted bar (macOS 26 toolbars, sticky site headers): the content under it
    /// shows through, washed out, behind the bar's own fixed controls. Its rows change
    /// with every scroll but do not move with the page.
    private func frostedFrame(_ content: Pixels, offset: Int, height: Int, topBar: Int, bottomBar: Int) -> Pixels {
        var rows = content.slice(offset, height)
        let controls = noisePage(width: content.width, height: height, seed: 11)
        func frost(_ index: Int) {
            rows[index] = zip(rows[index], controls.rows[index]).enumerated().map { item in
                item.offset % 4 == 3 ? 255 : UInt8((Int(item.element.0) + 3 * Int(item.element.1)) / 4)
            }
        }
        for i in 0..<topBar { frost(i) }
        for i in (height - bottomBar)..<height { frost(i) }
        return Pixels(width: content.width, rows: rows)
    }

    func testFrostedTopAndBottomBarsDoNotStopStitching() throws {
        // Bars well over the share of rows allowed to disagree (TEC-246: "Scroll more
        // slowly" on every grab under a translucent toolbar).
        let page = documentPage(width: 96, height: 900)
        let frameHeight = 200, topBar = 26, bottomBar = 22
        let offsets = [0, 30, 64, 65, 140, 220, 310, 400]
        let stitcher = ScrollingStitcher()
        let first = frostedFrame(page, offset: 0, height: frameHeight, topBar: topBar, bottomBar: bottomBar)
        XCTAssertEqual(stitcher.add(first.image()), .started)
        var last = 0
        var lastFrame = first
        for offset in offsets.dropFirst() {
            lastFrame = frostedFrame(page, offset: offset, height: frameHeight, topBar: topBar, bottomBar: bottomBar)
            XCTAssertEqual(stitcher.add(lastFrame.image()), .appended(rows: offset - last), "offset \(offset)")
            last = offset
        }
        // The top bar once (from the first frame), the page, the bottom bar once (latest).
        let expected = first.slice(0, topBar)
            + page.slice(topBar, last + frameHeight - bottomBar - topBar)
            + lastFrame.slice(frameHeight - bottomBar, bottomBar)
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 96, rows: expected))
    }

    // MARK: Things that stand still next to or over the scrolling content

    /// TEC-246: a capture taking in a second pane (another session, a sidebar) next
    /// to the one being scrolled said "Scroll more slowly" from the first grab.
    func testStaticPaneNextToTheScrollingOneDoesNotStopStitching() throws {
        let page = documentPage(width: 96, height: 900)
        let side = documentPage(width: 48, height: 200, seed: 99)
        let divider: [UInt8] = [120, 120, 120, 255, 120, 120, 120, 255]
        let frameHeight = 200
        func paneFrame(offset: Int) -> CGImage {
            Pixels(width: 96 + 2 + 48, rows: (0..<frameHeight).map { page.rows[offset + $0] + divider + side.rows[$0] }).image()
        }
        let offsets = [0, 40, 90, 150, 230, 300]
        let stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.add(paneFrame(offset: 0)), .started)
        var last = 0
        for offset in offsets.dropFirst() {
            XCTAssertEqual(stitcher.add(paneFrame(offset: offset)), .appended(rows: offset - last), "offset \(offset)")
            last = offset
        }
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result.height, last + frameHeight)
        // Cropped to the scrolling pane: the still one is not repeated down the page.
        XCTAssertLessThan(result.width, 96 + 2 + 8)
        XCTAssertGreaterThanOrEqual(result.width, 96)
        for (index, row) in result.rows.enumerated() {
            XCTAssertEqual(Array(row[0..<(96 * 4)]), page.rows[index], "row \(index)")
        }
    }

    /// A composer floating over the content near the bottom, with content scrolling
    /// past under it: it is drawn once at the bottom, never repeated, and the page
    /// above it is continuous.
    func testFloatingComposerOverTheContentIsDrawnOnce() throws {
        let page = documentPage(width: 96, height: 900)
        let frameHeight = 200, composerTop = 150, composerHeight = 24
        func composerFrame(offset: Int) -> CGImage {
            var pixels = Pixels(width: 96, rows: page.slice(offset, frameHeight))
            for row in composerTop..<(composerTop + composerHeight) {
                pixels.rows[row] = (0..<96).flatMap { column -> [UInt8] in
                    // A box with a label in it, the same in every frame.
                    if row == composerTop { return [60, 60, 60, 255] }
                    if row == composerTop + composerHeight - 1 { return [90, 90, 90, 255] }
                    let ink = (row - composerTop) % 5 == 2 && column % 7 < 4
                    return ink ? [60, 60, 60, 255] : [235, 235, 235, 255]
                }
            }
            return pixels.image()
        }
        let offsets = [0, 30, 70, 110, 160, 220, 280]
        let stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.add(composerFrame(offset: 0)), .started)
        var last = 0
        for offset in offsets.dropFirst() {
            XCTAssertEqual(stitcher.add(composerFrame(offset: offset)), .appended(rows: offset - last), "offset \(offset)")
            last = offset
        }
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        // Everything above the final frame's composer area is the page, row for row.
        var continuous = 0
        while continuous < result.height, result.rows[continuous] == page.rows[continuous] { continuous += 1 }
        XCTAssertGreaterThanOrEqual(continuous, last + composerTop - composerHeight * 2)
        // The composer's top edge appears exactly once.
        let edge = Pixels.from(composerFrame(offset: 0)).rows[composerTop]
        XCTAssertEqual(result.rows.filter { $0 == edge }.count, 1)
    }

    /// TEC-246: matching tried every offset row by row, ~40 s a frame for a Retina
    /// window in a Debug build (0.4 s optimised), so grabs fell so far apart that
    /// every one said "Scroll more slowly". A window-sized frame must stitch fast.
    /// The same line twice on the page, as far apart as one scroll: in both grabs it
    /// sits at the same height, so it looks like a floating bar. It used to be taken
    /// for one, which left most of the frame out and failed the match.
    func testRepeatedLineIsNotAFloatingBar() throws {
        var page = documentPage(width: 96, height: 1400)
        for row in 0..<36 { page.rows[680 + row] = page.rows[380 + row] }
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 0, height: 686))
        XCTAssertEqual(stitcher.add(frame(page, offset: 300, height: 686)), .appended(rows: 300))
        XCTAssertEqual(stitcher.add(frame(page, offset: 560, height: 686)), .appended(rows: 260))
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 96, rows: page.slice(0, 560 + 686)))
    }

    /// The same line at the same height in both grabs, with the scroll so long
    /// that it falls among the newly revealed rows: nothing can show it moved.
    func testRepeatedLineAmongNewRowsDoesNotStopStitching() throws {
        var page = documentPage(width: 96, height: 1400)
        for row in 0..<16 { page.rows[860 + row] = page.rows[460 + row] }
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 0, height: 686))
        XCTAssertEqual(stitcher.add(frame(page, offset: 400, height: 686)), .appended(rows: 400))
        XCTAssertEqual(stitcher.add(frame(page, offset: 700, height: 686)), .appended(rows: 300))
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 96, rows: page.slice(0, 700 + 686)))
    }

    func testWindowSizedFramesStitchQuickly() throws {
        let page = documentPage(width: 1200, height: 2000)
        let frameHeight = 800
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 0, height: frameHeight))
        var slowest: TimeInterval = 0
        var last = 0
        for offset in [180, 420, 700] {
            let image = frame(page, offset: offset, height: frameHeight)
            let start = Date()
            XCTAssertEqual(stitcher.add(image), .appended(rows: offset - last))
            slowest = max(slowest, Date().timeIntervalSince(start))
            last = offset
        }
        // Generous, so a busy test machine can't fail it; the old search took minutes.
        XCTAssertLessThan(slowest, 3, "slowest frame took \(slowest) s")
    }

    // MARK: Frames that must be ignored

    func testRepeatedFrameIsIgnored() throws {
        let page = documentPage(width: 80, height: 500)
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 0, height: 150))
        XCTAssertEqual(stitcher.add(frame(page, offset: 0, height: 150)), .unchanged)
        XCTAssertEqual(stitcher.add(frame(page, offset: 60, height: 150)), .appended(rows: 60))
        XCTAssertEqual(stitcher.add(frame(page, offset: 60, height: 150)), .unchanged)
        XCTAssertEqual(stitcher.add(frame(page, offset: 60, height: 150)), .unchanged)
        XCTAssertEqual(stitcher.height, 210)
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 80, rows: page.slice(0, 210)))
    }

    /// A spinner, a ticking timer or new text changing in place, with nothing
    /// scrolling: not a failed match. It used to keep the old frame as the reference,
    /// so every later grab failed too and the capture said "Scroll more slowly" for
    /// good (the Claude feed, live).
    func testContentChangingInPlaceIsNotAFailedMatch() throws {
        var page = documentPage(width: 96, height: 900)
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 0, height: 200))
        let band = 120..<132
        for tick in 1...4 {
            let noise = noisePage(width: 96, height: band.count, seed: UInt64(tick))
            for (index, row) in band.enumerated() { page.rows[row] = noise.rows[index] }
            XCTAssertEqual(stitcher.add(frame(page, offset: 0, height: 200)), .unchanged, "tick \(tick)")
        }
        XCTAssertEqual(stitcher.add(frame(page, offset: 40, height: 200)), .appended(rows: 40))
        XCTAssertEqual(stitcher.add(frame(page, offset: 90, height: 200)), .appended(rows: 50))
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result.height, 290)
        XCTAssertEqual(result.slice(0, band.lowerBound), page.slice(0, band.lowerBound))
        XCTAssertEqual(result.slice(band.upperBound, 290 - band.upperBound), page.slice(band.upperBound, 290 - band.upperBound))
    }

    func testScrollingBackUpIsIgnoredAndDownResumes() throws {
        let page = documentPage(width: 80, height: 600)
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 0, height: 150))
        XCTAssertEqual(stitcher.add(frame(page, offset: 90, height: 150)), .appended(rows: 90))
        XCTAssertEqual(stitcher.add(frame(page, offset: 40, height: 150)), .scrolledBack)
        XCTAssertEqual(stitcher.add(frame(page, offset: 10, height: 150)), .scrolledBack)
        XCTAssertEqual(stitcher.height, 240)
        // Back down past where it was: only the new rows are added.
        XCTAssertEqual(stitcher.add(frame(page, offset: 150, height: 150)), .appended(rows: 60))
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 80, rows: page.slice(0, 300)))
    }

    /// Going up a chat feed, which opens at the bottom: the content moves down.
    /// It used to count as scrolling back, then every grab failed.
    /// Apps redraw text that moved with slightly different shading: in Claude, on a
    /// real trackpad, a few spots per row came out up to 8 levels off (out of 255),
    /// the rest the same. A per-spot limit failed every grab after the first slow
    /// scroll.
    func testSlightlyReshadedRowsStillMatch() throws {
        // 384 wide: 128 matching spots of 3 pixels each, as on a real capture.
        let page = documentPage(width: 384, height: 900)
        func reshaded(offset: Int, seed: UInt64) -> CGImage {
            var random = SeededRandom(state: seed)
            var rows = page.slice(offset, 200)
            for index in rows.indices {
                for _ in 0..<6 {
                    let spot = Int(random.next() % 128) * 3
                    for x in spot..<(spot + 3) {
                        for channel in 0..<3 {
                            let value = Int(rows[index][x * 4 + channel])
                            rows[index][x * 4 + channel] = UInt8(value >= 128 ? value - 8 : value + 8)
                        }
                    }
                }
            }
            return Pixels(width: 384, rows: rows).image()
        }
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 0, height: 200))
        XCTAssertEqual(stitcher.add(reshaded(offset: 12, seed: 1)), .appended(rows: 12))
        XCTAssertEqual(stitcher.add(reshaded(offset: 28, seed: 2)), .appended(rows: 16))
        XCTAssertEqual(stitcher.add(reshaded(offset: 30, seed: 3)), .appended(rows: 2))
        XCTAssertEqual(stitcher.height, 230)
    }

    func testScrollingUpThePageStitches() throws {
        let page = documentPage(width: 96, height: 900)
        let frameHeight = 160
        let offsets = [600, 600, 560, 490, 489, 400, 300, 230]
        let stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.add(frame(page, offset: offsets[0], height: frameHeight)), .started)
        XCTAssertEqual(stitcher.add(frame(page, offset: offsets[1], height: frameHeight)), .unchanged)
        var last = offsets[1]
        for offset in offsets.dropFirst(2) {
            XCTAssertEqual(stitcher.add(frame(page, offset: offset, height: frameHeight)), .appended(rows: last - offset), "offset \(offset)")
            last = offset
        }
        // Then the other way: ignored, as scrolling back always is.
        XCTAssertEqual(stitcher.add(frame(page, offset: 280, height: frameHeight)), .scrolledBack)
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: page.width, rows: page.slice(last, offsets[0] + frameHeight - last)))
    }

    func testScrollingUpKeepsHeaderAndFooterOnce() throws {
        let page = documentPage(width: 96, height: 900)
        let header = noisePage(width: 96, height: 14, seed: 3).rows
        let footer = noisePage(width: 96, height: 10, seed: 4).rows
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 500, height: 180, header: header, footer: footer))
        XCTAssertEqual(stitcher.add(frame(page, offset: 450, height: 180, header: header, footer: footer)), .appended(rows: 50))
        XCTAssertEqual(stitcher.add(frame(page, offset: 380, height: 180, header: header, footer: footer)), .appended(rows: 70))
        let middle = 180 - header.count - footer.count
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 96, rows: header + page.slice(380, 500 + middle - 380) + footer))
    }

    func testJumpWithNoOverlapIsSkippedAndKeepsReference() throws {
        let page = documentPage(width: 80, height: 900)
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 0, height: 150))
        // Scrolled a whole frame and more between grabs: nothing to match.
        XCTAssertEqual(stitcher.add(frame(page, offset: 400, height: 150)), .noMatch)
        XCTAssertEqual(stitcher.height, 150)
        // The user scrolls back into range: stitching carries on from the old frame.
        XCTAssertEqual(stitcher.add(frame(page, offset: 100, height: 150)), .appended(rows: 100))
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 80, rows: page.slice(0, 250)))
    }

    func testBlankRegionNeverMatches() {
        let blank = Pixels(width: 50, rows: Array(repeating: Array(repeating: UInt8(255), count: 200), count: 300))
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(blank, offset: 0, height: 100))
        // Identical blank frames read as no movement, never as a guess.
        XCTAssertEqual(stitcher.add(frame(blank, offset: 50, height: 100)), .unchanged)
        XCTAssertEqual(stitcher.height, 100)
    }

    func testUnrelatedContentDoesNotMatch() {
        let a = noisePage(width: 60, height: 200, seed: 1)
        let b = noisePage(width: 60, height: 200, seed: 2)
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(a, offset: 0, height: 120))
        XCTAssertEqual(stitcher.add(frame(b, offset: 0, height: 120)), .noMatch)
        XCTAssertEqual(stitcher.height, 120)
    }

    func testDifferentSizeFrameIsRejected() {
        let page = documentPage(width: 80, height: 400)
        let stitcher = ScrollingStitcher()
        stitcher.add(frame(page, offset: 0, height: 150))
        XCTAssertEqual(stitcher.add(frame(page, offset: 20, height: 140)), .sizeMismatch)
        XCTAssertEqual(stitcher.height, 150)
    }

    // MARK: Height cap

    func testHeightIsCapped() throws {
        let page = documentPage(width: 64, height: 900)
        let stitcher = ScrollingStitcher(maxHeight: 300)
        stitcher.add(frame(page, offset: 0, height: 150))
        XCTAssertEqual(stitcher.add(frame(page, offset: 100, height: 150)), .appended(rows: 100))
        XCTAssertEqual(stitcher.add(frame(page, offset: 200, height: 150)), .reachedLimit(rows: 50))
        XCTAssertTrue(stitcher.isAtLimit)
        XCTAssertEqual(stitcher.add(frame(page, offset: 260, height: 150)), .reachedLimit(rows: 0))
        XCTAssertEqual(stitcher.height, 300)
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result, Pixels(width: 64, rows: page.slice(0, 300)))
    }

    func testDefaultCapIsTwentyThousandPixels() {
        XCTAssertEqual(ScrollingStitcher().maxHeight, 20_000)
    }

    // MARK: Overlay scroll bar

    /// macOS fades a scroll bar in at the right edge while scrolling, at a different
    /// place in every frame. Ignoring that band keeps the frames matching.
    func testMovingScrollBarAtRightEdgeIsIgnoredForMatching() throws {
        let width = 120, frameHeight = 160, barWidth = 8
        let page = documentPage(width: width, height: 700)
        func barFrame(offset: Int) -> CGImage {
            var pixels = Pixels(width: width, rows: page.slice(offset, frameHeight))
            // Thumb position follows the scroll offset, as a real one does.
            let thumbTop = offset * (frameHeight - 40) / 700
            for row in thumbTop..<(thumbTop + 40) {
                for column in (width - barWidth - 2)..<(width - 2) {
                    pixels.rows[row].replaceSubrange((column * 4)..<(column * 4 + 4), with: [90, 90, 90, 255])
                }
            }
            return pixels.image()
        }
        let stitcher = ScrollingStitcher(ignoredTrailingColumns: 12)
        stitcher.add(barFrame(offset: 0))
        XCTAssertEqual(stitcher.add(barFrame(offset: 70)), .appended(rows: 70))
        XCTAssertEqual(stitcher.add(barFrame(offset: 150)), .appended(rows: 80))
        let result = Pixels.from(try XCTUnwrap(stitcher.makeImage()))
        XCTAssertEqual(result.height, 150 + frameHeight)
        // Content left of the bar is exactly the page.
        let contentBytes = (width - barWidth - 2) * 4
        for (index, row) in result.rows.enumerated() {
            XCTAssertEqual(Array(row[0..<contentBytes]), Array(page.rows[index][0..<contentBytes]), "row \(index)")
        }
    }

    // MARK: Capture geometry

    func testCaptureRectSnapsToPixelsAndClampsToScreen() throws {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = try XCTUnwrap(ScrollingCaptureGeometry.captureRect(
            for: NSRect(x: 10.3, y: -20, width: 200.6, height: 400.2), screenFrame: screen, scale: 2
        ))
        XCTAssertEqual(rect, NSRect(x: 10.5, y: 0, width: 200.0, height: 380.0))
        let pixels = ScrollingCaptureGeometry.pixelSize(for: rect, scale: 2)
        XCTAssertEqual(pixels.width, 400)
        XCTAssertEqual(pixels.height, 760)
        XCTAssertNil(ScrollingCaptureGeometry.captureRect(
            for: NSRect(x: 2000, y: 0, width: 100, height: 100), screenFrame: screen, scale: 2
        ))
    }

    func testSourceRectIsDisplayLocalTopLeft() {
        // Secondary display to the right of a 1440×900 primary, 1080 tall.
        let screen = NSRect(x: 1440, y: -180, width: 1920, height: 1080)
        let source = ScrollingCaptureGeometry.sourceRect(
            for: NSRect(x: 1540, y: 600, width: 300, height: 200), screenFrame: screen
        )
        XCTAssertEqual(source, CGRect(x: 100, y: 100, width: 300, height: 200))
    }

    func testControlsGoBelowThenAboveThenInside() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let size = NSSize(width: 260, height: 36)
        let below = ScrollingCaptureGeometry.controlOrigin(controlSize: size, region: NSRect(x: 400, y: 300, width: 400, height: 400), visibleFrame: visible)
        XCTAssertEqual(below, NSPoint(x: 470, y: 252))
        let above = ScrollingCaptureGeometry.controlOrigin(controlSize: size, region: NSRect(x: 400, y: 10, width: 400, height: 400), visibleFrame: visible)
        XCTAssertEqual(above, NSPoint(x: 470, y: 422))
        let inside = ScrollingCaptureGeometry.controlOrigin(controlSize: size, region: NSRect(x: 0, y: 0, width: 1440, height: 875), visibleFrame: visible)
        XCTAssertEqual(inside, NSPoint(x: 590, y: 12))
    }

    // MARK: Toolbar entry

    func testScrollingButtonOnlyOnRegionStep() throws {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let region = NSRect(x: 200, y: 200, width: 400, height: 300)
        let regionView = ScreenshotAnnotationView(frame: screenFrame, screenshot: nil, screenshotRect: region)
        let window = NSWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = regionView
        let button = try XCTUnwrap(scrollingButton(in: regionView) as? NSButton)
        XCTAssertEqual(button.toolTip, "Scrolling")
        XCTAssertNotNil(NSImage(systemSymbolName: "scroll", accessibilityDescription: nil))

        var requested: NSRect?
        regionView.onScrollingCaptureRequested = { requested = $0 }
        button.performClick(nil)
        XCTAssertEqual(requested, region)

        let image = NSImage(size: NSSize(width: 100, height: 100))
        let editorView = ScreenshotAnnotationView(frame: screenFrame, screenshot: image, screenshotRect: region)
        let editorWindow = NSWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        editorWindow.contentView = editorView
        XCTAssertNil(scrollingButton(in: editorView), "the editor for a finished image has nothing to scroll")
    }

    private func scrollingButton(in view: NSView) -> NSView? {
        if view.identifier == AnnotationToolbarChrome.Identifier.scrollingCaptureButton { return view }
        for subview in view.subviews {
            if let found = scrollingButton(in: subview) { return found }
        }
        return nil
    }
}
