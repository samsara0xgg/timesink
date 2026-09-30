#if DEBUG
import AppKit
import SwiftUI
import WebKit

/// `--design-preview --screen-capture <dir>`: the sample-data surfaces in
/// real windows (real glass, real toolbars) on the built-in display, each
/// captured by window id with `screencapture -l`. The app never activates,
/// so windows draw in their inactive state; nothing goes in the menu bar.
@MainActor enum ScreenCapture {
    enum Host {
        /// A titled window with a unified toolbar, like the app's own.
        case window
        /// A borderless panel on glass: the menu bar popover's window.
        case glass(CGFloat)
        /// A transparent panel; the view draws its own card (flyouts, HUD).
        case clear
    }

    static var output: URL {
        let arguments = CommandLine.arguments
        let path = arguments.firstIndex(of: "--screen-capture").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        return URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
    }
    static let only = ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_ONLY"]

    static var builtIn: NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
    }

    static func shoot<V: View>(_ name: String, _ view: V, size: NSSize, dark: Bool, host: Host = .window, settle: Int = 900) async throws {
        let file = output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        if let only, !file.lastPathComponent.contains(only) { return }
        guard let screen = builtIn else { print("No built-in display: skipped \(file.lastPathComponent)"); return }
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view
            .environment(\.locale, RefinedPreview.locale)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
        let window: NSWindow
        switch host {
        case .window:
            let controller = NSHostingController(rootView: root)
            controller.sceneBridgingOptions = [.toolbars, .title]
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.contentViewController = controller
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
        case .glass(let radius):
            window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            let hosting = NSHostingView(rootView: root)
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
                glass.cornerRadius = radius
                glass.contentView = hosting
                window.contentView = glass
            } else {
                let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
                effect.material = .popover
                effect.state = .active
                effect.wantsLayer = true
                effect.layer?.cornerRadius = radius
                hosting.frame = effect.bounds
                hosting.autoresizingMask = [.width, .height]
                effect.addSubview(hosting)
                window.contentView = effect
            }
        case .clear:
            window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.contentView = NSHostingView(rootView: root)
        }
        window.appearance = NSApp.appearance
        window.colorSpace = .sRGB
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        let visible = screen.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(settle))
        guard window.screen == screen else { print("Not on the built-in display: skipped \(file.lastPathComponent)"); return }
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try shot.run()
        shot.waitUntilExit()
        print("Captured \(file.lastPathComponent)")
    }

    static func runAll() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try RefinedPreview.fixture()
        model.timeFormat = "24"
        let size = RefinedPreview.mainSize
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        for dark in [false, true] {
            for (name, page) in [("today", SidebarItem.today), ("activities", .activities), ("trends", .stats),
                                 ("focus", .focus), ("organization", .organization)] {
                model.sidebarSelection = page
                model.range = DateRangeSelection(kind: page == .stats ? .last7 : .day, anchor: page == .activities ? yesterday : Date())
                let activities = ActivitiesModel()
                activities.recompute(model: model, events: [])
                let midMorning = calendar.startOfDay(for: yesterday).addingTimeInterval(10.6 * 3600)
                if page == .activities, let item = model.rangedSpans().first(where: { $0.span.start >= midMorning }) {
                    activities.select(ActivitiesModel.selection(for: item), start: item.span.start)
                }
                try await shoot("main-\(name)", MainWindowView(model: model, activities: activities), size: size, dark: dark,
                                settle: page == .stats ? 3500 : 1200)
            }
            model.sidebarSelection = .organization
            for (name, tab) in [("categories", SettingsTab.categories), ("rules", .rules)] {
                model.organizationTab = tab
                try await shoot("main-\(name)", MainWindowView(model: model), size: size, dark: dark)
            }
            model.organizationTab = .uncategorized
            // No 隐私: its Chrome permission check blocks an unsigned build.
            for (name, tab) in [("general", SettingsTab.general), ("recording", .recording), ("llm", .llm),
                                ("notifications", .notifications), ("focus", .focus), ("account", .account)] {
                model.settingsTab = tab
                try await shoot("settings-\(name)", SettingsView(model: model), size: NSSize(width: 700, height: 500), dark: dark)
            }
            model.range = .today()
            model.sidebarSelection = .today
            await model.dashboard.recompute(model: model, forceStreak: true)
            // The popover's window takes the size its content asks for.
            func popover(_ name: String) async throws {
                let view = MenuBarDashboardView(model: model)
                try await shoot(name, view, size: RefinedPreview.fitting(view, dark: dark), dark: dark, host: .glass(28))
            }
            try await popover("popover")
            model.pauseTracking(minutes: 15)
            try await popover("popover-paused")
            model.resumeTracking()
            try model.focus?.start(minutes: 25)
            try await popover("popover-focus")
            model.focus?.finish(completed: false)
            model.accessibilityGranted = false
            try await popover("popover-permission")
            model.accessibilityGranted = true
            if let panes = await RefinedPreview.flyoutPanes(model: model) {
                for (name, pane) in panes {
                    let fit = RefinedPreview.fitting(pane, dark: dark)
                    try await shoot("flyout-\(name)", pane.padding(24), size: NSSize(width: fit.width + 48, height: fit.height + 48), dark: dark, host: .clear)
                }
            }
            try await shoot("menubar-items", HStack(spacing: 18) {
                Image(systemName: "hourglass"); Text(verbatim: "6:42")
                Image(nsImage: FocusCapsule.image(remaining: 26 * 60 + 12, planned: 45 * 60))
                Image(nsImage: FocusCapsule.image(symbol: "moon", text: String(localized: "离开了 \(48) 分钟 · 补记？")))
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.bar), size: NSSize(width: 520, height: 40), dark: dark, host: .clear)
            let lunch = DateInterval(start: calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600 + 120), duration: 48 * 60)
            try await shoot("away-prompt", AwayPrompt(model: model, interval: lunch).padding(12), size: NSSize(width: 360, height: 300), dark: dark, host: .glass(28))
            try await shoot("onboarding-1", OnboardingView(model: model, checksPermissions: false), size: NSSize(width: 500, height: 520), dark: dark)
            if let focus = model.focus {
                try await shoot("focus-hud", FocusHUDContentView(appName: "信息", appKey: "com.apple.MobileSMS", hideCount: 1, controller: focus, onReturn: {}, onAllow: {}), // l10n: data
                                size: NSSize(width: 312, height: 122), dark: dark, host: .clear)
            }
        }
    }
}
#endif
