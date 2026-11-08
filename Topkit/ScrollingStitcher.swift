import Accelerate
import CoreGraphics
import Foundation

/// Stitches frames of one screen region, captured while the user scrolls the content
/// under it, into a single tall image (TEC-246: "you scroll, it stitches").
///
/// Pure and synchronous: feed frames in capture order with `add(_:)`, read the result
/// with `makeImage()`. Not thread-safe; the capture session drives it from one queue.
///
/// How a new frame is placed against the previous one:
/// 1. Rows that sit unchanged at the same position at the top (a sticky header, a
///    toolbar) and at the bottom (a sticky footer) of both frames are set aside; only
///    the band between them is matched.
/// 2. The new frame's band is slid over the previous frame's band; the vertical offset
///    whose overlapping rows agree best wins, if enough of them agree. A run of
///    disagreeing rows at the very top or bottom of the overlap is set aside first:
///    a translucent sticky bar (a blurred toolbar, a frosted site header) shows the
///    content scrolling under it, so its rows neither stay put nor move with the page.
///    A bar at the bottom is then treated like the sticky footer.
///    Only the parts of each row that moved are compared: anything that stays put
///    while the content scrolls (a sidebar, a second pane next to the one being
///    scrolled, a floating composer or button over it) is left out, so it cannot
///    stop the match.
/// 3. Only the rows that offset reveals at the bottom are appended. The header stays
///    once at the top (it came with the first frame); the footer is taken from the
///    latest frame and drawn once at the very bottom.
///
/// The image is cropped to the columns that scrolled (plus any blank margin next to
/// them), so a pane or sidebar that never moved is not repeated down the page.
///
/// Either way works: when the content first moves down (going up a chat feed, which
/// opens at the bottom), the capture starts over upside down, so the same steps
/// stitch it, and the image is turned back the right way up at the end. After that,
/// going the other way, no movement, and frames with no reliable match are ignored,
/// and the previous frame is kept as the reference, so carrying on picks up again.
final class ScrollingStitcher {

    enum Outcome: Equatable {
        /// The first frame: the image starts as this frame.
        case started
        /// The frame scrolled further on; this many new rows were added.
        case appended(rows: Int)
        /// Nothing scrolled (or only a thin band changed in place). Not stitched.
        case unchanged
        /// The content moved back the way it came. Ignored.
        case scrolledBack
        /// No offset matched reliably (scrolled too far between frames, the region
        /// is blank, or the content changed). Ignored.
        case noMatch
        /// The frame is a different size from the first one. Ignored.
        case sizeMismatch
        /// The height cap was reached; `rows` were added before it. Every later frame
        /// returns this with 0 rows.
        case reachedLimit(rows: Int)
    }

    /// Pixel height the stitched image never exceeds.
    let maxHeight: Int

    /// Right-hand columns left out of matching (still drawn). macOS overlay scroll
    /// bars fade in there while scrolling and move with every frame.
    let ignoredTrailingColumns: Int

    /// Height in pixels of the image `makeImage()` would return now.
    var height: Int { bodyRowCount + footerRowCount }

    /// Pixel width of every frame (0 before the first one).
    private(set) var width = 0

    private(set) var isAtLimit = false

    // MARK: Tuning

    /// Columns are averaged into this many bins per row for matching: cheap, and
    /// tolerant of tiny rendering differences.
    private static let maxBins = 128
    /// A bin differs when its mean luma (×4) moves by more than this.
    private static let binTolerance: Int16 = 4
    /// A row and where it moved to agree when their bins differ by at most this on
    /// average (2 levels, ×4). Apps redraw text that moved with slightly different
    /// shading: single bins in Claude, on a real trackpad, were up to 8 levels off,
    /// so a per-bin limit failed every grab after the first slow scroll, but the
    /// average stays under 1 level at the right offset and is 3 or more one row off.
    private static let meanMatchTolerance = 8
    /// A row still matches with this many differing bins: macOS overlay scroll bars
    /// fade in over the right edge while scrolling, and a blinking caret is narrow.
    private static let allowedDifferingBins = 2
    /// Share of overlapping rows allowed to disagree for an offset to be accepted.
    private static let maxMismatchRatio = 0.25
    /// Most of the overlap a translucent sticky bar at its top or bottom may take.
    private static let maxBarShare = 0.25
    /// Share of the overlap that may disagree or sit under bars, both counted: a
    /// weak match squeezed between two big "bars" (grabs that do not overlap at all
    /// on a dark, sparse page reached 0.67) would leave a wrong seam, worse than a
    /// skipped grab. Real frosted bars stay under 0.58.
    private static let maxShareWithBars = 0.6
    /// A row needs at least this many bins that moved to count as evidence.
    private static let minComparedBins = 3

    // MARK: State

    private var colorSpace: CGColorSpace?
    /// RGBA rows of everything above the footer, top to bottom.
    private var body: [UInt8] = []
    private var bodyRowCount = 0
    /// Bottom rows of `previous` that are drawn after the body (the sticky footer).
    private var footerRowCount = 0
    private var previous: Frame?
    /// Bins where content scrolled in some placement: the scrolling area's columns.
    private var scrolledBins: ClosedRange<Int>?
    /// Bins where anything at all moved in some placement.
    private var movedBins: [Bool] = []
    /// Rows of the latest frame that were page content (not header or footer).
    private var lastBand: Range<Int>?
    /// Going up the page: every frame is matched upside down, and the image is
    /// turned back at the end.
    private var scrollsUp = false
    /// Set once the first rows are added: the direction never changes after that.
    private var directionKnown = false
    /// Until then, the frame the next one is matched against, so the capture can
    /// start over upside down from it.
    private var referenceImage: CGImage?

    init(maxHeight: Int = 20_000, ignoredTrailingColumns: Int = 0) {
        self.maxHeight = max(1, maxHeight)
        self.ignoredTrailingColumns = max(0, ignoredTrailingColumns)
    }

    // MARK: Adding frames

    @discardableResult
    func add(_ image: CGImage) -> Outcome {
        let outcome = addOriented(image)
        guard !directionKnown else { return outcome }
        switch outcome {
        case .started, .unchanged:
            referenceImage = image
        case .appended, .reachedLimit:
            directionKnown = true
            referenceImage = nil
        case .scrolledBack:
            // The content moved down first: the user is going up the page. Start
            // over upside down from the reference, then place this frame again.
            guard let reference = referenceImage else { return outcome }
            restartUpsideDown()
            addOriented(reference)
            return addOriented(image)
        default:
            break
        }
        return outcome
    }

    private func restartUpsideDown() {
        colorSpace = nil
        body = []
        bodyRowCount = 0
        footerRowCount = 0
        previous = nil
        scrolledBins = nil
        movedBins = []
        lastBand = nil
        width = 0
        isAtLimit = false
        scrollsUp = true
        directionKnown = true
        referenceImage = nil
    }

    @discardableResult
    private func addOriented(_ image: CGImage) -> Outcome {
        if isAtLimit { return .reachedLimit(rows: 0) }
        guard let previous else {
            let space = Self.rgbColorSpace(of: image)
            guard let frame = Frame(image: image, colorSpace: space, ignoredTrailingColumns: ignoredTrailingColumns, upsideDown: scrollsUp) else {
                return .sizeMismatch
            }
            colorSpace = space
            width = frame.width
            let rows = min(frame.height, maxHeight)
            body = Array(frame.pixels[0..<(rows * frame.bytesPerRow)])
            bodyRowCount = rows
            footerRowCount = 0
            self.previous = frame
            if rows < frame.height {
                isAtLimit = true
                return .reachedLimit(rows: rows)
            }
            return .started
        }
        guard image.width == previous.width, image.height == previous.height,
              let frame = Frame(
                image: image,
                colorSpace: colorSpace ?? Self.rgbColorSpace(of: image),
                ignoredTrailingColumns: ignoredTrailingColumns,
                upsideDown: scrollsUp
              ) else {
            return .sizeMismatch
        }
        return place(frame, after: previous)
    }

    private func place(_ new: Frame, after old: Frame) -> Outcome {
        let rows = new.height
        // 1. Static bands at the top and bottom.
        var header = 0
        while header < rows, Self.rowsMatch(old, header, new, header) { header += 1 }
        if header == rows { return .unchanged }
        var staticFooter = 0
        while staticFooter < rows - header,
              Self.rowsMatch(old, rows - 1 - staticFooter, new, rows - 1 - staticFooter) {
            staticFooter += 1
        }
        let moving = rows - header - staticFooter
        // Only a thin band changed (a spinner, a ticking timer, new text) and the
        // rest stood still: it changed in place, nothing scrolled. The new frame
        // becomes the reference, or every later grab would be compared against the
        // stale one and fail too.
        let changedInPlace = moving * 4 <= rows
        let minOverlap = max(8, moving / 10)
        guard moving > minOverlap else { return changedInPlace ? keepInPlace(new) : .noMatch }

        // A blank band can match at any offset: there is nothing to go on.
        if (header + 1 ..< header + moving).allSatisfy({ Self.rowsMatch(new, header, new, $0) }) {
            return changedInPlace ? keepInPlace(new) : .noMatch
        }

        // 2. Best offset. Positive: content moved up (scrolled down) by `dy` rows.
        let still = Self.stillCells(old, new)
        let movedRows = Self.movedRowCounts(still: still, bins: new.bins, top: header, moving: moving)
        let scrolling = Self.scrollingColumns(movedRows: movedRows, moving: moving)
        guard let (dy, bottomBar) = Self.bestOffset(old: old, new: new, still: still, scrolling: scrolling, movedRows: movedRows, top: header, moving: moving, minOverlap: minOverlap) else {
            return changedInPlace ? keepInPlace(new) : .noMatch
        }
        if dy == 0 { return keepInPlace(new) }
        if dy < 0 { return .scrolledBack }
        // A translucent bar at the bottom is drawn once, from the latest frame, like
        // the static footer: its rows are not page content.
        var footer = staticFooter + bottomBar
        // A frosted bar blurs what passes under it, so on a move smaller than the bar
        // its rows still look like they match: keep the bar measured on bigger moves.
        if footer < footerRowCount, dy < footerRowCount - footer, rows - footerRowCount - dy > header {
            footer = footerRowCount
        }
        let active = noteScrolledBins(movedRows: movedRows, moving: moving)
        // Something floating over the content near the bottom (a composer, a button
        // bar) with content scrolling past under it: everything from it down, and the
        // faded rows just above it, is drawn once from the latest frame. Only rows
        // that have come out above it are page content.
        if let (floating, floatingHeight) = Self.floatingBand(new, old: old, dy: dy, still: still, active: active, top: header + moving / 2, bottom: rows - staticFooter) {
            // The fade fades out upwards, so its top rows can still agree here and
            // there: it ends after 16 agreeing rows in a row. Its faint top can pass
            // for content, so at least the control's own height (or an eighth of the
            // band) above it is left out too: those rows reach the image anyway, as
            // they scroll up, from a later frame.
            var fadeTop = min(floating, floating - max(floatingHeight, moving / 8) + 1)
            var agreeingRun = 0
            let cap = Int(Double(moving) * Self.maxBarShare)
            var row = floating - 1
            while floating - row <= cap, row > header, row + dy < rows, agreeingRun < 16 {
                switch Self.compareMoving(old, row + dy, new, row, still: still, scrolling: scrolling) {
                case .disagree:
                    fadeTop = min(fadeTop, row)
                    agreeingRun = 0
                case .agree:
                    agreeingRun += 1
                case .none:
                    break
                }
                row -= 1
            }
            // Identical lines repeat on some pages ("Ran 2 commands ›" down a chat),
            // and one can land at the same height in both grabs. A "control" that
            // would leave nothing to add is taken for one of those and ignored: at
            // worst a real one is drawn twice, never a capture that stops.
            if rows - max(footer, rows - fadeTop) - dy > header {
                footer = max(footer, rows - fadeTop)
            }
        }
        guard rows - footer - dy > header else { return .noMatch }
        lastBand = header..<(rows - footer)

        // 3. Re-anchor the body to end where the new footer starts in `old`, then
        // append the rows the scroll revealed.
        if footer > footerRowCount {
            // Rows that were body in the last placement are footer now.
            let drop = footer - footerRowCount
            bodyRowCount -= drop
            body.removeLast(drop * old.bytesPerRow)
        } else if footer < footerRowCount {
            appendRows(of: old, from: rows - footerRowCount, to: rows - footer)
        }
        footerRowCount = footer

        let start = rows - footer - dy
        previous = new
        if bodyRowCount + dy + footer <= maxHeight {
            appendRows(of: new, from: start, to: rows - footer)
            return .appended(rows: dy)
        }
        // Cap reached: fill to exactly `maxHeight` with the frame's rows in order and
        // drop the footer, so the image never jumps from mid-page to the footer.
        let before = height
        let fill = min(dy + footer, max(0, maxHeight - bodyRowCount))
        appendRows(of: new, from: start, to: start + fill)
        footerRowCount = 0
        isAtLimit = true
        return .reachedLimit(rows: max(0, height - before))
    }

    /// Nothing scrolled: `new` replaces the reference (and the footer drawn from
    /// it), so small changes in place never add up to a failed match.
    private func keepInPlace(_ new: Frame) -> Outcome {
        previous = new
        return .unchanged
    }

    /// Widens `scrolledBins` to every bin where at least a tenth of the band moved
    /// this time (a spinner or a ticking timer elsewhere moves far less) and returns
    /// those bins.
    private func noteScrolledBins(movedRows: [Int], moving: Int) -> [Int] {
        let needed = max(4, moving / 10)
        let bins = movedRows.count
        var first: Int?
        var last: Int?
        if movedBins.count != bins { movedBins = [Bool](repeating: false, count: bins) }
        var active: [Int] = []
        for bin in 0..<bins {
            let count = movedRows[bin]
            if count >= 2 { movedBins[bin] = true }
            if count >= needed {
                active.append(bin)
                if first == nil { first = bin }
                last = bin
            }
        }
        guard let first, let last else { return active }
        if let current = scrolledBins {
            scrolledBins = min(current.lowerBound, first)...max(current.upperBound, last)
        } else {
            scrolledBins = first...last
        }
        return active
    }

    /// Top row and height of the lowest band (8+ rows, between `top` and `bottom`)
    /// that stood still across the scrolling columns and has something drawn in it:
    /// a control floating over the content. Nil when there is none.
    ///
    /// A band that also matches the old frame `dy` rows further down moved with the
    /// page: it is content that happens to look the same at that height (the same
    /// line twice on the page, as far apart as the scroll), not a control.
    private static func floatingBand(_ frame: Frame, old: Frame, dy: Int, still: [Bool], active: [Int], top: Int, bottom: Int) -> (top: Int, height: Int)? {
        guard active.count >= minComparedBins, bottom > top else { return nil }
        let bins = frame.bins
        func isStill(_ row: Int) -> Bool {
            var moved = 0
            for bin in active where !still[row * bins + bin] {
                moved += 1
                if moved > allowedDifferingBins { return false }
            }
            return true
        }
        func hasContent(_ row: Int) -> Bool {
            var low = Int16.max, high = Int16.min
            for bin in active {
                let v = frame.signature[row * bins + bin]
                low = min(low, v)
                high = max(high, v)
            }
            return Int(high) - Int(low) > Int(binTolerance) * 2
        }
        // A control is drawn the same pixel for pixel in both frames; different text
        // can share a row's bin averages, never its pixels.
        let columns = (frame.binEdges[active.first ?? 0] * 4)..<(frame.binEdges[(active.last ?? 0) + 1] * 4)
        // Only rows with something drawn count: blank rows match anywhere.
        func samePixels(_ rows: ClosedRange<Int>) -> Bool {
            var same = 0
            var drawnRows = 0
            for row in rows where hasContent(row) {
                drawnRows += 1
                let base = row * frame.bytesPerRow
                var differing = 0
                var index = columns.lowerBound
                while index < columns.upperBound {
                    let d = Int(frame.pixels[base + index]) - Int(old.pixels[base + index])
                    if d > 8 || d < -8 { differing += 1 }
                    index += 1
                }
                if differing * 50 <= columns.count { same += 1 }
            }
            return drawnRows >= 4 && same * 10 >= drawnRows * 9
        }
        func movedWithPage(_ rows: ClosedRange<Int>) -> Bool {
            var comparable = 0
            var agreeing = 0
            for row in rows where row + dy < frame.height {
                comparable += 1
                var total = 0
                for bin in active {
                    total += abs(Int(old.signature[(row + dy) * bins + bin]) - Int(frame.signature[row * bins + bin]))
                }
                if total <= active.count * meanMatchTolerance { agreeing += 1 }
            }
            return comparable > 0 && agreeing * 2 > comparable
        }
        var row = bottom - 1
        while row >= top {
            guard isStill(row) else { row -= 1; continue }
            var runTop = row
            var drawn = hasContent(row)
            while runTop - 1 >= top, isStill(runTop - 1) {
                runTop -= 1
                if !drawn { drawn = hasContent(runTop) }
            }
            if row - runTop + 1 >= 8, drawn, !movedWithPage(runTop...row), samePixels(runTop...row) { return (runTop, row - runTop + 1) }
            row = runTop - 1
        }
        return nil
    }

    /// Pixel columns kept in the image: the scrolled bins, widened over every bin
    /// next to them that moved at all or is blank (a margin, a divider), up to where
    /// something that stood still with content in it begins (a sidebar, another
    /// pane). Every column when nothing narrower is known.
    private func keptColumns(of frame: Frame) -> Range<Int> {
        guard let scrolledBins, movedBins.count == frame.bins else { return 0..<frame.width }
        let band = lastBand ?? 0..<frame.height
        // Blank bins are kept while the background stays the same: a divider or a
        // pane with another colour ends the margin.
        func widen(from edge: Int, step: Int) -> Int {
            var bin = edge
            var background: Int16?
            while bin + step >= 0, bin + step < frame.bins {
                let next = bin + step
                if movedBins[next] {
                    background = nil
                } else if let value = frame.blankValue(ofBin: next, rows: band),
                          background.map({ abs(Int($0) - Int(value)) <= Int(Self.binTolerance) }) ?? true {
                    background = value
                } else {
                    break
                }
                bin = next
            }
            return bin
        }
        let lower = widen(from: scrolledBins.lowerBound, step: -1)
        let upper = widen(from: scrolledBins.upperBound, step: 1)
        let start = lower == 0 ? 0 : frame.binEdges[lower]
        // The last bin carries the ignored trailing columns (the scroll bar band).
        let end = upper == frame.bins - 1 ? frame.width : frame.binEdges[upper + 1]
        return start..<end
    }

    private func appendRows(of frame: Frame, from start: Int, to end: Int) {
        guard end > start else { return }
        body.append(contentsOf: frame.pixels[(start * frame.bytesPerRow)..<(end * frame.bytesPerRow)])
        bodyRowCount += end - start
    }

    // MARK: Output

    /// The stitched image at full resolution, in the frames' colour space.
    func makeImage() -> CGImage? {
        guard let previous, width > 0, height > 0 else { return nil }
        var pixels = body
        let footerStart = (previous.height - footerRowCount) * previous.bytesPerRow
        pixels.append(contentsOf: previous.pixels[footerStart..<(previous.height * previous.bytesPerRow)])
        let columns = keptColumns(of: previous)
        let bytesPerRow = columns.count * 4
        if columns.count < width {
            var cropped = [UInt8]()
            cropped.reserveCapacity(bytesPerRow * height)
            for row in 0..<height {
                let base = row * previous.bytesPerRow
                cropped.append(contentsOf: pixels[(base + columns.lowerBound * 4)..<(base + columns.upperBound * 4)])
            }
            pixels = cropped
        }
        if scrollsUp {
            // Matched upside down: turn it back the right way up.
            var turned = [UInt8]()
            turned.reserveCapacity(pixels.count)
            for row in stride(from: height - 1, through: 0, by: -1) {
                turned.append(contentsOf: pixels[(row * bytesPerRow)..<((row + 1) * bytesPerRow)])
            }
            pixels = turned
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: columns.count,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: Frame.bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: Matching

    /// Offsets worth checking row by row, best first: the band's per-row brightness
    /// (over the columns that moved) is slid over the old band's, and the offsets
    /// where the two profiles line up closest win, with their neighbours. Cheap:
    /// one number per row, so every offset is tried.
    private static func likelyOffsets(old: Frame, new: Frame, movedRows: [Int], top: Int, moving: Int, maxShift: Int) -> [Int] {
        guard maxShift >= 1 else { return [] }
        let bins = old.bins
        let needed = max(4, moving / 10)
        var active = (0..<bins).filter { movedRows[$0] >= needed }
        if active.count < minComparedBins { active = Array(0..<bins) }
        func profile(_ frame: Frame) -> [Int32] {
            var result = [Int32](repeating: 0, count: moving)
            frame.signature.withUnsafeBufferPointer { sig in
                active.withUnsafeBufferPointer { act in
                    for index in 0..<moving {
                        let base = (top + index) * bins
                        var sum: Int32 = 0
                        for bin in act { sum += Int32(sig[base + bin]) }
                        result[index] = sum * 16 / Int32(act.count)
                    }
                }
            }
            return result
        }
        let oldProfile = profile(old)
        let newProfile = profile(new)
        // Mean clipped difference per overlapping row, for every offset.
        var scored: [(dy: Int, score: Double)] = []
        scored.reserveCapacity(maxShift * 2)
        oldProfile.withUnsafeBufferPointer { po in
            newProfile.withUnsafeBufferPointer { pn in
                for dy in -maxShift...maxShift where dy != 0 {
                    let overlap = moving - abs(dy)
                    let newStart = dy >= 0 ? 0 : -dy
                    let oldStart = dy >= 0 ? dy : 0
                    var total: Int32 = 0
                    var index = 0
                    while index < overlap {
                        let d = pn[newStart + index] - po[oldStart + index]
                        total += min(d < 0 ? -d : d, 256)
                        index += 1
                    }
                    scored.append((dy, Double(total) / Double(overlap)))
                }
            }
        }
        // Only the bottom of each dip, so the shortlist holds different places, not
        // one place and its neighbours: when the best-looking dip is wrong (a short
        // overlap on a mostly blank page), the real one is still checked.
        var dips: [(dy: Int, score: Double)] = []
        for (index, entry) in scored.enumerated() {
            let before = index > 0 && scored[index - 1].dy == entry.dy - 1 ? scored[index - 1].score : .infinity
            let after = index + 1 < scored.count && scored[index + 1].dy == entry.dy + 1 ? scored[index + 1].score : .infinity
            if entry.score <= before && entry.score <= after { dips.append(entry) }
        }
        dips.sort { $0.score < $1.score || ($0.score == $1.score && abs($0.dy) < abs($1.dy)) }
        var result: [Int] = []
        for (dy, _) in dips.prefix(8) {
            for n in [dy, dy - 1, dy + 1] where n != 0 && abs(n) <= maxShift && !result.contains(n) {
                result.append(n)
            }
        }
        return result
    }

    /// Per bin, how many rows of the band moved.
    private static func movedRowCounts(still: [Bool], bins: Int, top: Int, moving: Int) -> [Int] {
        var counts = [Int](repeating: 0, count: bins)
        still.withUnsafeBufferPointer { st in
            counts.withUnsafeMutableBufferPointer { out in
                var row = top
                while row < top + moving {
                    let base = row * bins
                    var bin = 0
                    while bin < bins {
                        if !st[base + bin] { out[bin] += 1 }
                        bin += 1
                    }
                    row += 1
                }
            }
        }
        return counts
    }

    /// Cells (row × bin) that look the same at the same place in both frames: what
    /// stood still (a sidebar, another pane, a floating composer) and blank areas.
    /// Neither says anything about where the content went.
    private static func stillCells(_ old: Frame, _ new: Frame) -> [Bool] {
        var still = [Bool](repeating: false, count: old.signature.count)
        old.signature.withUnsafeBufferPointer { a in
            new.signature.withUnsafeBufferPointer { b in
                still.withUnsafeMutableBufferPointer { out in
                    var i = 0
                    while i < out.count {
                        let d = a[i] &- b[i]
                        out[i] = d <= binTolerance && d >= -binTolerance
                        i += 1
                    }
                }
            }
        }
        return still
    }

    private enum RowEvidence { case agree, disagree, none }

    /// Columns where a tenth of the band moved (all of them if too few did): the
    /// scrolling content, not a pane or sidebar that stood still beside it.
    private static func scrollingColumns(movedRows: [Int], moving: Int) -> [Bool] {
        let needed = max(4, moving / 10)
        let mask = movedRows.map { $0 >= needed }
        return mask.filter { $0 }.count >= minComparedBins ? mask : [Bool](repeating: true, count: movedRows.count)
    }

    /// Compares two rows over the scrolling columns by their average difference:
    /// apps redraw text that moved with slightly different shading, so single spots
    /// can be well off while the row as a whole matches. A big difference where
    /// either side stood still (a pane, a composer floating over the content) is set
    /// aside. A row with nothing drawn in it is no evidence either way.
    private static func compareMoving(_ old: Frame, _ oldRow: Int, _ new: Frame, _ newRow: Int, still: [Bool], scrolling: [Bool]) -> RowEvidence {
        let bins = old.bins
        let baseOld = oldRow * bins
        let baseNew = newRow * bins
        var compared = 0
        var total = 0
        var low = Int.max
        var high = Int.min
        still.withUnsafeBufferPointer { st in
            old.signature.withUnsafeBufferPointer { so in
                new.signature.withUnsafeBufferPointer { sn in
                    scrolling.withUnsafeBufferPointer { sc in
                        var i = 0
                        while i < bins {
                            if sc[i] {
                                let a = Int(so[baseOld + i])
                                let d = abs(a - Int(sn[baseNew + i]))
                                if !(d > meanMatchTolerance * 2 && (st[baseOld + i] || st[baseNew + i])) {
                                    compared += 1
                                    total += d
                                    low = min(low, a)
                                    high = max(high, a)
                                }
                            }
                            i += 1
                        }
                    }
                }
            }
        }
        guard compared >= minComparedBins, high - low > Int(binTolerance) * 2 else { return .none }
        return total <= compared * meanMatchTolerance ? .agree : .disagree
    }

    /// The offset (new band row i ↔ old band row i + dy) whose overlap agrees best,
    /// or nil when none agrees well enough, plus how many rows at the bottom of the
    /// overlap were set aside as a translucent bar. Ties go to the smaller movement.
    ///
    /// Rows are compared only where they moved (see `stillCells`); rows with nothing
    /// that moved are no evidence either way. For each offset, a run of disagreeing
    /// rows at the very top and at the very bottom of the overlap (each at most
    /// `maxBarShare` of it) is set aside, and the rows between must agree within
    /// `maxMismatchRatio`. Offsets are ranked by all disagreeing rows, set-aside ones
    /// included, so the true offset (only the bars disagree) beats a wrong one.
    /// Offset 0 (nothing scrolled, something small changed) compares whole rows.
    private static func bestOffset(old: Frame, new: Frame, still: [Bool], scrolling: [Bool], movedRows: [Int], top: Int, moving: Int, minOverlap: Int) -> (dy: Int, bottomBar: Int)? {
        let maxShift = moving - minOverlap
        var best: (dy: Int, bottomBar: Int, ratio: Double, agreeing: Int)?
        // Nothing moved first, then only the few offsets the row profiles point at:
        // checking every offset row by row took 0.4 s a frame optimised and over
        // 30 s in a Debug build, so grabs fell seconds apart and none overlapped.
        let candidates = [0] + likelyOffsets(old: old, new: new, movedRows: movedRows, top: top, moving: moving, maxShift: maxShift)
        let minEvidence = max(4, minOverlap / 2)
        for dy in candidates {
            let overlap = moving - abs(dy)
            func evidence(_ index: Int) -> RowEvidence {
                let newRow = top + (dy >= 0 ? index : index - dy)
                let oldRow = top + (dy >= 0 ? index + dy : index)
                if dy == 0 { return rowsMatch(old, oldRow, new, newRow) ? .agree : .disagree }
                return compareMoving(old, oldRow, new, newRow, still: still, scrolling: scrolling)
            }
            let barCap = Int(Double(overlap) * maxBarShare)
            // A bar runs to the first agreeing row, through blank rows too (no
            // evidence either way); only its disagreeing rows count against the cap.
            func bar(_ row: (Int) -> Int) -> (length: Int, disagreeing: Int)? {
                var length = 0
                var disagreeing = 0
                while length < overlap / 2 {
                    switch evidence(row(length)) {
                    case .agree: return (length, disagreeing)
                    case .disagree: disagreeing += 1
                    case .none: break
                    }
                    if disagreeing >= barCap && barCap > 0 { return nil }
                    length += 1
                }
                return barCap > 0 ? nil : (length, disagreeing)
            }
            guard let (topBar, topBarEvidence) = bar({ $0 }),
                  let (bottomBar, bottomBarEvidence) = bar({ overlap - 1 - $0 }) else { continue }
            let barRows = topBarEvidence + bottomBarEvidence
            guard overlap - topBar - bottomBar >= minOverlap else { continue }
            var agreeing = 0
            var disagreeing = 0
            let bestRatio = best?.ratio ?? 1
            var index = topBar
            var hopeless = false
            while index < overlap - bottomBar {
                switch evidence(index) {
                case .agree: agreeing += 1
                case .disagree:
                    disagreeing += 1
                    // Already worse than allowed for the most rows this offset can still get.
                    let ceiling = agreeing + disagreeing + (overlap - bottomBar - index - 1)
                    if Double(disagreeing) > Double(ceiling) * maxMismatchRatio { hopeless = true }
                case .none: break
                }
                if hopeless { break }
                index += 1
            }
            if hopeless { continue }
            let counted = agreeing + disagreeing
            guard counted >= minEvidence,
                  Double(disagreeing) <= Double(counted) * maxMismatchRatio else { continue }
            let ratio = Double(disagreeing + barRows) / Double(counted + barRows)
            guard ratio <= maxShareWithBars else { continue }
            // Equally clean: the offset with more rows agreeing wins (a short overlap
            // on a mostly blank page agrees too easily).
            if let best, ratio > bestRatio || (ratio == bestRatio && agreeing <= best.agreeing) { continue }
            best = (dy, bottomBar, ratio, agreeing)
            // Clean and well supported: no other offset can beat it.
            if disagreeing + barRows == 0 && agreeing * 2 >= overlap { break }
        }
        return best.map { ($0.dy, $0.bottomBar) }
    }

    private static func rowsMatch(_ a: Frame, _ rowA: Int, _ b: Frame, _ rowB: Int) -> Bool {
        let bins = a.bins
        let baseA = rowA * bins
        let baseB = rowB * bins
        var differing = 0
        return a.signature.withUnsafeBufferPointer { sa in
            b.signature.withUnsafeBufferPointer { sb in
                for i in 0..<bins {
                    let d = sa[baseA + i] &- sb[baseB + i]
                    if d > binTolerance || d < -binTolerance {
                        differing += 1
                        if differing > allowedDifferingBins { return false }
                    }
                }
                return true
            }
        }
    }

    private static func rgbColorSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    // MARK: Frame

    /// One frame as RGBA bytes plus a per-row signature for matching.
    private struct Frame {
        static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)

        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixels: [UInt8]
        let bins: Int
        /// Pixel column where each bin starts, plus the end of the last one.
        let binEdges: [Int]
        /// `height × bins` mean luma values, ×4 for sub-level precision.
        let signature: [Int16]

        /// The bin's value when it is the same all the way down `rows` (a blank
        /// margin, a divider), else nil (it has content). Nil outside the frame.
        func blankValue(ofBin bin: Int, rows: Range<Int>) -> Int16? {
            guard bin >= 0, bin < bins, !rows.isEmpty else { return nil }
            let first = signature[rows.lowerBound * bins + bin]
            for row in rows.dropFirst() {
                let d = signature[row * bins + bin] &- first
                if d > ScrollingStitcher.binTolerance || d < -ScrollingStitcher.binTolerance { return nil }
            }
            return first
        }

        init?(image: CGImage, colorSpace: CGColorSpace, ignoredTrailingColumns: Int, upsideDown: Bool = false) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }
            let bytesPerRow = width * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
            let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: Frame.bitmapInfo.rawValue
                ) else { return false }
                context.interpolationQuality = .none
                if upsideDown {
                    // Whole-pixel flip: exact, rows simply in reverse order.
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }

            // Never ignore so much that nothing is left to match on.
            let matchedWidth = ignoredTrailingColumns < width / 2 ? width - ignoredTrailingColumns : width
            let bins = min(ScrollingStitcher.maxBins, matchedWidth)
            var signature = [Int16](repeating: 0, count: bins * height)
            // Bin edges once, shared by every row.
            let edges = (0...bins).map { $0 * matchedWidth / bins }
            // Luma per pixel, then the mean of each bin, with Accelerate: a plain loop
            // over every pixel cost ~0.2 s a frame in a Debug build.
            let count = width * height
            var luma = [Float](repeating: 0, count: count)
            var channel = [Float](repeating: 0, count: count)
            pixels.withUnsafeBufferPointer { px in
                guard let base = px.baseAddress else { return }
                for (offset, weight) in [(0, Float(77)), (1, Float(150)), (2, Float(29))] {
                    var w = weight
                    vDSP_vfltu8(base + offset, 4, &channel, 1, vDSP_Length(count))
                    vDSP_vsma(channel, 1, &w, luma, 1, &luma, 1, vDSP_Length(count))
                }
            }
            luma.withUnsafeBufferPointer { lp in
                guard let base = lp.baseAddress else { return }
                signature.withUnsafeMutableBufferPointer { sig in
                    for row in 0..<height {
                        let rowBase = row * width
                        for bin in 0..<bins {
                            let start = edges[bin], end = edges[bin + 1]
                            var sum: Float = 0
                            vDSP_sve(base + rowBase + start, 1, &sum, vDSP_Length(end - start))
                            // (sum / 256) is luma 0…255; ×4 keeps a quarter-level of detail.
                            sig[row * bins + bin] = Int16(Int(sum) * 4 / (256 * max(1, end - start)))
                        }
                    }
                }
            }
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
            self.pixels = pixels
            self.bins = bins
            self.binEdges = edges
            self.signature = signature
        }
    }
}
