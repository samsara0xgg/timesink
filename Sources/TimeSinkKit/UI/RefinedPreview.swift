#if DEBUG
import AppKit
import SwiftUI
import TipKit
import Observation
import WebKit

/// Deterministic design review, isolated from tracking, permissions, sync and personal data.
public enum RefinedPreview {
    @MainActor private static var stage: RefinedPreviewStage?
    @MainActor public static func run() {
        try? Tips.configure()
        RefinedPreviewApp.main()
    }
    @MainActor fileprivate static func start(stage: RefinedPreviewStage) async {
        guard !stage.started else { return }
        stage.started = true
        self.stage = stage
        do {
            if CommandLine.arguments.contains("--perf-review") {
                var waited = 0
                while stage.window == nil, waited < 60 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
                guard let window = stage.window else { throw CocoaError(.fileWriteUnknown) }
                NSApp.appearance = NSAppearance(named: .darkAqua)
                window.appearance = NSApp.appearance
                stage.dark = true
                try await PerfReview.run(window: window) { view in
                    stage.size = mainSize
                    stage.content = view
                }
            } else {
                try await renderAll()
            }
        }
        catch { print("Preview failed: \(error)"); exit(1) }
        exit(0)
    }
    @MainActor private static func renderAll() async throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/design-audit-images/refined")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--motion-review") {
            try await renderMotion(to: output)
            try await renderBlockPage(to: output)
            return
        }
        let model = try fixture()
        model.timeFormat = "12"
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for (name, page) in [("today", SidebarItem.today), ("activities", .activities), ("trends", .stats), ("focus", .focus), ("organization", .organization)] {
                model.sidebarSelection = page
                // Activities shows yesterday: a whole synthetic day, not a morning.
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                model.range = DateRangeSelection(kind: page == .stats ? .last7 : .day, anchor: page == .activities ? yesterday : Date())
                let selectedActivities = ActivitiesModel()
                selectedActivities.recompute(model: model, events: [])
                // Mid-morning deep work: a folded stretch of editor, terminal and doc hops.
                let midMorning = Calendar.current.startOfDay(for: yesterday).addingTimeInterval(10.6 * 3600)
                if page == .activities, let item = model.rangedSpans().first(where: { $0.span.start >= midMorning }) {
                    selectedActivities.select(ActivitiesModel.selection(for: item), start: item.span.start)
                }
                try await render(MainWindowView(model: model, activities: selectedActivities), size: mainSize, dark: dark, to: output.appendingPathComponent("\(name)-\(suffix).png"))
            }
            let activityModel = ActivitiesModel()
            model.range = .today()
            activityModel.recompute(model: model, events: [])
            if let item = model.rangedSpans(for: .today()).first {
                activityModel.select(ActivitiesModel.selection(for: item), start: item.span.start)
                try await render(ActivityInspector(model: model, activities: activityModel), size: .init(width: 272, height: 760), dark: dark, to: output.appendingPathComponent("inspector-\(suffix).png"))
            }
            try await render(TitleRuleEditor(model: model, pending: .init(prefill: "SwiftUI", scopeKey: "stackoverflow.com", scopeLabel: "stackoverflow.com", categoryID: "learning")), size: .init(width: 460, height: 380), dark: dark, to: output.appendingPathComponent("title-rule-\(suffix).png"))
            for step in 0..<5 {
                try await render(OnboardingView(model: model, initialStep: step, checksPermissions: false), size: .init(width: 500, height: 470), dark: dark, to: output.appendingPathComponent("onboarding-\(step + 1)-\(suffix).png"))
            }
            model.sidebarSelection = .organization
            for (name, tab) in [("categories", SettingsTab.categories), ("rules", .rules)] {
                model.organizationTab = tab
                try await render(MainWindowView(model: model), size: mainSize, dark: dark, to: output.appendingPathComponent("\(name)-\(suffix).png"))
            }
            model.organizationTab = .uncategorized
            for (name, tab) in [("general", SettingsTab.general), ("privacy", .privacy), ("notifications", .notifications), ("account", .account), ("ai", .llm), ("about", .about)] {
                model.settingsTab = tab
                try await render(SettingsView(model: model), size: .init(width: 640, height: 560), dark: dark, to: output.appendingPathComponent("settings-\(name)-\(suffix).png"))
            }
            try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 760), dark: dark, to: output.appendingPathComponent("menu-\(suffix).png"))
            model.pauseTracking(minutes: 15)
            try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 570), dark: dark, to: output.appendingPathComponent("menu-paused-\(suffix).png"))
            model.resumeTracking()
            try model.focus?.start(minutes: 25)
            try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 510), dark: dark, to: output.appendingPathComponent("menu-focus-\(suffix).png"))
            if let focus = model.focus {
                try await render(FocusHUDContentView(appName: "信息", appKey: "com.apple.MobileSMS", hideCount: 1, controller: focus, onReturn: {}, onAllow: {}), size: .init(width: 312, height: 122), dark: dark, to: output.appendingPathComponent("focus-hud-\(suffix).png")) // l10n: data
            }
            model.focus?.finish(completed: false)
            try await renderFlyouts(model: model, dark: dark, suffix: suffix, to: output)
            model.sidebarSelection = .activities
            model.range = DateRangeSelection(kind: .day, anchor: Calendar.current.date(byAdding: .day, value: -40, to: Date())!)
            try await render(MainWindowView(model: model), size: mainSize, dark: dark, to: output.appendingPathComponent("activities-empty-\(suffix).png"))
            model.sidebarSelection = .stats
            model.range = DateRangeSelection(kind: .last30, anchor: Date())
            try await render(MainWindowView(model: model), size: mainSize, dark: dark, to: output.appendingPathComponent("trends-30-\(suffix).png"))
            model.range = .today()
            model.accessibilityGranted = false
            try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 520), dark: dark, to: output.appendingPathComponent("menu-permission-\(suffix).png"))
            model.accessibilityGranted = true
        }
        model.sidebarSelection = .today
        try await render(MainWindowView(model: model), size: .init(width: 800, height: 580), dark: false, to: output.appendingPathComponent("today-compact.png"))
        model.timeFormat = "24"
        try await render(MainWindowView(model: model), size: .init(width: 800, height: 580), dark: false, to: output.appendingPathComponent("today-compact-24h.png"))
        try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 760), dark: false, to: output.appendingPathComponent("menu-24h.png"))
        try FocusBlockPage.html.write(to: output.appendingPathComponent("blocked.html"), atomically: true, encoding: .utf8)
        print("Rendered native review surfaces to \(output.path)")
    }
    static let only = ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_ONLY"]
    static let locale = Locale(identifier: ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_LOCALE"] ?? "zh_CN")
    /// Main window captures, `WIDTHxHEIGHT`; defaults to the scene's default size.
    static let mainSize: NSSize = {
        let parts = (ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_MAIN"] ?? "1200x820").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : NSSize(width: 1200, height: 820)
    }()
    static func skips(_ url: URL) -> Bool { only.map { !url.lastPathComponent.contains($0) } ?? false }

    /// Puts a preview window on the Mac's built-in display, off the external
    /// screens someone is working on. With the lid closed it stays put.
    @MainActor static func moveToBuiltInDisplay(_ window: NSWindow) {
        let builtIn = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        guard let visible = builtIn?.visibleFrame else { return }
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX, y: visible.maxY))
    }

    /// Sizes the stage window on the built-in display and brings it forward
    /// for a capture.
    @MainActor static func present(_ window: NSWindow, size: NSSize) {
        window.setContentSize(size)
        moveToBuiltInDisplay(window)
        // Timing needs the window on screen, not in focus: leave the user's app in front.
        if CommandLine.arguments.contains("--perf-review") { window.orderFrontRegardless(); return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The size a flyout panel takes: `PanelHost` sizes it to fit.
    @MainActor static func fitting<V: View>(_ view: V, dark: Bool) -> NSSize {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, locale))
        host.layout()
        return host.fittingSize
    }

    @MainActor private static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) async throws {
        guard !skips(url) else { return }
        guard let stage else { throw CocoaError(.fileWriteUnknown) }
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        stage.window?.appearance = NSApp.appearance
        stage.dark = dark
        stage.size = size
        stage.content = AnyView(view.id(url.lastPathComponent))
        try await Task.sleep(for: .milliseconds(650))
        guard let window = stage.window else { throw CocoaError(.fileWriteUnknown) }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Wherever the pointer rests must not hover rows open mid-capture.
        window.ignoresMouseEvents = true
        present(window, size: size)
        try await Task.sleep(for: .milliseconds(250))
        guard let content = window.contentView else { throw CocoaError(.fileWriteUnknown) }
        // Main/settings captures include the real SwiftUI scene toolbar/titlebar.
        let capturesFrame = url.lastPathComponent.hasPrefix("settings-") || size.width >= 800
        let host = capturesFrame ? (content.superview ?? content) : content
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        FileHandle.standardError.write(Data(("Captured " + url.lastPathComponent + "\n").utf8))
    }
    /// The popover's hover panes, built the way `MenuBarDashboardView`
    /// builds them from its dashboard model.
    @MainActor private static func renderFlyouts(model: AppModel, dark: Bool, suffix: String, to output: URL) async throws {
        let dashboard = TodayDashboardModel()
        await dashboard.recompute(model: model, forceStreak: true)
        let categories = model.resolver.categoriesByID
        let byCategory = Aggregator.durationByCategory(dashboard.todayItems)
        let scoreRows = TodayDashboardModel.scoreContributions(byCategory: byCategory, categories: categories)
            .map { ScoreBreakdownView.Row(id: $0.id, name: $0.name, colorHex: $0.colorHex, seconds: $0.seconds, points: $0.points, share: $0.share) }
        var hourTotals: [String: TimeInterval] = [:]
        for entry in Aggregator.stackedSeries(dashboard.todayItems, bucket: .hour, calendar: .current) {
            hourTotals["\(Calendar.current.component(.hour, from: entry.bucketStart))|\(entry.categoryID)", default: 0] += entry.seconds
        }
        let bars = hourTotals.map { key, seconds in
            let parts = key.split(separator: "|")
            return HourlyBigView.Bar(hour: Int(parts[0])!, categoryID: String(parts[1]), colorHex: categories[String(parts[1])]?.colorHex ?? "#8E8E93", seconds: seconds)
        }
        let top = dashboard.topCategories.first!
        let items = dashboard.todayItems.filter { $0.categoryID == top.id }
        var hourBars = Array(repeating: 0.0, count: 24)
        for (hour, seconds) in Aggregator.profileByHourOfDay(items, calendar: .current) { hourBars[hour] = seconds / 3600 }
        let subs = Aggregator.durationByDomainOrApp(items).prefix(5).map { CategoryDetailView.SubEntry(id: $0.key, label: $0.label, seconds: $0.seconds) }
        let panes: [(String, AnyView)] = [
            ("score", AnyView(ScoreBreakdownView(rows: scoreRows, pulse: dashboard.pulse, pulseDelta: dashboard.pulseDelta))),
            ("compare", AnyView(CompareBaseView(label: String(localized: "投入时长比较"), todayValue: dashboard.focus, delta: dashboard.focusDelta))),
            ("streak", AnyView(StreakDotsView(dailyPulses: dashboard.streakLookbackPulses, threshold: TodayDashboardModel.streakThreshold, streakDays: dashboard.streakDays))),
            ("category", AnyView(CategoryDetailView(categoryID: top.id, name: top.name, colorHex: top.colorHex, seconds: top.seconds, hourBars: hourBars, subs: Array(subs), onOpenActivities: {}))),
            ("hourly", AnyView(HourlyBigView(categories: categories, todayBars: bars, loadLast7Bars: { bars }))),
            ("budget", AnyView(BudgetProgressView(rows: dashboard.allBudgetRows.map { BudgetProgressView.Row(id: $0.id, name: $0.name, colorHex: $0.colorHex, spent: $0.spent, limit: $0.limit) }, warnPercent: dashboard.budgetWarnPercent))),
        ]
        for (name, pane) in panes {
            // The panel is transparent; the pane draws its own card and shadow.
            let size = fitting(pane, dark: dark)
            try await render(pane.padding(24), size: NSSize(width: size.width + 48, height: size.height + 48), dark: dark, to: output.appendingPathComponent("flyout-\(name)-\(suffix).png"))
        }
    }

    @MainActor private static func renderMotion(to output: URL) async throws {
        guard let stage else { return }
        let frames = output.appendingPathComponent("number-motion-frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try await render(RefinedMotionProof(stage: stage), size: .init(width: 860, height: 260), dark: false, to: output.appendingPathComponent("number-motion-start.png"))
        var times: [[String: Any]] = []
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<120 {
            if index == 20 { stage.motionValue = "5h 59m" }
            if index == 70 { stage.motionValue = "6h 00m" }
            try await Task.sleep(for: .milliseconds(33))
            guard let content = stage.window?.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw CocoaError(.fileWriteUnknown) }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let filename = String(format: "%03d.png", index)
            try bitmap.representation(using: .png, properties: [:])!.write(to: frames.appendingPathComponent(filename))
            times.append(["file": filename, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start, "value": stage.motionValue])
        }
        let log: [String: Any] = ["origin": "Native SwiftUI frame recording; same RefinedNumberMotion modifier as Today and menu; synthetic values; left normal 280ms, right Reduce Motion 150ms", "frames": times]
        try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("number-motion-timing.json"))
    }

    @MainActor private static func renderBlockPage(to output: URL) async throws {
        let file = output.appendingPathComponent("blocked.html")
        try FocusBlockPage.html.write(to: file, atomically: true, encoding: .utf8)
        for dark in [false, true] {
            guard let stage else { return }
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "dark" : "light"
            stage.dark = dark; stage.size = NSSize(width: 900, height: 600)
            stage.content = AnyView(RefinedBlockProof(web: web).id(suffix))
            stage.window?.appearance = web.appearance
            try await Task.sleep(for: .milliseconds(350))
            stage.window?.setContentSize(stage.size)
            var url = URLComponents(url: file, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "domain", value: "bilibili.com"), URLQueryItem(name: "endsAt", value: String(Date().addingTimeInterval(1122).timeIntervalSince1970))]
            web.loadFileURL(url.url!, allowingReadAccessTo: output)
            try await Task.sleep(for: .seconds(2))
            let snapshot = try await web.takeSnapshot(configuration: nil)
            guard let data = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: output.appendingPathComponent("blocked-\(suffix).png"))
            FileHandle.standardError.write(Data(("Captured blocked-" + suffix + ".png\n").utf8))
        }
    }
    @MainActor static func fixture() throws -> AppModel {
        let db = try AppDatabase.openInMemory()
        let categories = CategoryStore(db), spans = SpanStore(db), settings = SettingsStore(db)
        SeedImporter.importIfNeeded(categoryStore: categories, settings: settings)
        // Corrections a person would have made: the seed files GitHub under
        // learning, and WWDC videos are study, not entertainment.
        try categories.setUserDomain("github.com", categoryID: "softwareDev")
        try categories.upsertUserTitleRule(pattern: "WWDC", scopeKey: "youtube.com", categoryID: "learning")
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        try db.write { db in
            for offset in 0..<30 {
                let day = calendar.date(byAdding: .day, value: -offset, to: today)!
                for var span in SyntheticDay.spans(for: day, seed: UInt64(offset), calendar: calendar) where span.start < Date() {
                    span.end = min(span.end, Date())
                    try span.insert(db)
                }
            }
        }
        let engine = TrackerEngine(spanStore: spans, settings: settings)
        let model = AppModel(categoryStore: categories, spanStore: spans, settings: settings, resolver: CategoryResolver(categoryStore: categories), engine: engine)
        let budget = BudgetStore(db)
        try budget.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        try budget.setBudget(categoryID: "communication", dailySeconds: 2700)
        model.budgetStore = budget
        let sessions = FocusSessionStore(db)
        model.focusStore = sessions
        model.focus = FocusSessionController(store: sessions, settings: settings)
        settings.setFocusBlockedApps(["com.apple.MobileSMS", "com.apple.Music"])
        settings.setFocusBlockedCategories(["socialMedia", "entertainment", "shopping"])
        for offset in 0..<4 {
            let start = today.addingTimeInterval(Double(-offset * 86400 + 10 * 3600))
            let session = try sessions.start(at: start, plannedSeconds: 2700)
            try sessions.finish(id: session.id!, end: start.addingTimeInterval(2700), appBlocks: offset % 2, siteBlocks: 1, completed: true)
        }
        model.dataChanged()
        return model
    }
}

/// A made-up developer's day with real-world churn: every file, tab or
/// thread change starts a new record, and short hops interrupt longer runs,
/// so a weekday lands near 2,000 records -- the fragmentation the timeline
/// has to fold. Seeded per day, so every render is identical. No real data.
private enum SyntheticDay {
    struct Source {
        let bundle: String, app: String, titles: [String], url: String?
    }
    private static let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? true
    private static func app(_ bundle: String, _ en: String, _ cn: String, _ titles: [String]) -> Source {
        Source(bundle: bundle, app: zh ? cn : en, titles: titles, url: nil)
    }
    private static func web(_ url: String, _ titles: [String]) -> Source {
        Source(bundle: "com.apple.Safari", app: "Safari", titles: titles, url: url)
    }
    // l10n: data -- everything below is fixture content, not UI text.
    static let xcode = app("com.apple.dt.Xcode", "Xcode", "Xcode", ["Aurora — TimelineView.swift", "Aurora — SessionStore.swift", "Aurora — FoldingTests.swift", "Aurora — Package.swift"])
    static let terminal = app("com.apple.Terminal", "Terminal", "终端", ["aurora — swift test", "aurora — git rebase", "aurora — zsh"]) // l10n: data
    static let mail = app("com.apple.mail", "Mail", "邮件", ["Inbox", "Re: Timeline review notes", "Weekly sync agenda"]) // l10n: data
    static let messages = app("com.apple.MobileSMS", "Messages", "信息", ["Design crew", "Mia", "Aurora launch"]) // l10n: data
    static let zoom = app("us.zoom.xos", "zoom.us", "zoom.us", ["Zoom Meeting"])
    static let notes = app("com.apple.Notes", "Notes", "备忘录", ["Timeline ideas", "Standup notes"]) // l10n: data
    static let music = app("com.apple.Music", "Music", "音乐", ["Focus Flow"]) // l10n: data
    static let sketchpad = app("app.sketchpad.mac", "Sketchpad", "Sketchpad", ["Untitled board"])
    static let github = web("https://github.com/aurora-app/aurora/pull/128", ["Fold timeline slivers · Pull Request #128 · aurora-app/aurora", "Issues · aurora-app/aurora", "Actions · aurora-app/aurora"])
    static let docs = web("https://developer.apple.com/documentation/swiftui", ["Layout | Apple Developer Documentation", "TimelineView | Apple Developer Documentation"])
    static let stack = web("https://stackoverflow.com/questions/74223423", ["SwiftUI list with thousands of rows is slow - Stack Overflow"])
    static let linear = web("https://linear.app/aurora/issue/AUR-212", ["AUR-212 Fold short switches on the timeline"])
    static let figma = web("https://www.figma.com/file/aurora", ["Aurora — Timeline v2 – Figma"])
    static let gdocs = web("https://docs.google.com/document/d/aurora", ["Aurora design doc - Google Docs"])
    static let youtube = web("https://www.youtube.com/watch?v=demo", ["WWDC23: Demystify SwiftUI performance - YouTube", "Lo-fi beats to code to - YouTube"])
    static let reddit = web("https://www.reddit.com/r/swift", ["r/swift"])
    static let news = web("https://www.nytimes.com", ["The New York Times - Breaking News"])
    static let shop = web("https://www.amazon.com/dp/demo", ["Amazon.com: USB-C hub"])

    /// A stretch of the day: long runs from `main`, hops to `hops`.
    struct Phase {
        let from: Double, to: Double
        let main: [Source], hops: [Source]
        let run: ClosedRange<Double>, hopChance: Double
    }
    static let weekday: [Phase] = [
        Phase(from: 8.7, to: 9.3, main: [mail, messages, news], hops: [github, linear], run: 30...240, hopChance: 0.5),
        Phase(from: 9.3, to: 11.7, main: [xcode, xcode, terminal], hops: [docs, stack, messages, github, terminal], run: 60...900, hopChance: 0.7),
        Phase(from: 11.7, to: 12.25, main: [zoom], hops: [notes], run: 1500...2100, hopChance: 0.3),
        Phase(from: 13.1, to: 14.8, main: [figma, figma, gdocs], hops: [messages, notes, youtube, sketchpad], run: 60...600, hopChance: 0.55),
        Phase(from: 14.8, to: 15.25, main: [youtube, reddit], hops: [messages, shop], run: 20...300, hopChance: 0.6),
        Phase(from: 15.25, to: 17.7, main: [github, github, xcode, terminal], hops: [linear, messages, mail, stack], run: 30...600, hopChance: 0.65),
        Phase(from: 17.7, to: 18.2, main: [notes, mail], hops: [music, sketchpad], run: 60...400, hopChance: 0.4),
    ]
    static let weekend: [Phase] = [
        Phase(from: 10.5, to: 11.4, main: [youtube, reddit, news], hops: [messages, shop], run: 60...600, hopChance: 0.5),
        Phase(from: 15.0, to: 16.2, main: [xcode, github], hops: [docs, messages], run: 120...900, hopChance: 0.5),
    ]

    static func spans(for day: Date, seed: UInt64, calendar: Calendar) -> [Span] {
        var rng = SplitMix64(state: seed &* 0x9E37_79B9 &+ 1)
        let phases = calendar.isDateInWeekend(day) ? weekend : weekday
        let shift = Double.random(in: -0.3...0.3, using: &rng) // hours
        var result: [Span] = []
        func add(_ source: Source, _ start: Date, _ seconds: Double) -> Date {
            let end = start.addingTimeInterval(seconds)
            let title = source.titles.randomElement(using: &rng)!
            result.append(Span(start: start, end: end, appBundleID: source.bundle, appName: source.app, title: title,
                               url: source.url, domain: source.url.flatMap(DomainParser.domain(from:))))
            return end
        }
        for phase in phases {
            var t = day.addingTimeInterval((phase.from + shift) * 3600)
            let end = day.addingTimeInterval((phase.to + shift) * 3600)
            while t < end {
                // A run on one source, cut into records by file/tab changes.
                let source = phase.main.randomElement(using: &rng)!
                let runEnd = min(end, t.addingTimeInterval(Double.random(in: phase.run, using: &rng)))
                while t < runEnd {
                    t = add(source, t, min(runEnd.timeIntervalSince(t), Double.random(in: 4...45, using: &rng)))
                }
                // Hops: mostly a few seconds, sometimes a real detour.
                if Double.random(in: 0..<1, using: &rng) < phase.hopChance {
                    for _ in 0..<Int.random(in: 1...3, using: &rng) {
                        let long = Double.random(in: 0..<1, using: &rng) < 0.15
                        t = add(phase.hops.randomElement(using: &rng)!, t, long ? Double.random(in: 30...150, using: &rng) : Double.random(in: 2...20, using: &rng))
                    }
                }
                // Tiny gaps fold away; a rare longer one is time away.
                let away = Double.random(in: 0..<1, using: &rng)
                t = t.addingTimeInterval(away < 0.04 ? Double.random(in: 180...600, using: &rng) : away < 0.3 ? Double.random(in: 1...8, using: &rng) : 0)
            }
        }
        return result
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
@MainActor @Observable fileprivate final class RefinedPreviewStage {
    var motionValue = "5h 58m"
    var started = false
    var content = AnyView(Color.clear)
    var size = NSSize(width: 1200, height: 820)
    var dark = false
    var window: NSWindow?
    var anchor: NSView?
}

private struct RefinedMotionProof: View {
    let stage: RefinedPreviewStage
    var body: some View {
        HStack(spacing: 20) {
            column(reduced: false)
            column(reduced: true)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(RefinedStyle.work)
    }
    private func column(reduced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reduced ? "减弱动态效果 · 150ms 淡变" : "普通模式 · 280ms 数字滚动") // l10n: data
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("今天已记录").font(.system(size: 12)).foregroundStyle(.secondary) // l10n: data
            Text(stage.motionValue).font(.system(size: 34, weight: .semibold)).tracking(-0.68).monospacedDigit()
                .modifier(RefinedNumberMotion(value: stage.motionValue, reducedOverride: reduced))
            Text("隔离预览 · 示例数据").font(.system(size: 11)).foregroundStyle(.secondary) // l10n: data
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).workspacePanel()
    }
}
private struct RefinedBlockProof: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

@MainActor private struct RefinedPreviewApp: App {
    @State private var stage = RefinedPreviewStage()
    var body: some Scene {
        Window("TimeSink · 示例数据验收", id: "refined-preview") { // l10n: data
            stage.content
                .frame(width: stage.size.width, height: stage.size.height)
                .environment(\.colorScheme, stage.dark ? .dark : .light)
                .preferredColorScheme(stage.dark ? .dark : .light)
                .environment(\.locale, RefinedPreview.locale)
                .background(RefinedWindowProbe(window: $stage.window))
                .task {
                    NSApp.setActivationPolicy(CommandLine.arguments.contains("--perf-review") ? .accessory : .regular)
                    await RefinedPreview.start(stage: stage)
                }
        }.windowResizability(.contentSize)
    }
}
private struct RefinedWindowProbe: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard self.window !== view.window else { return }
            self.window = view.window
            guard let window = view.window else { return }
            // Captures keep sRGB on any display, not the built-in panel's P3.
            // Timing runs keep the display's own space, as the app does:
            // converting every frame would inflate the render cost.
            if !CommandLine.arguments.contains("--perf-review") { window.colorSpace = .sRGB }
            RefinedPreview.moveToBuiltInDisplay(window)
        }
    }
}
#endif
