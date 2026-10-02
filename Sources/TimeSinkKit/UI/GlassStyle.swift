import SwiftUI

/// Liquid Glass (2.0). On macOS 26 a surface is `.glassEffect`, and the
/// glass on one screen shares a `GlassGroup`, so it blurs once; before 26 it
/// is a thin material with a 0.5 pt rim. Glass never sits on glass: what
/// lies inside a glass surface is a `GlassPlatter` fill.
///
/// Reduce Transparency swaps every surface for a solid fill; Increase
/// Contrast draws a 1 pt rim.
/// False for a page kept alive behind the one on screen. System glass does not
/// fade with its parents' opacity, so a hidden page's glass would show through.
private struct PageActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var pageActive: Bool {
        get { self[PageActiveKey.self] }
        set { self[PageActiveKey.self] = newValue }
    }
}

struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.pageActive) private var pageActive

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(tint ?? RefinedStyle.panel, in: shape)
                .overlay(rim)
        } else {
            glass(content).overlay { if contrast == .increased { rim } }
        }
    }

    @ViewBuilder private func glass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), pageActive {
            content.glassEffect(glassStyle, in: shape)
        } else {
            material(content)
        }
        #else
        material(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26, *)
    private var glassStyle: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
    #endif

    private func material(_ content: Content) -> some View {
        content
            .background {
                if let tint { shape.fill(tint) } else { shape.fill(.ultraThinMaterial) }
            }
            .overlay(shape.strokeBorder(.white.opacity(0.35), lineWidth: 0.5).blendMode(.plusLighter))
            .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var rim: some View {
        shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.55 : 0.12),
                           lineWidth: contrast == .increased ? 1 : 0.5)
    }
}

/// Groups the glass surfaces of one screen so they blur once and can morph
/// into each other (`glassID`).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A fill inside glass: sections of the popover, rows of the inspector.
struct GlassPlatter<S: InsettableShape>: ViewModifier {
    let shape: S
    var strong = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .overlay { if contrast == .increased { shape.strokeBorder(.primary.opacity(0.35), lineWidth: 1) } }
    }

    private var fill: Color {
        if reduceTransparency || scheme == .dark {
            return .primary.opacity(strong ? 0.1 : 0.055)
        }
        return .white.opacity(strong ? 0.74 : 0.5)
    }
}

extension View {
    func glassSurface(in shape: some InsettableShape = Capsule(), tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    func glassSurface(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                              tint: tint, interactive: interactive))
    }

    func glassPlatter(cornerRadius: CGFloat = Design.Radius.card, strong: Bool = false) -> some View {
        modifier(GlassPlatter(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), strong: strong))
    }

    /// Ties a glass surface to its counterparts in the same `GlassGroup`, so
    /// one can morph into another (the hourglass into its capsules, a button
    /// into the timer it starts).
    @ViewBuilder
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            glassEffectID(id, in: namespace)
        } else {
            matchedGeometryEffect(id: id, in: namespace)
        }
        #else
        matchedGeometryEffect(id: id, in: namespace)
        #endif
    }
}

/// The primary action of a glass surface: tinted glass on macOS 26, the
/// accent-filled bordered style before.
struct GlassProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
        #else
        content.buttonStyle(.borderedProminent)
        #endif
    }
}

/// A secondary glass button: clear glass on macOS 26, bordered before.
struct GlassButton: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
        #else
        content.buttonStyle(.bordered)
        #endif
    }
}

extension View {
    func glassProminentButton() -> some View { modifier(GlassProminentButton()) }
    func glassButton() -> some View { modifier(GlassButton()) }
}
