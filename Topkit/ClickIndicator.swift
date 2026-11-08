import AppKit
import CoreGraphics
import CoreMedia

/// "Show clicks" for screen recordings (TEC-248): every mouse click during a
/// recording gets a short ring burned into the video at the click point.
///
/// Burned into the frames (like captions) rather than drawn in an on-screen
/// overlay window, so it also works for window recordings — those capture a
/// single window and would never see an overlay.
enum ClickIndicator {
    /// Recording toolbar toggle; off unless the user switches it on.
    static let defaultsKey = "recordingShowClicks"

    enum Kind: Equatable {
        case left
        case right
    }

    /// Ripple timing and size, in points (scaled to video pixels at draw time).
    static let duration: Double = 0.45
    static let startRadius: CGFloat = 8
    static let endRadius: CGFloat = 26
    static let lineWidth: CGFloat = 3

    /// 0…1 through the ripple, or nil before it starts / once it has finished.
    static func progress(elapsed: Double) -> Double? {
        guard elapsed >= 0, elapsed <= duration else { return nil }
        return elapsed / duration
    }

    /// Ring radius in points: grows fast then settles (ease-out cubic).
    static func radius(progress p: Double) -> CGFloat {
        let t = min(max(p, 0), 1)
        let eased = 1 - pow(1 - t, 3)
        return startRadius + (endRadius - startRadius) * CGFloat(eased)
    }

    /// Ring opacity: fully visible for the first fifth, then fades out.
    static func opacity(progress p: Double) -> CGFloat {
        let t = min(max(p, 0), 1)
        let hold = 0.2
        guard t > hold else { return 1 }
        return CGFloat(1 - (t - hold) / (1 - hold))
    }

    /// Cocoa global point (bottom-left origin) → video pixel point in CG
    /// bottom-left space (what a CGBitmapContext over the frame buffer uses).
    /// `captureRect` is the recorded area in Cocoa global points. nil when the
    /// click lands outside the recorded area.
    static func videoPoint(globalPoint: CGPoint, captureRect: CGRect, pixelSize: (width: Int, height: Int)) -> CGPoint? {
        guard captureRect.width > 0, captureRect.height > 0,
              captureRect.contains(globalPoint) else { return nil }
        let sx = CGFloat(pixelSize.width) / captureRect.width
        let sy = CGFloat(pixelSize.height) / captureRect.height
        return CGPoint(
            x: (globalPoint.x - captureRect.minX) * sx,
            y: (globalPoint.y - captureRect.minY) * sy
        )
    }

    /// Video pixels per point for the recorded area.
    static func pixelScale(captureRect: CGRect, pixelWidth: Int) -> CGFloat {
        guard captureRect.width > 0 else { return 1 }
        return CGFloat(pixelWidth) / captureRect.width
    }

    /// The Halo colour from Preferences (same keys and fallback as HaloView),
    /// so clicks match the cursor halo.
    static func color(from defaults: UserDefaults = .standard) -> CGColor {
        let r = defaults.object(forKey: "haloColorRed") as? Double ?? 1
        let g = defaults.object(forKey: "haloColorGreen") as? Double ?? 1
        let b = defaults.object(forKey: "haloColorBlue") as? Double ?? 1
        let a = defaults.object(forKey: "haloColorAlpha") as? Double ?? 1
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a > 0 ? a : 1)
    }
}

/// One click to animate in the video. Built on main, read on the recorder's
/// sample queue (all value types / immutable CGColor).
struct RecordedClick {
    /// Video pixels, CG bottom-left origin.
    let center: CGPoint
    /// Host clock (same timeline as SCK frame PTS).
    let time: CMTime
    let kind: ClickIndicator.Kind
    let color: CGColor
    /// Video pixels per point.
    let scale: CGFloat

    func elapsed(at pts: CMTime) -> Double {
        CMTimeGetSeconds(CMTimeSubtract(pts, time))
    }

    /// True while the ring is still on screen at `pts`.
    func isVisible(at pts: CMTime) -> Bool {
        ClickIndicator.progress(elapsed: elapsed(at: pts)) != nil
    }
}

/// Draws the click rings for one frame. Pure CG, safe off the main thread.
enum ClickIndicatorRenderer {

    static func draw(_ clicks: [RecordedClick], at pts: CMTime, in context: CGContext) {
        for click in clicks {
            guard let p = ClickIndicator.progress(elapsed: click.elapsed(at: pts)) else { continue }
            draw(click, progress: p, in: context)
        }
    }

    static func draw(_ click: RecordedClick, progress p: Double, in context: CGContext) {
        let alpha = ClickIndicator.opacity(progress: p)
        guard alpha > 0 else { return }
        let scale = max(click.scale, 0.1)
        let radius = ClickIndicator.radius(progress: p) * scale
        let lineWidth = ClickIndicator.lineWidth * scale
        let baseAlpha = click.color.alpha
        let stroke = click.color.copy(alpha: baseAlpha * alpha) ?? click.color
        let fill = click.color.copy(alpha: baseAlpha * alpha * 0.22) ?? click.color

        context.saveGState()
        defer { context.restoreGState() }
        // Soft dark shadow keeps a light ring readable on white UI; the Halo's
        // own glow alone disappears there.
        context.setShadow(
            offset: .zero,
            blur: 4 * scale,
            color: CGColor(gray: 0, alpha: 0.4 * alpha)
        )

        let ring = CGRect(x: click.center.x - radius, y: click.center.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(fill)
        context.fillEllipse(in: ring)
        context.setStrokeColor(stroke)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: ring)

        if click.kind == .right {
            // Right click: a second, inner ring.
            let inner = radius * 0.55
            context.setLineWidth(lineWidth * 0.75)
            context.strokeEllipse(in: CGRect(x: click.center.x - inner, y: click.center.y - inner, width: inner * 2, height: inner * 2))
        }
    }
}

/// Watches mouse-down events while a recording with "Show clicks" runs.
/// A global monitor sees clicks in other apps (mouse events need no
/// Accessibility or Input Monitoring grant, sandboxed or not); a local one
/// sees clicks on Topkit's own windows. Main thread only.
final class ClickMonitor {
    private var monitors: [Any] = []

    /// `onClick` receives the click's Cocoa global location.
    func start(onClick: @escaping (CGPoint, ClickIndicator.Kind) -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let handle: (NSEvent) -> Void = { event in
            let kind: ClickIndicator.Kind = event.type == .rightMouseDown ? .right : .left
            onClick(NSEvent.mouseLocation, kind)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    deinit { stop() }
}
