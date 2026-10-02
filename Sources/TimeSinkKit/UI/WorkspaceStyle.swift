import SwiftUI

/// Set by the main window, which draws the one backdrop for every page: a
/// page's own `WorkspaceBackground` is then clear, so nothing seams.
private struct ShellProvidesBackgroundKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var shellProvidesBackground: Bool {
        get { self[ShellProvidesBackgroundKey.self] }
        set { self[ShellProvidesBackgroundKey.self] = newValue }
    }
}

/// The floor everything sits on: `DesignBackground`, unless the main window
/// already drew it.
struct WorkspaceBackground: View {
    @Environment(\.shellProvidesBackground) private var provided
    var body: some View {
        if provided { Color.clear } else { DesignBackground() }
    }
}
