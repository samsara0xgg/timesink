import SwiftUI
import Charts
import Observation
import os

private let menuBarDashboardLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "menuBarDashboard")

/// Data for the menu-bar popover dashboard: today's numbers, deltas vs
/// yesterday, the >=70 streak, top categories, and the hourly profile.
/// Mirrors the StatsModel pattern: one `recompute` from cached
/// `AppModel.rangedSpans(for:)` fetches, no DB access of its own.
@MainActor
@Observable
final class TodayDashboardModel {
    static let streakThreshold = 70
    private static let streakLookbackDays = 30

    var pulse: Int?
    /// Whole-day ratio comparison (today's pulse so far vs. yesterday's
    /// final pulse) -- unlike `focusDelta`/`totalDelta` below, this is
    /// intentionally NOT clipped to the same elapsed time-of-day: a ratio
    /// isn't biased by comparing a partial day to a full one the way a raw
    /// duration difference is.
    var pulseDelta: Int?
    var focus: TimeInterval = 0
    /// Today's focus time so far minus yesterday's focus time over the SAME
    /// elapsed time-of-day (yesterday's spans clipped to
    /// `[yesterdayStart, yesterdayStart + elapsed]` via `clippedToElapsed`)
    /// -- CONTROLLER RULING 14. Comparing today's partial day against
    /// yesterday's full day made this negative by construction until
    /// evening, every day.
    var focusDelta: TimeInterval?
    var total: TimeInterval = 0
    /// Same "same time-of-day" semantics as `focusDelta`; see its doc comment.
    var totalDelta: TimeInterval?
    var streakDays = 0
    var topCategories: [(id: String, name: String, colorHex: String, seconds: TimeInterval)] = []
    var maxCategorySeconds: TimeInterval = 0
    /// 24 entries, hours of tracked time per hour-of-day.
    var hourProfile: [Double] = Array(repeating: 0, count: 24)

    /// C4: the tightest (highest spent/limit ratio) up to 2 enabled budgets,
    /// for the popover's budget progress row. Empty when `budgetStore` isn't
    /// wired up yet (bootstrap) or no budgets are enabled.
    var budgetRows: [(id: String, name: String, colorHex: String, spent: TimeInterval, limit: TimeInterval)] = []
    /// Mirror of `settings.budgetWarnPercent`, refreshed alongside
    /// `budgetRows` -- lets the popover's caption read observable
    /// `@Observable` state instead of a live SQLite read from inside a
    /// SwiftUI body.
    var budgetWarnPercent = 20

    /// C1+ drill-down: every enabled budget (not just the tightest 2 --
    /// `budgetRows` above), same sort as `budgetRows`. Computed from the
    /// SAME `budgetStore.budgets()` read as `budgetRows` (see `recompute`)
    /// -- keeping the full list alongside the top-2 prefix costs no extra
    /// DB read, only the drill-down pane consuming it instead of throwing
    /// the rest away.
    var allBudgetRows: [(id: String, name: String, colorHex: String, spent: TimeInterval, limit: TimeInterval)] = []

    /// C1+ drill-down: today's raw categorized spans, kept around after
    /// `recompute` derives `byCategory`/`hourProfile`/`topCategories` from
    /// them, so a category-row hover (`CategoryDetailView`) can filter to
    /// just that category and re-run `Aggregator.profileByHourOfDay`/
    /// `durationByDomainOrApp` on demand -- no new `rangedSpans` query, just
    /// re-aggregating an array already in memory.
    var todayItems: [CategorizedSpan] = []

    /// C1+ drill-down: the 30-day per-day pulse array `streakDays` above was
    /// computed from (`StreakDotsView`'s dot pattern) -- see
    /// `refreshStreakIfDayChanged`, which keeps this alongside `streakDays`
    /// rather than discarding it, so no second `.last30` lookback runs just
    /// to render the dots.
    var streakLookbackPulses: [Int?] = []

    /// Calendar day (startOfDay) the 30-day streak lookback last ran for.
    /// That lookback is a full-month fetch+classify+day-split -- expensive
    /// enough that re-running it on every `recompute` (every dataVersion
    /// bump, i.e. every ~1.5s debounce window while live tracking is
    /// running and the popover is open) would cost this actor for a number
    /// that changes at most once a day. `@ObservationIgnored`: never read by
    /// the view, so it must not register through `@Observable` -- same
    /// reasoning as `AppModel.rangeCache`.
    @ObservationIgnored
    private var lastStreakDay: Date?

    /// Per-bump refresh: today, yesterday, and their deltas (unconditional,
    /// cheap -- `AppModel.rangedSpans(for:)` memoizes both ranges between
    /// `dataChanged()` calls). The 30-day streak lookback is gated
    /// separately: `forceStreak` recomputes it unconditionally (the
    /// popover's `.onAppear` -- `.menuBarExtraStyle(.window)` keeps this
    /// view's `@State dashboard` alive across dismissals, so without a
    /// force the day-changed guard below would only ever fire once per day,
    /// on the FIRST open, and every reopen that day would silently serve a
    /// stale number even if category edits or a threshold crossing changed
    /// it); the dataVersion-driven path passes `false` and relies on the
    /// guard. See `refreshStreakIfDayChanged`.
    func recompute(model: AppModel, forceStreak: Bool) {
        let calendar = Calendar.current
        let categories = model.resolver.categoriesByID

        let today = model.rangedSpans(for: .today())
        todayItems = today
        let byCategory = Aggregator.durationByCategory(today)
        pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories)
        focus = Aggregator.focusTime(durationByCategory: byCategory, categories: categories)
        total = Aggregator.totalDuration(today.map(\.span))

        let now = Date()
        let yesterdayAnchor = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let yesterday = model.rangedSpans(for: DateRangeSelection(kind: .day, anchor: yesterdayAnchor))
        let yByCategory = Aggregator.durationByCategory(yesterday)
        let yPulse = Aggregator.pulse(durationByCategory: yByCategory, categories: categories)
        pulseDelta = zip2(pulse, yPulse).map { $0 - $1 }

        // focus/total deltas compare the SAME elapsed time-of-day, not
        // today's partial day against yesterday's full day (see doc comments
        // on `focusDelta`/`totalDelta`); pulseDelta above stays a whole-day
        // ratio comparison and must not be clipped.
        let elapsed = now.timeIntervalSince(calendar.startOfDay(for: now))
        let yesterdayStart = calendar.startOfDay(for: yesterdayAnchor)
        let clippedYesterday = Self.clippedToElapsed(yesterday, windowStart: yesterdayStart, elapsed: elapsed)
        let clippedYByCategory = Aggregator.durationByCategory(clippedYesterday)
        let clippedYFocus = Aggregator.focusTime(durationByCategory: clippedYByCategory, categories: categories)
        let clippedYTotal = Aggregator.totalDuration(clippedYesterday.map(\.span))
        focusDelta = yesterday.isEmpty ? nil : focus - clippedYFocus
        totalDelta = yesterday.isEmpty ? nil : total - clippedYTotal

        topCategories = byCategory
            .compactMap { id, seconds -> (String, String, String, TimeInterval)? in
                guard let c = categories[id] else { return nil }
                return (id, c.name, c.colorHex, seconds)
            }
            .sorted { $0.3 > $1.3 }
            .prefix(3)
            .map { $0 }
        maxCategorySeconds = topCategories.first?.seconds ?? 0

        var profile = Array(repeating: 0.0, count: 24)
        for (hour, seconds) in Aggregator.profileByHourOfDay(today, calendar: calendar) {
            profile[hour] = seconds / 3600.0
        }
        hourProfile = profile

        // C4: reuses `byCategory` (already computed above) -- no new span
        // query, but `budgets()` itself still runs a DB read each recompute.
        budgetWarnPercent = model.settings.budgetWarnPercent
        let sortedBudgetRows = ((try? model.budgetStore?.budgets()) ?? [])
            .filter(\.enabled)
            .compactMap { budget -> (id: String, name: String, colorHex: String, spent: TimeInterval, limit: TimeInterval)? in
                guard let category = categories[budget.categoryID] else { return nil }
                return (budget.categoryID, category.name, category.colorHex,
                        byCategory[budget.categoryID] ?? 0, TimeInterval(budget.dailySeconds))
            }
            .sorted { lhs, rhs in
                // Deterministic tiebreak (fold-in 4): equal ratios (e.g. all
                // 0/limit first thing in the morning) would otherwise fall
                // back to `budgets()`'s undocumented fetch order.
                let lhsRatio = lhs.limit > 0 ? lhs.spent / lhs.limit : 0
                let rhsRatio = rhs.limit > 0 ? rhs.spent / rhs.limit : 0
                if lhsRatio != rhsRatio { return lhsRatio > rhsRatio }
                if lhs.limit != rhs.limit { return lhs.limit < rhs.limit }
                return lhs.id < rhs.id
            }
        // C1+: the drill-down (`BudgetProgressView`) wants every enabled
        // budget; the popover row itself only ever shows the tightest 2 --
        // both are sliced from this one sorted list, no second DB read.
        allBudgetRows = sortedBudgetRows
        budgetRows = Array(sortedBudgetRows.prefix(2))

        refreshStreakIfDayChanged(model: model, calendar: calendar, categories: categories, force: forceStreak)
    }

    /// Runs the 30-day streak lookback when `force` is true (every popover
    /// open) or when the calendar day has rolled over since the last run --
    /// skipped otherwise (every dataVersion-driven refresh within the same
    /// day the popover has already opened for). Accepted tradeoff: a
    /// streak-threshold crossing while the popover sits open without being
    /// reopened surfaces only on the next open, not live.
    private func refreshStreakIfDayChanged(
        model: AppModel, calendar: Calendar, categories: [String: Category], force: Bool
    ) {
        let todayStart = calendar.startOfDay(for: Date())
        guard force || lastStreakDay != todayStart else { return }
        lastStreakDay = todayStart

        let lookback = model.rangedSpans(for: DateRangeSelection(kind: .last30, anchor: Date()))
        let pulses = Self.dailyPulses(items: lookback, categories: categories,
                                       days: Self.streakLookbackDays,
                                       endingAt: Date(), calendar: calendar)
        // C1+: `StreakDotsView`'s dot pattern reuses this same 30-day
        // lookback's per-day breakdown -- kept alongside the derived
        // `streakDays` count instead of discarded, no second lookback.
        streakLookbackPulses = pulses
        streakDays = Self.streak(dailyPulses: pulses, threshold: Self.streakThreshold)
    }

    /// Lifted to `Aggregator.dailyPulses` (Task 7 C2) so `StatsModel` can
    /// share it; this stays as a one-line forward so this type's tests and
    /// call sites are unaffected. Pure, so `nonisolated` -- lets
    /// `TodayDashboardModelTests` call it synchronously without a
    /// `@MainActor` hop.
    nonisolated static func dailyPulses(items: [CategorizedSpan], categories: [String: Category],
                            days: Int, endingAt: Date, calendar: Calendar) -> [Int?] {
        Aggregator.dailyPulses(items: items, categories: categories, days: days, endingAt: endingAt, calendar: calendar)
    }

    /// Lifted to `Aggregator.clippedToElapsed` (Task 7 C2); see `dailyPulses`
    /// above. Used to compare yesterday's spans up to the same time-of-day as
    /// "now", instead of yesterday's full day (CONTROLLER RULING 14).
    nonisolated static func clippedToElapsed(
        _ items: [CategorizedSpan], windowStart: Date, elapsed: TimeInterval
    ) -> [CategorizedSpan] {
        Aggregator.clippedToElapsed(items, windowStart: windowStart, elapsed: elapsed)
    }

    /// Lifted to `Aggregator.streak` (Task 7 C2); see `dailyPulses` above.
    nonisolated static func streak(dailyPulses: [Int?], threshold: Int) -> Int {
        Aggregator.streak(dailyPulses: dailyPulses, threshold: threshold)
    }

    /// C1+ 分数环 hover 下钻数据源: for each tracked category, its
    /// color/name/duration, per-category pulse points (same 0-100 scale as
    /// `Aggregator.pulse`'s per-category weighting -- productivity +2 → 100,
    /// -2 → 0, linear between, clamped -- see `pulsePoints` below), and its
    /// share of today's TOTAL tracked time (plain `seconds / totalSeconds`,
    /// NOT weighted by points -- so the drill-down's bar width and this
    /// number agree, matching `categoryRow`'s existing bar convention).
    /// Sorted by weighted contribution (`seconds * points`) descending --
    /// what actually drove the pulse ring, unlike a plain-duration sort
    /// (that's `topCategories`); ties broken by `id` ascending for
    /// determinism, same tiebreak convention as `budgetRows`' sort.
    nonisolated static func scoreContributions(
        byCategory: [String: TimeInterval], categories: [String: Category]
    ) -> [(id: String, name: String, colorHex: String, seconds: TimeInterval, points: Double, share: Double)] {
        let totalSeconds = byCategory.values.reduce(0, +)
        guard totalSeconds > 0 else { return [] }
        return byCategory
            .compactMap { id, seconds -> (id: String, name: String, colorHex: String, seconds: TimeInterval, points: Double, share: Double)? in
                guard let category = categories[id] else { return nil }
                let points = pulsePoints(forProductivity: category.productivity)
                return (id, category.name, category.colorHex, seconds, points, seconds / totalSeconds)
            }
            .sorted { lhs, rhs in
                let lhsContribution = lhs.seconds * lhs.points
                let rhsContribution = rhs.seconds * rhs.points
                if lhsContribution != rhsContribution { return lhsContribution > rhsContribution }
                return lhs.id < rhs.id
            }
    }

    /// Same formula as `Aggregator.pulse`'s private per-category weighting
    /// (productivity +2 → 100, -2 → 0, linear between, clamped to 0...100)
    /// -- duplicated here rather than exposed from `Aggregator` since it's a
    /// one-line pure expression and that formula is intentionally private
    /// there (an implementation detail of the pulse average, not public
    /// API).
    nonisolated private static func pulsePoints(forProductivity productivity: Int) -> Double {
        let raw = 50.0 + Double(productivity) * 25.0
        return min(100, max(0, raw))
    }
}

private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

// MARK: - C1+ hover drill-down wiring

/// Identifies one of the popover's seven hover-drillable rows -- both the
/// key for `expandedDrill` (the in-popover degraded-path state) and the
/// discriminator `MenuBarDashboardView` uses to pick which content-builder
/// method to call. `category(id)` carries the row's category id so every
/// category row shares one case.
private enum DrillKind: Equatable {
    case score, compareFocus, compareTotal, streak, category(String), spark, budget
}

/// Captures the `NSWindow` hosting this SwiftUI subtree (the `MenuBarExtra`
/// popover's window under `.menuBarExtraStyle(.window)`) -- zero-size,
/// attached once at `MenuBarDashboardView`'s root. `view.window` is nil at
/// `makeNSView` time (the view isn't attached to the window hierarchy yet),
/// so both callbacks defer to the next run-loop turn.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { self.window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.window = nsView.window }
    }
}

/// Converts a SwiftUI `.global`-space rect (top-left origin, Y down -- the
/// hosting hierarchy's own coordinate space) to AppKit screen coordinates
/// (bottom-left origin) via `window`. `NSHostingView` runs SwiftUI's
/// coordinate space flipped to match AppKit's content view, so a single
/// Y-flip against the window's content height is the whole conversion.
@MainActor
private func screenRect(fromGlobal rect: CGRect, window: NSWindow) -> CGRect {
    let contentHeight = window.contentView?.frame.height ?? window.frame.height
    let flippedLocal = CGRect(x: rect.minX, y: contentHeight - rect.maxY, width: rect.width, height: rect.height)
    return window.convertToScreen(flippedLocal)
}

/// Hover wiring for one of the popover's seven drill-down panes: hovering
/// this view for 0.15s shows `content()` in `host`'s `NSPanel`, positioned
/// next to this view's on-screen frame (via `hostWindow` + `screenRect`);
/// the mouse leaving schedules the panel's close (`PanelHost`'s own 0.25s
/// default, canceled by hovering the panel itself -- see `PanelHost.show`).
/// `host.show` returning `false` (no host window yet, or a degenerate/
/// off-screen anchor frame -- NSPanel positioning against a `MenuBarExtra`'s
/// private layout is a known-risk area, spec §10) falls back to
/// `expandedDrill`: the same `content()` expanded in place, dismissed by an
/// explicit「收起」rather than by hover-out (avoids flicker for an
/// already-degraded, presumably less precise hover signal).
private struct DrillDownModifier<DrillContent: View>: ViewModifier {
    let host: PanelHost
    let kind: DrillKind
    let hostWindow: NSWindow?
    @Binding var expandedDrill: DrillKind?
    let content: () -> DrillContent

    private static var hoverDelay: TimeInterval { 0.15 }

    @State private var frame: CGRect = .zero
    @State private var showTask: Task<Void, Never>?

    func body(content base: Content) -> some View {
        base
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.frame(in: .global), initial: true) { _, newValue in
                            frame = newValue
                        }
                }
            )
            .onHover { hovering in
                if hovering {
                    host.cancelScheduledClose()
                    showTask?.cancel()
                    showTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.hoverDelay))
                        guard !Task.isCancelled else { return }
                        attemptShow()
                    }
                } else {
                    showTask?.cancel()
                    showTask = nil
                    host.scheduleClose()
                }
            }
    }

    private func attemptShow() {
        let anchorFrame = hostWindow.map { screenRect(fromGlobal: frame, window: $0) } ?? .zero
        if host.show(content(), near: anchorFrame) {
            if expandedDrill == kind { expandedDrill = nil }
        } else {
            expandedDrill = kind
        }
    }
}

extension View {
    fileprivate func drillDown<DrillContent: View>(
        host: PanelHost, kind: DrillKind, hostWindow: NSWindow?,
        expandedDrill: Binding<DrillKind?>,
        @ViewBuilder content: @escaping () -> DrillContent
    ) -> some View {
        modifier(DrillDownModifier(host: host, kind: kind, hostWindow: hostWindow,
                                    expandedDrill: expandedDrill, content: content))
    }
}

/// Degraded-path inline expansion for one drill-down pane: the SAME
/// `content` `PanelHost` would have shown, expanded in place with a
/// trailing「收起」-- the sanctioned fallback (spec §10) for when
/// `WindowAccessor`/`PanelHost` can't resolve a valid on-screen position.
/// Not a stub: this renders the real drill-down view, not a placeholder.
private struct ExpandedDrillView<Content: View>: View {
    let content: Content
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            content
            Button("收起", action: onCollapse)
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// The menu-bar popover dashboard (preview C1). Replaces the old
/// three-line text dropdown.
struct MenuBarDashboardView: View {
    let model: AppModel
    @State private var dashboard = TodayDashboardModel()
    @State private var gaugeProgress: Double = 0
    /// C4: switches the popover between the normal dashboard and the focus
    /// duration/block-list configuration screen. Superseded entirely by
    /// `FocusRunningView` whenever a session is actually running, regardless
    /// of this mode -- see `body`'s top-level `if`.
    @State private var popoverMode: PopoverMode = .dashboard
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// C1+ hover drill-down: one reused `PanelHost` (see its own doc
    /// comment for why it isn't `FocusHUDController`), the popover's own
    /// `NSWindow` (captured by `WindowAccessor`, used to convert a hovered
    /// row's local frame to screen coordinates), and which pane -- if any --
    /// is expanded in the degraded in-popover path.
    @State private var panelHost = PanelHost()
    @State private var hostWindow: NSWindow?
    @State private var expandedDrill: DrillKind?

    private var focusRunning: Bool { model.focus?.running != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if focusRunning {
                FocusRunningView(model: model)
            } else if popoverMode == .focusConfig {
                FocusConfigView(model: model, onCancel: { popoverMode = .dashboard }, onStart: startFocus)
            } else {
                HStack(spacing: 14) {
                    Button(action: openStatsToday) { scoreColumn }
                        .buttonStyle(.plain)
                        .drillDown(host: panelHost, kind: .score, hostWindow: hostWindow, expandedDrill: $expandedDrill) {
                            scoreBreakdownContent()
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: openStatsToday) {
                            kpiLine(value: Format.duration(dashboard.focus), label: "专注",
                                    delta: dashboard.focusDelta.map(Format.durationDelta))
                        }
                        .buttonStyle(.plain)
                        .drillDown(host: panelHost, kind: .compareFocus, hostWindow: hostWindow, expandedDrill: $expandedDrill) {
                            compareBaseContent(focus: true)
                        }
                        Button(action: openStatsToday) {
                            kpiLine(value: Format.duration(dashboard.total), label: "总计",
                                    delta: dashboard.totalDelta.map(Format.durationDelta))
                        }
                        .buttonStyle(.plain)
                        .drillDown(host: panelHost, kind: .compareTotal, hostWindow: hostWindow, expandedDrill: $expandedDrill) {
                            compareBaseContent(focus: false)
                        }
                        if dashboard.streakDays >= 2 {
                            Button(action: openStatsTrend) {
                                Text("连续 \(dashboard.streakDays) 天保持 \(TodayDashboardModel.streakThreshold) 分以上")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            .drillDown(host: panelHost, kind: .streak, hostWindow: hostWindow, expandedDrill: $expandedDrill) {
                                streakDotsContent()
                            }
                        }
                    }
                }
                if expandedDrill == .score {
                    ExpandedDrillView(content: scoreBreakdownContent()) { expandedDrill = nil }
                }
                if expandedDrill == .compareFocus {
                    ExpandedDrillView(content: compareBaseContent(focus: true)) { expandedDrill = nil }
                }
                if expandedDrill == .compareTotal {
                    ExpandedDrillView(content: compareBaseContent(focus: false)) { expandedDrill = nil }
                }
                if expandedDrill == .streak {
                    ExpandedDrillView(content: streakDotsContent()) { expandedDrill = nil }
                }
            }

            if !focusRunning && popoverMode == .dashboard {
                if !dashboard.topCategories.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(dashboard.topCategories, id: \.id) { entry in
                            Button(action: { openActivities(category: entry.id) }) {
                                categoryRow(entry)
                            }
                            .buttonStyle(.plain)
                            .drillDown(host: panelHost, kind: .category(entry.id), hostWindow: hostWindow, expandedDrill: $expandedDrill) {
                                categoryDetailContent(entry)
                            }
                            if expandedDrill == .category(entry.id) {
                                ExpandedDrillView(content: categoryDetailContent(entry)) { expandedDrill = nil }
                            }
                        }
                    }
                }

                if dashboard.total > 0 {
                    sparkline
                        .drillDown(host: panelHost, kind: .spark, hostWindow: hostWindow, expandedDrill: $expandedDrill) {
                            hourlyBigContent()
                        }
                    if expandedDrill == .spark {
                        ExpandedDrillView(content: hourlyBigContent()) { expandedDrill = nil }
                    }
                }

                if !dashboard.budgetRows.isEmpty {
                    Button(action: openBudgetSettings) { budgetSection }
                        .buttonStyle(.plain)
                        .drillDown(host: panelHost, kind: .budget, hostWindow: hostWindow, expandedDrill: $expandedDrill) {
                            budgetProgressContent()
                        }
                    if expandedDrill == .budget {
                        ExpandedDrillView(content: budgetProgressContent()) { expandedDrill = nil }
                    }
                }

                Button("开始专注") { popoverMode = .focusConfig }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }

            // Fold-in: kept OUTSIDE the dashboard-only block above -- this
            // warning is actionable (check Chrome Automation permission),
            // so hiding it for the length of a running focus session (up to
            // 90 minutes) would bite. Shown regardless of `popoverMode`/
            // `focusRunning`.
            if model.engine.chromeCaptureDegraded {
                Label("Chrome 网页读取已降级，请检查自动化权限", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()
            HStack {
                Button("打开 TimeSink") { openWindow(id: "main") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Text("设置") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("退出") {
                    model.engine.stop()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 300)
        .background(WindowAccessor(window: $hostWindow))
        // `.menuBarExtraStyle(.window)` keeps this view (and its @State
        // dashboard) alive across popover dismissals, so `.onAppear` fires
        // on every open, not just app launch -- force the streak lookback
        // there so a reopen always reflects same-day changes (a threshold
        // crossing, a category edit). The dataVersion path stays unforced;
        // see `TodayDashboardModel.recompute`.
        .onAppear { refresh(forceStreak: true) }
        .onChange(of: model.dataVersion) { refresh(forceStreak: false) }
        // C1+: the hover panel (and any degraded in-popover expansion) must
        // not outlive the popover itself -- spec §10's "弹出层关闭随之消失".
        .onDisappear {
            panelHost.closeNow()
            expandedDrill = nil
        }
    }

    /// Starts the session and, on success, drops back to the normal
    /// dashboard mode (superseded immediately by `FocusRunningView` since
    /// `focusRunning` is now true). A `start(minutes:)` failure (DB write
    /// error) leaves the config screen up rather than silently discarding
    /// the user's action.
    private func startFocus(minutes: Int) {
        guard let focus = model.focus else { return }
        do {
            try focus.start(minutes: minutes)
            popoverMode = .dashboard
        } catch {
            menuBarDashboardLogger.error("focus.start failed: \(String(describing: error))")
        }
    }

    private func refresh(forceStreak: Bool) {
        dashboard.recompute(model: model, forceStreak: forceStreak)
        let target = Double(dashboard.pulse ?? 0) / 100.0
        if reduceMotion {
            gaugeProgress = target
        } else {
            gaugeProgress = 0
            withAnimation(.spring(duration: 0.6)) { gaugeProgress = target }
        }
    }

    // MARK: - C1+ click-through routes

    /// 分数环 / 专注行 / 总计行 all deepen to the same destination: 统计·今天.
    private func openStatsToday() {
        model.openStats(range: .today())
        openWindow(id: "main")
    }

    /// 连续达标行 deepens to 统计 anchored on the same 30-day window its
    /// hover pane (`StreakDotsView`) shows.
    private func openStatsTrend() {
        model.openStats(range: DateRangeSelection(kind: .last30, anchor: Date()))
        openWindow(id: "main")
    }

    private func openActivities(category: String) {
        model.openActivities(category: category, range: .today())
        openWindow(id: "main")
    }

    /// R-T11g: activate-only, no `.setActivationPolicy(.regular)` -- same
    /// convention as `BudgetSettingsPane`'s click route and the
    /// `.settingsBudget` notification route (`TimeSinkApp.swift`); there's
    /// no matching restore-to-`.accessory` path for a policy flip here.
    private func openBudgetSettings() {
        model.settingsTab = .budget
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    // MARK: - C1+ drill-down content builders
    //
    // Each builds one hover pane's content from data `dashboard` already
    // loaded this recompute (plus, for `hourlyBigContent`'s 近 7 天 toggle,
    // a lazily-fetched `.last7` range) -- no view here reads `AppModel`/
    // `TrackerEngine` directly (see `DrillDownViews.swift`'s header
    // comment), so these methods are the one place that bridges dashboard
    // state into the pure drill-down view types.

    private func scoreBreakdownContent() -> ScoreBreakdownView {
        let byCategory = Aggregator.durationByCategory(dashboard.todayItems)
        let rows = TodayDashboardModel.scoreContributions(byCategory: byCategory, categories: model.resolver.categoriesByID)
            .map { ScoreBreakdownView.Row(id: $0.id, name: $0.name, colorHex: $0.colorHex,
                                           seconds: $0.seconds, points: $0.points, share: $0.share) }
        return ScoreBreakdownView(rows: rows, pulse: dashboard.pulse, pulseDelta: dashboard.pulseDelta)
    }

    private func compareBaseContent(focus: Bool) -> CompareBaseView {
        focus
            ? CompareBaseView(label: "专注时长比较", todayValue: dashboard.focus, delta: dashboard.focusDelta)
            : CompareBaseView(label: "总计时长比较", todayValue: dashboard.total, delta: dashboard.totalDelta)
    }

    private func streakDotsContent() -> StreakDotsView {
        StreakDotsView(dailyPulses: dashboard.streakLookbackPulses,
                        threshold: TodayDashboardModel.streakThreshold, streakDays: dashboard.streakDays)
    }

    private func categoryDetailContent(
        _ entry: (id: String, name: String, colorHex: String, seconds: TimeInterval)
    ) -> CategoryDetailView {
        let items = dashboard.todayItems.filter { $0.categoryID == entry.id }
        var bars = Array(repeating: 0.0, count: 24)
        for (hour, seconds) in Aggregator.profileByHourOfDay(items, calendar: Calendar.current) {
            bars[hour] = seconds / 3600.0
        }
        let subs = Aggregator.durationByDomainOrApp(items).prefix(5)
            .map { CategoryDetailView.SubEntry(id: $0.key, label: $0.label, seconds: $0.seconds) }
        return CategoryDetailView(name: entry.name, colorHex: entry.colorHex, seconds: entry.seconds,
                                   hourBars: bars, subs: Array(subs))
    }

    private func hourlyBigContent() -> HourlyBigView {
        let categories = model.resolver.categoriesByID
        let todayBars = Self.hourlyBars(items: dashboard.todayItems, categories: categories)
        return HourlyBigView(categories: categories, todayBars: todayBars, loadLast7Bars: {
            let items = model.rangedSpans(for: DateRangeSelection(kind: .last7, anchor: Date()))
            return Self.hourlyBars(items: items, categories: categories)
        })
    }

    private static func hourlyBars(items: [CategorizedSpan], categories: [String: Category]) -> [HourlyBigView.Bar] {
        let calendar = Calendar.current
        return Aggregator.stackedSeries(items, bucket: .hour, calendar: calendar).map { entry in
            HourlyBigView.Bar(hour: calendar.component(.hour, from: entry.bucketStart),
                               categoryID: entry.categoryID,
                               colorHex: categories[entry.categoryID]?.colorHex ?? "#8E8E93",
                               seconds: entry.seconds)
        }
    }

    private func budgetProgressContent() -> BudgetProgressView {
        let rows = dashboard.allBudgetRows.map {
            BudgetProgressView.Row(id: $0.id, name: $0.name, colorHex: $0.colorHex, spent: $0.spent, limit: $0.limit)
        }
        return BudgetProgressView(rows: rows, warnPercent: dashboard.budgetWarnPercent)
    }

    /// The score gauge plus its 环比 (pulse delta) chip, grouped together so
    /// the delta reads as "vs yesterday" for the ring specifically, not for
    /// an unrelated KPI row.
    private var scoreColumn: some View {
        VStack(spacing: 4) {
            scoreGauge
            if let pulseDelta = dashboard.pulseDelta {
                Text(Self.signed(pulseDelta) + " 分")
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(pulseDelta < 0 ? Color.red : Color.green)
            }
        }
    }

    private var scoreGauge: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 7)
            Circle()
                .trim(from: 0, to: gaugeProgress)
                .stroke(scoreColor(dashboard.pulse),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(dashboard.pulse.map(String.init) ?? "--")
                    .font(.title2.weight(.bold)).monospacedDigit()
                Text("生产力分").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 78, height: 78)
    }

    private func kpiLine(value: String, label: String, delta: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let delta {
                Text(delta)
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(delta.hasPrefix("-") ? Color.red : Color.green)
            }
        }
    }

    private func categoryRow(_ entry: (id: String, name: String, colorHex: String, seconds: TimeInterval)) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: entry.colorHex)).frame(width: 8, height: 8)
            Text(entry.name).font(.caption).frame(width: 60, alignment: .leading)
            GeometryReader { geo in
                let ratio = dashboard.maxCategorySeconds > 0
                    ? entry.seconds / dashboard.maxCategorySeconds : 0
                Capsule().fill(Color(hex: entry.colorHex))
                    .frame(width: max(4, geo.size.width * ratio))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 6)
            Text(Format.duration(entry.seconds))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// C4 budget progress row(s), between the sparkline and the Chrome
    /// degraded notice -- the tightest up to 2 enabled budgets, reusing
    /// `categoryRow`'s bar geometry with spent/limit on the right instead of
    /// a plain duration.
    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(dashboard.budgetRows, id: \.id) { row in
                budgetProgressRow(row)
            }
            Text("剩 \(dashboard.budgetWarnPercent)% 时提醒")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func budgetProgressRow(
        _ row: (id: String, name: String, colorHex: String, spent: TimeInterval, limit: TimeInterval)
    ) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: row.colorHex)).frame(width: 8, height: 8)
            Text(row.name).font(.caption).frame(width: 60, alignment: .leading)
            GeometryReader { geo in
                let ratio = row.limit > 0 ? min(1, row.spent / row.limit) : 0
                Capsule().fill(Color(hex: row.colorHex))
                    .frame(width: max(4, geo.size.width * ratio))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 6)
            Text("\(Format.duration(row.spent)) / \(Format.duration(row.limit))")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("今日分布").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("0 – 24 时").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Chart(Array(dashboard.hourProfile.enumerated()), id: \.offset) { hour, hours in
                AreaMark(x: .value("时", hour), y: .value("时长", hours))
                    .opacity(0.16)
                LineMark(x: .value("时", hour), y: .value("时长", hours))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 40)
        }
    }

    private static func signed(_ v: Int) -> String { v >= 0 ? "+\(v)" : "\(v)" }
}
