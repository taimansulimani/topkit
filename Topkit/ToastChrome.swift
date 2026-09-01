import AppKit

/// Shared toast visuals so floating toasts match the current system appearance.
enum ToastChrome {
    static func matchesDarkAppearance(_ appearance: NSAppearance = NSApp.effectiveAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func styleContainer(_ view: NSView) {
        let appearance = NSApp.effectiveAppearance
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        let dark = matchesDarkAppearance(appearance)
        let bg: NSColor
        if dark {
            bg = NSColor(white: 0.1, alpha: 0.95)
            view.layer?.borderWidth = 0
            view.layer?.borderColor = nil
        } else {
            bg = NSColor(white: 1.0, alpha: 0.94)
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        }
        view.layer?.backgroundColor = bg.cgColor
    }

    static func primaryLabelColor() -> NSColor {
        matchesDarkAppearance() ? .white : .labelColor
    }
}
