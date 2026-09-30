#if DEBUG
import AppKit
import SwiftUI
import GRDB

/// Main-thread cost of each interaction, measured the way a person feels it:
/// from the state change until the main run loop goes back to sleep. Runs on
/// the synthetic fixture, or on a read-only database copy named by
/// `TIMESINK_PERF_DB`. Never starts the tracker; prints timings only.
@MainActor enum PerfReview {
    /// One pass of the main run loop, from waking to sleeping again. Frame
    /// commits happen at the end of a pass, so a pass longer than a frame
    /// interval is a dropped frame.
    struct Pass { let start: Double; let end: Double; var ms: Double { (end - start) * 1000 } }

    struct Sample {
        let label: String
        /// State change to the end of the pass that drew it.
        let firstFrame: Double
        /// Main-thread time spent in the second after the change.
        let busy: Double
        let longest: Double
        /// State change to the end of the last pass longer than 2 ms.
        let settle: Double
        /// Passes over 16.7 ms: frames a 60 Hz display dropped.
        let drops: Int
        /// Main-thread CPU time in the window: unlike `busy`, not inflated
        /// when other processes compete for the cores.
        let cpu: Double
    }

    @MainActor final class Monitor {
        var passes: [Pass] = []
        private var woke: Double?
        init() {
            let after = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.woke = CACurrentMediaTime() }
            }
            // Ordered last, after SwiftUI's update and Core Animation's commit.
            let before = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let woke = self.woke else { return }
                    self.passes.append(Pass(start: woke, end: CACurrentMediaTime()))
                    self.woke = nil
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), after, .commonModes)
            CFRunLoopAddObserver(CFRunLoopGetMain(), before, .commonModes)
        }
    }

    private static let monitor = Monitor()
    private static var samples: [Sample] = []

    static func measure(_ label: String, window: Double = 1.0, _ change: () -> Void) async -> Sample {
        monitor.passes.removeAll()
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let t0 = CACurrentMediaTime()
        change()
        try? await Task.sleep(for: .seconds(window))
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
        let after = monitor.passes.filter { $0.end >= t0 && $0.start <= t0 + window }
        let sample = Sample(
            label: label,
            firstFrame: (after.first.map { $0.end - t0 } ?? 0) * 1000,
            busy: after.map { min($0.end, t0 + window) - max($0.start, t0) }.reduce(0, +) * 1000,
            longest: after.map(\.ms).max() ?? 0,
            settle: (after.last(where: { $0.ms > 2 }).map { $0.end - t0 } ?? 0) * 1000,
            drops: after.filter { $0.ms > 16.7 }.count,
            cpu: cpu)
        samples.append(sample)
        print(String(format: "PERF %@ first=%.1f busy=%.1f cpu=%.1f longest=%.1f settle=%.0f drops=%d",
                     label, sample.firstFrame, sample.busy, sample.cpu, sample.longest, sample.settle, sample.drops))
        return sample
    }

    static func run(window: NSWindow, show: (AnyView) -> Void) async throws {
        let model = try ProcessInfo.processInfo.environment["TIMESINK_PERF_DB"].map(realModel) ?? RefinedPreview.fixture()
        let activities = ActivitiesModel()
        let size = RefinedPreview.mainSize
        show(AnyView(MainWindowView(model: model, activities: activities)))
        RefinedPreview.present(window, size: size)
        try await Task.sleep(for: .seconds(1.5))
        print("PERF today_spans=\(model.rangedSpans(for: .today()).count) window=\(Int(size.width))x\(Int(size.height))")
        if let loop = ProcessInfo.processInfo.environment["TIMESINK_PERF_LOOP"] {
            try await profileLoop(loop, model: model, activities: activities)
            return
        }

        // Page switches: the first round builds each page, later rounds are warm.
        let pages: [(String, SidebarItem)] = [("activities", .activities), ("trends", .stats), ("focus", .focus), ("rules", .organization), ("today", .today)]
        let environment = ProcessInfo.processInfo.environment
        for round in 1...(environment["TIMESINK_PERF_ROUNDS"].flatMap(Int.init) ?? 3) {
            for (name, page) in pages {
                _ = await measure("switch_\(round)_to_\(name)") { navigate(model, to: page) }
            }
        }
        if environment["TIMESINK_PERF_ONLY"] == "switch" { report(); return }
        if environment["TIMESINK_PERF_ONLY"] == "activities" {
            model.sidebarSelection = .activities
            model.range = .today()
            try await Task.sleep(for: .seconds(1))
            for step in [-1, 1, -1, 1, -1, 1, -1, 1] {
                _ = await measure("activities_day_\(step > 0 ? "next" : "prev")") { model.range.shift(step) }
            }
            let items = model.rangedSpans(for: model.range)
            for item in [items[items.count / 5], items[items.count * 3 / 5], items[items.count / 2], items[items.count / 5]] {
                _ = await measure("activities_select") { activities.select(ActivitiesModel.selection(for: item), start: item.span.start) }
            }
            for _ in 1...4 {
                _ = await measure("activities_zoom_in") { activities.timelineHourHeight = TimelineZoom.stops.last ?? activities.timelineHourHeight }
                _ = await measure("activities_zoom_out") { activities.timelineHourHeight = TimelineZoom.stops.first ?? activities.timelineHourHeight }
            }
            for index in 1...3 {
                _ = await measure("write_activities_\(index)") { model.engineDataChangedForTesting(writtenFrom: Date().addingTimeInterval(-30)) }
            }
            try await scroll(window: window, label: "scroll_activities")
            report(); return
        }

        // A tracker write lands about every 1.5 s while recording.
        for (name, page) in pages {
            model.sidebarSelection = page
            if page == .activities { model.range = .today() }
            try await Task.sleep(for: .seconds(1))
            for index in 1...3 {
                _ = await measure("write_\(name)_\(index)") { model.engineDataChangedForTesting(writtenFrom: Date().addingTimeInterval(-30)) }
            }
        }

        // Day stepping in Activities, and range changes in Trends.
        model.sidebarSelection = .activities
        model.range = .today()
        try await Task.sleep(for: .seconds(1))
        for step in [-1, -1, -1, 1, 1, 1] {
            _ = await measure("activities_day_\(step > 0 ? "next" : "prev")") { model.range.shift(step) }
        }
        if let item = model.rangedSpans(for: model.range).dropFirst(40).first {
            _ = await measure("activities_select") { activities.select(ActivitiesModel.selection(for: item), start: item.span.start) }
        }
        _ = await measure("activities_zoom_in") { activities.timelineHourHeight = TimelineZoom.stops.last ?? activities.timelineHourHeight }
        _ = await measure("activities_zoom_out") { activities.timelineHourHeight = TimelineZoom.stops.first ?? activities.timelineHourHeight }
        model.sidebarSelection = .stats
        for kind in [DateRangeSelection.Kind.last30, .week, .month, .last7] {
            _ = await measure("trends_range_\(kind)") { model.range = DateRangeSelection(kind: kind, anchor: Date()) }
        }

        // Scrolling: one pass per step, stepped at 120 Hz.
        for page in [SidebarItem.today, .activities] {
            model.sidebarSelection = page
            model.range = .today()
            try await Task.sleep(for: .seconds(1))
            try await scroll(window: window, label: "scroll_\(page)")
        }

        // The popover, built fresh the way a menu bar window builds it.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: RefinedStyle.popoverWidth, height: 700),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        for index in 1...4 {
            var host: NSHostingView<AnyView>?
            var firstHeight: CGFloat = 0
            _ = await measure("popover_open_\(index)") {
                let view = NSHostingView(rootView: AnyView(MenuBarDashboardView(model: model).environment(\.locale, RefinedPreview.locale)))
                panel.contentView = view
                firstHeight = view.fittingSize.height
                panel.setContentSize(view.fittingSize)
                RefinedPreview.moveToBuiltInDisplay(panel)
                panel.orderFrontRegardless()
                host = view
            }
            print(String(format: "PERF popover_open_%d height_first=%.0f height_settled=%.0f", index, firstHeight, host?.fittingSize.height ?? 0))
            _ = await measure("popover_write_\(index)") { model.engineDataChangedForTesting(writtenFrom: Date().addingTimeInterval(-30)) }
            panel.orderOut(nil)
            panel.contentView = nil
            try await Task.sleep(for: .milliseconds(300))
        }

        report()
    }

    /// What a sidebar click does.
    private static func navigate(_ model: AppModel, to page: SidebarItem) {
        switch page {
        case .today: model.openToday()
        case .stats: model.openStats(range: DateRangeSelection(kind: .last7, anchor: Date()))
        default: model.sidebarSelection = page
        }
    }

    /// Repeats one interaction for a sampling profiler: `sample <pid>` while it runs.
    private static func profileLoop(_ loop: String, model: AppModel, activities: ActivitiesModel) async throws {
        let pause = Duration.milliseconds(500)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: RefinedStyle.popoverWidth, height: 700),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        if loop.hasPrefix("write_") {
            model.sidebarSelection = [ "write_today": .today, "write_activities": .activities, "write_trends": .stats ][loop] ?? .today
            model.range = model.sidebarSelection == .stats ? DateRangeSelection(kind: .last7, anchor: Date()) : .today()
        }
        try await Task.sleep(for: .seconds(1))
        print("LOOP_START pid=\(getpid())")
        fflush(stdout)
        let sampler = Process()
        if let out = ProcessInfo.processInfo.environment["TIMESINK_PERF_SAMPLE"] {
            sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sampler.arguments = [String(getpid()), "12", "-mayDie", "-file", out]
            try sampler.run()
        }
        let end = Date().addingTimeInterval(16)
        while Date() < end {
            switch loop {
            case "activities", "today", "trends", "rules":
                let page: SidebarItem = ["activities": .activities, "today": .today, "trends": .stats, "rules": .organization][loop]!
                navigate(model, to: page)
                try await Task.sleep(for: pause)
                navigate(model, to: .focus)
            case "select":
                model.sidebarSelection = .activities
                let items = model.rangedSpans(for: model.range)
                for item in [items[items.count / 5], items[items.count * 3 / 5]] {
                    activities.select(ActivitiesModel.selection(for: item), start: item.span.start)
                    try await Task.sleep(for: pause)
                }
            case "day":
                model.sidebarSelection = .activities
                model.range.shift(-1)
                try await Task.sleep(for: pause)
                model.range.shift(1)
            case "popover":
                let view = NSHostingView(rootView: AnyView(MenuBarDashboardView(model: model).environment(\.locale, RefinedPreview.locale)))
                panel.contentView = view
                panel.setContentSize(view.fittingSize)
                RefinedPreview.moveToBuiltInDisplay(panel)
                panel.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(900))
                panel.orderOut(nil)
                panel.contentView = nil
            default:
                model.engineDataChangedForTesting(writtenFrom: Date().addingTimeInterval(-30))
            }
            try await Task.sleep(for: pause)
        }
        if sampler.isRunning { sampler.waitUntilExit() }
        print("LOOP_END")
    }

    /// Scrolls the tallest scroll view in the window down and back, one step per frame.
    private static func scroll(window: NSWindow, label: String) async throws {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        guard let content = window.contentView,
              let target = scrollViews(content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = target.documentView else { return }
        let travel = max(0, document.frame.height - target.contentView.bounds.height)
        print(String(format: "PERF %@ travel=%.0f", label, travel))
        guard travel > 0 else { return }
        monitor.passes.removeAll()
        let t0 = CACurrentMediaTime()
        let steps = 90
        for step in 0...(steps * 2) {
            let progress = Double(step <= steps ? step : steps * 2 - step) / Double(steps)
            target.contentView.scroll(to: NSPoint(x: 0, y: travel * progress))
            target.reflectScrolledClipView(target.contentView)
            try await Task.sleep(for: .milliseconds(8))
        }
        let passes = monitor.passes.filter { $0.end >= t0 }.map(\.ms).sorted()
        guard !passes.isEmpty else { return }
        let p95 = passes[min(passes.count - 1, Int(Double(passes.count) * 0.95))]
        print(String(format: "PERF %@ passes=%d median=%.1f p95=%.1f longest=%.1f drops=%d", label, passes.count,
                     passes[passes.count / 2], p95, passes.last!, passes.filter { $0 > 16.7 }.count))
    }

    private static func report() {
        let groups = Dictionary(grouping: samples) { sample in
            // switch_2_to_today and switch_3_to_today are one warm group.
            let parts = sample.label.split(separator: "_")
            if sample.label.hasPrefix("switch_") { return parts[1] == "1" ? "switch_cold_\(parts.last!)" : "switch_warm_\(parts.last!)" }
            if sample.label.hasPrefix("write_") || sample.label.hasPrefix("popover_") { return parts.dropLast().joined(separator: "_") }
            return sample.label
        }
        print("PERF summary (ms; median of repeats, worst longest)")
        for (key, values) in groups.sorted(by: { $0.key < $1.key }) {
            func median(_ path: KeyPath<Sample, Double>) -> Double { values.map { $0[keyPath: path] }.sorted()[values.count / 2] }
            print(String(format: "PERF_SUMMARY %@ n=%d first=%.1f busy=%.1f cpu=%.1f longest=%.1f settle=%.0f drops=%d", key, values.count,
                         median(\.firstFrame), median(\.busy), median(\.cpu), values.map(\.longest).max() ?? 0, median(\.settle), values.map(\.drops).max() ?? 0))
        }
    }

    private static func realModel(path: String) throws -> AppModel {
        var configuration = Configuration()
        configuration.readonly = true
        let db = try DatabasePool(path: path, configuration: configuration)
        let categories = CategoryStore(db), spans = SpanStore(db), settings = SettingsStore(db)
        let model = AppModel(categoryStore: categories, spanStore: spans, settings: settings,
                             resolver: CategoryResolver(categoryStore: categories),
                             engine: TrackerEngine(spanStore: spans, settings: settings))
        model.budgetStore = BudgetStore(db)
        model.focusStore = FocusSessionStore(db)
        return model
    }
}
#endif
