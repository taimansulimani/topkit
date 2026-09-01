import AppKit
import Foundation

/// The one place that says which global shortcut arms which annotation tool.
///
/// The same combo has to reach three surfaces: the Carbon hotkey bindings in
/// `AppDelegate`, the Annotate submenu, and the tooltips on both toolbars (the live
/// Annotate strip and the screenshot editor). They used to agree only by coincidence
/// — the toolbars showed no shortcut at all — so the mapping lives here and every
/// surface reads it.
enum AnnotationToolShortcuts {

    /// UserDefaults key holding the user's combo for this tool. The names are
    /// historical (`shortcutAddRectangle` is the grid) and must not be renamed
    /// without migrating existing preferences.
    static func defaultsKey(for tool: AnnotationTool) -> String {
        switch tool {
        case .freehand:            return "shortcutDraw"
        case .rectangle:           return "shortcutAnnotateRectangle"
        case .circle:              return "shortcutAnnotateCircle"
        case .arrow:               return "shortcutAnnotateArrow"
        case .text:                return "shortcutAnnotateText"
        case .blur:                return "shortcutAnnotateRedact"
        case .sticker:             return "shortcutAnnotateSticker"
        case .numberBadge:         return "shortcutAnnotateBadge"
        case .measure:             return "shortcutMeasure"
        case .guide(.vertical):    return "shortcutAddVerticalGuide"
        case .guide(.horizontal):  return "shortcutAddGuide"
        case .grid:                return "shortcutAddRectangle"
        }
    }

    /// The assigned combo exactly as the user sees it ("⌥⌘R"), or nil once cleared.
    ///
    /// Rarely nil in practice: `AppDelegate` registers a `⌃⇧`-something default for
    /// every one of these keys, so tooltips carry a combo out of the box.
    static func displayString(for tool: AnnotationTool, defaults: UserDefaults = .standard) -> String? {
        let raw = defaults.string(forKey: defaultsKey(for: tool))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// "Rectangle (⌥⌘R)", falling back to the bare title when the user has cleared the
    /// shortcut rather than showing empty brackets.
    static func tooltip(_ title: String, tool: AnnotationTool, defaults: UserDefaults = .standard) -> String {
        guard let shortcut = displayString(for: tool, defaults: defaults) else { return title }
        return "\(title) (\(shortcut))"
    }

    /// Same shape for the fixed keys that are not user-configurable.
    static func tooltip(_ title: String, fixedKey: String) -> String {
        "\(title) (\(fixedKey))"
    }

    /// Glyphs for the fixed editor keys, so Close/Save/End read like the rest.
    enum FixedKey {
        static let escape = "⎋"
        static let `return` = "↩"
    }
}
