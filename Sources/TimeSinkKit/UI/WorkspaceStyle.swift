import SwiftUI

/// Content surfaces sit one step apart; window chrome and controls keep their
/// native materials, system type and the user's accent color.
struct WorkspaceBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        RefinedStyle.work
    }
}

private struct WorkspacePanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(RefinedStyle.panel, in: RoundedRectangle(cornerRadius: RefinedStyle.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: RefinedStyle.panelRadius)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
    }
}

extension View {
    func workspacePanel() -> some View { modifier(WorkspacePanel()) }
}
