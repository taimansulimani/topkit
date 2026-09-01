import XCTest
import CoreMedia
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class TrimRangeTests: XCTestCase {
    private let duration = CMTime(seconds: 10, preferredTimescale: 600)

    func testValidSubrange() {
        let r = TrimRange.resolve(
            start: CMTime(seconds: 2, preferredTimescale: 600),
            end: CMTime(seconds: 8, preferredTimescale: 600),
            duration: duration
        )
        XCTAssertEqual(r?.start.seconds, 2)
        XCTAssertEqual(r?.end.seconds, 8)
    }

    func testFullRangeIsNoOp() {
        // Trimming nothing → nil (skip the export entirely).
        let r = TrimRange.resolve(start: .zero, end: duration, duration: duration)
        XCTAssertNil(r)
    }

    func testInvalidTimesFallBackToBounds() {
        // AVPlayerItem defaults: reversePlaybackEndTime/forwardPlaybackEndTime
        // are .invalid when untouched → treat as 0 / duration → no-op.
        let r = TrimRange.resolve(start: .invalid, end: .invalid, duration: duration)
        XCTAssertNil(r)
    }

    func testStartOnlyTrim() {
        let r = TrimRange.resolve(
            start: CMTime(seconds: 3, preferredTimescale: 600),
            end: .invalid,
            duration: duration
        )
        XCTAssertEqual(r?.start.seconds, 3)
        XCTAssertEqual(r?.end.seconds, 10)
    }

    func testDegenerateRangeIsNil() {
        let t = CMTime(seconds: 5, preferredTimescale: 600)
        XCTAssertNil(TrimRange.resolve(start: t, end: t, duration: duration))
    }

    func testEndClampedToDuration() {
        let r = TrimRange.resolve(
            start: CMTime(seconds: 1, preferredTimescale: 600),
            end: CMTime(seconds: 99, preferredTimescale: 600),
            duration: duration
        )
        XCTAssertEqual(r?.end.seconds, 10)
    }

    func testInvalidDurationIsNil() {
        XCTAssertNil(TrimRange.resolve(start: .zero, end: .zero, duration: .invalid))
    }
}
