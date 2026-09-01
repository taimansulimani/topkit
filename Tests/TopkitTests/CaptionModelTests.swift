import XCTest
import AVFoundation
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class CaptionModelTests: XCTestCase {

    // MARK: CaptionTranscript (finalized + volatile merge)

    func testDisplayTextMergesFinalizedAndVolatile() {
        var t = CaptionTranscript()
        t.appendFinal("Hello world.")
        t.updateVolatile("this is")
        XCTAssertEqual(t.displayText, "Hello world. this is")
    }

    func testDisplayTextVolatileOnly() {
        var t = CaptionTranscript()
        t.updateVolatile("typing away")
        XCTAssertEqual(t.displayText, "typing away")
    }

    func testFinalReplacesVolatile() {
        var t = CaptionTranscript()
        t.updateVolatile("hello wor")
        t.appendFinal("Hello world.")
        XCTAssertEqual(t.displayText, "Hello world.")
    }

    func testFinalizedTailIsBounded() {
        var t = CaptionTranscript()
        for i in 0..<200 {
            t.appendFinal("sentence number \(i) is here.")
        }
        // Finalized text must not grow without bound; only a tail is kept.
        XCTAssertLessThanOrEqual(t.displayText.count, CaptionTranscript.maxRetainedCharacters)
        XCTAssertTrue(t.displayText.hasSuffix("sentence number 199 is here."))
    }

    func testEmptyTranscriptIsEmpty() {
        let t = CaptionTranscript()
        XCTAssertEqual(t.displayText, "")
    }

    // MARK: CaptionLineLayout.wrap

    func testWrapShortLineUnchanged() {
        XCTAssertEqual(CaptionLineLayout.wrap("hello world", maxCharsPerLine: 20), ["hello world"])
    }

    func testWrapBreaksOnWordBoundaries() {
        let lines = CaptionLineLayout.wrap("the quick brown fox jumps", maxCharsPerLine: 10)
        XCTAssertEqual(lines, ["the quick", "brown fox", "jumps"])
    }

    func testWrapHardBreaksOverlongWord() {
        let lines = CaptionLineLayout.wrap("abcdefghijkl", maxCharsPerLine: 5)
        XCTAssertEqual(lines, ["abcde", "fghij", "kl"])
    }

    func testWrapEmptyStringGivesNoLines() {
        XCTAssertEqual(CaptionLineLayout.wrap("", maxCharsPerLine: 10), [])
        XCTAssertEqual(CaptionLineLayout.wrap("   ", maxCharsPerLine: 10), [])
    }

    // MARK: CaptionLineLayout.tailLines (what the caption bar shows)

    func testTailLinesReturnsLastLines() {
        let lines = CaptionLineLayout.tailLines(
            of: "one two three four five six seven eight",
            maxLines: 2,
            maxCharsPerLine: 10
        )
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last, "eight")
    }

    func testTailLinesShorterTextReturnsAll() {
        let lines = CaptionLineLayout.tailLines(of: "hi there", maxLines: 2, maxCharsPerLine: 20)
        XCTAssertEqual(lines, ["hi there"])
    }

    // MARK: CaptionRenderMetrics (burn-in geometry, pixel space)

    func testFontSizeScalesWithVideoHeightAndClamps() {
        // 3% of height, clamped to [16, 72] at the default size.
        XCTAssertEqual(CaptionRenderMetrics.fontSize(forPixelHeight: 1000), 30)
        XCTAssertEqual(CaptionRenderMetrics.fontSize(forPixelHeight: 100), 16)
        XCTAssertEqual(CaptionRenderMetrics.fontSize(forPixelHeight: 10000), 72)
    }

    func testFontSizeHonoursUserScale() {
        // The preference multiplies the base size; the ceiling scales with it
        // so "large" actually enlarges big recordings too, the floor never
        // drops below legibility.
        XCTAssertEqual(CaptionRenderMetrics.fontSize(forPixelHeight: 1000, scale: 2.0), 60)
        XCTAssertEqual(CaptionRenderMetrics.fontSize(forPixelHeight: 1000, scale: 0.75), 22.5, accuracy: 0.01)
        XCTAssertEqual(CaptionRenderMetrics.fontSize(forPixelHeight: 100, scale: 0.5), 16)
        XCTAssertEqual(CaptionRenderMetrics.fontSize(forPixelHeight: 10000, scale: 1.4), 72 * 1.4, accuracy: 0.01)
        // Garbage scale never breaks rendering.
        XCTAssertEqual(CaptionRenderMetrics.fontSize(forPixelHeight: 1000, scale: 0), 30)
        XCTAssertEqual(CaptionRenderMetrics.fontSize(forPixelHeight: 1000, scale: -3), 30)
    }

    func testStoredSubtitleScaleIsReadWithSaneFallback() {
        let defaults = UserDefaults(suiteName: "CaptionSizeTests")!
        defaults.removePersistentDomain(forName: "CaptionSizeTests")
        XCTAssertEqual(CaptionRenderMetrics.userScale(from: defaults), 1.0)
        defaults.set(1.4, forKey: "subtitleSizeScale")
        XCTAssertEqual(CaptionRenderMetrics.userScale(from: defaults), 1.4)
        defaults.set(-2.0, forKey: "subtitleSizeScale")
        XCTAssertEqual(CaptionRenderMetrics.userScale(from: defaults), 1.0)
        defaults.removePersistentDomain(forName: "CaptionSizeTests")
    }

    func testCaptionLingerIsShort() {
        // Subtitles must clear promptly once speech stops (user feedback:
        // 4s felt sticky).
        XCTAssertLessThanOrEqual(CaptionSession.lingerSeconds, 2.0)
        XCTAssertGreaterThan(CaptionSession.lingerSeconds, 0.5)
    }

    func testMaxCharsPerLineFitsWidth() {
        let chars = CaptionRenderMetrics.maxCharsPerLine(pixelWidth: 1920, fontSize: 30)
        // Average glyph ~0.55 * fontSize, with 90% of width usable.
        XCTAssertGreaterThan(chars, 60)
        XCTAssertLessThan(chars, 130)
        // Never degenerate for tiny recordings.
        XCTAssertGreaterThanOrEqual(CaptionRenderMetrics.maxCharsPerLine(pixelWidth: 40, fontSize: 16), 8)
    }

    func testCaptionRectCenteredAtBottom() {
        let rect = CaptionRenderMetrics.captionRect(
            textSize: CGSize(width: 400, height: 80),
            videoWidth: 1920,
            videoHeight: 1080
        )
        // Horizontally centred (allowing for padding), above the bottom margin.
        XCTAssertEqual(rect.midX, 960, accuracy: 1)
        XCTAssertGreaterThan(rect.minY, 0)
        XCTAssertLessThan(rect.maxY, 1080 / 2)
        XCTAssertGreaterThanOrEqual(rect.width, 400)
        XCTAssertGreaterThanOrEqual(rect.height, 80)
    }

    // MARK: CaptionTextStyle (matches screenshot annotation text styling)

    func testOutlineStrokeWidthMatchesAnnotationFormula() {
        // Screenshot annotations use max(3.0, pointSize * 0.38).
        XCTAssertEqual(CaptionTextStyle.outlineStrokeWidth(fontPointSize: 40), 15.2, accuracy: 0.001)
        XCTAssertEqual(CaptionTextStyle.outlineStrokeWidth(fontPointSize: 5), 3.0)
    }

    func testFillColorDefaultsToBlackAndReadsStoredComponents() {
        let defaults = UserDefaults(suiteName: "CaptionTextStyleTests")!
        defaults.removePersistentDomain(forName: "CaptionTextStyleTests")
        let fallback = CaptionTextStyle.fillColor(from: defaults)
        XCTAssertEqual(fallback.red, 0)
        XCTAssertEqual(fallback.green, 0)
        XCTAssertEqual(fallback.blue, 0)
        XCTAssertEqual(fallback.alpha, 1)

        defaults.set(0.2, forKey: "subtitleColorRed")
        defaults.set(0.4, forKey: "subtitleColorGreen")
        defaults.set(0.6, forKey: "subtitleColorBlue")
        defaults.set(0.8, forKey: "subtitleColorAlpha")
        let stored = CaptionTextStyle.fillColor(from: defaults)
        XCTAssertEqual(stored.red, 0.2, accuracy: 0.001)
        XCTAssertEqual(stored.green, 0.4, accuracy: 0.001)
        XCTAssertEqual(stored.blue, 0.6, accuracy: 0.001)
        XCTAssertEqual(stored.alpha, 0.8, accuracy: 0.001)
        defaults.removePersistentDomain(forName: "CaptionTextStyleTests")
    }

    func testFillColorZeroAlphaFallsBackToOpaque() {
        let defaults = UserDefaults(suiteName: "CaptionTextStyleTests")!
        defaults.removePersistentDomain(forName: "CaptionTextStyleTests")
        defaults.set(1.0, forKey: "subtitleColorRed")
        defaults.set(0.0, forKey: "subtitleColorAlpha")
        XCTAssertEqual(CaptionTextStyle.fillColor(from: defaults).alpha, 1.0)
        defaults.removePersistentDomain(forName: "CaptionTextStyleTests")
    }

    // MARK: RecordingEncoding.audioSettings

    func testAudioSettingsAreAAC() {
        let s = RecordingEncoding.audioSettings(sampleRate: 48_000, channels: 1)
        XCTAssertEqual(s[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(s[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(s[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(s[AVEncoderBitRateKey] as? Int, 96_000)
    }

    func testAudioSettingsClampChannelsAndSampleRate() {
        // 5-channel interface mic → clamp to stereo; absurd sample rate → 48k.
        let s = RecordingEncoding.audioSettings(sampleRate: 192_000, channels: 5)
        XCTAssertEqual(s[AVNumberOfChannelsKey] as? Int, 2)
        XCTAssertEqual(s[AVSampleRateKey] as? Double, 48_000)
        // Stereo gets a higher bitrate than mono.
        XCTAssertEqual(s[AVEncoderBitRateKey] as? Int, 128_000)
        // Zero/garbage channel counts never produce an invalid track.
        let mono = RecordingEncoding.audioSettings(sampleRate: 0, channels: 0)
        XCTAssertEqual(mono[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(mono[AVSampleRateKey] as? Double, 48_000)
    }
}
