#if DEBUG
import AppKit
import SwiftUI
import WebKit

/// `--design-preview --screen-capture <dir>`: the sample-data surfaces in
/// real windows (real toolbars) that never reach a display, each drawn
/// into a bitmap. The app never activates; nothing goes in the menu bar.
@MainActor enum ScreenCapture {
    enum Host {
        /// A window with a hidden title bar, like the app's own.
        case window
        /// A borderless panel on glass: the menu bar popover's window.
        case glass(CGFloat)
        /// A transparent panel; the view draws its own card (flyouts, HUD).
        case clear

        var isWindow: Bool { if case .window = self { true } else { false } }
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

    /// The language the strings resolve to (`-AppleLanguages`), for file names.
    static let language = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "en" : "zh"

    /// Renders off screen: the window is built but never ordered in, so no
    /// display ever shows it, and its frame view is drawn into a bitmap.
    static func shoot<V: View>(_ name: String, _ view: V, size: NSSize, dark: Bool = false, host: Host = .window, settle: Int = 900) async throws {
        let file = output.appendingPathComponent("\(name)-\(language).png")
        if let only, !file.lastPathComponent.contains(only) { return }
        NSApp.appearance = NSAppearance(named: .aqua)
        let resizable = shrink && name.hasPrefix("main-")
        let root = view
            .environment(\.locale, RefinedPreview.locale)
            .environment(\.colorScheme, .light)
            // Off screen no display drives an animation: everything lands at once.
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
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
            window.initialFirstResponder = controller.view
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
        case .glass(let radius):
            // Glass samples what is behind a window on screen; off screen it
            // stands in as the light tint it shows over a plain desktop.
            window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = NSHostingView(rootView: root.background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: radius, style: .continuous)))
        case .clear:
            window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = NSHostingView(rootView: root)
        }
        window.appearance = NSApp.appearance
        window.colorSpace = .sRGB
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(settle))
        try render(window, to: file, frame: host.isWindow)
        if resizable {
            window.setContentSize(Design.windowMinSize)
            try await Task.sleep(for: .milliseconds(settle))
            try render(window, to: output.appendingPathComponent("\(name)-shrunk-\(language).png"), frame: true)
        }
    }

    /// Draws the window at 2x: with `frame`, the title bar and toolbar too.
    private static func render(_ window: NSWindow, to file: URL, frame: Bool) throws {
        guard let content = window.contentView else { return }
        let view = frame ? (content.superview ?? content) : content
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: file)
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
        window.initialFirstResponder = controller.view
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
        if ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_MEASURE"] != nil {
            // What readying Trends ahead costs: the time its numbers take and the memory they add.
            let stats = StatsModel()
            let before = footprintMB()
            let started = ContinuousClock.now
            await stats.recompute(model: model, range: DateRangeSelection(kind: .last7, anchor: Date()))
            let elapsed = started.duration(to: .now)
            print(String(format: "STATS_PREFETCH loaded=%@ ms=%.0f footprintMB before=%.1f after=%.1f", stats.hasLoaded ? "yes" : "no",
                         Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15, before, footprintMB()))
            // How much of that is memory freed but not yet handed back to the system.
            _ = malloc_zone_pressure_relief(nil, 0)
            print(String(format: "STATS_RELIEF footprintMB=%.1f", footprintMB()))
            if let hold = ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_MEASURE_HOLD"].flatMap(Double.init) {
                print("STATS_HOLD pid=\(getpid())")
                try await Task.sleep(for: .seconds(hold))
            }
            // The 14-day interruption counts the Trends page adds once it is shown.
            let trendStart = ContinuousClock.now
            let beforeTrend = footprintMB()
            await stats.loadInterruptionTrend(model: model)
            let trend = trendStart.duration(to: .now)
            print(String(format: "STATS_TREND days=%d ms=%.0f footprintMB before=%.1f after=%.1f", stats.interruptionTrend?.count ?? 0,
                         Double(trend.components.seconds) * 1000 + Double(trend.components.attoseconds) / 1e15, beforeTrend, footprintMB()))
            let again = ContinuousClock.now
            await stats.recompute(model: model, range: DateRangeSelection(kind: .last7, anchor: Date()))
            let second = again.duration(to: .now)
            print(String(format: "STATS_PREFETCH_AGAIN ms=%.0f", Double(second.components.seconds) * 1000 + Double(second.components.attoseconds) / 1e15))
        }
        if ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_MEASURE_TODAY"] != nil {
            // What opening Today costs: the first (cold) refresh and two more with every cache warm.
            for run in 1...3 {
                let today = TodayModel()
                let started = ContinuousClock.now
                await today.refresh(model: model, dayOffset: 0)
                let elapsed = started.duration(to: .now)
                print(String(format: "TODAY_REFRESH run=%d ms=%.0f", run, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15))
                // The background read for the "new project" todo, which Today does not wait for.
                let suggested = ContinuousClock.now
                _ = await model.projectSuggestions()
                let waited = suggested.duration(to: .now)
                print(String(format: "SUGGESTIONS_READY run=%d ms=%.0f", run, Double(waited.components.seconds) * 1000 + Double(waited.components.attoseconds) / 1e15))
            }
            return
        }
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let quiet = calendar.date(byAdding: .day, value: -40, to: Date())!
        let wide = NSSize(width: 1460, height: 880), standard = NSSize(width: 1280, height: 820), small: NSSize = Design.windowMinSize
        let dark = false
        /// One state of one page at each size; `setup` runs on the built list.
        func main(_ name: String, _ page: SidebarItem, kind: DateRangeSelection.Kind = .day, anchor: Date = Date(),
                  sizes: [NSSize] = [wide], settle: Int = 1200,
                  setup: (ActivitiesModel) async -> Void = { _ in }) async throws {
            model.sidebarSelection = page
            model.range = DateRangeSelection(kind: kind, anchor: anchor)
            let activities = ActivitiesModel()
            activities.recompute(model: model, events: [])
            await setup(activities)
            for size in sizes {
                try await shoot("main-\(name)-\(Int(size.width))", MainWindowView(model: model, activities: activities), size: size, settle: settle)
            }
            model.activityFilter = nil
            model.activitySearch = ""
            model.activityTimeInterval = nil
        }
        func refilter(_ activities: ActivitiesModel) { activities.recompute(model: model, events: []) }

        // Projects, each on its own sample: the tab with none (recommendations open), with three and
        // recommendations, before the recommendations open, and Today coloured by project.
        func projectsPage(_ name: String, _ sample: AppModel, _ page: SidebarItem, sizes: [NSSize]) async throws {
            sample.timeFormat = "24"
            sample.sidebarSelection = page
            sample.organizationTab = .projects
            if page == .today { sample.todayDayOffset = 0 }
            sample.range = DateRangeSelection(kind: .day, anchor: Date())
            for size in sizes {
                try await shoot("main-\(name)-\(Int(size.width))", MainWindowView(model: sample), size: size, settle: page == .today ? 4000 : 6000)
            }
        }
        if only?.contains("proj") ?? true {
            try await projectsPage("projects-empty", model, .organization, sizes: [wide, small])
            let young = try RefinedPreview.fixture(days: 2)
            try await projectsPage("projects-gate", young, .organization, sizes: [wide, small])
            let sample = try RefinedPreview.fixture(projects: true)
            try await projectsPage("projects", sample, .organization, sizes: [wide, small])
            UserDefaults.standard.set("project", forKey: "todayTimelineColors")
            try await projectsPage("today-projects", sample, .today, sizes: [wide, small])
            // No project anywhere: the legend points at the Projects tab.
            let bare = try RefinedPreview.fixture(repos: false)
            try await projectsPage("today-projects-none", bare, .today, sizes: [wide, small])
            UserDefaults.standard.removeObject(forKey: "todayTimelineColors")
        }

        try await main("today", .today, sizes: [wide, standard, small])
        // "By project" on a day with no project: the empty state, not a quiet fall back to categories.
        UserDefaults.standard.set("project", forKey: "todayTimelineColors")
        try await main("today-by-project", .today, sizes: [wide, small])
        UserDefaults.standard.removeObject(forKey: "todayTimelineColors")
        model.todayDayOffset = -40
        try await main("today-empty", .today)
        model.todayDayOffset = 0

        // A day: sessions, the timeline, the inspector in each state.
        func longestSession(_ activities: ActivitiesModel) async {
            await activities.loadSessions(model: model)
            activities.selectedSession = activities.sessions.max { $0.recorded < $1.recorded }?.start
        }
        func longestBlock(_ activities: ActivitiesModel) {
            activities.mode = .timeline
            if let block = activities.timelineBlocks.filter(\.matchesFilter).max(by: { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }),
               let activity = block.activity {
                activities.select(activity, start: block.start)
            }
        }
        try await main("act-day", .activities, anchor: yesterday, sizes: [wide, standard, small], setup: longestSession)
        try await main("act-day-none", .activities, anchor: yesterday) { await $0.loadSessions(model: model) }
        try await main("act-day-closed", .activities, anchor: yesterday, sizes: [wide, small]) { activities in
            await activities.loadSessions(model: model)
            activities.showsInspector = false
        }
        try await main("act-day-timeline", .activities, anchor: yesterday, sizes: [wide, small]) { longestBlock($0) }
        try await main("act-day-heatmap", .activities, anchor: yesterday) { activities in
            let start = calendar.startOfDay(for: yesterday).addingTimeInterval(15 * 3600)
            model.activityTimeInterval = DateInterval(start: start, duration: 3600)
            refilter(activities)
        }
        try await main("act-day-filter", .activities, anchor: yesterday) { activities in
            model.activityFilter = "softwareDev"
            refilter(activities)
            longestBlock(activities)
        }
        try await main("act-day-empty", .activities, anchor: quiet)
        try await main("act-day-toast", .activities, anchor: yesterday) { activities in
            await longestSession(activities)
            activities.showUndo(String(localized: "已并入上一段")) {}
        }
        try await main("act-day-toast-split", .activities, anchor: yesterday, sizes: [wide, small]) { activities in
            await longestSession(activities)
            activities.showUndo(String(localized: "已拆开")) {}
        }
        try await main("act-day-toast-project", .activities, anchor: yesterday, sizes: [wide, small]) { activities in
            await longestSession(activities)
            activities.showUndo(String(localized: "已把这段归到「\("Atlas")」")) {}
        }
        try await main("act-day-toast-recat", .activities, anchor: yesterday, sizes: [wide, small]) { activities in
            await longestSession(activities)
            activities.showUndo(String(localized: "已改分类")) {}
        }

        // Seven days: the grouped list.
        try await main("act-week", .activities, kind: .last7, sizes: [wide, standard, small])
        try await main("act-week-filter", .activities, kind: .last7, sizes: [wide, small]) { activities in
            model.activityFilter = "softwareDev"
            refilter(activities)
        }
        try await main("act-week-app", .activities, kind: .last7) { $0.grouping = 1 }
        try await main("act-week-time", .activities, kind: .last7) { $0.grouping = 2 }
        try await main("act-week-search", .activities, kind: .last7) { activities in
            model.activitySearch = "github"
            refilter(activities)
        }
        try await main("act-week-row", .activities, kind: .last7, sizes: [wide, small]) { activities in
            if let group = activities.groups.first, let row = group.rows.first {
                activities.select(ActivitySelection(categoryID: group.id, rowID: row.id))
            }
        }
        try await main("act-week-closed", .activities, kind: .last7) { $0.showsInspector = false }

        try await main("trends", .stats, kind: .last7, sizes: [wide, standard, small], settle: 3500)
        // The whole page at both ends of the width, then with a day pointed at in the daily bars and in the interruptions.
        let tall = [NSSize(width: 1460, height: 2500), NSSize(width: small.width, height: 3700)]
        try await main("trends-long", .stats, kind: .last7, sizes: tall, settle: 9000)
        StatsView.previewHover = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -2, to: Date())!)
        InterruptionTrendCard.previewHover = StatsView.previewHover
        try await main("trends-hover", .stats, kind: .last7, sizes: [tall[0]], settle: 9000)
        StatsView.previewHover = nil
        InterruptionTrendCard.previewHover = nil
        try await main("trends-30", .stats, kind: .last30, settle: 3500)
        // Trends before its numbers: shot almost at once, the cards in their loading dress.
        try await main("trends-loading", .stats, kind: .last7, sizes: [wide, small], settle: 30)
        // The interruption radar: today, an hour pointed at, an hour chosen, an app pointed at, the week, the small card.
        do {
            let today = calendar.dateInterval(of: .day, for: Date())!
            let rose = InterruptionRose(data: await model.interruptions(for: today))
            var weekData = DayInterruptions()
            for offset in 0..<7 {
                let day = calendar.dateInterval(of: .day, for: calendar.date(byAdding: .day, value: -offset, to: today.start)!)!
                let value = await model.interruptions(for: day)
                weekData.episodes += value.episodes
            }
            let weekRose = InterruptionRose(data: weekData)
            let busiest = rose.hourTotals.firstIndex(of: rose.busiest) ?? 12
            let weekBusiest = weekRose.hourTotals.firstIndex(of: weekRose.busiest) ?? 12
            let top = rose.sourceIDs.first
            func radar(_ name: String, _ period: InterruptionRadarCard.Period = .today, hovered: Int? = nil, selected: Int? = nil, source: String? = nil) async throws {
                InterruptionRadarCard.previewState = (hovered, selected, source)
                try await shoot(name, InterruptionRadarCard(model: model, period: period).padding(24).background(WorkspaceBackground()),
                                size: NSSize(width: 960, height: period == .today ? 660 : 580), settle: 1200)
            }
            try await radar("radar-today")
            try await radar("radar-hover", hovered: busiest)
            try await radar("radar-selected", selected: busiest)
            try await radar("radar-app", source: top)
            try await radar("radar-week", .week)
            try await radar("radar-week-hover", .week, hovered: weekBusiest)
            InterruptionRadarCard.previewState = (busiest, nil, nil)
            try await shoot("radar-card-hover", InterruptionRadarCard(model: model, onOpen: {}).frame(width: 300).padding(24).background(WorkspaceBackground()),
                            size: NSSize(width: 350, height: 460), settle: 1200)
            InterruptionRadarCard.previewState = (nil, nil, nil)
            try await shoot("radar-card", InterruptionRadarCard(model: model, onOpen: {}).frame(width: 300).padding(24).background(WorkspaceBackground()),
                            size: NSSize(width: 350, height: 460), settle: 1200)
        }
        try await main("focus", .focus, sizes: [wide, standard, small])
        try model.focus?.start(minutes: 25)
        try await main("focus-running", .focus)
        model.focus?.finish(completed: false)
        // Earlier weeks: the sample only has the last four days, so give two older weeks a few sessions.
        if let store = model.focusStore {
            let displayCalendar = model.displayCalendar
            for (weeksBack, days) in [(1, [0, 1, 1, 3, 4]), (3, [2])] {
                let weekStart = FocusWeek.interval(weeksBack: weeksBack, now: Date(), calendar: displayCalendar).start
                for (index, day) in days.enumerated() {
                    let start = displayCalendar.date(byAdding: .day, value: day, to: weekStart)!.addingTimeInterval(Double(9 + index * 3) * 3600)
                    let session = try store.start(at: start, plannedSeconds: 2700)
                    try store.finish(id: session.id!, end: start.addingTimeInterval(Double(25 + index * 7) * 60), appBlocks: index % 2, siteBlocks: 0, completed: index != 2)
                }
            }
            // Taller than the usual window, so the history card at the foot of the page is in the frame.
            let tall = [NSSize(width: wide.width, height: 1150), NSSize(width: small.width, height: 1500)]
            for (name, weeksBack) in [("focus-week", 0), ("focus-prev-week", 1), ("focus-empty-week", 2)] {
                FocusWorkspaceView.previewWeeksBack = weeksBack
                try await main(name, .focus, sizes: tall)
            }
            FocusWorkspaceView.previewWeeksBack = 0
        }
        // Its queue reads 30 days before it draws.
        try await main("org", .organization, sizes: [wide, standard, small], settle: 4000)
        do {
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
            let rule = TitleRuleEditor(model: model, pending: PendingTitleRule(prefill: "WWDC", scopeKey: "youtube.com", // l10n: data
                                                                                scopeLabel: "youtube.com", categoryID: "learning"))
                .background(Design.surface)
            try await shoot("sheet-title-rule", rule, size: RefinedPreview.fitting(rule, dark: dark), host: .clear)
        }
    }
}
/// This process's footprint in MB, as Activity Monitor counts it.
private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

#endif
