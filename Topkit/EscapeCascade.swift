import Foundation

/// Escape while several overlay tools (and possibly a recording) are live.
///
/// **Rule: last tool opened wins.** Esc dismisses the most recently started overlay
/// tool; only when the stack is empty does the caller (screen recording) stop itself.
///
/// Why a stack, not a fixed priority list: Annotate-then-Halo must Esc-close Halo
/// first. A hard-coded "Annotate always first" order cleared drawings underneath a
/// tool the user had just opened.
///
/// Recording owns the Carbon Esc hotkey while capturing (it consumes the key
/// system-wide). Tools push/pop here on start/stop; recording calls `consume()`
/// before `stopRecording()`.
enum EscapeCascade {

    enum Layer: Equatable {
        case annotate
        case halo
        case colorPicker
        case magnifier
    }

    private static var stack: [Layer] = []

    /// Mark a tool as the newest Esc target. Re-pushing moves it to the top.
    static func push(_ layer: Layer) {
        assert(Thread.isMainThread)
        stack.removeAll { $0 == layer }
        stack.append(layer)
    }

    /// Drop a tool from the stack (on stop / cancel). Safe if it is not present.
    static func pop(_ layer: Layer) {
        assert(Thread.isMainThread)
        stack.removeAll { $0 == layer }
    }

    /// Dismiss the topmost live tool. Returns `true` if Esc was consumed.
    @discardableResult
    static func consume() -> Bool {
        assert(Thread.isMainThread)
        while let top = stack.last {
            guard isLive(top) else {
                stack.removeLast()
                continue
            }
            switch top {
            case .annotate:     _ = AnnotateManager.shared.consumeEscape()
            case .halo:         _ = HaloManager.shared.consumeEscape()
            case .colorPicker:  _ = ColorPickerManager.shared.consumeEscape()
            case .magnifier:    _ = MagnifyingGlassManager.shared.consumeEscape()
            }
            return true
        }
        return false
    }

    private static func isLive(_ layer: Layer) -> Bool {
        switch layer {
        case .annotate:     return AnnotateManager.shared.isActive
        case .halo:         return HaloManager.shared.isHaloActive
        case .colorPicker:  return ColorPickerManager.shared.isPicking
        case .magnifier:    return MagnifyingGlassManager.shared.isMagnifying
        }
    }

    // MARK: - Tests

    static func _resetForTesting() { stack = [] }
    static var _stackForTesting: [Layer] { stack }
}
