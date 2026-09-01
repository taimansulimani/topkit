import AppKit

/// Draws the live caption lines in the shared annotation style (outlined
/// text, no background) — same look as the burned-in render, in points.
private final class CaptionOverlayTextView: NSView {
    var lines: [String] = [] {
        didSet { needsDisplay = true }
    }
    var font: NSFont = CaptionTextStyle.font(size: CaptionOverlayController.fontPointSize)
    var fill: NSColor = CaptionTextStyle.fillNSColor()

    override func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else { return }
        let pad = CaptionTextStyle.outlineExtent(fontPointSize: font.pointSize)
        let lineHeight = CaptionTextStyle.lineHeight(for: font)
        for (index, line) in lines.enumerated() {
            let size = CaptionTextStyle.size(of: line, font: font)
            let x = (bounds.width - size.width) / 2
            let y = pad + CGFloat(lines.count - 1 - index) * lineHeight
            CaptionTextStyle.drawOutlined(line, font: font, fill: fill, at: NSPoint(x: x, y: y))
        }
    }
}

/// Live caption feedback shown while recording: click-through outlined text
/// pinned to the bottom-centre of the recorded area so the user sees what
/// dictation heard. It is excluded from the capture filter (region mode) or
/// naturally absent from it (window mode) — the recorded pixels get their own
/// burned-in copy from CaptionBurnInRenderer, so this never doubles up in
/// the file.
final class CaptionOverlayController {

    static let fontPointSize: CGFloat = 16

    private let window: NSWindow
    private let textView = CaptionOverlayTextView()
    private var anchorRect: NSRect

    /// For the SCContentFilter exclusion list. The window is ordered front
    /// (fully transparent) before shareable content is fetched, same trick as
    /// the dim chrome windows.
    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    init(anchorRect: NSRect, level: NSWindow.Level) {
        self.anchorRect = anchorRect
        window = NSWindow(
            contentRect: NSRect(x: anchorRect.midX, y: anchorRect.minY, width: 2, height: 2),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.contentView = textView
        window.orderFrontRegardless()
    }

    /// nil hides the caption.
    func setText(_ text: String?) {
        guard let text, !text.isEmpty else {
            textView.lines = []
            window.setContentSize(NSSize(width: 2, height: 2))
            return
        }
        // Style prefs can change between recordings (and mid-recording via
        // Preferences) — re-read on every update, matching the burn renderer.
        let fontSize = max(Self.fontPointSize * CaptionRenderMetrics.userScale(), 12)
        textView.font = CaptionTextStyle.font(size: fontSize)
        textView.fill = CaptionTextStyle.fillNSColor()

        let maxWidth = min(max(anchorRect.width - 32, 120), 700)
        let maxChars = max(Int(maxWidth / (fontSize * 0.55)), 8)
        textView.lines = CaptionLineLayout.tailLines(
            of: text,
            maxLines: CaptionRenderMetrics.maxLines,
            maxCharsPerLine: maxChars
        )
        layout()
    }

    func updateAnchor(_ rect: NSRect) {
        guard rect != anchorRect else { return }
        anchorRect = rect
        if !textView.lines.isEmpty { layout() }
    }

    func close() {
        window.orderOut(nil)
    }

    private func layout() {
        let font = textView.font
        let pad = CaptionTextStyle.outlineExtent(fontPointSize: font.pointSize)
        let lineHeight = CaptionTextStyle.lineHeight(for: font)
        var maxLineWidth: CGFloat = 0
        for line in textView.lines {
            maxLineWidth = max(maxLineWidth, CaptionTextStyle.size(of: line, font: font).width)
        }
        let size = NSSize(
            width: ceil(maxLineWidth) + pad * 2,
            height: lineHeight * CGFloat(textView.lines.count) + pad * 2
        )
        let origin = NSPoint(
            x: anchorRect.midX - size.width / 2,
            y: anchorRect.minY + 14
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        textView.frame = NSRect(origin: .zero, size: size)
    }
}
