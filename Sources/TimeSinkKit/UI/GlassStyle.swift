import SwiftUI

/// The 2.0 glass is gone: these keep their names and are flat. A surface is
/// a white card with a hairline, a platter a quiet fill inside one, and the
/// buttons are the design system's own two.
/// False for a page kept alive behind the one on screen. Read by the pages that keep one alive.
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

    func body(content: Content) -> some View {
        content
            .background(tint ?? Design.surface, in: shape)
            .overlay(shape.strokeBorder(Design.line, lineWidth: 0.5))
    }
}

/// Passes through: nothing to blur once, now.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View { content }
}

/// A fill inside a surface: sections of the popover, rows of the inspector.
struct GlassPlatter<S: InsettableShape>: ViewModifier {
    let shape: S
    var strong = false

    func body(content: Content) -> some View {
        content.background(Design.floor, in: shape)
            .overlay { if strong { shape.strokeBorder(Design.line, lineWidth: 0.5) } }
    }
}

extension View {
    func glassSurface(in shape: some InsettableShape = Capsule(), tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint))
    }

    func glassSurface(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint))
    }

    func glassPlatter(cornerRadius: CGFloat = Design.Radius.card, strong: Bool = false) -> some View {
        modifier(GlassPlatter(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), strong: strong))
    }

    /// Ties two views of one screen together, so one can morph into another.
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        matchedGeometryEffect(id: id, in: namespace)
    }

    func glassProminentButton() -> some View { buttonStyle(AccentButtonStyle()) }
    func glassButton() -> some View { buttonStyle(PillButtonStyle()) }
}
