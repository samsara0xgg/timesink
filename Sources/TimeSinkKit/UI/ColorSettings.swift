import AppKit
import SwiftUI

/// The person's colour choices, kept in UserDefaults and applied at once:
/// the scheme (`ColorSystem.use`, which builds the palette one time) and the
/// appearance (`NSApp.appearance`, which every window, the popover and its
/// panels follow). Scene roots wear `colorRefresh()`, which re-creates them
/// when `revision` changes, so every open window repaints without a restart.
@MainActor @Observable final class ColorSettings {
    static let shared = ColorSettings()

    enum Appearance: String, CaseIterable {
        case system, light, dark
        var name: NSAppearance.Name? { self == .light ? .aqua : self == .dark ? .darkAqua : nil }
    }

    static let appearanceKey = "appearanceMode"

    /// Bumped on every scheme change; scene roots use it as their identity.
    private(set) var revision = 0

    var scheme: ColorSystem.Scheme {
        didSet {
            guard scheme != oldValue else { return }
            UserDefaults.standard.set(scheme.rawValue, forKey: ColorSystem.defaultsKey)
            ColorSystem.use(scheme)
            revision += 1
        }
    }

    var appearance: Appearance {
        didSet {
            guard appearance != oldValue else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
            applyAppearance()
        }
    }

    private init() {
        scheme = ColorSystem.scheme
        appearance = UserDefaults.standard.string(forKey: Self.appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    /// Sets the app-wide appearance. A DEBUG `TIMESINK_APPEARANCE=light|dark` wins at launch (captures).
    func applyAppearance(launch: Bool = false) {
        #if DEBUG
        if launch, let name = ProcessInfo.processInfo.environment["TIMESINK_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
            return
        }
        #endif
        NSApp.appearance = appearance.name.flatMap { NSAppearance(named: $0) }
    }
}

extension View {
    /// Redraws this scene root when the colour scheme changes.
    func colorRefresh() -> some View { modifier(ColorRefresh()) }
}

private struct ColorRefresh: ViewModifier {
    func body(content: Content) -> some View {
        content.id(ColorSettings.shared.revision)
    }
}
