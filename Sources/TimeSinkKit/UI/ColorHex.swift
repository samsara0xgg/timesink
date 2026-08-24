import SwiftUI

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
}
