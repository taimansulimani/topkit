import Foundation
import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcuts via Carbon `RegisterEventHotKey`.
///
/// This replaces the previous CGEventTap-based shortcut handling. RegisterEventHotKey
/// needs NO Accessibility/Input Monitoring permission and is fully compatible with the
/// App Sandbox and the Mac App Store. The system consumes the registered combo for us,
/// so matched shortcuts no longer fall through to the focused app.
///
/// Shortcuts are stored in UserDefaults as glyph strings (e.g. "⌘⇧K"), matching the
/// existing preferences UI. We parse those strings back into a virtual key code +
/// Carbon modifier mask for registration.
final class HotKeyManager {
    static let shared = HotKeyManager()
    private init() {}

    private struct Registration {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    /// One-off hotkeys registered outside the preferences bindings (e.g. plain
    /// Esc while a recording runs). Survive `reload(bindings:)`.
    private var transientRegistrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x54_50_4B_54 // 'TPKT'

    /// (Re)register all shortcuts from the supplied bindings.
    /// `bindings` maps a UserDefaults key (e.g. "shortcutPickColor") to the action to run.
    func reload(bindings: [(key: String, action: () -> Void)]) {
        assert(Thread.isMainThread, "HotKeyManager.reload must run on the main thread")
        unregisterAll()
        installHandlerIfNeeded()

        let defaults = UserDefaults.standard
        for binding in bindings {
            guard let glyphs = defaults.string(forKey: binding.key), !glyphs.isEmpty else { continue }
            guard let parsed = Self.parse(glyphs) else {
                debugLog("⚠️ HotKey: could not parse shortcut '\(glyphs)' for \(binding.key)")
                continue
            }
            register(keyCode: parsed.keyCode, modifiers: parsed.modifiers, action: binding.action)
        }
    }

    func unregisterAll() {
        for (_, reg) in registrations {
            UnregisterEventHotKey(reg.ref)
        }
        registrations.removeAll()
    }

    /// Register a hotkey outside the preferences bindings. Returns an id for
    /// `unregisterTransient`, or nil if registration failed. While registered,
    /// the combo is consumed system-wide — keep the window short.
    @discardableResult
    func registerTransient(keyCode: UInt32, modifiers: UInt32 = 0, action: @escaping () -> Void) -> UInt32? {
        assert(Thread.isMainThread, "HotKeyManager.registerTransient must run on the main thread")
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            debugLog("⚠️ HotKey: transient RegisterEventHotKey failed (status \(status)) keyCode=\(keyCode)")
            return nil
        }
        transientRegistrations[id] = Registration(ref: ref, action: action)
        return id
    }

    func unregisterTransient(id: UInt32) {
        guard let reg = transientRegistrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(reg.ref)
    }

    // MARK: - Registration

    private func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            // -9868 (eventInternalErr) occurs for Option-only / Option+Shift combos on
            // macOS 15+ in sandboxed apps. Other combinations register fine.
            debugLog("⚠️ HotKey: RegisterEventHotKey failed (status \(status)) keyCode=\(keyCode) modifiers=\(modifiers)")
            return
        }

        registrations[id] = Registration(ref: ref, action: action)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            manager.handleHotKey(id: hotKeyID.id)
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func handleHotKey(id: UInt32) {
        guard let reg = registrations[id] ?? transientRegistrations[id] else { return }
        // RegisterEventHotKey already delivers on the main thread, but keep the
        // action dispatch explicit to match the previous tap behaviour.
        DispatchQueue.main.async { reg.action() }
    }

    // MARK: - Glyph string parsing

    /// Parse a shortcut glyph string (e.g. "⌘⇧K", "⌃⌥␣") into a virtual key code and a
    /// Carbon modifier mask. Returns nil if the key glyph is not recognised.
    static func parse(_ glyphs: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var keyGlyph = glyphs

        // Strip modifier glyphs from the front. The preferences UI emits them in the
        // order ⌃⌥⇧⌘, but we tolerate any order.
        func take(_ glyph: Character, _ mask: Int) {
            if keyGlyph.contains(glyph) {
                modifiers |= UInt32(mask)
                keyGlyph.removeAll { $0 == glyph }
            }
        }
        take("⌃", controlKey)
        take("⌥", optionKey)
        take("⇧", shiftKey)
        take("⌘", cmdKey)

        guard let code = keyCode(for: keyGlyph) else { return nil }
        return (code, modifiers)
    }

    /// Map a single key glyph (the non-modifier remainder of a shortcut string) to a
    /// virtual key code on the standard ANSI layout. Shifted symbol forms map to their
    /// base physical key (the shift is carried separately in the modifier mask).
    private static func keyCode(for glyph: String) -> UInt32? {
        // Special keys emitted by AppDelegate's key parser.
        switch glyph {
        case "↩": return UInt32(kVK_Return)
        case "⇥": return UInt32(kVK_Tab)
        case "␣": return UInt32(kVK_Space)
        case "⌫": return UInt32(kVK_Delete)
        case "⎋": return UInt32(kVK_Escape)
        case "←": return UInt32(kVK_LeftArrow)
        case "→": return UInt32(kVK_RightArrow)
        case "↓": return UInt32(kVK_DownArrow)
        case "↑": return UInt32(kVK_UpArrow)
        default: break
        }

        guard glyph.count == 1, let char = glyph.uppercased().first else { return nil }
        return ansiKeyCodes[char]
    }

    private static let ansiKeyCodes: [Character: UInt32] = [
        // Letters
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
        "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "O": 31, "U": 32,
        "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
        // Digits
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        // Punctuation (base glyph)
        "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50,
        // Shifted symbol forms -> base physical key
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "*": 28, "(": 25, ")": 29,
        "_": 27, "+": 24, "{": 33, "}": 30, "|": 42, ":": 41, "\"": 39, "<": 43, ">": 47, "?": 44, "~": 50,
    ]
}
