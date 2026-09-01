import XCTest
import AVFoundation
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class RecordingSupportTests: XCTestCase {

    // MARK: RecordingFilename

    func testFilenameFormat() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 16
        comps.hour = 14; comps.minute = 3; comps.second = 9
        let date = Calendar.current.date(from: comps)!
        let name = RecordingFilename.make(date: date, isTaken: { _ in false })
        XCTAssertEqual(name, "Recording_2026-07-16_14-03-09.mov")
    }

    func testFilenameCollisionAppendsSuffix() {
        let date = Date(timeIntervalSince1970: 0)
        var taken: Set<String> = []
        let first = RecordingFilename.make(date: date, isTaken: { taken.contains($0) })
        taken.insert(first)
        let second = RecordingFilename.make(date: date, isTaken: { taken.contains($0) })
        taken.insert(second)
        let third = RecordingFilename.make(date: date, isTaken: { taken.contains($0) })
        XCTAssertTrue(second.hasSuffix("_2.mov"))
        XCTAssertTrue(third.hasSuffix("_3.mov"))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(second, third)
    }

    // MARK: RecordingRegionMath.sourceRect (Cocoa global → display-local top-left origin)

    func testSourceRectOnPrimaryDisplay() {
        // Display 1920x1080 at origin (0,0). Selection 400x300 whose Cocoa
        // origin is (100, 200) → top-left-origin y = 1080 - 200 - 300 = 580.
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: 100, y: 200, width: 400, height: 300)
        let src = RecordingRegionMath.sourceRect(selectionGlobal: selection, displayFrame: display)
        XCTAssertEqual(src, CGRect(x: 100, y: 580, width: 400, height: 300))
    }

    func testSourceRectOnSecondaryDisplayWithNegativeOrigin() {
        // Secondary display to the left: origin (-1440, 0), 1440x900.
        // Selection at global (-1000, 100), 200x200 → local x = 440,
        // top-left y = 900 - 100 - 200 = 600.
        let display = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: -1000, y: 100, width: 200, height: 200)
        let src = RecordingRegionMath.sourceRect(selectionGlobal: selection, displayFrame: display)
        XCTAssertEqual(src, CGRect(x: 440, y: 600, width: 200, height: 200))
    }

    // MARK: RecordingRegionMath.evenPixelSize

    func testEvenPixelSizeRoundsDownToEven() {
        let s = RecordingRegionMath.evenPixelSize(pointSize: CGSize(width: 401.5, height: 303), scale: 2)
        XCTAssertEqual(s.width, 802)   // 803 → 802
        XCTAssertEqual(s.height, 606)
    }

    func testEvenPixelSizeNeverBelowTwo() {
        let s = RecordingRegionMath.evenPixelSize(pointSize: CGSize(width: 1, height: 0.4), scale: 1)
        XCTAssertEqual(s.width, 2)
        XCTAssertEqual(s.height, 2)
    }

    // MARK: RecordingRegionMath.clamped

    func testClampIntersectsWithDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 900, y: 700, width: 400, height: 400) // spills off top-right
        let r = RecordingRegionMath.clamped(selection: selection, toDisplay: display)
        XCTAssertEqual(r, CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    func testClampEnforcesMinimumSizeInsideDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 990, y: 790, width: 300, height: 300) // sliver
        let r = RecordingRegionMath.clamped(selection: selection, toDisplay: display, minSize: 40)
        XCTAssertEqual(r.width, 40)
        XCTAssertEqual(r.height, 40)
        XCTAssertTrue(display.contains(r))
    }

    func testClampReturnsIntegralRect() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 10.3, y: 20.7, width: 100.2, height: 50.6)
        let r = RecordingRegionMath.clamped(selection: selection, toDisplay: display)
        XCTAssertEqual(r, r.integral)
    }

    // MARK: RecordingEncoding

    func testBitrateClampsLow() {
        XCTAssertEqual(RecordingEncoding.averageBitRate(pixelWidth: 100, pixelHeight: 100, frameRate: 60), 1_500_000)
    }

    func testBitrateClampsHigh() {
        // Retina 5K full screen would want ~53 Mbps raw; cap keeps files small.
        XCTAssertEqual(RecordingEncoding.averageBitRate(pixelWidth: 5120, pixelHeight: 2880, frameRate: 60), 14_000_000)
    }

    func testBitrateMidRange() {
        // 1920*1080*60*0.06 = 7,464,960
        XCTAssertEqual(RecordingEncoding.averageBitRate(pixelWidth: 1920, pixelHeight: 1080, frameRate: 60), 7_464_960)
    }

    func testVideoSettingsShape() {
        let s = RecordingEncoding.videoSettings(pixelWidth: 800, pixelHeight: 600)
        XCTAssertEqual(s[AVVideoWidthKey] as? Int, 800)
        XCTAssertEqual(s[AVVideoHeightKey] as? Int, 600)
        XCTAssertEqual(s[AVVideoCodecKey] as? AVVideoCodecType, .h264)
        let props = s[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertNotNil(props?[AVVideoAverageBitRateKey])
        XCTAssertEqual(props?[AVVideoMaxKeyFrameIntervalKey] as? Int, 120)
        XCTAssertEqual(props?[AVVideoAllowFrameReorderingKey] as? Bool, false)
    }
}
