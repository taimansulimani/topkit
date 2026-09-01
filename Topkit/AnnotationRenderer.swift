import AppKit
import CoreGraphics
import Foundation

/// Stateless rendering of annotations into a CGContext.
///
/// Both the on-screen path (`ScreenshotAnnotationView.draw`) and the export path
/// (`ScreenshotAnnotationView.renderAnnotations`) go through here, so the two can
/// no longer drift apart.
enum AnnotationRenderer {

    /// Mosaic cell size, in points, for redaction.
    private static let mosaicBlockPoints: CGFloat = 9

    /// Bounding frame for a text annotation, derived from the rendered content.
    /// Only the origin of the stored frame is authoritative; the size is recomputed so a
    /// stale stored height cannot leave a gap on screen or displace the text on export.
    static func textFrame(for annotation: Annotation) -> NSRect {
        guard case .text = annotation.type,
              let text = annotation.text,
              !text.isEmpty,
              let fontSize = annotation.fontSize else {
            return annotation.frame
        }
        return textAnnotationFrame(text: text, fontSize: fontSize, topLeft: annotation.frame.origin)
    }

    static func textAnnotationFrame(text: String, fontSize: CGFloat, topLeft: NSPoint) -> NSRect {
        let fontName = UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica"
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let outlineExtent = AnnotationRenderer.textOutlineExtent(for: font)
        let verticalPad = AnnotationRenderer.textVerticalPad(for: font)
        let fillAttrs = AnnotationRenderer.textFillAttributes(font: font, color: .labelColor)
        let attributedString = NSAttributedString(string: text.isEmpty ? " " : text, attributes: fillAttrs)
        let textBounds = attributedString.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        let measuredTextWidth = ceil(textBounds.width)
        let measuredTextHeight = ceil(textBounds.height)
        let w = max(textAnnotationMinWidth, measuredTextWidth + textAnnotationPadding + outlineExtent * 2)
        let h = max(AnnotationRenderer.textContentLineHeight(for: font), measuredTextHeight) + verticalPad * 2
        return NSRect(x: topLeft.x, y: topLeft.y, width: w, height: h)
    }

    static func textOutlineStrokeWidth(for font: NSFont) -> CGFloat {
        max(textOutlineMinWidth, font.pointSize * 0.38)
    }

    /// Visual outline grows roughly half the configured stroke width beyond glyph edges.
    static func textOutlineExtent(for font: NSFont) -> CGFloat {
        max(1.5, textOutlineStrokeWidth(for: font) * 0.55)
    }

    /// Vertical glyph padding needed for outlined text; smaller than horizontal stroke width
    /// to avoid oversized selection boxes after editing.
    static func textVerticalPad(for font: NSFont) -> CGFloat {
        max(1.5, textOutlineExtent(for: font) * 0.65)
    }

    static func textFillAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    /// Tight content line height for this font.
    static func textContentLineHeight(for font: NSFont) -> CGFloat {
        ceil(max(1, font.ascender - font.descender))
    }

    /// Computes a text drawing rect centered vertically inside the annotation frame.
    static func centeredTextRect(in annotationFrame: NSRect, text: String, font: NSFont, color: NSColor) -> NSRect {
        let fillAttrs = textFillAttributes(font: font, color: color)
        let outlineExtent = textOutlineExtent(for: font)
        let verticalPad = textVerticalPad(for: font)
        let wrapW = max(1, annotationFrame.width - textAnnotationPadding - outlineExtent * 2)
        let measuredTextHeight = ceil(
            NSAttributedString(string: text, attributes: fillAttrs).boundingRect(
                with: NSSize(width: wrapW, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            ).height
        )
        let contentHeight = max(textContentLineHeight(for: font), measuredTextHeight) + verticalPad * 2
        let verticalInset = max(0, (annotationFrame.height - contentHeight) / 2)
        // Optical centering: outlined glyphs can read slightly top-heavy when mathematically centered.
        // Shift down a bit using descender magnitude so perceived center matches selection box center.
        let baselineBias = max(0, ceil(abs(font.descender) * 0.35))
        return NSRect(
            x: annotationFrame.origin.x,
            // Annotation geometry uses top-left style coordinates (Y grows downward),
            // so centering means moving the text origin down by the inset amount.
            y: annotationFrame.origin.y + verticalInset + baselineBias,
            width: annotationFrame.width,
            height: min(annotationFrame.height, contentHeight)
        )
    }

    /// Draw label text in two passes: white stroke-only first, then color fill on top.
    static func drawOutlinedAnnotationText(_ text: String, font: NSFont, fillColor: NSColor, in textRect: NSRect) {
        let strokeW = textOutlineStrokeWidth(for: font)
        // NSStrokeWidthAttributeName is a percentage of font point size.
        // Positive value draws stroke only.
        let strokePercent = (strokeW / max(font.pointSize, 1)) * 100
        let strokeAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.white,
            .strokeWidth: strokePercent
        ]
        let strokeOnly = NSAttributedString(string: text, attributes: strokeAttrs)
        let fillOnly = NSAttributedString(string: text, attributes: textFillAttributes(font: font, color: fillColor))
        guard let context = NSGraphicsContext.current?.cgContext else {
            strokeOnly.draw(in: textRect)
            fillOnly.draw(in: textRect)
            return
        }
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        strokeOnly.draw(in: textRect)
        fillOnly.draw(in: textRect)
        context.restoreGState()
    }

    static func drawStickerPointer(direction: StickerPointerDirection, stickerFrame: NSRect, color: NSColor, in context: CGContext) {
        let (dx, dy) = direction.unitVector
        let halfW = stickerFrame.width / 2
        let halfH = stickerFrame.height / 2
        let midX = stickerFrame.midX
        let midY = stickerFrame.midY
        // t = distance from center to rect edge in direction (dx, dy)
        let t: CGFloat
        if abs(dx) < 0.001 { t = halfH / max(0.001, abs(dy)) }
        else if abs(dy) < 0.001 { t = halfW / max(0.001, abs(dx)) }
        else { t = min(halfW / abs(dx), halfH / abs(dy)) }
        let startX = midX + t * dx
        let startY = midY + t * dy
        let arrowLength: CGFloat = 16
        let tipX = startX + arrowLength * dx
        let tipY = startY + arrowLength * dy
        let headLength: CGFloat = 6
        let headAngle: CGFloat = .pi / 6
        let angle = atan2(dy, dx)
        let back1 = NSPoint(x: tipX - headLength * cos(angle - headAngle), y: tipY - headLength * sin(angle - headAngle))
        let back2 = NSPoint(x: tipX - headLength * cos(angle + headAngle), y: tipY - headLength * sin(angle + headAngle))
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.move(to: NSPoint(x: startX, y: startY))
        context.addLine(to: NSPoint(x: tipX, y: tipY))
        context.strokePath()
        context.move(to: NSPoint(x: tipX, y: tipY))
        context.addLine(to: back1)
        context.addLine(to: back2)
        context.closePath()
        context.fillPath()
    }

    static func bakedMosaic(of source: NSImage, sourceRect: NSRect, outSize: NSSize) -> NSImage? {
        guard outSize.width >= 1, outSize.height >= 1,
              let full = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pxW = CGFloat(full.width)
        let pxH = CGFloat(full.height)
        let sx = pxW / max(1, source.size.width)
        let sy = pxH / max(1, source.size.height)
        // CGImage cropping uses a top-left origin, y increasing downward.
        var crop = CGRect(x: sourceRect.minX * sx, y: sourceRect.minY * sy,
                          width: sourceRect.width * sx, height: sourceRect.height * sy).integral
        crop = crop.intersection(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        guard crop.width >= 1, crop.height >= 1, let region = full.cropping(to: crop) else { return nil }

        let cols = max(1, Int((outSize.width / mosaicBlockPoints).rounded()))
        let rows = max(1, Int((outSize.height / mosaicBlockPoints).rounded()))

        // 1) Downsample (averaging) to cols×rows.
        guard let smallRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: cols, pixelsHigh: rows,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: smallRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: region, size: NSSize(width: crop.width, height: crop.height))
            .draw(in: NSRect(x: 0, y: 0, width: cols, height: rows))
        NSGraphicsContext.restoreGraphicsState()
        guard let smallCG = smallRep.cgImage else { return nil }

        // 2) Upscale with NO interpolation to bake solid blocks.
        let outScale: CGFloat = 2
        let outPxW = max(1, Int((outSize.width * outScale).rounded()))
        let outPxH = max(1, Int((outSize.height * outScale).rounded()))
        guard let outRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: outPxW, pixelsHigh: outPxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outRep)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: smallCG, size: NSSize(width: cols, height: rows))
            .draw(in: NSRect(x: 0, y: 0, width: outPxW, height: outPxH))
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: outSize)
        outRep.size = outSize
        result.addRepresentation(outRep)
        return result
    }

    /// Draw a redaction annotation. Draws the baked mosaic if available; otherwise a solid
    /// dark fill so sensitive pixels are never left visible. Context is Y-flipped (annotation space).
    static func drawRedaction(_ annotation: Annotation, mosaic: NSImage?, in context: CGContext) {
        let frame = annotation.frame
        context.saveGState()
        if let mosaic = mosaic {
            context.translateBy(x: frame.midX, y: frame.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -frame.midX, y: -frame.midY)
            let g = NSGraphicsContext.current
            let prev = g?.imageInterpolation
            g?.imageInterpolation = .none
            mosaic.draw(in: frame, from: .zero, operation: .copy, fraction: 1.0)
            if let prev { g?.imageInterpolation = prev }
        } else {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(frame)
        }
        context.restoreGState()
    }

    /// Draw a numbered badge: a filled disc in the annotation colour, a white ring, and the
    /// number centred in white. Context is Y-flipped (annotation space), so the glyph is unflipped.
    static func drawNumberBadge(_ annotation: Annotation, in context: CGContext) {
        let frame = annotation.frame
        guard frame.width >= 1, frame.height >= 1 else { return }
        let number = annotation.badgeNumber ?? 1

        context.saveGState()
        if annotation.colorMode == .rainbow {
            context.saveGState()
            context.addEllipse(in: frame)
            context.clip()
            context.drawLinearGradient(rainbowGradient(),
                                       start: CGPoint(x: frame.minX, y: frame.midY),
                                       end: CGPoint(x: frame.maxX, y: frame.midY),
                                       options: [])
            context.restoreGState()
        } else {
            context.setFillColor(annotation.color.cgColor)
            context.fillEllipse(in: frame)
        }
        let ringWidth = max(1.5, frame.width * 0.06)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(ringWidth)
        context.strokeEllipse(in: frame.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
        context.restoreGState()

        let text = "\(number)"
        let fontSize = max(8, frame.height * 0.55)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let astr = NSAttributedString(string: text, attributes: attrs)
        let textSize = astr.size()
        let textRect = NSRect(
            x: frame.midX - textSize.width / 2,
            y: frame.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        context.saveGState()
        context.translateBy(x: textRect.midX, y: textRect.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -textRect.midX, y: -textRect.midY)
        astr.draw(in: textRect)
        context.restoreGState()
    }
}

extension AnnotationRenderer {
    /// The two behaviours that differ between the on-screen and export render paths.
    struct Context {
        /// Frame to render a text annotation into. On screen this recomputes from the
        /// current text and font so a stale stored height cannot leave a gap.
        var textFrame: (Annotation) -> NSRect = { AnnotationRenderer.textFrame(for: $0) }

        /// Frame to render a guide into. Guides are infinite alignment lines: only the
        /// perpendicular position is meaningful, so the caller supplies the canvas they
        /// should span (and clips the result). Defaults to the stored frame.
        var guideFrame: (Annotation) -> NSRect = { $0.frame }

        /// True while this text annotation is being edited inline, in which case the raw
        /// frame is used as-is rather than being re-centred.
        var isInlineEditing: (Annotation) -> Bool = { _ in false }

        /// Pixels to pixelate for a redaction, or nil to fall back to a solid fill.
        var mosaic: (Annotation) -> NSImage? = { _ in nil }

        /// Grid dimension readouts are an on-canvas editing affordance, like a
        /// selection handle: shown on screen, left out of the exported image. Off by
        /// default, so `export` omits them without having to say so.
        var showsGridLabels = false

        /// The grid dimension currently being typed into. Its label is suppressed
        /// because the inline field is drawing over that spot.
        var editingGridLabel: (Annotation) -> GridLabel? = { _ in nil }

        static let export = Context()
    }

    static func draw(_ annotation: Annotation, in context: CGContext, using ctx: Context) {
        context.saveGState()
        // Opacity applies to the whole mark. Redaction keeps 1.0 (a translucent
        // mosaic would leak the pixels it hides).
        context.setAlpha(annotation.opacity)
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.thickness)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.type {
        case .freehand:
            if let points = annotation.pathPoints, points.count >= 2 {
                if annotation.colorMode == .rainbow {
                    strokeRainbowPath(points, in: context)
                } else {
                    context.move(to: points[0])
                    for i in 1..<points.count {
                        context.addLine(to: points[i])
                    }
                    context.strokePath()
                }
            }
        case .rectangle:
            if annotation.colorMode == .rainbow {
                strokeRainbowPath(rectanglePolyline(annotation.frame), in: context)
            } else {
                context.stroke(annotation.frame)
            }
        case .circle:
            if annotation.colorMode == .rainbow {
                strokeRainbowPath(ellipsePolyline(annotation.frame), in: context)
            } else {
                context.strokeEllipse(in: annotation.frame)
            }
        case .arrow:
            if let start = annotation.startPoint, let end = annotation.endPoint {
                // Draw arrow line, but stop before the arrowhead
                let angle = atan2(end.y - start.y, end.x - start.x)
                // Arrow length scales with thickness
                let arrowLength: CGFloat = max(15, annotation.thickness * 2.5)
                let arrowAngle: CGFloat = .pi / 6
                
                // Calculate where line should end (before arrowhead)
                let lineEnd = NSPoint(
                    x: end.x - arrowLength * cos(angle),
                    y: end.y - arrowLength * sin(angle)
                )

                if annotation.colorMode == .rainbow {
                    strokeRainbowPath([start, lineEnd], in: context)
                } else {
                    context.move(to: start)
                    context.addLine(to: lineEnd)
                    context.strokePath()
                }

                // Draw arrowhead
                let arrowPoint1 = NSPoint(
                    x: end.x - arrowLength * cos(angle - arrowAngle),
                    y: end.y - arrowLength * sin(angle - arrowAngle)
                )
                let arrowPoint2 = NSPoint(
                    x: end.x - arrowLength * cos(angle + arrowAngle),
                    y: end.y - arrowLength * sin(angle + arrowAngle)
                )

                // Match the head to the tip end of the gradient so it does not read
                // as a stray solid cap on a rainbow arrow.
                if annotation.colorMode == .rainbow {
                    context.setFillColor(rainbowColor(at: 1).cgColor)
                }
                context.move(to: end)
                context.addLine(to: arrowPoint1)
                context.addLine(to: arrowPoint2)
                context.closePath()
                context.fillPath()
            }
        case .text:
            if let text = annotation.text, !text.isEmpty, let fontSize = annotation.fontSize {
                let fontName = UserDefaults.standard.string(forKey: "screenshotAnnotationFont") ?? "Helvetica"
                let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
                let renderFrame = ctx.textFrame(annotation)
                let textRect: NSRect
                if ctx.isInlineEditing(annotation) {
                    textRect = renderFrame
                } else {
                    textRect = centeredTextRect(in: renderFrame, text: text, font: font, color: annotation.color)
                }
                // Draw text right-side up: context is Y-flipped, so unflip for text only.
                context.saveGState()
                context.translateBy(x: textRect.midX, y: textRect.midY)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: -textRect.midX, y: -textRect.midY)
                if annotation.colorMode == .rainbow,
                   let image = rainbowTextImage(text, font: font, size: textRect.size) {
                    // Same local flip as the sticker image path, which is proven to
                    // draw an upright-baked image the right way up in this context.
                    image.draw(in: textRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                } else {
                    drawOutlinedAnnotationText(text, font: font, fillColor: annotation.color, in: textRect)
                }
                context.restoreGState()
            }
        case .sticker(let stickerType):
            let iconName: String
            let stickerColor: NSColor
            switch stickerType {
            case .redX:
                iconName = "xmark.circle.fill"
                stickerColor = .systemRed
            case .greenCheck:
                iconName = "checkmark.circle.fill"
                stickerColor = .systemGreen
            case .yellowExclamation:
                iconName = "exclamationmark.triangle.fill"
                stickerColor = .systemYellow
            }
            
            // Draw sticker using lockFocus for reliable image creation
            if let iconImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: annotation.frame.height * 0.8, weight: .bold)
                if let configuredIcon = iconImage.withSymbolConfiguration(config) {
                    let drawRect = annotation.frame
                    let iconSize = drawRect.size
                    
                    // Create tinted icon using lockFocus (more reliable)
                    let tintedIcon = NSImage(size: iconSize)
                    tintedIcon.lockFocus()
                    // Draw the icon
                    configuredIcon.draw(in: NSRect(origin: .zero, size: iconSize), from: .zero, operation: .sourceOver, fraction: 1.0)
                    // Apply color tint
                    stickerColor.set()
                    NSRect(origin: .zero, size: iconSize).fill(using: .sourceAtop)
                    tintedIcon.unlockFocus()
                    tintedIcon.isTemplate = false
                    
                    // Draw the tinted icon - flip it vertically because we're in a flipped context
                    // The image was created in a standard coordinate system, so we need to flip it
                    context.saveGState()
                    context.translateBy(x: drawRect.midX, y: drawRect.midY)
                    context.scaleBy(x: 1.0, y: -1.0)
                    context.translateBy(x: -drawRect.midX, y: -drawRect.midY)
                    tintedIcon.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    context.restoreGState()
                }
            }
            if let dir = annotation.stickerPointerDirection {
                drawStickerPointer(direction: dir, stickerFrame: annotation.frame, color: stickerColor, in: context)
            }
        case .blur:
            // A baked mosaic wins: on the live overlay there is no source to
            // re-sample, and re-sampling would capture the overlay itself.
            drawRedaction(annotation, mosaic: annotation.bakedMosaic ?? ctx.mosaic(annotation), in: context)
        case .numberBadge:
            drawNumberBadge(annotation, in: context)
        case .measure:
            drawMeasure(annotation, in: context)
        case .guide(let orientation):
            drawGuide(annotation, orientation: orientation, in: context, using: ctx)
        case .grid:
            drawGrid(annotation, in: context)
            if ctx.showsGridLabels {
                drawGridLabels(annotation, suppressing: ctx.editingGridLabel(annotation), in: context)
            }
        }

        context.restoreGState()
    }

    /// A full-canvas alignment line. Only the perpendicular position is stored
    /// meaningfully; `ctx.guideFrame` re-spans the current canvas so enlarging the
    /// selection hole grows the guide rather than leaving a stub of the old width.
    static func drawGuide(_ annotation: Annotation, orientation: GuideOrientation,
                          in context: CGContext, using ctx: Context = .export) {
        let frame = ctx.guideFrame(annotation)
        let start: NSPoint
        let end: NSPoint
        if orientation == .horizontal {
            start = NSPoint(x: frame.minX, y: frame.midY)
            end = NSPoint(x: frame.maxX, y: frame.midY)
        } else {
            start = NSPoint(x: frame.midX, y: frame.minY)
            end = NSPoint(x: frame.midX, y: frame.maxY)
        }
        context.setLineWidth(max(1, annotation.thickness))
        context.setLineCap(.butt)
        if annotation.colorMode == .rainbow {
            strokeRainbowPath([start, end], in: context)
        } else {
            context.setStrokeColor(annotation.color.cgColor)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }
    }

    /// Re-span a guide across `canvas`, keeping its perpendicular position (and the
    /// thickness encoded in the stored frame). Guides behave like infinite lines
    /// clipped to the selection — this is the unclipped infinite segment.
    static func guideFrame(for annotation: Annotation, orientation: GuideOrientation,
                           spanning canvas: NSRect) -> NSRect {
        if orientation == .horizontal {
            let thickness = max(annotation.frame.height, 2)
            return NSRect(
                x: canvas.minX,
                y: annotation.frame.midY - thickness / 2,
                width: canvas.width,
                height: thickness
            )
        } else {
            let thickness = max(annotation.frame.width, 2)
            return NSRect(
                x: annotation.frame.midX - thickness / 2,
                y: canvas.minY,
                width: thickness,
                height: canvas.height
            )
        }
    }

    /// A translucent region with a 10px grid, from the old rectangle guide. Opacity is
    /// already applied via the context alpha set in `draw`.
    static func drawGrid(_ annotation: Annotation, in context: CGContext) {
        let frame = annotation.frame
        guard frame.width >= 1, frame.height >= 1 else { return }

        // The fill carries the colour mode, not just the border: a rainbow grid with a
        // solid surface reads as a plain rectangle that happens to have a colourful edge.
        let isRainbow = annotation.colorMode == .rainbow
        if isRainbow {
            context.saveGState()
            context.clip(to: frame)
            context.drawLinearGradient(rainbowGradient(),
                                       start: CGPoint(x: frame.minX, y: frame.midY),
                                       end: CGPoint(x: frame.maxX, y: frame.midY),
                                       options: [])
            context.restoreGState()
        } else {
            context.setFillColor(annotation.color.cgColor)
            context.fill(frame)
        }

        // Grid lines contrast with the fill's brightness so they read on either. A
        // rainbow fill is sampled at its midpoint, the same stand-in the measure
        // label uses for a gradient stroke.
        let base = isRainbow ? rainbowColor(at: 0.5) : annotation.color
        let rgb = base.usingColorSpace(.deviceRGB) ?? base
        let brightness = (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
        let gridColor = brightness > 0.5 ? NSColor.black.withAlphaComponent(0.3) : NSColor.white.withAlphaComponent(0.3)
        context.setStrokeColor(gridColor.cgColor)
        context.setLineWidth(0.5)
        let spacing: CGFloat = 10
        var x = frame.minX + spacing
        while x < frame.maxX {
            context.move(to: NSPoint(x: x, y: frame.minY))
            context.addLine(to: NSPoint(x: x, y: frame.maxY))
            x += spacing
        }
        var y = frame.minY + spacing
        while y < frame.maxY {
            context.move(to: NSPoint(x: frame.minX, y: y))
            context.addLine(to: NSPoint(x: frame.maxX, y: y))
            y += spacing
        }
        context.strokePath()

        // Border — a rainbow grid gets a gradient perimeter, matching a rainbow rect.
        context.setLineWidth(1)
        if isRainbow {
            strokeRainbowPath(rectanglePolyline(frame), in: context)
        } else {
            context.setStrokeColor(annotation.color.cgColor)
            context.stroke(frame)
        }
    }

    /// Which of a grid's two editable dimension labels is meant.
    enum GridLabel {
        case width
        case height
    }

    /// Size of a grid's dimension label. The inline field that replaces it on click
    /// uses the same box, so the swap does not shift under the pointer.
    static let gridLabelSize = NSSize(width: 48, height: 18)

    /// Frames for a grid's width and height labels, in annotation space (Y down, so
    /// `minY` is the top edge). Width sits centred on the top edge, height centred on
    /// the left edge — inside the shape when it has room, otherwise just outside, so a
    /// small grid still has something to click.
    static func gridLabelRects(for frame: NSRect) -> (width: NSRect, height: NSRect) {
        let size = gridLabelSize
        let inset: CGFloat = 3

        let widthY = frame.height >= size.height * 2 + inset
            ? frame.minY + inset
            : frame.minY - size.height - inset
        let width = NSRect(x: frame.midX - size.width / 2, y: widthY,
                           width: size.width, height: size.height)

        let heightX = frame.width >= size.width + inset * 2
            ? frame.minX + inset
            : frame.minX - size.width - inset
        let height = NSRect(x: heightX, y: frame.midY - size.height / 2,
                            width: size.width, height: size.height)

        return (width, height)
    }

    /// The pixel-dimension readouts on a grid. `suppressed` is the one currently being
    /// typed into, which the inline field is already drawing.
    static func drawGridLabels(_ annotation: Annotation, suppressing suppressed: GridLabel?, in context: CGContext) {
        let frame = annotation.frame
        guard frame.width >= 1, frame.height >= 1 else { return }
        let rects = gridLabelRects(for: frame)
        if suppressed != .width {
            drawGridLabel("\(Int(frame.width.rounded()))", in: rects.width, context: context)
        }
        if suppressed != .height {
            drawGridLabel("\(Int(frame.height.rounded()))", in: rects.height, context: context)
        }
    }

    /// One dark pill with a pixel count, unflipped locally so the glyphs stay upright.
    /// Drawn at full alpha: a grid is deliberately faint, and its readout should not
    /// fade with it.
    private static func drawGridLabel(_ text: String, in rect: NSRect, context: CGContext) {
        let font = NSFont.systemFont(ofSize: 11)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let astr = NSAttributedString(string: text, attributes: attrs)
        let textSize = astr.size()

        context.saveGState()
        context.setAlpha(1)
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.setFillColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        context.fillPath()
        astr.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
        context.restoreGState()
    }

    /// A two-point measurement line with a pixel-distance label beside its midpoint.
    /// Context is Y-flipped (annotation space); the label is unflipped locally, the
    /// same trick the text and sticker cases use to stay upright.
    static func drawMeasure(_ annotation: Annotation, in context: CGContext) {
        guard let start = annotation.startPoint, let end = annotation.endPoint else { return }

        // The line, honouring the colour mode.
        if annotation.colorMode == .rainbow {
            strokeRainbowPath([start, end], in: context)
        } else {
            context.setStrokeColor(annotation.color.cgColor)
            context.setLineWidth(annotation.thickness)
            context.setLineCap(.round)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let text = String(format: "%.0f px", distance)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let astr = NSAttributedString(string: text, attributes: attrs)
        let textSize = astr.size()
        let padding: CGFloat = 4
        let boxW = textSize.width + padding * 2
        let boxH = textSize.height + padding * 2

        // Offset the label to one side of the line so it does not sit on the stroke.
        let len = max(1, distance)
        let offset: CGFloat = 14
        let cx = (start.x + end.x) / 2 + (-dy / len) * offset
        let cy = (start.y + end.y) / 2 + (dx / len) * offset
        let labelColor = annotation.colorMode == .rainbow ? rainbowColor(at: 0.5) : annotation.color

        context.saveGState()
        context.translateBy(x: cx, y: cy)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -cx, y: -cy)
        let box = NSRect(x: cx - boxW / 2, y: cy - boxH / 2, width: boxW, height: boxH)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.setFillColor(labelColor.cgColor)
        context.fillPath()
        astr.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding))
        context.restoreGState()
    }
}

extension AnnotationRenderer {
    /// The Draw tool's rainbow brush: hue advances with distance travelled along the
    /// stroke, so the gradient is even regardless of drawing speed.
    ///
    /// Long segments are subdivided because CoreGraphics strokes one colour per path;
    /// the subdivision is capped so a single fast flick across a wide display cannot
    /// generate an unbounded number of stroke calls (the original had no cap).
    static func strokeRainbowPath(_ points: [NSPoint], in context: CGContext) {
        guard points.count >= 2 else { return }

        var segmentLengths: [CGFloat] = []
        var totalLength: CGFloat = 0
        for i in 0..<(points.count - 1) {
            let dx = points[i + 1].x - points[i].x
            let dy = points[i + 1].y - points[i].y
            let length = sqrt(dx * dx + dy * dy)
            segmentLengths.append(length)
            totalLength += length
        }
        guard totalLength > 0 else { return }

        var travelled: CGFloat = 0
        for i in 0..<(points.count - 1) {
            let start = points[i]
            let end = points[i + 1]
            let segmentLength = segmentLengths[i]
            let subdivisions = max(1, min(64, Int(segmentLength / 2)))

            for j in 0..<subdivisions {
                let t1 = CGFloat(j) / CGFloat(subdivisions)
                let t2 = CGFloat(j + 1) / CGFloat(subdivisions)
                let p1 = NSPoint(x: start.x + (end.x - start.x) * t1,
                                 y: start.y + (end.y - start.y) * t1)
                let p2 = NSPoint(x: start.x + (end.x - start.x) * t2,
                                 y: start.y + (end.y - start.y) * t2)
                let midpoint = travelled + segmentLength * ((t1 + t2) / 2)
                context.setStrokeColor(rainbowColor(at: midpoint / totalLength).cgColor)
                context.move(to: p1)
                context.addLine(to: p2)
                context.strokePath()
            }
            travelled += segmentLength
        }
    }

    /// Sine waves offset by 120 degrees give a smoother cycle than an HSB sweep.
    static func rainbowColor(at position: CGFloat) -> NSColor {
        let phase = position * .pi * 2
        return NSColor(
            red: (sin(phase) + 1) / 2,
            green: (sin(phase + .pi * 2 / 3) + 1) / 2,
            blue: (sin(phase + .pi * 4 / 3) + 1) / 2,
            alpha: 1.0
        )
    }

    // MARK: - Rainbow for shapes, fills and text

    /// Closed polyline around a rectangle, for a rainbow perimeter stroke.
    static func rectanglePolyline(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY),
         NSPoint(x: r.minX, y: r.minY)]
    }

    /// Sampled polyline around the ellipse inscribed in `r`, for a rainbow stroke.
    static func ellipsePolyline(_ r: NSRect, segments: Int = 72) -> [NSPoint] {
        guard r.width > 0, r.height > 0, segments >= 3 else { return [] }
        let a = r.width / 2, b = r.height / 2
        let cx = r.midX, cy = r.midY
        return (0...segments).map { i in
            let t = CGFloat(i) / CGFloat(segments) * .pi * 2
            return NSPoint(x: cx + a * cos(t), y: cy + b * sin(t))
        }
    }

    /// Rainbow gradient sampled along the brush curve, in device RGB.
    static func rainbowGradient() -> CGGradient {
        let space = CGColorSpaceCreateDeviceRGB()
        let steps = 24
        let colors = (0...steps).map {
            (rainbowColor(at: CGFloat($0) / CGFloat(steps)).usingColorSpace(.deviceRGB) ?? .red).cgColor
        }
        // Valid device-RGB colours in a device-RGB space never yield nil.
        return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    }

    /// Text baked into an image: white outline, then a horizontal rainbow gradient
    /// kept only where the glyphs are. Drawn like the sticker image, which is proven
    /// to land upright in the Y-flipped annotation context.
    static func rainbowTextImage(_ text: String, font: NSFont, size: NSSize) -> NSImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let rect = NSRect(origin: .zero, size: size)

        // Rainbow-filled glyphs on a clear background (gradient masked by glyph alpha).
        let glyphs = NSImage(size: size)
        glyphs.lockFocus()
        if let cg = NSGraphicsContext.current?.cgContext {
            cg.drawLinearGradient(rainbowGradient(),
                                  start: CGPoint(x: 0, y: rect.midY),
                                  end: CGPoint(x: rect.maxX, y: rect.midY),
                                  options: [])
        }
        NSGraphicsContext.current?.compositingOperation = .destinationIn
        NSAttributedString(string: text, attributes: textFillAttributes(font: font, color: .black))
            .draw(in: rect)
        glyphs.unlockFocus()

        // Compose the white halo underneath, rainbow glyphs on top.
        let out = NSImage(size: size)
        out.lockFocus()
        let strokeW = textOutlineStrokeWidth(for: font)
        let strokePercent = (strokeW / max(font.pointSize, 1)) * 100
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.white,
            .strokeWidth: strokePercent
        ]).draw(in: rect)
        glyphs.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        out.unlockFocus()
        return out
    }
}
