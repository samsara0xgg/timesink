import SwiftUI
import Charts
import Observation

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
        budgetRows = ((try? model.budgetStore?.budgets()) ?? [])
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
            .prefix(2)
            .map { $0 }

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
        streakDays = Self.streak(
            dailyPulses: Self.dailyPulses(items: lookback, categories: categories,
                                          days: Self.streakLookbackDays,
                                          endingAt: Date(), calendar: calendar),
            threshold: Self.streakThreshold)
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
}

private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focusRunning: Bool { model.focus?.running != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if focusRunning {
                FocusRunningView(model: model)
            } else if popoverMode == .focusConfig {
                FocusConfigView(model: model, onCancel: { popoverMode = .dashboard }, onStart: startFocus)
            } else {
                HStack(spacing: 14) {
                    scoreColumn
                    VStack(alignment: .leading, spacing: 4) {
                        kpiLine(value: Format.duration(dashboard.focus), label: "专注",
                                delta: dashboard.focusDelta.map(Format.durationDelta))
                        kpiLine(value: Format.duration(dashboard.total), label: "总计",
                                delta: dashboard.totalDelta.map(Format.durationDelta))
                        if dashboard.streakDays >= 2 {
                            Text("连续 \(dashboard.streakDays) 天保持 \(TodayDashboardModel.streakThreshold) 分以上")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }

            if !focusRunning && popoverMode == .dashboard {
                if !dashboard.topCategories.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(dashboard.topCategories, id: \.id) { entry in
                            categoryRow(entry)
                        }
                    }
                }

                if dashboard.total > 0 {
                    sparkline
                }

                if !dashboard.budgetRows.isEmpty {
                    budgetSection
                }

                if model.engine.chromeCaptureDegraded {
                    Label("Chrome 网页读取已降级，请检查自动化权限", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Button("开始专注") { popoverMode = .focusConfig }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
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
        // `.menuBarExtraStyle(.window)` keeps this view (and its @State
        // dashboard) alive across popover dismissals, so `.onAppear` fires
        // on every open, not just app launch -- force the streak lookback
        // there so a reopen always reflects same-day changes (a threshold
        // crossing, a category edit). The dataVersion path stays unforced;
        // see `TodayDashboardModel.recompute`.
        .onAppear { refresh(forceStreak: true) }
        .onChange(of: model.dataVersion) { refresh(forceStreak: false) }
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
            // Logged inside `FocusSessionController`/`FocusSessionStore`
            // already; nothing actionable to add here beyond staying on the
            // config screen so the user can retry.
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
