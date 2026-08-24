import SwiftUI
import AppKit

extension Color {
    /// Builds a `Color` from a hex string, with or without a leading `#`:
    /// `"RRGGBB"` or `"RRGGBBAA"`. Falls back to opaque black for any other
    /// length rather than crashing on malformed category colors.
    public init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r, g, b, a: Double
        switch cleaned.count {
        case 8:
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        default:
            r = Double((value & 0xFF_0000) >> 16) / 255
            g = Double((value & 0x00_FF00) >> 8) / 255
            b = Double(value & 0x00_00FF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Converts to an uppercase "RRGGBB" hex string via the sRGB color space
    /// (the inverse of `init(hex:)`, minus alpha — category colors are always
    /// opaque). Falls back to `"000000"` if the color has no direct sRGB
    /// representation (e.g. a pattern or unresolved system color). A
    /// wide-gamut pick (e.g. Display P3) is not guaranteed to land inside
    /// 0...1 once converted to sRGB — `usingColorSpace(.sRGB)`'s contract
    /// does not promise clamping — so each component is clamped to 0...255
    /// before formatting; otherwise `%02X` (a minimum width, not a maximum)
    /// would emit a corrupted 7+ digit or negative-wraparound hex string.
    public func toHex() -> String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "000000" }
        let r = Color.clamp255(rgb.redComponent * 255)
        let g = Color.clamp255(rgb.greenComponent * 255)
        let b = Color.clamp255(rgb.blueComponent * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// Clamps a 0...255-scaled color component to a valid single byte.
    /// Not private so `ColorHexTests` can exercise the wide-gamut edge case
    /// (e.g. 279 → 255, -12 → 0) directly and deterministically, rather than
    /// depending on whether the current OS's `NSColor.usingColorSpace(.sRGB)`
    /// happens to pre-clamp its output for a given input.
    static func clamp255(_ v: Double) -> Int {
        max(0, min(255, Int(v.rounded())))
    }
}
