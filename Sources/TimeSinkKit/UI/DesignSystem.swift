import AppKit
import SwiftUI

/// The design language: a flat light floor, white cards with a hairline,
/// two inks, and colour kept for what it means (see `ColorSystem`).
///
/// Everything the window, the popover and their panels draw with lives
/// here. A size, a gap, a colour or a duration written anywhere else is a
/// bug to fix by naming it here first.
enum Design {
    // MARK: Spacing, size

    /// A 4-point grid.
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        /// Inside a card.
        static let card: CGFloat = 20
        /// The page's side margin.
        static let page: CGFloat = 24
    }

    enum Radius {
        /// Cards, panels, the popover's sections.
        static let card: CGFloat = 12
        /// Buttons, segments, rows, fields.
        static let control: CGFloat = 7
        /// Blocks and bars inside a chart.
        static let mark: CGFloat = 4
    }

    static let barHeight: CGFloat = 52
    /// The narrowest main window the pages are laid out for.
    static let windowMinSize = CGSize(width: 760, height: 560)
    static let controlHeight: CGFloat = 28
    /// One row of a list.
    static let rowHeight: CGFloat = 32
    /// A column of durations at body size: room for "24 小时 25 分".
    static let durationWidth: CGFloat = 84

    // MARK: Colour

    /// A colour with a light and a dark value, each with its own alpha; it
    /// follows the appearance the view is drawn in.
    static func color(light: UInt32, _ lightAlpha: Double = 1, dark: UInt32, _ darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    /// The tokens below live in `ColorSystem`; these names are what the views use.
    static let floor = ColorSystem.floor
    static let surface = ColorSystem.surface
    static let ink = ColorSystem.ink
    static let ink2 = ColorSystem.ink2
    static let iconInk = ColorSystem.iconInk
    static let line = ColorSystem.line
    static let line2 = ColorSystem.line2
    static let track = ColorSystem.track
    static let hoverFill = ColorSystem.hoverFill
    static let selectedFill = ColorSystem.selectedFill

    /// What you can press: the person's own system accent.
    static let accent = Color.accentColor
    /// Over a limit, an error. Never an interruption (`interruption`).
    static let alert = ColorSystem.alert
    /// Near a limit.
    static let warning = ColorSystem.warning
    /// Recording right now.
    static let live = ColorSystem.live
    /// An interruption, and the same one a step stronger under the pointer.
    static let interruption = ColorSystem.interruption
    static let interruptionActive = ColorSystem.interruptionActive

    // Hatch (away or unrecorded time)
    static let hatchBase = ColorSystem.hatchBase
    static let hatchLine = ColorSystem.hatchLine

    // MARK: Project colours

    /// Projects are named by the person, so their colour is picked by the
    /// name (`ProjectPalette`). The last slot is for time that belongs to no project.
    static func projectColor(_ index: Int?) -> Color { ColorSystem.project(index) }
    /// The ink for text on a project's colour.
    static func projectLabel(_ index: Int?) -> Color { ColorSystem.projectLabel(index) }

    // MARK: Motion

    /// Hover, press, a choice changing: there and done.
    static let quick = Animation.easeOut(duration: 0.12)
    /// One page or one card's content giving way to the next: a fade, in place.
    static let page = Animation.easeOut(duration: 0.15)
    /// Something opening, closing or moving to a new place. No overshoot.
    static let layout = Animation.smooth(duration: 0.25)
    /// Reduce Motion fades; nothing moves.
    static func motion(_ animation: Animation, reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.12) : animation
    }
}

// MARK: - Type

extension Font {
    /// The page's one sentence; the popover's total. 26 pt.
    static let display = Font.largeTitle.weight(.semibold)
    /// A figure that leads: header numbers, a card's main value. 17 pt.
    static let figure = Font.title2.weight(.semibold).monospacedDigit()
    /// Notes, labels, axes. 11 pt. (Everything else is `.body`, 13 pt.)
    static let note = Font.subheadline
    /// The focus dial and countdown.
    static let timer = Font.system(size: 44, weight: .semibold).monospacedDigit()
}

/// A card's heading: the body size, semibold.
private struct CardTitle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.body.weight(.semibold)).foregroundStyle(Design.ink)
    }
}

extension View {
    func cardTitle() -> some View { modifier(CardTitle()) }
}

// MARK: - Window background

/// The window's floor: one flat colour.
struct DesignBackground: View {
    var body: some View {
        Design.floor.accessibilityHidden(true).allowsHitTesting(false)
    }
}

// MARK: - Card

/// The one card: white, a hairline, a 12 pt corner, no shadow. Increase
/// Contrast draws the edge darker.
struct DesignCard: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
        content
            .background(Design.surface, in: shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.4) : Design.line,
                                   lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func designCard() -> some View { modifier(DesignCard()) }
    /// A card floating over the page (a block's details, a toast): the one
    /// place a shadow is drawn, because it really is above.
    func floatingCard() -> some View {
        modifier(DesignCard()).shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
    /// A scrolling list in a card: its row plates reach into the card's
    /// margin, so their text lines up with the heading, and its foot fades
    /// out instead of cutting a row in half. The list ends with
    /// `Design.Space.lg` of room for the fade.
    func cardList() -> some View {
        padding(.horizontal, -Design.Space.sm).fadeFoot()
    }
    /// A scroll view's last `Design.Space.lg` fades out: what continues
    /// below shows that it does, and nothing ends cut in half.
    func fadeFoot() -> some View {
        mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Design.Space.lg)
            }
        }
    }
    /// A card with the standard inner margin, its content packed at the top.
    func cardBox() -> some View {
        padding(Design.Space.card)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .designCard()
    }
}

// MARK: - Buttons

/// A secondary button: a grey plate that darkens under the pointer.
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = Design.controlHeight
    var tint: Color?
    var font: Font = .body

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
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            configuration.label
                .font(font)
                .foregroundStyle(tint ?? Design.ink)
                .padding(.horizontal, height < 26 ? Design.Space.sm : 10)
                .frame(height: height)
                .background(configuration.isPressed ? Design.selectedFill : hovered && enabled ? Design.selectedFill.opacity(0.8) : Design.hoverFill, in: shape)
                .overlay { if contrast == .increased { shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1) } }
                .animation(reduceMotion ? nil : Design.quick, value: hovered)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
                .contentShape(shape)
        }
    }
}

/// The page's one primary action: the accent, filled.
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = Design.controlHeight

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
                .font(.body.weight(.semibold)).foregroundStyle(enabled ? Color.white : Design.ink2)
                .padding(.horizontal, 14).frame(height: height)
                .background(enabled ? Design.accent : Design.selectedFill, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                .brightness(configuration.isPressed ? -0.08 : hovered ? 0.04 : 0)
                .animation(reduceMotion ? nil : Design.quick, value: hovered)
                .onHover { hovered = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// A row that shows a plate under the pointer.
struct HoverRowStyle: ButtonStyle {
    var radius: CGFloat = Design.Radius.control
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
                    .fill(configuration.isPressed ? Design.selectedFill : hovered ? Design.hoverFill : .clear))
                .animation(reduceMotion ? nil : Design.quick, value: hovered)
                .onHover { hovered = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// A link inside a card: secondary ink and a trailing ›, underlined under
/// the pointer. (Accent-coloured text is too faint to read at 13 pt.)
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    struct LinkBody: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .foregroundStyle(Design.ink2)
                .underline(hovered)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovered = $0 }
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Segments

/// One row of choices, the chosen one on a grey plate: the main window's
/// pages, 日/周/月, 会话/时间线. Flat; a change is a quick fade, never a slide.
struct Segmented<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    var height: CGFloat = Design.controlHeight
    @ViewBuilder let label: (Value) -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                SegmentButton(selected: selection == option, height: height) {
                    selection = option
                } label: { label(option) }
            }
        }
        .animation(reduceMotion ? nil : Design.quick, value: selection)
        .fixedSize()
    }
}

struct SegmentButton<Label: View>: View {
    let selected: Bool
    var height: CGFloat = Design.controlHeight
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .font(.body.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Design.ink : Design.ink2)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 10).frame(height: height)
                .background(selected ? Design.selectedFill : hovered ? Design.hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
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
