import AppKit
import SwiftUI

/// Every colour the app draws with, in one place, each with a light and a
/// dark value. One kind of data, one colour:
///
/// - a category or a project: its own colour (`category`, `project`);
/// - a magnitude (minutes, a score, a count by week): one indigo ramp (`ramp`);
/// - an interruption: one soft amber (`interruption`);
/// - everything else: two inks, two greys, white cards, and the system
///   accent for what you can press. Red is for a limit passed or an error.
///
/// Two schemes are kept side by side until the owner chooses:
/// - A "conservative": the shipped category and project colours, nudged only
///   where a label could not be read;
/// - B "harmonised": the same hues re-cut in OKLCH (even lightness and
///   chroma, warm and green fills lifted), projects in a deeper, duller family.
/// `scripts/color_check.py` reads the tables below and checks them (label
/// contrast, colour-blind separation, ramp steps); `ColorSystemTests` repeats
/// the label rule.
enum ColorSystem {
    enum Scheme: String { case conservative = "A", harmonised = "B" }

    /// The scheme in use. DEBUG builds read `TIMESINK_COLOR_SCHEME=A|B`.
    static let scheme: Scheme = {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["TIMESINK_COLOR_SCHEME"], let scheme = Scheme(rawValue: name.uppercased()) {
            return scheme
        }
        #endif
        return .conservative
    }()

    typealias Pair = (light: UInt32, dark: UInt32)

    // MARK: Surfaces, inks, lines

    /// The window under everything.
    static let floor = Design.color(light: 0xF5F5F7, dark: 0x1C1C1E)
    /// Cards and panels: one step off the floor in both appearances.
    static let surface = Design.color(light: 0xFFFFFF, dark: 0x2C2C2F)
    /// Text. Two inks, both 4.5:1 or better on the floor and on a card.
    static let ink = Design.color(light: 0x1D1D1F, dark: 0xF2F2F4)
    static let ink2 = Design.color(light: 0x6A6A71, dark: 0xA8A8B0)
    /// Symbols that sit beside text.
    static let iconInk = Design.color(light: 0x55555C, dark: 0xC8C8CE)
    /// Hairlines: card edges, dividers; row separators inside a card.
    static let line = Design.color(light: 0x000000, 0.09, dark: 0xFFFFFF, 0.12)
    static let line2 = Design.color(light: 0x000000, 0.055, dark: 0xFFFFFF, 0.07)
    /// The empty part of a bar or meter.
    static let track = Design.color(light: 0x000000, 0.06, dark: 0xFFFFFF, 0.09)
    /// A control or row under the pointer; the chosen segment.
    static let hoverFill = Design.color(light: 0x000000, 0.045, dark: 0xFFFFFF, 0.07)
    static let selectedFill = Design.color(light: 0x000000, 0.075, dark: 0xFFFFFF, 0.11)
    /// Away or unrecorded time.
    static let hatchBase = Design.color(light: 0xECECEF, dark: 0x252528)
    static let hatchLine = Design.color(light: 0x000000, 0.05, dark: 0xFFFFFF, 0.06)
    /// A panel inside a window (the rules pane's list).
    static let panel = Design.color(light: 0xFFFFFF, dark: 0x2C2C2F)

    // MARK: Status

    /// Over a limit, an error. Never an interruption.
    static let alert = Design.color(light: 0xD70015, dark: 0xFF6961)
    /// Near a limit, paused, needs attention.
    static let warning = Design.color(light: 0xC98300, dark: 0xF2AA2E)
    /// Recording right now; allowed, saved.
    static let live = Design.color(light: 0x1F7A35, dark: 0x30D158)

    // MARK: Categories

    static let categoriesA: [String: Pair] = [
        "softwareDev": (0x2B6FEC, 0x0A84FF), "learning": (0x34C759, 0x30D158),
        "writing": (0x30B0C7, 0x40C8E0), "business": (0xA74AD6, 0xBF5AF2),
        "utilities": (0x8E8E93, 0xA1A1A6), "communication": (0xFF9F0A, 0xFF9F0A),
        "news": (0x5856D6, 0x5E5CE6), "jobSearch": (0xA2845E, 0xAC8E68),
        "research": (0x64D2FF, 0x70D7FF), "socialMedia": (0xFF3B30, 0xFF453A),
        "entertainment": (0xFFD60A, 0xFFD60A), "misc": (0x98989D, 0x727278),
        "uncategorized": (0xC7C7CC, 0x55575E)
    ]

    static let categoriesB: [String: Pair] = [
        "softwareDev": (0x3C73C5, 0x4174BF),
        "jobSearch": (0xA2835D, 0x8B6F4B),
        "learning": (0x73D885, 0x62C073),
        "writing": (0x39ABAD, 0x259497),
        "research": (0x90CDF1, 0x7EB6D7),
        "business": (0xA24FA0, 0x9E539D),
        "communication": (0xF39340, 0xD87F2F),
        "entertainment": (0xF2DD5A, 0xDAC64A),
        "socialMedia": (0xCF413A, 0xB32E2A),
        "news": (0x4E4FA1, 0x4C469F),
        "utilities": (0x6C727B, 0x90969F),
        "misc": (0x95989F, 0x66696F),
        "uncategorized": (0xC9CBCE, 0x4B4D50)
    ]

    static var categories: [String: Pair] { scheme == .conservative ? categoriesA : categoriesB }

    // MARK: Projects (index 8: time that belongs to no project)

    static let projectsA: [Pair] = [
        (0x2F6BEA, 0x4C8DFF), (0x7C5CE0, 0x9B82FF), (0x14968A, 0x22C3AE), (0xC27A0E, 0xE3A23A),
        (0xCE3D74, 0xFF6B9E), (0x5E9A2E, 0x7CC24A), (0xE05C37, 0xFF7A5C), (0x1A91BA, 0x35B6E0),
        (0x7D8797, 0x8D95A5)
    ]

    static let projectsB: [Pair] = [
        (0x056784, 0x58BFE6),
        (0x8D3D68, 0x974C72),
        (0x173F81, 0x648CCF),
        (0x924414, 0x9B532B),
        (0x017C56, 0x68C79D),
        (0x692256, 0xB871A1),
        (0x6F1A0F, 0xC67162),
        (0x6F61AF, 0x695CA3),
        (0x616A75, 0x848D98)
    ]

    static var projects: [Pair] { scheme == .conservative ? projectsA : projectsB }

    // MARK: Magnitude ramp (indigo): little -> much

    static let rampLight: [UInt32] = [0xEAEEFC, 0xC4CCEF, 0x8E9AD7, 0x5C68AE, 0x343C77]
    static let rampDark: [UInt32] = [0x2B2F42, 0x474F79, 0x6B76B0, 0x93A0E0, 0xC3CEFF]

    // MARK: Interruptions (one soft amber)

    static let interruption = Design.color(light: 0xE8AF4F, dark: 0xE6B55D)
    /// Under the pointer, chosen: one step stronger.
    static let interruptionActive = Design.color(light: 0xD28A0E, dark: 0xF8CE78)
    /// The radar's five leading apps (the first interrupts most), then the rest.
    static let radarLight: [UInt32] = [0x935A03, 0xB47819, 0xD39837, 0xE9B860, 0xF6D795, 0xA6ABB3]
    static let radarDark: [UInt32] = [0xF3CB7A, 0xDBAC59, 0xC18E3D, 0xA3722D, 0x885B26, 0x5A5E65]
    static let radar: [Color] = zip(radarLight, radarDark).map { Design.color(light: $0, dark: $1) }

    // MARK: Lookups

    private static let categoryColors: [String: Color] = categories.mapValues { Design.color(light: $0.light, dark: $0.dark) }
    private static let categoryLabels: [String: Color] = categories.mapValues { label(on: $0) }
    private static let projectColors: [Color] = projects.map { Design.color(light: $0.light, dark: $0.dark) }
    private static let projectLabels: [Color] = projects.map { label(on: $0) }

    /// A shipped category's colour, by id.
    static func category(_ id: String) -> Color? { categoryColors[id] }
    /// The ink for text on a shipped category's fill.
    static func categoryLabel(_ id: String) -> Color? { categoryLabels[id] }

    static func project(_ index: Int?) -> Color {
        guard let index else { return projectColors[projectColors.count - 1] }
        return projectColors[index % (projectColors.count - 1)]
    }
    static func projectLabel(_ index: Int?) -> Color {
        guard let index else { return projectLabels[projectLabels.count - 1] }
        return projectLabels[index % (projectLabels.count - 1)]
    }

    /// The label ink for a custom colour the person picked (the same in both appearances).
    static func label(onHex hex: String) -> Color {
        label(on: (light: hexValue(hex), dark: hexValue(hex)))
    }

    private static func label(on pair: Pair) -> Color {
        Design.color(light: labelInk(on: pair.light), dark: labelInk(on: pair.dark))
    }

    static let darkInk: UInt32 = 0x1D1D1F

    /// White or the dark ink, whichever reads better on the fill.
    static func labelInk(on fill: UInt32) -> UInt32 {
        contrast(0xFFFFFF, fill) >= contrast(darkInk, fill) ? 0xFFFFFF : darkInk
    }

    // MARK: Ramp

    private static let rampSteps = 16
    private static let rampColors: [Color] = (0..<rampSteps).map { step in
        let t = Double(step) / Double(rampSteps - 1)
        return Design.color(light: lerp(rampLight, t), dark: lerp(rampDark, t))
    }

    /// 0 (little) ... 1 (much) on the indigo ramp, in 16 steps.
    static func ramp(_ t: Double) -> Color {
        rampColors[Int((min(1, max(0, t)) * Double(rampSteps - 1)).rounded())]
    }

    // MARK: Maths

    private static func channels(_ hex: UInt32) -> [Double] {
        [Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)]
    }

    private static func lerp(_ stops: [UInt32], _ t: Double) -> UInt32 {
        let position = t * Double(stops.count - 1)
        let index = min(stops.count - 2, Int(position))
        let f = position - Double(index)
        let a = channels(stops[index]), b = channels(stops[index + 1])
        let mixed = zip(a, b).map { UInt32((($0 + ($1 - $0) * f)).rounded()) }
        return mixed[0] << 16 | mixed[1] << 8 | mixed[2]
    }

    static func hexValue(_ hex: String) -> UInt32 {
        UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(6), radix: 16) ?? 0
    }

    /// WCAG relative luminance.
    static func luminance(_ hex: UInt32) -> Double {
        let c = channels(hex).map { v -> Double in
            let s = v / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    /// WCAG contrast ratio, 1...21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
