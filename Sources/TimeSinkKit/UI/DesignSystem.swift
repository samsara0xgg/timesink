import AppKit
import SwiftUI

/// The v3 design language: Liquid Glass controls floating over a calm
/// window, opaque cards that carry the content. Light is the airy day
/// version (four colour blooms, white cards, an orange bead); dark is its own
/// graphite palette (recessed nav, lit rims, an orange pilot light), not an
/// inverted light theme.
///
/// Everything the shell and the dashboard pages draw with lives here:
/// tokens (colour, spacing, radius, motion) and the modifiers built on them.
/// Glass itself comes from `GlassStyle.swift`; this file never stacks glass
/// on glass.
enum Design {
    // MARK: Spacing, size

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        /// The page's side margin.
        static let page: CGFloat = 28
    }

    enum Radius {
        static let lightCard: CGFloat = 22
        static let graphiteCard: CGFloat = 18
        static let strip: CGFloat = 18
        static let well: CGFloat = 12
        static let block: CGFloat = 8
    }

    static let barHeight: CGFloat = 68
    /// The narrowest main window the pages are laid out for.
    static let windowMinSize = CGSize(width: 760, height: 560)
    static let controlHeight: CGFloat = 40
    static let navHeight: CGFloat = 46

    // MARK: Colour

    /// A colour with a light and a dark value, each with its own alpha.
    static func color(light: UInt32, _ lightAlpha: Double = 1, dark: UInt32, _ darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static let ink = color(light: 0x16161A, dark: 0xEDEEF0)
    static let ink2 = color(light: 0x55565E, dark: 0xA4A7AF)
    static let ink3 = color(light: 0x85868F, dark: 0x6F727B)
    /// Icons on glass and in the nav.
    static let iconInk = color(light: 0x4A4A52, dark: 0xC3C5CC)

    static let line = color(light: 0x101828, 0.07, dark: 0xFFFFFF, 0.075)
    static let line2 = color(light: 0x101828, 0.045, dark: 0xFFFFFF, 0.05)
    static let track = color(light: 0x000000, 0.06, dark: 0xFFFFFF, 0.07)

    static let accent = color(light: 0xF2711C, dark: 0xFF7A1A)
    /// Orange as text.
    static let accentInk = color(light: 0xC2560B, dark: 0xFFA061)
    static let interruption = color(light: 0xE5345A, dark: 0xFF4D6D)
    static let interruptionSoft = color(light: 0xE5345A, 0.10, dark: 0xFF4D6D, 0.15)
    static let link = color(light: 0x2F6BEA, dark: 0x5B9BFF)
    static let live = color(light: 0x22B14C, dark: 0x32D74B)
    static let liveInk = color(light: 0x1F7A3A, dark: 0x62E07E)
    static let liveHalo = color(light: 0x22B14C, 0.10, dark: 0x32D74B, 0.14)

    // Card
    static let cardTop = color(light: 0xFFFFFF, 0.94, dark: 0x1C1D21)
    static let cardBottom = color(light: 0xFFFFFF, 0.82, dark: 0x16171A)
    static let cardSolid = color(light: 0xFAFAFB, dark: 0x1A1B1F)
    static let cardRing = color(light: 0x101828, 0.08, dark: 0xFFFFFF, 0.055)
    static let cardHighlight = color(light: 0xFFFFFF, dark: 0xFFFFFF, 0.075)

    // Pill, glass fallback
    static let pillTop = color(light: 0xFFFFFF, dark: 0x2A2C31)
    static let pillBottom = color(light: 0xF6F7F9, dark: 0x222428)
    static let pillHover = color(light: 0xFFFFFF, dark: 0x30323A)
    static let pillRing = color(light: 0x101828, 0.14, dark: 0xFFFFFF, 0.07)
    /// A pill sitting on a card: a step brighter than the card itself.
    static let chip = color(light: 0xFFFFFF, dark: 0x2E3036)
    static let glassTint = color(light: 0xFFFFFF, 0, dark: 0x2A2C31, 0.55)

    // Bead
    static let beadTop = color(light: 0xFFFFFF, dark: 0x36383F)
    static let beadBottom = color(light: 0xFFF6EF, dark: 0x27292E)
    static let navWell = color(light: 0xFFFFFF, 0.3, dark: 0x0C0D0F)

    // Hatch (away or unrecorded time)
    static let hatchBase = color(light: 0xE4E6EB, dark: 0x1A1C20)
    static let hatchLine = color(light: 0x000000, 0.05, dark: 0xFFFFFF, 0.05)

    /// Row under the pointer.
    static let rowHover = color(light: 0xFFFFFF, 0.75, dark: 0xFFFFFF, 0.045)

    // MARK: Project colours

    /// Projects are named by the person, so their colour is picked by the
    /// name (`ProjectPalette`). Index 8 is for time that belongs to no project.
    static let projectColors: [Color] = [
        color(light: 0x2F6BEA, dark: 0x4C8DFF), color(light: 0x7C5CE0, dark: 0x9B82FF),
        color(light: 0x0F9488, dark: 0x22C3AE), color(light: 0xC27A0E, dark: 0xE3A23A),
        color(light: 0xD6457A, dark: 0xFF6B9E), color(light: 0x5E9A2E, dark: 0x7CC24A),
        color(light: 0xD6532E, dark: 0xFF7A5C), color(light: 0x0E8CB5, dark: 0x35B6E0),
        color(light: 0x7A8494, dark: 0x8D95A5)
    ]
    static func projectColor(_ index: Int?) -> Color {
        guard let index else { return projectColors[projectColors.count - 1] }
        return projectColors[index % (projectColors.count - 1)]
    }

    // MARK: Motion

    /// The nav bead: a droplet that overshoots a little and settles.
    static let bead = Animation.spring(response: 0.38, dampingFraction: 0.78)
    /// Page to page: short, so a switch never feels slow.
    static let pageOut = Animation.easeOut(duration: 0.08)
    static let pageIn = Animation.easeOut(duration: 0.15).delay(0.07)
    /// Cards, blocks and rows arriving, once.
    static let reveal = Animation.spring(response: 0.44, dampingFraction: 0.88)
    static let hover = Animation.easeOut(duration: 0.12)
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.78)
    /// Layout-level changes: a card filtering, a row going away.
    static let settle = Animation.spring(response: 0.38, dampingFraction: 0.84)
    /// Reduce Motion still fades; it never moves.
    static func motion(_ animation: Animation, reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.12) : animation
    }
}

// MARK: - Type

extension Font {
    /// Rounded, tabular numerals: the face every number in the dashboard wears.
    static func num(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// A card's heading: bold ink in light, small tracked caps-weight in graphite.
private struct CardTitle: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if scheme == .dark {
            content.font(.system(size: 13, weight: .semibold)).tracking(0.8).foregroundStyle(Color(hex: "#C9CBD1"))
        } else {
            content.font(.system(size: 13, weight: .bold)).foregroundStyle(Design.ink)
        }
    }
}

/// Dark makes a coloured figure glow like a lit display; light stays flat.
private struct GlowInDark: ViewModifier {
    let color: Color
    var radius: CGFloat = 13
    var strength = 0.55
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.shadow(color: scheme == .dark ? color.opacity(strength) : .clear, radius: radius)
    }
}

extension View {
    func cardTitle() -> some View { modifier(CardTitle()) }
    func glowInDark(_ color: Color, radius: CGFloat = 13, strength: Double = 0.55) -> some View {
        modifier(GlowInDark(color: color, radius: radius, strength: strength))
    }
}

// MARK: - Window background

/// The window's floor. Light: a pale gradient with four soft colour blooms
/// in the corners. Dark: near-black with a lamp glow from the top, a faint
/// orange ember in the corner and a dot grid. Both carry a barely-there grain.
/// Drawn once per size; nothing here moves.
struct DesignBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Canvas { context, size in
                if scheme == .dark { Self.paintDark(&context, size) } else { Self.paintLight(&context, size) }
            }
            if contrast != .increased {
                Image(nsImage: DesignGrain.image(dark: scheme == .dark))
                    .resizable(resizingMode: .tile).opacity(0.55).allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static func bloom(_ context: inout GraphicsContext, _ size: CGSize, center: CGPoint, radii: CGSize,
                              color: Color, stop: CGFloat = 0.64) {
        // An ellipse: a circular gradient scaled on y.
        let r = radii.width * stop
        var scaled = context
        scaled.translateBy(x: center.x, y: center.y)
        scaled.scaleBy(x: 1, y: radii.height / radii.width)
        scaled.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
                    with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: .zero, startRadius: 0, endRadius: r))
    }

    private static func paintLight(_ context: inout GraphicsContext, _ size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color(hex: "#EEF0F5"), Color(hex: "#E8EBF1")]),
                                                      startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        let scale = min(1.25, max(0.7, size.width / 1280))
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: size.width * fx, y: size.height * fy) }
        func radii(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w * scale, height: h * scale) }
        bloom(&context, size, center: at(-0.04, -0.06), radii: radii(900, 520), color: Color(red: 64 / 255, green: 128 / 255, blue: 1).opacity(0.30))
        bloom(&context, size, center: at(1.04, -0.08), radii: radii(820, 500), color: Color(red: 1, green: 146 / 255, blue: 84 / 255).opacity(0.27))
        bloom(&context, size, center: at(1.04, 1.08), radii: radii(860, 480), color: Color(red: 168 / 255, green: 118 / 255, blue: 1).opacity(0.24))
        bloom(&context, size, center: at(-0.04, 1.08), radii: radii(760, 440), color: Color(red: 52 / 255, green: 196 / 255, blue: 186 / 255).opacity(0.20))
    }

    private static func paintDark(_ context: inout GraphicsContext, _ size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: "#101114")))
        let scale = min(1.25, max(0.7, size.width / 1280))
        bloom(&context, size, center: CGPoint(x: size.width / 2, y: -240 * scale), radii: CGSize(width: 1000 * scale, height: 420 * scale),
              color: .white.opacity(0.075), stop: 0.7)
        bloom(&context, size, center: .zero, radii: CGSize(width: 700 * scale, height: 300 * scale),
              color: Color(red: 1, green: 122 / 255, blue: 26 / 255).opacity(0.05), stop: 0.7)
        var dots = Path()
        for x in stride(from: CGFloat(0), to: size.width, by: 18) {
            for y in stride(from: CGFloat(0), to: size.height, by: 18) {
                dots.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
            }
        }
        context.fill(dots, with: .color(.white.opacity(0.04)))
    }
}

/// A tile of fine noise, made once: black specks on light, white on dark.
private enum DesignGrain {
    @MainActor private static var cache: [Bool: NSImage] = [:]

    @MainActor static func image(dark: Bool) -> NSImage {
        if let hit = cache[dark] { return hit }
        let side = 160
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        let ceiling = dark ? 13 : 18
        for pixel in 0..<side * side {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let alpha = UInt8(truncatingIfNeeded: Int(state >> 33) % (ceiling + 1))
            // Premultiplied: white specks carry their alpha in every channel.
            let value = dark ? alpha : 0
            bytes[pixel * 4] = value; bytes[pixel * 4 + 1] = value; bytes[pixel * 4 + 2] = value; bytes[pixel * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return NSImage() }
        let image = NSImage(cgImage: cg, size: NSSize(width: side / 2, height: side / 2))
        cache[dark] = image
        return image
    }
}

// MARK: - Card

/// An opaque card: a pale-to-paler fill, a hairline ring, a lit top edge and
/// two soft shadows. Reduce Transparency makes the fill solid; Increase
/// Contrast thickens the ring.
struct DesignCard: ViewModifier {
    var radius: CGFloat?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let r = radius ?? (scheme == .dark ? Design.Radius.graphiteCard : Design.Radius.lightCard)
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        content
            .background {
                Group {
                    if reduceTransparency { shape.fill(Design.cardSolid) }
                    else { shape.fill(LinearGradient(colors: [Design.cardTop, Design.cardBottom], startPoint: .top, endPoint: .bottom)) }
                }
                .shadow(color: scheme == .dark ? .black.opacity(0.7) : Color(hex: "#101828").opacity(0.03), radius: 0.5, y: 1)
                .shadow(color: scheme == .dark ? .black.opacity(0.45) : Color(hex: "#101828").opacity(0.08), radius: scheme == .dark ? 20 : 14, y: scheme == .dark ? 14 : 9)
            }
            .overlay { ring(shape) }
    }

    private func ring(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.4) : Design.cardRing,
                               lineWidth: contrast == .increased ? 1 : scheme == .dark ? 1 : 0.5)
            shape.strokeBorder(LinearGradient(colors: [Design.cardHighlight, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)),
                               lineWidth: 1).padding(0.5)
        }.allowsHitTesting(false)
    }
}

extension View {
    func designCard(radius: CGFloat? = nil) -> some View { modifier(DesignCard(radius: radius)) }
}

// MARK: - Glass controls

/// A glass control: Liquid Glass on macOS 26, a graphite or frosted capsule
/// before it and under Reduce Transparency.
private struct GlassControl<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.glassSurface(in: shape, tint: scheme == .dark ? Design.glassTint : nil, interactive: interactive)
    }
}

extension View {
    func glassControl(in shape: some InsettableShape = Capsule(), interactive: Bool = false) -> some View {
        modifier(GlassControl(shape: shape, interactive: interactive))
    }
}

/// The recessed well the nav's tabs sit in on graphite; glass in light.
struct NavWell: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if scheme == .dark {
            content.background {
                Capsule().fill(Color(hex: "#0C0D0F"))
                    .overlay {
                        // Inner shadow: a dark edge blurred inwards.
                        Capsule().strokeBorder(.black.opacity(0.85), lineWidth: 3).blur(radius: 2.5).offset(y: 1.5).clipShape(Capsule())
                    }
                    .overlay(Capsule().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                    .shadow(color: .white.opacity(0.07), radius: 0, y: 1)
            }
        } else {
            content.glassControl()
        }
    }
}

extension View {
    func navWell() -> some View { modifier(NavWell()) }
}

/// The selected tab's raised bead. Light: white with an orange glow under
/// it. Graphite: a lit slab with an orange pilot light at its foot.
struct BeadBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = Capsule()
        if scheme == .dark {
            shape.fill(LinearGradient(colors: [Design.beadTop, Design.beadBottom], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.15), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                .overlay(alignment: .bottom) {
                    Capsule().fill(Design.accent).frame(width: 16, height: 2).padding(.bottom, 3)
                        .shadow(color: Design.accent.opacity(0.85), radius: 3)
                }
                .shadow(color: .black.opacity(0.6), radius: 4, y: 3)
        } else {
            shape.fill(LinearGradient(colors: [Design.beadTop, Design.beadBottom], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(LinearGradient(colors: [Design.accent.opacity(0.0), Design.accent.opacity(0.28)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
                .overlay(shape.strokeBorder(.white, lineWidth: 1).blur(radius: 0.4).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
                .shadow(color: Design.accent.opacity(0.30), radius: 9, y: 6)
                .shadow(color: Color(hex: "#101828").opacity(0.10), radius: 1, y: 1)
        }
    }
}

// MARK: - Buttons

/// The dashboard's secondary button: a small raised capsule.
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var tint: Color?
    var font: Font = .system(size: 12)

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, height: height, tint: tint, font: font)
    }

    struct PillBody: View {
        let configuration: Configuration
        let height: CGFloat
        let tint: Color?
        let font: Font
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .font(font)
                .foregroundStyle(tint ?? Design.ink)
                .padding(.horizontal, height < 26 ? 9 : 12)
                .frame(height: height)
                .background {
                    let shape = Capsule()
                    shape.fill(hovered && enabled ? AnyShapeStyle(Design.pillHover)
                               : AnyShapeStyle(LinearGradient(colors: [Design.pillTop, Design.pillBottom], startPoint: .top, endPoint: .bottom)))
                        .overlay(shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Design.pillRing, lineWidth: scheme == .dark ? 1 : 0.5))
                        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.08 : 0.9), .clear], startPoint: .top, endPoint: .center), lineWidth: 1).padding(0.5))
                        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.07), radius: 1.2, y: 1)
                }
                .brightness(configuration.isPressed ? (scheme == .dark ? 0.05 : -0.04) : 0)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : Design.press, value: configuration.isPressed)
                .animation(reduceMotion ? nil : Design.hover, value: hovered)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
                .contentShape(Capsule())
        }
    }
}

/// The page's one primary action: solid orange.
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        AccentBody(configuration: configuration, height: height)
    }

    struct AccentBody: View {
        let configuration: Configuration
        let height: CGFloat
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: height)
                .background {
                    Capsule().fill(Design.accent)
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1).padding(0.5))
                        .shadow(color: Design.accent.opacity(hovered ? 0.5 : 0.32), radius: hovered ? 9 : 6, y: 3)
                }
                .brightness(configuration.isPressed ? -0.06 : hovered ? 0.04 : 0)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : Design.press, value: configuration.isPressed)
                .animation(reduceMotion ? nil : Design.hover, value: hovered)
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovered = $0 }
                .contentShape(Capsule())
        }
    }
}

/// A row that lifts a soft plate when the pointer is over it.
struct HoverRowStyle: ButtonStyle {
    var radius: CGFloat = 10
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, radius: radius)
    }

    struct RowBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Design.rowHover.opacity(configuration.isPressed ? 1 : hovered ? 0.85 : 0)))
                .animation(reduceMotion ? nil : Design.hover, value: hovered)
                .onHover { hovered = $0 }
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Hatch

/// Faint diagonal stripes over a colour: a guess, as against a known fact.
struct StripeOverlay: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: -size.height, to: size.width, by: 8) {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 2)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

// MARK: - Motion modifiers

/// Fades and lifts a view in the first time it appears, `index` steps into a
/// stagger, and never again: a page kept alive behind another is not replayed.
private struct RevealOnce: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                withAnimation(Design.motion(Design.reveal, reduced: reduceMotion).delay(reduceMotion ? 0 : Double(min(index, 8)) * 0.035)) { shown = true }
            }
    }
}

/// Brightens a view under the pointer, a hair.
private struct HoverBrighten: ViewModifier {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .brightness(hovered ? 0.06 : 0).saturation(hovered ? 1.05 : 1)
            .animation(reduceMotion ? nil : Design.hover, value: hovered)
            .onHover { hovered = $0 }
    }
}

extension View {
    func revealOnce(index: Int = 0) -> some View { modifier(RevealOnce(index: index)) }
    func hoverBrighten() -> some View { modifier(HoverBrighten()) }
}
