import AppKit
import Foundation

enum HexColorParser {
    /// Parses a hex color string like "#FF0000", "#F00", "FF0000", or "F00".
    static func parse(_ string: String) -> NSColor? {
        var hex = string.uppercased()

        // Remove # prefix if present
        if hex.hasPrefix("#") {
            hex = String(hex.dropFirst())
        }

        // Must be 3 or 6 hex characters
        guard hex.count == 3 || hex.count == 6 else { return nil }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        // Expand 3-char to 6-char (#F00 -> #FF0000)
        if hex.count == 3 {
            let chars = Array(hex)
            hex = "\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
        }

        // Parse RGB values
        guard let r = Int(hex.prefix(2), radix: 16),
              let g = Int(hex.dropFirst(2).prefix(2), radix: 16),
              let b = Int(hex.dropFirst(4).prefix(2), radix: 16) else { return nil }

        return NSColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}

enum HexColorConverter {
    /// Converts an `NSColor` into a "#RRGGBB" hex string (sRGB).
    static func colorToHex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int(c.redComponent * 255),
                      Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}

