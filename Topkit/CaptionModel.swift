import Foundation
import CoreGraphics

/// Rolling dictation transcript for live captions: finalized text accumulates
/// (bounded to a tail), the volatile hypothesis is replaced on every partial.
struct CaptionTranscript {
    /// Upper bound on retained finalized text — captions only ever show the
    /// last couple of lines, so anything beyond this can be dropped.
    static let maxRetainedCharacters = 600

    private var finalized = ""
    private var volatile = ""

    var displayText: String {
        let joined = volatile.isEmpty ? finalized : (finalized.isEmpty ? volatile : finalized + " " + volatile)
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func updateVolatile(_ text: String) {
        volatile = text
    }

    mutating func appendFinal(_ text: String) {
        volatile = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finalized = finalized.isEmpty ? trimmed : finalized + " " + trimmed
        if finalized.count > Self.maxRetainedCharacters {
            finalized = String(finalized.suffix(Self.maxRetainedCharacters))
        }
    }

    mutating func clear() {
        finalized = ""
        volatile = ""
    }
}

/// Word-wrapping for caption lines. Pure string maths so the same layout
/// drives both the on-screen overlay and the burned-in render.
enum CaptionLineLayout {
    static func wrap(_ text: String, maxCharsPerLine: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty, maxCharsPerLine > 0 else { return [] }
        var lines: [String] = []
        var current = ""
        for word in words {
            var word = word
            // Hard-break words longer than a line.
            while word.count > maxCharsPerLine {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                lines.append(String(word.prefix(maxCharsPerLine)))
                word = String(word.dropFirst(maxCharsPerLine))
            }
            if word.isEmpty { continue }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= maxCharsPerLine {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// The last `maxLines` wrapped lines — captions show the tail of speech.
    static func tailLines(of text: String, maxLines: Int, maxCharsPerLine: Int) -> [String] {
        Array(wrap(text, maxCharsPerLine: maxCharsPerLine).suffix(maxLines))
    }
}

/// Geometry for the burned-in caption bar, in video pixel space.
enum CaptionRenderMetrics {
    static let maxLines = 2
    static let scaleDefaultsKey = "subtitleSizeScale"

    /// Preference multipliers offered in Settings (Small → Extra Large).
    static let sizeOptions: [(label: String, scale: Double)] = [
        ("Small", 0.75),
        ("Medium", 1.0),
        ("Large", 1.4),
        ("Extra Large", 2.0),
    ]

    /// User preference multiplier; garbage / missing values fall back to 1.
    static func userScale(from defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.double(forKey: scaleDefaultsKey)
        return value > 0 ? CGFloat(value) : 1.0
    }

    /// 3% of the video height, clamped so tiny/huge recordings stay legible.
    /// `scale` multiplies the base size; the ceiling grows with it so Large
    /// actually enlarges big recordings, while the floor never drops below 16.
    static func fontSize(forPixelHeight height: Int, scale: CGFloat = 1.0) -> CGFloat {
        let safeScale = scale > 0 ? scale : 1.0
        let raw = CGFloat(height) * 0.03 * safeScale
        return min(max(raw, 16), 72 * safeScale)
    }

    /// How many characters fit on one caption line: 90% of the width is
    /// usable, average glyph advance ~0.55 × font size.
    static func maxCharsPerLine(pixelWidth: Int, fontSize: CGFloat) -> Int {
        max(Int(CGFloat(pixelWidth) * 0.9 / (fontSize * 0.55)), 8)
    }

    /// Background pill rect for the rendered text block: bottom-centred with
    /// padding, sitting a font-relative margin above the bottom edge.
    static func captionRect(textSize: CGSize, videoWidth: Int, videoHeight: Int) -> CGRect {
        let padX = textSize.height * 0.25
        let padY = textSize.height * 0.12
        let width = textSize.width + padX * 2
        let height = textSize.height + padY * 2
        let bottomMargin = max(CGFloat(videoHeight) * 0.04, 12)
        return CGRect(
            x: (CGFloat(videoWidth) - width) / 2,
            y: bottomMargin,
            width: width,
            height: height
        )
    }
}
