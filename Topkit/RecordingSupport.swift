import Foundation
import CoreGraphics
import AVFoundation
import CoreMedia

/// Timestamped recording filenames with collision suffixes
/// (Recording_2026-07-16_14-03-09.mov, …_14-03-09_2.mov, …).
enum RecordingFilename {
    static func make(date: Date, isTaken: (String) -> Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "Recording_\(formatter.string(from: date))"
        var candidate = base + ".mov"
        var n = 2
        while isTaken(candidate) {
            candidate = "\(base)_\(n).mov"
            n += 1
        }
        return candidate
    }
}

/// Coordinate maths between Cocoa global rects (bottom-left origin) and
/// ScreenCaptureKit's display-local, top-left-origin point rects.
enum RecordingRegionMath {
    /// `SCStreamConfiguration.sourceRect`: points, relative to the display,
    /// origin at the display's TOP-left (Cocoa rects are bottom-left).
    static func sourceRect(selectionGlobal: CGRect, displayFrame: CGRect) -> CGRect {
        let localX = selectionGlobal.origin.x - displayFrame.origin.x
        let localBottomY = selectionGlobal.origin.y - displayFrame.origin.y
        let topLeftY = displayFrame.height - localBottomY - selectionGlobal.height
        return CGRect(x: localX, y: topLeftY, width: selectionGlobal.width, height: selectionGlobal.height)
    }

    /// Output size in pixels, rounded down to even values (H.264 encoders
    /// reject odd dimensions), floor 2.
    static func evenPixelSize(pointSize: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let w = max(Int(pointSize.width * scale) & ~1, 2)
        let h = max(Int(pointSize.height * scale) & ~1, 2)
        return (w, h)
    }

    /// One SCStream records one display, so the selection is clamped to the
    /// display it (mostly) lives on. Result is integral and at least
    /// `minSize` on each side, kept inside the display.
    static func clamped(selection: CGRect, toDisplay displayFrame: CGRect, minSize: CGFloat = 40) -> CGRect {
        var r = selection.intersection(displayFrame)
        if r.isNull { r = CGRect(x: displayFrame.midX, y: displayFrame.midY, width: 0, height: 0) }
        if r.width < minSize {
            r.size.width = minSize
            r.origin.x = min(r.origin.x, displayFrame.maxX - minSize)
            r.origin.x = max(r.origin.x, displayFrame.minX)
        }
        if r.height < minSize {
            r.size.height = minSize
            r.origin.y = min(r.origin.y, displayFrame.maxY - minSize)
            r.origin.y = max(r.origin.y, displayFrame.minY)
        }
        return r.integral
    }
}

/// H.264 output settings tuned for screen content: hardware encoder, small
/// files (SCK only delivers frames when pixels change), crisp UI text at a
/// bounded bitrate, no B-frames (realtime writer friendly).
enum RecordingEncoding {
    static let frameRate = 60

    /// Average bitrate: 0.06 bits per pixel per frame, clamped to 1.5–14 Mbps.
    static func averageBitRate(pixelWidth: Int, pixelHeight: Int, frameRate: Int = frameRate) -> Int {
        let raw = Double(pixelWidth) * Double(pixelHeight) * Double(frameRate) * 0.06
        return Int(min(max(raw, 1_500_000), 14_000_000))
    }

    /// AAC settings for the optional microphone track. Channels clamp to
    /// mono/stereo and the sample rate to the AAC-sane 44.1/48 kHz pair —
    /// whatever exotic format the input device reports, the written track
    /// stays small and universally playable.
    static func audioSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        let outChannels = min(max(channels, 1), 2)
        let outRate: Double = (sampleRate == 44_100) ? 44_100 : 48_000
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outRate,
            AVNumberOfChannelsKey: outChannels,
            AVEncoderBitRateKey: outChannels == 1 ? 96_000 : 128_000,
        ]
    }

    static func videoSettings(pixelWidth: Int, pixelHeight: Int, frameRate: Int = frameRate) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate(pixelWidth: pixelWidth, pixelHeight: pixelHeight, frameRate: frameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }
}

/// Converts AVPlayerView trim results into an export range.
/// After `beginTrimming` ends with .okButton, the chosen bounds live in the
/// player item's `reversePlaybackEndTime` (start) and `forwardPlaybackEndTime`
/// (end); `.invalid` means "untouched" (0 / duration). Returns nil when the
/// result is a no-op or invalid — callers skip the export.
enum TrimRange {
    static func resolve(start: CMTime, end: CMTime, duration: CMTime) -> CMTimeRange? {
        guard duration.isNumeric, duration > .zero else { return nil }
        let s = start.isNumeric ? max(start, .zero) : .zero
        let e = end.isNumeric ? min(end, duration) : duration
        guard e > s else { return nil }
        if s == .zero && e == duration { return nil }
        return CMTimeRange(start: s, end: e)
    }
}
