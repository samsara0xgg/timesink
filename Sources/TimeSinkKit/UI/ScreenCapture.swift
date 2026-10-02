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
        /// A window with a hidden title bar, like the app's own.
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

    /// `TIMESINK_PREVIEW_SHRINK=1`: each main-window shot is taken again
    /// after the same window shrinks to its minimum, the way a person drags
    /// it smaller (a fresh small window hides layout that sticks).
    static let shrink = ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_SHRINK"] != nil

    static func shoot<V: View>(_ name: String, _ view: V, size: NSSize, dark: Bool, host: Host = .window, settle: Int = 900) async throws {
        let file = output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        if let only, !file.lastPathComponent.contains(only) { return }
        guard let screen = builtIn else { print("No built-in display: skipped \(file.lastPathComponent)"); return }
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let resizable = shrink && name.hasPrefix("main-")
        let root = view
            .environment(\.locale, RefinedPreview.locale)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: resizable ? nil : size.width, height: resizable ? nil : size.height)
        let window: NSWindow
        switch host {
        case .window:
            let controller = NSHostingController(rootView: root)
            controller.sceneBridgingOptions = [.toolbars, .title]
            if resizable { controller.sizingOptions = [.minSize] }
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.contentViewController = controller
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
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
        capture(window, to: file)
        if resizable {
            window.setContentSize(Design.windowMinSize)
            window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
            try await Task.sleep(for: .milliseconds(settle))
            capture(window, to: output.appendingPathComponent("\(name)-shrunk-\(dark ? "dark" : "light").png"))
        }
    }

    private static func capture(_ window: NSWindow, to file: URL) {
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try? shot.run()
        shot.waitUntilExit()
        print("Captured \(file.lastPathComponent)")
    }

    /// Lets the host show nothing until the recording runs, so the first
    /// appearance is in it.
    @MainActor @Observable final class MotionStage { var shown = false }

    private struct MotionRoot: View {
        let model: AppModel
        let stage: MotionStage
        var body: some View {
            if stage.shown { MainWindowView(model: model) } else { Color.clear }
        }
    }

    /// `--motion`: a recording of the window alone (never the desktop) as it
    /// appears and then switches through every page, from sample data.
    /// `ffmpeg -i motion.mov -vf fps=60 f%03d.png` pulls the frames out.
    static func runMotion() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let screen = builtIn else { print("No built-in display"); return }
        let model = try RefinedPreview.fixture()
        model.timeFormat = "24"
        let size = RefinedPreview.mainSize
        let dark = CommandLine.arguments.contains("--dark")
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let stage = MotionStage()
        let root = MotionRoot(model: model, stage: stage)
            .environment(\.locale, RefinedPreview.locale)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSApp.appearance
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        let visible = screen.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let movie = output.appendingPathComponent("motion.mov")
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-v", "-V", "13", "-l", String(window.windowNumber), movie.path]
        try shot.run()
        try await Task.sleep(for: .milliseconds(1200))
        window.alphaValue = 1
        stage.shown = true                                   // first appearance
        try await Task.sleep(for: .milliseconds(2200))
        for page in [SidebarItem.activities, .stats, .focus, .organization, .today] {
            model.sidebarSelection = page
            try await Task.sleep(for: .milliseconds(1300))
        }
        shot.waitUntilExit()
        print("Motion recording written")
    }

    static func runAll() async throws {
        if CommandLine.arguments.contains("--motion") { try await runMotion(); return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // `TIMESINK_PREVIEW_DB`: a copy of a real database instead of the
        // sample day, for auditing real lengths. Never the live file.
        let model = try ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_DB"].map(PerfReview.realModel) ?? RefinedPreview.fixture()
        model.timeFormat = "24"
        let size = RefinedPreview.mainSize
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        // The app is light only.
        for dark in [false] {
            for (name, page) in [("today", SidebarItem.today), ("activities", .activities), ("trends", .stats),
                                 ("focus", .focus), ("organization", .organization)] {
                model.sidebarSelection = page
                model.range = DateRangeSelection(kind: page == .stats ? .last7 : .day, anchor: page == .activities ? yesterday : Date())
                let activities = ActivitiesModel()
                activities.recompute(model: model, events: [])
                if page == .activities {
                    // The day's longest session open in the inspector.
                    await activities.loadSessions(model: model)
                    activities.selectedSession = activities.sessions.max { $0.recorded < $1.recorded }?.start
                }
                try await shoot("main-\(name)", MainWindowView(model: model, activities: activities), size: size, dark: dark,
                                settle: page == .stats ? 3500 : 1200)
                if page == .activities, activities.sessions.count > 1 {
                    // A session that continues the one before it: the merge suggestion shows.
                    let list = activities.sessions
                    let same = list.indices.dropFirst().first { index in
                        list[index].categoryID == list[index - 1].categoryID
                            && list[index].start.timeIntervalSince(list[index - 1].end) < 15 * 60
                    }
                    if let same {
                        activities.selectedSession = list[same].start
                        try await shoot("main-activities-merge", MainWindowView(model: model, activities: activities), size: size, dark: dark, settle: 1200)
                    }
                }
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
                                size: NSSize(width: 300, height: 52), dark: dark, host: .clear)
            }
        }
    }
}
#endif
