import AppKit
import Foundation

enum ShortcutKeyParser {
    /// Parses a shortcut string (e.g. "⌃⌥⇧⌘C") into an `NSMenuItem`-compatible key equivalent and modifier flags.
    static func parse(shortcutString: String) -> (keyEquivalent: String?, modifiers: NSEvent.ModifierFlags) {
        var modifiers: NSEvent.ModifierFlags = []
        var keyChar: String?

        for char in shortcutString {
            switch char {
            case "⌃":
                modifiers.insert(.control)
            case "⌥":
                modifiers.insert(.option)
            case "⇧":
                modifiers.insert(.shift)
            case "⌘":
                modifiers.insert(.command)

            case "↩":
                keyChar = "\r"
            case "⇥":
                keyChar = "\t"
            case "␣":
                keyChar = " "
            case "⌫":
                keyChar = String(UnicodeScalar(NSBackspaceCharacter)!)
            case "⎋":
                keyChar = String(UnicodeScalar(27)!) // ESC

            // Arrow keys (use NSEvent key-equivalent convention used elsewhere in the app)
            case "←":
                keyChar = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case "→":
                keyChar = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case "↑":
                keyChar = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case "↓":
                keyChar = String(UnicodeScalar(NSDownArrowFunctionKey)!)

            default:
                // Allow letters, digits, and common punctuation
                if char.isLetter || char.isNumber || "!@#$%^&*()_+-=[]{}|;':\",./<>?".contains(char) {
                    keyChar = String(char).lowercased()
                }
            }
        }

        guard let keyChar, !keyChar.isEmpty else {
            return (nil, modifiers)
        }
        return (keyChar, modifiers)
    }
}

