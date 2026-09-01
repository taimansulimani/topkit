import AppKit
import CoreGraphics
import CoreVideo

/// Shared styling for subtitles, mirroring screenshot annotation text exactly:
/// the user's annotation font, a configurable fill colour, and the same white
/// outline (two passes: white stroke, then colour fill) — no background pill.
enum CaptionTextStyle {

    /// Same formula as ScreenshotAnnotationView's textOutlineStrokeWidth.
    static func outlineStrokeWidth(fontPointSize: CGFloat) -> CGFloat {
        max(3.0, fontPointSize * 0.38)
    }

    /// Visual outline extent beyond glyph edges (annotation formula).
    static func outlineExtent(fontPointSize: CGFloat) -> CGFloat {
        max(1.5, outlineStrokeWidth(fontPointSize: fontPointSize) * 0.55)
    }

    /// Subtitle fill colour components from preferences; default black,
    /// zero/unset alpha treated as opaque so subtitles can't vanish.
    static func fillColor(from defaults: UserDefaults = .standard) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let red = defaults.object(forKey: "subtitleColorRed") as? Double ?? 0
        let green = defaults.object(forKey: "subtitleColorGreen") as? Double ?? 0
        let blue = defaults.object(forKey: "subtitleColorBlue") as? Double ?? 0
        var alpha = defaults.object(forKey: "subtitleColorAlpha") as? Double ?? 1
        if alpha <= 0 { alpha = 1 }
        return (red, green, blue, alpha)
    }

    static func fillNSColor(from defaults: UserDefaults = .standard) -> NSColor {
        let c = fillColor(from: defaults)
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    /// The screenshot annotation font at the requested size.
    static func font(size: CGFloat) -> NSFont {
        let name = UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica"
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }

    static func fillAttributes(font: NSFont, fill: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: fill]
    }

    /// Two-pass outlined draw, identical to drawOutlinedAnnotationText:
    /// white stroke-only first (strokeWidth is a % of point size), fill on top.
    /// Requires a current NSGraphicsContext; `point` is the bounding box
    /// origin (bottom-left in an unflipped context).
    static func drawOutlined(_ text: String, font: NSFont, fill: NSColor, at point: NSPoint) {
        let strokePercent = (outlineStrokeWidth(fontPointSize: font.pointSize) / max(font.pointSize, 1)) * 100
        let strokeAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.white,
            .strokeWidth: strokePercent,
        ]
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            NSAttributedString(string: text, attributes: strokeAttrs).draw(at: point)
            NSAttributedString(string: text, attributes: fillAttributes(font: font, fill: fill)).draw(at: point)
            context.restoreGState()
        } else {
            NSAttributedString(string: text, attributes: strokeAttrs).draw(at: point)
            NSAttributedString(string: text, attributes: fillAttributes(font: font, fill: fill)).draw(at: point)
        }
    }

    static func size(of text: String, font: NSFont) -> CGSize {
        NSAttributedString(string: text, attributes: fillAttributes(font: font, fill: .black)).size()
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(max(1, font.ascender - font.descender)) + 2
    }
}

/// A rendered caption ready to composite: the image plus where it sits in the
/// video frame (pixel coords, CG bottom-left origin — which matches a
/// CGBitmapContext wrapped around the frame buffer).
struct CaptionBurnImage {
    let image: CGImage
    let rect: CGRect
}

/// Renders caption text as annotation-styled outlined lines, in video pixel
/// space. Main thread (cheap: only runs when the caption text changes).
enum CaptionBurnInRenderer {

    static func render(text: String, videoWidth: Int, videoHeight: Int) -> CaptionBurnImage? {
        let fontSize = CaptionRenderMetrics.fontSize(
            forPixelHeight: videoHeight,
            scale: CaptionRenderMetrics.userScale()
        )
        let maxChars = CaptionRenderMetrics.maxCharsPerLine(pixelWidth: videoWidth, fontSize: fontSize)
        let lines = CaptionLineLayout.tailLines(
            of: text,
            maxLines: CaptionRenderMetrics.maxLines,
            maxCharsPerLine: maxChars
        )
        guard !lines.isEmpty else { return nil }

        let font = CaptionTextStyle.font(size: fontSize)
        let fill = CaptionTextStyle.fillNSColor()
        let outlinePad = CaptionTextStyle.outlineExtent(fontPointSize: font.pointSize)
        let lineHeight = CaptionTextStyle.lineHeight(for: font)

        let lineSizes = lines.map { CaptionTextStyle.size(of: $0, font: font) }
        let textSize = CGSize(
            width: ceil(lineSizes.map(\.width).max() ?? 0) + outlinePad * 2,
            height: lineHeight * CGFloat(lines.count) + outlinePad * 2
        )
        let rect = CaptionRenderMetrics.captionRect(textSize: textSize, videoWidth: videoWidth, videoHeight: videoHeight)

        let pixelWidth = max(Int(ceil(rect.width)), 2)
        let pixelHeight = max(Int(ceil(rect.height)), 2)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        // Lines top-down, each centred; CG y grows upward.
        let blockOriginX = (CGFloat(pixelWidth) - textSize.width) / 2 + outlinePad
        let blockOriginY = (CGFloat(pixelHeight) - textSize.height) / 2 + outlinePad
        for (index, line) in lines.enumerated() {
            let x = blockOriginX + (textSize.width - outlinePad * 2 - lineSizes[index].width) / 2
            let y = blockOriginY + CGFloat(lines.count - 1 - index) * lineHeight
            CaptionTextStyle.drawOutlined(line, font: font, fill: fill, at: NSPoint(x: x, y: y))
        }

        guard let image = context.makeImage() else { return nil }
        return CaptionBurnImage(image: image, rect: rect)
    }
}

/// Copies a captured BGRA frame into a writable buffer and stamps the caption
/// onto it. Runs on the recorder's sample queue for every frame while a
/// caption is visible — pure memcpy + one small CG draw, no color conversion
/// of the base pixels.
enum CaptionPixelCompositor {

    static func copyAndBurn(source: CVPixelBuffer, into dest: CVPixelBuffer, caption: CaptionBurnImage) -> Bool {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(dest) == kCVPixelFormatType_32BGRA else { return false }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }

        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(dest) else { return false }

        let height = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(dest))
        let width = min(CVPixelBufferGetWidth(source), CVPixelBufferGetWidth(dest))
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(dest)
        let rowBytes = min(min(srcStride, dstStride), width * 4)

        if srcStride == dstStride {
            memcpy(dstBase, srcBase, srcStride * height)
        } else {
            for row in 0..<height {
                memcpy(dstBase + row * dstStride, srcBase + row * srcStride, rowBytes)
            }
        }

        guard let context = CGContext(
            data: dstBase,
            width: CVPixelBufferGetWidth(dest),
            height: CVPixelBufferGetHeight(dest),
            bitsPerComponent: 8,
            bytesPerRow: dstStride,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return true } // frame copied; worst case the caption is skipped

        context.draw(caption.image, in: caption.rect)
        return true
    }
}
