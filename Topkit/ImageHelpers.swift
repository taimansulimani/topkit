import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// High-quality, lossless image handling for clipboard, screenshots, and UI.
/// Uses full pixel resolution and PNG (no extra compression) so images stay Retina-sharp.
enum ImageHelpers {

    /// Returns PNG data at the image’s full pixel resolution (lossless, no resize).
    /// Prefer this over tiffRepresentation to avoid resolution/scale issues on Retina.
    /// Uses the highest-resolution representation so exported images stay sharp (e.g. 2x on Retina).
    static func pngData(from image: NSImage) -> Data? {
        // Prefer explicit bitmap rep with most pixels so we export at true Retina resolution
        if let bestRep = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }),
           bestRep.pixelsWide > 0, bestRep.pixelsHigh > 0 {
            return bestRep.representation(using: .png, properties: [:])
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// Prefer PNG from pasteboard when available for best quality; otherwise convert NSImage to PNG at full resolution.
    static func imageDataFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        let pngType = NSPasteboard.PasteboardType.png
        if pasteboard.availableType(from: [pngType]) != nil,
           let pngData = pasteboard.data(forType: pngType),
           !pngData.isEmpty {
            return pngData
        }
        guard let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else {
            return nil
        }
        return pngData(from: image)
    }

    /// Aspect-fill thumbnail decoded straight from encoded bytes (PNG/whatever) WITHOUT ever
    /// materialising the full-resolution bitmap. Uses ImageIO to read the pixel dimensions cheaply,
    /// then decodes a downsampled image just large enough to cover the target box. For a 20MP Retina
    /// screenshot this avoids the ~80MB full RGBA decode that `NSImage(data:)` would do — order-of-
    /// magnitude less CPU and memory per thumbnail. Falls back to nil if the data isn't decodable.
    static func aspectFillThumbnail(from data: Data, targetSize: NSSize, scale: CGFloat = 2.0) -> NSImage? {
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }

        let targetPixelW = targetSize.width * scale
        let targetPixelH = targetSize.height * scale

        // Read source pixel dimensions without decoding the image.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let srcW = (props?[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let srcH = (props?[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0

        // Longest edge to request: enough that an aspect-fill crop still covers the target box,
        // clamped so we never upscale during decode (small sources decode at full size).
        let maxPixelSize: Int
        if srcW > 0, srcH > 0 {
            let coverScale = min(max(targetPixelW / srcW, targetPixelH / srcH), 1.0)
            maxPixelSize = max(1, Int((max(srcW, srcH) * coverScale).rounded(.up)))
        } else {
            maxPixelSize = max(1, Int(max(targetPixelW, targetPixelH).rounded(.up)))
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let downsampled = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return aspectFillThumbnail(image: downsampled, targetSize: targetSize, scale: scale)
    }

    /// Aspect-FIT counterpart, decoded straight from encoded bytes the same way: the whole
    /// image scaled down to sit inside a `maxDimension` box, never upscaled. Hover previews
    /// use this — an aspect-fill crop of a wide screenshot shows the middle of it and little
    /// else, which is the opposite of what a preview is for.
    static func aspectFitThumbnail(from data: Data, maxDimension: CGFloat, scale: CGFloat = 2.0) -> NSImage? {
        guard maxDimension > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // ImageIO's own max-pixel-size IS an aspect fit, so the decode does the work.
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int((maxDimension * scale).rounded(.up)))
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        // Point size = pixels ÷ scale, but only where the decode actually downsampled: a
        // source smaller than the box comes back at its own size and must stay there.
        let pixelSize = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let longestEdge = max(pixelSize.width, pixelSize.height)
        let pointScale = longestEdge > maxDimension ? longestEdge / maxDimension : 1
        let size = NSSize(width: pixelSize.width / pointScale, height: pixelSize.height / pointScale)
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Thumbnail that fills target size (aspect fill) at 2x pixel density for Retina menus/previews.
    static func aspectFillThumbnail(image: NSImage, targetSize: NSSize, scale: CGFloat = 2.0) -> NSImage {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return image }

        let pixelW = max(1, Int(targetSize.width * scale))
        let pixelH = max(1, Int(targetSize.height * scale))
        let widthRatio = CGFloat(pixelW) / imageSize.width
        let heightRatio = CGFloat(pixelH) / imageSize.height
        let scaleFactor = max(widthRatio, heightRatio)
        let scaledW = imageSize.width * scaleFactor
        let scaledH = imageSize.height * scaleFactor
        let cropX = (scaledW - CGFloat(pixelW)) / 2
        let cropY = (scaledH - CGFloat(pixelH)) / 2

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixelW * 4,
            bitsPerPixel: 32
        ) else {
            let fallback = NSImage(size: targetSize)
            fallback.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(
                in: NSRect(x: -cropX, y: -cropY, width: scaledW, height: scaledH),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            fallback.unlockFocus()
            return fallback
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.shouldAntialias = true

        image.draw(
            in: NSRect(x: -cropX, y: -cropY, width: scaledW, height: scaledH),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: targetSize)
        rep.size = targetSize
        result.addRepresentation(rep)
        return result
    }
}
