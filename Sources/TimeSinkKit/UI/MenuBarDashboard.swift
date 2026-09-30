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
    var overview: DayOverview?
    /// Yesterday's recorded time up to the same time of day (see
    /// `focusDelta`); nil when yesterday has no records.
    var yesterdayTotal: TimeInterval?
    /// Same "same time-of-day" semantics as `focusDelta`, in whole minutes
    /// (`Format.minuteDelta`) so it matches the two durations shown.
    var totalDelta: TimeInterval? { yesterdayTotal.map { Format.minuteDelta(total, $0) } }
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

    @ObservationIgnored private let streakWorker = StatsWorker()
    @ObservationIgnored private var lastStreakUpdate: Date?
    @ObservationIgnored private var lastStreakEditVersion = -1
    @ObservationIgnored private var streakGeneration = 0

    /// Refresh today's small summary immediately; prepare the month-long streak
    /// on a background actor. Reopening within a minute reuses the snapshot.
    /// `headlineOnly` stops after the score, the same-time comparison and
    /// the streak: the Today page shows nothing else from here.
    func recompute(model: AppModel, forceStreak: Bool, headlineOnly: Bool = false) async {
        let calendar = Calendar.current
        let categories = model.resolver.categoriesByID

        let today = model.rangedSpans(for: .today())
        todayItems = today
        let byCategory = Aggregator.durationByCategory(today)
        pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories)
        focus = Aggregator.focusTime(durationByCategory: byCategory, categories: categories)
        total = Aggregator.totalDuration(today.map(\.span))

        let now = Date()
        if !headlineOnly { overview = DayOverview(items: today, categories: categories, sessions: [], now: now) }
        let yesterdayAnchor = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let yesterday = model.rangedSpans(for: DateRangeSelection(kind: .day, anchor: yesterdayAnchor))
        let yByCategory = Aggregator.durationByCategory(yesterday)
        let yPulse = Aggregator.pulse(durationByCategory: yByCategory, categories: categories)
        pulseDelta = zip2(pulse, yPulse).map { $0 - $1 }

        // focus/total deltas compare the SAME elapsed time-of-day, not
        // today's partial day against yesterday's full day (see doc comments
        // on `focusDelta`/`totalDelta`); pulseDelta above stays a whole-day
        // ratio comparison and must not be clipped.
        // The same wall-clock time yesterday: on a DST day, seconds since
        // midnight would land an hour off.
        let yesterdayStart = calendar.startOfDay(for: yesterdayAnchor)
        let elapsed = yesterdayAnchor.timeIntervalSince(yesterdayStart)
        let clippedYesterday = Self.clippedToElapsed(yesterday, windowStart: yesterdayStart, elapsed: elapsed)
        let clippedYByCategory = Aggregator.durationByCategory(clippedYesterday)
        let clippedYFocus = Aggregator.focusTime(durationByCategory: clippedYByCategory, categories: categories)
        let clippedYTotal = Aggregator.totalDuration(clippedYesterday.map(\.span))
        focusDelta = yesterday.isEmpty ? nil : Format.minuteDelta(focus, clippedYFocus)
        yesterdayTotal = yesterday.isEmpty ? nil : clippedYTotal
        if headlineOnly {
            await refreshStreakIfDayChanged(model: model, calendar: calendar, force: forceStreak)
            return
        }

        topCategories = byCategory
            .compactMap { id, seconds -> (String, String, String, TimeInterval)? in
                guard let c = categories[id] else { return nil }
                return (id, c.name, c.colorHex, seconds)
            }
            .sorted { $0.3 > $1.3 }
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

        await refreshStreakIfDayChanged(model: model, calendar: calendar, force: forceStreak)
    }

    private func refreshStreakIfDayChanged(
        model: AppModel, calendar: Calendar, force: Bool
    ) async {
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let editVersion = model.dataEditVersion
        guard force || lastStreakDay != todayStart || lastStreakEditVersion != editVersion
                || now.timeIntervalSince(lastStreakUpdate ?? .distantPast) >= 60 else { return }
        streakGeneration += 1
        let request = streakGeneration
        do {
            let pulses = try await streakWorker.dailyPulses(store: model.spanStore,
                classification: model.resolver.snapshot(), categories: model.resolver.categoriesByID,
                editVersion: editVersion, dataVersion: model.dataVersion,
                days: Self.streakLookbackDays, endingAt: now, calendar: calendar)
            try Task.checkCancellation()
            guard request == streakGeneration, model.dataEditVersion == editVersion else { return }
            streakLookbackPulses = pulses
            streakDays = Self.streak(dailyPulses: pulses, threshold: Self.streakThreshold)
            lastStreakDay = todayStart
            lastStreakEditVersion = editVersion
            lastStreakUpdate = now
        } catch is CancellationError {
            // A dismissed popover keeps its last completed snapshot for reopening.
        } catch {
            menuBarDashboardLogger.error("streak refresh failed: \(String(describing: error))")
        }
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
    /// (that's `topCategories`). Ties (R-T13a: EVERY floor-points category,
    /// e.g. all of socialMedia/entertainment, ties at contribution 0 --
    /// alphabetical alone would rank a 1-minute row above a 3-hour one)
    /// break by `seconds` descending first, THEN `id` ascending for
    /// determinism.
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
                if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
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

/// A zero-size probe view, flipped to match SwiftUI's own top-left-origin,
/// Y-down coordinate convention -- lets `NSView.convert(_:to:)` correctly
/// reinterpret a SwiftUI `.global`-space rect without a hand-rolled Y-flip
/// (F4 fix: the previous implementation hand-computed a flip against
/// `window.contentView`'s height, assuming that view's origin was `.zero`
/// in window base coordinates and making no X adjustment at all --
/// `NSView.convert(_:to:)` is AppKit's own, assumption-free coordinate-space
/// machinery; it only needs the source view's `isFlipped` to accurately
/// describe how to interpret its own bounds).
private final class FlippedProbeView: NSView {
    override var isFlipped: Bool { true }
}

/// Captures the `NSWindow` hosting this SwiftUI subtree (the `MenuBarExtra`
/// popover's window under `.menuBarExtraStyle(.window)`) plus the probe
/// view itself (the reference `screenRect` converts through) -- zero-size,
/// attached once at `MenuBarDashboardView`'s root. `view.window` is nil at
/// `makeNSView` time (the view isn't attached to the window hierarchy yet),
/// so both callbacks defer to the next run-loop turn. Writes are guarded
/// (F3 fix): SwiftUI happens to dedupe equal `@State` writes today, but
/// that's not a contract worth leaning on -- `updateNSView` runs on every
/// SwiftUI update pass, and an unconditional write is a latent
/// self-sustaining update cycle if that deduping behavior ever changes.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = FlippedProbeView(frame: .zero)
        DispatchQueue.main.async {
            self.window = view.window
            self.anchorView = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if self.window !== nsView.window { self.window = nsView.window }
            if self.anchorView !== nsView { self.anchorView = nsView }
        }
    }
}

/// Converts a SwiftUI `.global`-space rect to AppKit screen coordinates:
/// `anchorView.convert(_:to:)` (source view's own bounds space -> the
/// window's base coordinate system), then `window.convertToScreen(_:)`
/// (window base -> screen). `anchorView` must be a `FlippedProbeView` so
/// `convert` interprets `rect`'s Y the way SwiftUI's `.global` space
/// actually measures it (F4 fix -- see `FlippedProbeView`'s doc comment).
@MainActor
private func screenRect(fromGlobal rect: CGRect, anchorView: NSView, window: NSWindow) -> CGRect {
    let localRect = anchorView.convert(rect, to: nil)
    return window.convertToScreen(localRect)
}

/// Hover wiring for one of the popover's seven drill-down panes: hovering
/// this view for 0.15s shows `content()` in `host`'s `NSPanel`, positioned
/// next to the popover window (via `hostWindow`/`anchorView` + `screenRect`
/// -- fold-in 3: X anchors off the WINDOW's own frame, not this row's
/// narrower one; Y stays row-anchored, see `attemptShow`); the mouse
/// leaving schedules the panel's close (`PanelHost`'s own 0.25s default,
/// canceled by hovering the panel itself -- see `PanelHost.show`).
/// `host.show` returning `false` (no host window/anchor view yet, or a
/// degenerate/off-screen anchor frame -- NSPanel positioning against a
/// `MenuBarExtra`'s private layout is a known-risk area, spec §10) falls
/// back to `expandedDrill`: the same `content()` expanded in place,
/// dismissed by an explicit「收起」rather than by hover-out (avoids flicker
/// for an already-degraded, presumably less precise hover signal).
///
/// `shownKind` (shared across every row via one `MenuBarDashboardView`-level
/// binding) tracks which pane, if any, is CURRENTLY showing in `host`'s
/// panel -- `.onDisappear` uses it to close that panel if THIS row (the one
/// that showed it) is torn down before its own hover-out ever fires (F2:
/// reachable when the popover dismisses mid-hover-in, or when this row
/// drops out of `topCategories` on a `dataVersion` recompute).
private struct DrillDownModifier<DrillContent: View>: ViewModifier {
    let host: PanelHost
    let kind: DrillKind
    let hostWindow: NSWindow?
    let anchorView: NSView?
    @Binding var expandedDrill: DrillKind?
    @Binding var shownKind: DrillKind?
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
                    guard expandedDrill != kind else { return }
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
            .accessibilityAction(named: "展开详情") {
                showTask?.cancel()
                host.closeNow()
                expandedDrill = kind
            }
            .onDisappear {
                // F2: a pending 0.15s show timer must never fire after this
                // row is gone. Two reachable orderings: (a) hover-in armed
                // the timer, then a click within 150ms dismisses the
                // popover before it elapses; (b) this row is removed by a
                // `dataVersion` recompute (e.g. it fell out of
                // `topCategories`) with no `onHover(false)` ever firing to
                // schedule a close on its own.
                showTask?.cancel()
                showTask = nil
                if shownKind == kind {
                    host.closeNow()
                    shownKind = nil
                }
                if expandedDrill == kind {
                    expandedDrill = nil
                }
            }
    }

    private func attemptShow() {
        if host.shouldDeferSwitch() {
            showTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                attemptShow()
            }
            return
        }
        guard let hostWindow, let anchorView else {
            // WindowAccessor never resolved a window/probe view -- the
            // sanctioned fallback (spec §10): expand in place.
            expandedDrill = kind
            return
        }
        guard hostWindow.isVisible else {
            // F2 belt-and-suspenders: the popover already closed underneath
            // this pending timer -- `.onDisappear` above should already
            // have canceled it; this guards a race. Nothing live left to
            // anchor against or to expand inline into.
            return
        }
        let rowFrame = screenRect(fromGlobal: frame, anchorView: anchorView, window: hostWindow)
        // Fold-in 3: synthesize an anchor whose X-extent is the POPOVER
        // WINDOW's own screen frame (so `PanelHost.position`'s existing
        // `anchorFrame.minX - size.width - gap` / `.maxX + gap` logic sits
        // the panel just outside the WHOLE popover, not 8pt inside this
        // row's own left edge) and whose Y-extent is this row's frame
        // (vertical alignment stays row-anchored).
        let windowFrame = hostWindow.frame
        let anchorFrame = CGRect(x: windowFrame.minX, y: rowFrame.minY,
                                  width: windowFrame.width, height: rowFrame.height)
        if host.show(content(), near: anchorFrame) {
            shownKind = kind
            // Fold-in 1: clear ANY inline expansion on a successful show,
            // not just this row's own kind -- a different pane's degraded
            // expansion left open, with this pane's NSPanel now succeeding,
            // would otherwise leave a stale inline block behind it.
            expandedDrill = nil
        } else {
            expandedDrill = kind
        }
    }
}

extension View {
    fileprivate func drillDown<DrillContent: View>(
        host: PanelHost, kind: DrillKind, hostWindow: NSWindow?, anchorView: NSView?,
        expandedDrill: Binding<DrillKind?>, shownKind: Binding<DrillKind?>,
        @ViewBuilder content: @escaping () -> DrillContent
    ) -> some View {
        modifier(DrillDownModifier(host: host, kind: kind, hostWindow: hostWindow, anchorView: anchorView,
                                    expandedDrill: expandedDrill, shownKind: shownKind, content: content))
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
    /// Kept on the model: SwiftUI builds the popover window afresh on every
    /// open, and a model created with it would open empty, then grow.
    private var dashboard: TodayDashboardModel { model.dashboard }
    /// C4: switches the popover between the normal dashboard and the focus
    /// duration/block-list configuration screen. Superseded entirely by
    /// `FocusRunningView` whenever a session is actually running, regardless
    /// of this mode -- see `body`'s top-level `if`.
    @State private var focusError: String?
    @State private var categoriesExpanded = false
    @FocusState private var keyboardCategory: String?
    @State private var focusMinutes = 25
    @State private var showsCapture = false
    @State private var showsSync = false
    @State private var captureSummary = ObservationStore.Summary(count: 0, latestAt: nil)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// C1+ hover drill-down: one reused `PanelHost` (see its own doc
    /// comment for why it isn't `FocusHUDController`), the popover's own
    /// `NSWindow` + probe view (captured by `WindowAccessor`, used to
    /// convert a hovered row's local frame to screen coordinates), which
    /// pane (if any) is CURRENTLY showing in `panelHost`'s NSPanel, and
    /// which pane (if any) is expanded in the degraded in-popover path.
    @State private var panelHost = PanelHost()
    @State private var hostWindow: NSWindow?
    @State private var anchorView: NSView?
    @State private var shownKind: DrillKind?
    @State private var expandedDrill: DrillKind?

    private var focusRunning: Bool { model.focus?.running != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section {
                dashboardHeader
                if model.accessibilityGranted && !model.trackingPaused && !focusRunning { currentActivity }
            }
            if focusRunning {
                section { FocusRunningView(model: model) }
                section {
                    HStack {
                        Text("今天已记录").foregroundStyle(.secondary)
                        Text(Format.duration(dashboard.total)).fontWeight(.semibold).monospacedDigit()
                        Spacer()
                        Button("查看今天", action: openToday).buttonStyle(.link)
                    }.font(.system(size: 12))
                    if let overview = dashboard.overview { DayRibbonView(overview: overview, compact: true) }
                }
            } else {
                if !model.accessibilityGranted {
                    section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("辅助功能权限已关闭", systemImage: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                            Text("TimeSink 靠它看到最前面的应用和窗口标题。关闭期间不会记录任何时间。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("打开系统设置…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }.buttonStyle(.borderedProminent)
                            Text("重新打开后会自动继续，不需要重启。").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                if model.trackingPaused { section { pausedContent } }
                section { todaySummary }
                if model.accessibilityGranted && !model.trackingPaused {
                    if !dashboard.topCategories.isEmpty { section { categoryList } }
                    if !dashboard.budgetRows.isEmpty {
                        section {
                            Button(action: openBudgetSettings) { budgetSection }
                                .buttonStyle(.plain)
                                .drillDown(host: panelHost, kind: .budget, hostWindow: hostWindow, anchorView: anchorView,
                                    expandedDrill: $expandedDrill, shownKind: $shownKind) { budgetProgressContent() }
                        }
                    }
                    section { quickFocus }
                }
            }
            if model.chromeDegraded {
                section {
                    Button {
                        model.settingsTab = .permissions
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings(); AppWindow.settings.bringForward()
                    } label: {
                        Label("Chrome 网页读取已降级 · 检查权限", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(RefinedStyle.warning)
                    }.buttonStyle(.plain)
                }
            }
            if let focusError { Text(focusError).font(.system(size: 11)).foregroundStyle(.red).padding(14) }
            expandedContent
            section { footer }
        }
        .frame(width: RefinedStyle.popoverWidth)
        .environment(\.locale, model.displayLocale)
        .environment(\.calendar, model.displayCalendar)
        .background(RefinedStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .background(WindowAccessor(window: $hostWindow, anchorView: $anchorView))
        .animation(RefinedStyle.motion(reduced: reduceMotion), value: model.trackingPaused)
        .animation(RefinedStyle.motion(reduced: reduceMotion), value: categoriesExpanded)
        .task(id: model.dataVersion) {
            await refresh(forceStreak: false)
            guard !Task.isCancelled else { return }
            panelHost.prewarm()
            captureSummary = model.observationStore?.summary(since: Calendar.current.startOfDay(for: Date())) ?? captureSummary
        }
        .onAppear { focusMinutes = model.settings.focusDurationMinutes }
        .onDisappear {
            panelHost.closeNow(); shownKind = nil; expandedDrill = nil
        }
    }

    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider().opacity(0.65) }
    }

    private var todaySummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 4) {
                Button(action: openToday) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Format.duration(dashboard.total)).font(.system(size: 34, weight: .semibold))
                            .tracking(-0.8).monospacedDigit().refinedNumberMotion(Format.duration(dashboard.total))
                        Text("今天已记录").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
                .drillDown(host: panelHost, kind: .compareTotal, hostWindow: hostWindow, anchorView: anchorView,
                    expandedDrill: $expandedDrill, shownKind: $shownKind) { compareBaseContent(focus: false) }
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Format.duration(dashboard.focus)).font(.system(size: 17, weight: .semibold)).monospacedDigit().refinedNumberMotion(Format.duration(dashboard.focus))
                    Text("投入 · 占 \(Int((dashboard.focus / max(1, dashboard.total) * 100).rounded()))%")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .drillDown(host: panelHost, kind: .compareFocus, hostWindow: hostWindow, anchorView: anchorView,
                    expandedDrill: $expandedDrill, shownKind: $shownKind) { compareBaseContent(focus: true) }
            }
            if let delta = dashboard.totalDelta {
                Text("比昨天同时段 \(Format.durationDelta(delta))").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, -7).monospacedDigit()
            } else if dashboard.total < 300 {
                Text("新的一天刚开始。离开电脑和锁屏的时间不会计入。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let overview = dashboard.overview {
                Button(action: openToday) { DayRibbonView(overview: overview, compact: true) }.buttonStyle(.plain)
                    .drillDown(host: panelHost, kind: .spark, hostWindow: hostWindow, anchorView: anchorView,
                        expandedDrill: $expandedDrill, shownKind: $shownKind) { hourlyBigContent() }
            }
            HStack(spacing: 6) {
                if model.showScore {
                    Button { expandedDrill = expandedDrill == .score ? nil : .score } label: {
                        Label("评分 \(dashboard.pulse.map(String.init) ?? "—") · 连续 \(dashboard.streakDays) 天达标", systemImage: "chart.bar")
                    }
                    .drillDown(host: panelHost, kind: .score, hostWindow: hostWindow, anchorView: anchorView,
                        expandedDrill: $expandedDrill, shownKind: $shownKind) { scoreBreakdownContent() }
                }
                Button { expandedDrill = expandedDrill == .spark ? nil : .spark } label: {
                    Label("24 小时分布", systemImage: "clock")
                }
            }.font(.system(size: 11)).controlSize(.mini)
        }.opacity(model.trackingPaused ? 0.55 : 1)
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(dashboard.topCategories.prefix(categoriesExpanded ? dashboard.topCategories.count : 5)), id: \.id) { entry in
                Button { openActivities(category: entry.id) } label: { categoryRow(entry) }
                    .buttonStyle(RefinedRowButtonStyle())
                    .background(shownKind == .category(entry.id) ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .drillDown(host: panelHost, kind: .category(entry.id), hostWindow: hostWindow, anchorView: anchorView,
                        expandedDrill: $expandedDrill, shownKind: $shownKind) { categoryDetailContent(entry) }
                    .focused($keyboardCategory, equals: entry.id)
                    .onKeyPress(.upArrow) { moveCategory(-1, from: entry.id); return .handled }
                    .onKeyPress(.downArrow) { moveCategory(1, from: entry.id); return .handled }
                    .onKeyPress(.rightArrow) { expandedDrill = .category(entry.id); return .handled }
                    .onKeyPress(.leftArrow) { expandedDrill = nil; panelHost.closeNow(); return .handled }
                    .accessibilityLabel("\(entry.name)，\(Format.duration(entry.seconds))，占 \(Int((entry.seconds / max(1, dashboard.total) * 100).rounded()))%，有详情")
            }
            if dashboard.topCategories.count > 5 {
                let rest = dashboard.topCategories.dropFirst(5)
                Button { categoriesExpanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: categoriesExpanded ? "chevron.up" : "chevron.down")
                        Text(categoriesExpanded ? "收起" : "另外 \(rest.count) 个分类 · \(Format.duration(rest.reduce(0) { $0 + $1.seconds }))")
                        Spacer()
                    }.font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 26)
                }.buttonStyle(.plain)
            }
        }
    }

    private func moveCategory(_ step: Int, from id: String) {
        let ids = Array(dashboard.topCategories.prefix(categoriesExpanded ? dashboard.topCategories.count : 5)).map(\.id)
        guard let index = ids.firstIndex(of: id), !ids.isEmpty else { return }
        keyboardCategory = ids[(index + step + ids.count) % ids.count]
    }

    private var quickFocus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Picker("专注时长", selection: $focusMinutes) {
                    ForEach(FocusPresets.minutes, id: \.self) { Text("\($0)").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 158)
                Text("分钟").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // No bare-Space shortcut: the popover has no text field to
                // absorb it, so any Space press would start blocking apps.
                Button("开始专注") { startFocus(minutes: focusMinutes) }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(model.focus == nil)
            }
            HStack(spacing: 4) {
                Text("将隐藏 \(model.settings.focusAppBlockEnabled ? model.settings.focusBlockedApps.count : 0) 个应用 · 拦截 \(model.settings.focusSiteBlockEnabled ? model.settings.focusBlockedCategories.count : 0) 类网站")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button("编辑…", action: openBudgetSettings).buttonStyle(.link).font(.system(size: 11))
            }
        }.onChange(of: focusMinutes) { _, value in model.settings.setFocusDurationMinutes(value) }
    }

    private var pausedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let until = model.trackingResumeAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(alignment: .firstTextBaseline) {
                        Text(Format.mmss(until.timeIntervalSince(context.date))).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                        Text("后恢复").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            Text("暂停期间不记录应用、网站、窗口标题和屏幕画面。这段时间在时间带里留空，不会补记。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("再加 15 分钟") { model.extendTrackingPause(minutes: 15) }
                Button("1 小时后恢复") { model.pauseTracking(minutes: 60) }
                Button("直到我恢复") { model.pauseTracking(minutes: nil) }
            }.controlSize(.small)
        }
    }

    @ViewBuilder private var expandedContent: some View {
        if expandedDrill == .spark { ExpandedDrillView(content: hourlyBigContent(compact: true)) { expandedDrill = nil } }
        if expandedDrill == .score { ExpandedDrillView(content: scoreBreakdownContent(compact: true)) { expandedDrill = nil } }
        if expandedDrill == .compareFocus { ExpandedDrillView(content: compareBaseContent(focus: true, compact: true)) { expandedDrill = nil } }
        if expandedDrill == .compareTotal { ExpandedDrillView(content: compareBaseContent(focus: false, compact: true)) { expandedDrill = nil } }
        if expandedDrill == .streak { ExpandedDrillView(content: streakDotsContent(compact: true)) { expandedDrill = nil } }
        if expandedDrill == .budget { ExpandedDrillView(content: budgetProgressContent(compact: true)) { expandedDrill = nil } }
        if case .category(let id) = expandedDrill, let entry = dashboard.topCategories.first(where: { $0.id == id }) {
            ExpandedDrillView(content: categoryDetailContent(entry, compact: true)) { expandedDrill = nil }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Button { showsCapture.toggle() } label: {
                    // Its own width, so the longer status is never cut; sync takes the rest.
                    Label(String(localized: "屏幕采集 · \(model.trackingPaused || model.screenCapturePaused ? String(localized: "已暂停") : model.screenCollector == nil ? String(localized: "未开启") : String(localized: "\(captureSummary.count) 张"))"), systemImage: "viewfinder")
                        .fixedSize()
                }.popover(isPresented: $showsCapture) {
                    VStack(alignment: .leading, spacing: 12) {
                        ScreenCaptureRow(model: model)
                        Text("屏幕画面只保存在本机。").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("记录与隐私设置…") { model.settingsTab = .privacy; openSettings(); AppWindow.settings.bringForward() }
                    }.padding(16).frame(width: 280)
                }
                Button { showsSync.toggle() } label: {
                    Label(model.sync?.isSyncing == true ? "正在同步" : model.sync?.lastError != nil ? "同步失败" : model.settings.cloudSyncEnabled ? "待传 \(model.sync?.pending ?? 0)" : "同步未开启", systemImage: "icloud")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.popover(isPresented: $showsSync) {
                    VStack(alignment: .leading, spacing: 12) {
                        CloudSyncRow(model: model)
                        Button("账号与同步…") { model.settingsTab = .account; openSettings(); AppWindow.settings.bringForward() }
                    }.padding(16).frame(width: 240)
                }
            }.font(.system(size: 11)).controlSize(.mini)
            HStack(spacing: 6) {
                Button(action: openToday) {
                    HStack(spacing: 6) { Image(systemName: "macwindow"); Text("打开 TimeSink"); Text("⌘O").foregroundStyle(.secondary) }
                }.controlSize(.small).keyboardShortcut("o")
                Spacer()
                // Same route as the other Settings entries: a bare SettingsLink
                // can open the window behind the frontmost app.
                Button { openSettings(); AppWindow.settings.bringForward() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("设置… ⌘,").accessibilityLabel("设置")
                Button { model.engine.stop(); NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).help("退出 TimeSink ⌘Q").accessibilityLabel("退出 TimeSink")
            }.foregroundStyle(.secondary)
        }
    }

    /// Starts the session; the popover then shows `FocusRunningView`. A
    /// `start(minutes:)` failure (DB write error) is shown instead of being
    /// silently discarded.
    private func startFocus(minutes: Int) {
        guard let focus = model.focus else { return }
        do {
            try focus.start(minutes: minutes)
            focusError = nil
        } catch {
            focusError = String(localized: "无法开始专注，请重试。")
            menuBarDashboardLogger.error("focus.start failed: \(String(describing: error))")
        }
    }

    private func refresh(forceStreak: Bool) async {
        await dashboard.recompute(model: model, forceStreak: forceStreak)
    }

    private var dashboardHeader: some View {
        HStack(spacing: 6) {
            // The date gives way first.
            RecordingStatusView(model: model).layoutPriority(1)
            ViewThatFits(in: .horizontal) {
                Text(Date(), format: .dateTime.month().day().weekday(.abbreviated))
                Text(Date(), format: .dateTime.month().day())
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            RecordingPauseMenu(model: model)
            Menu {
                Button("评分明细") { expandedDrill = .score }
                Button("投入时长比较") { expandedDrill = .compareFocus }
                Button("总时长比较") { expandedDrill = .compareTotal }
                Button("连续达标") { expandedDrill = .streak }
                Button("24 小时分布") { expandedDrill = .spark }
                Divider()
                Button("查看趋势", action: openStatsTrend)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多统计")
        }.frame(height: 22)
    }

    private var currentActivity: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            if let current = model.engine.currentActivity, model.engine.isRunning, !model.engine.isSuspended {
                HStack(spacing: 10) {
                    AppIcon(bundleID: current.appBundleID, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(current.document ?? current.title ?? current.appName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 5) {
                            Text(current.domain ?? current.appName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            CategoryChip(category: model.resolver.categoriesByID[model.resolver.categoryID(for: current)])
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(Format.duration(max(0, context.date.timeIntervalSince(current.start)))).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text("自 \(model.time(current.start))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Label(model.engine.isSuspended ? "你离开了电脑，这段时间不计入。回来后会自动继续。" : "下一段活动会显示在这里。", systemImage: model.engine.isSuspended ? "moon" : "sun.max")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func openToday() {
        model.openToday()
        openWindow(id: "main"); AppWindow.main.bringForward()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - C1+ click-through routes

    /// 连续达标行 deepens to 统计 anchored on the same 30-day window its
    /// hover pane (`StreakDotsView`) shows.
    private func openStatsTrend() {
        model.openStats(range: DateRangeSelection(kind: .last30, anchor: Date()))
        openWindow(id: "main")
        AppWindow.main.bringForward()
    }

    private func openActivities(category: String) {
        model.openActivities(category: category, range: .today())
        openWindow(id: "main")
        AppWindow.main.bringForward()
    }

    /// R-T11g: activate-only, no `.setActivationPolicy(.regular)` -- same
    /// convention as the `.settingsBudget` notification route
    /// (`TimeSinkApp.swift`); there's no matching restore-to-`.accessory`
    /// path for a policy flip here.
    private func openBudgetSettings() {
        model.sidebarSelection = .focus
        openWindow(id: "main"); AppWindow.main.bringForward()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - C1+ drill-down content builders
    //
    // Each builds one hover pane's content from data `dashboard` already
    // loaded this recompute (plus, for `hourlyBigContent`'s 近 7 天 toggle,
    // a lazily-fetched `.last7` range) -- no view here reads `AppModel`/
    // `TrackerEngine` directly (see `DrillDownViews.swift`'s header
    // comment), so these methods are the one place that bridges dashboard
    // state into the pure drill-down view types. `compact` (F1 fix)
    // requests `DrillWidths.compact` instead of the pane's normal panel
    // width -- passed `true` only by the `ExpandedDrillView` (in-popover
    // degraded) call sites, since that path is bounded by the popover's own
    // content width, unlike the floating `NSPanel`.

    private func scoreBreakdownContent(compact: Bool = false) -> ScoreBreakdownView {
        let byCategory = Aggregator.durationByCategory(dashboard.todayItems)
        let rows = TodayDashboardModel.scoreContributions(byCategory: byCategory, categories: model.resolver.categoriesByID)
            .map { ScoreBreakdownView.Row(id: $0.id, name: $0.name, colorHex: $0.colorHex,
                                           seconds: $0.seconds, points: $0.points, share: $0.share) }
        return ScoreBreakdownView(rows: rows, pulse: dashboard.pulse, pulseDelta: dashboard.pulseDelta,
                                   width: compact ? DrillWidths.compact : DrillWidths.score)
    }

    private func compareBaseContent(focus: Bool, compact: Bool = false) -> CompareBaseView {
        let width = compact ? DrillWidths.compact : DrillWidths.compare
        return focus
            ? CompareBaseView(label: String(localized: "投入时长比较"), todayValue: dashboard.focus, delta: dashboard.focusDelta, width: width)
            : CompareBaseView(label: String(localized: "总计时长比较"), todayValue: dashboard.total, delta: dashboard.totalDelta, width: width)
    }

    private func streakDotsContent(compact: Bool = false) -> StreakDotsView {
        StreakDotsView(dailyPulses: dashboard.streakLookbackPulses,
                        threshold: TodayDashboardModel.streakThreshold, streakDays: dashboard.streakDays,
                        width: compact ? DrillWidths.compact : DrillWidths.streak)
    }

    private func categoryDetailContent(
        _ entry: (id: String, name: String, colorHex: String, seconds: TimeInterval), compact: Bool = false
    ) -> CategoryDetailView {
        let items = dashboard.todayItems.filter { $0.categoryID == entry.id }
        var bars = Array(repeating: 0.0, count: 24)
        for (hour, seconds) in Aggregator.profileByHourOfDay(items, calendar: Calendar.current) {
            bars[hour] = seconds / 3600.0
        }
        let subs = Aggregator.durationByDomainOrApp(items).prefix(5)
            .map { CategoryDetailView.SubEntry(id: $0.key, label: $0.label, seconds: $0.seconds) }
        return CategoryDetailView(categoryID: entry.id, name: entry.name, colorHex: entry.colorHex, seconds: entry.seconds,
                                   hourBars: bars, subs: Array(subs),
                                   width: compact ? DrillWidths.compact : DrillWidths.category,
                                   onOpenActivities: {
                                       panelHost.closeNow()
                                       expandedDrill = nil
                                       openActivities(category: entry.id)
                                   })
    }

    private func hourlyBigContent(compact: Bool = false) -> HourlyBigView {
        let categories = model.resolver.categoriesByID
        let todayBars = Self.hourlyBars(items: dashboard.todayItems, categories: categories)
        return HourlyBigView(categories: categories, todayBars: todayBars, loadLast7Bars: {
            let items = model.rangedSpans(for: DateRangeSelection(kind: .last7, anchor: Date()))
            return Self.hourlyBars(items: items, categories: categories)
        }, width: compact ? DrillWidths.compact : DrillWidths.hourly)
    }

    /// Fold-in 4: collapses by `(hour-of-day, categoryID)` BEFORE
    /// constructing bars -- `Aggregator.stackedSeries` keys by absolute
    /// `bucketStart`, so a multi-day range (近 7 天) yields up to one entry
    /// PER DAY sharing the same hour-of-day/category; handing those to
    /// `HourlyBigView` unmerged meant each got its own `max(1, _)`-floored
    /// stacked rectangle, inflating quiet-hour categories' visual height by
    /// up to 6pt. Also gives every `Bar` a stable `(hour, categoryID)`-keyed
    /// identity instead of a fresh `UUID()` per render (see `Bar.id`).
    private static func hourlyBars(items: [CategorizedSpan], categories: [String: Category]) -> [HourlyBigView.Bar] {
        struct HourCategoryKey: Hashable { let hour: Int; let categoryID: String }
        let calendar = Calendar.current
        var totals: [HourCategoryKey: TimeInterval] = [:]
        for entry in Aggregator.stackedSeries(items, bucket: .hour, calendar: calendar) {
            let key = HourCategoryKey(hour: calendar.component(.hour, from: entry.bucketStart), categoryID: entry.categoryID)
            totals[key, default: 0] += entry.seconds
        }
        return totals.map { key, seconds in
            HourlyBigView.Bar(hour: key.hour, categoryID: key.categoryID,
                               colorHex: categories[key.categoryID]?.colorHex ?? "#8E8E93", seconds: seconds)
        }
    }

    private func budgetProgressContent(compact: Bool = false) -> BudgetProgressView {
        let rows = dashboard.allBudgetRows.map {
            BudgetProgressView.Row(id: $0.id, name: $0.name, colorHex: $0.colorHex, spent: $0.spent, limit: $0.limit)
        }
        return BudgetProgressView(rows: rows, warnPercent: dashboard.budgetWarnPercent,
                                   width: compact ? DrillWidths.compact : DrillWidths.budget)
    }

    private func categoryRow(_ entry: (id: String, name: String, colorHex: String, seconds: TimeInterval)) -> some View {
        let ratio = entry.seconds / max(1, dashboard.total)
        let color = RefinedStyle.category(entry.id, hex: entry.colorHex)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.system(size: 13)).lineLimit(1)
                GeometryReader { geo in
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * ratio)
                }.frame(height: 3)
            }
            Spacer(minLength: 0)
            Text(Format.duration(entry.seconds)).font(.system(size: 12)).monospacedDigit().frame(minWidth: 45, alignment: .trailing)
            Text("\(Int((ratio * 100).rounded()))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
        }.frame(height: 30).contentShape(Rectangle())
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(dashboard.budgetRows, id: \.id) { row in
                RefinedBudgetRow(name: row.name, color: RefinedStyle.category(row.id, hex: row.colorHex),
                    spent: row.spent, limit: row.limit, warningPercent: dashboard.budgetWarnPercent)
            }
        }
    }


}

/// Refresh only while this status is visible, including the Settings round trip.
struct ScreenCaptureRow: View {
    let model: AppModel
    var compact = false
    @State private var summary = ObservationStore.Summary(count: 0, latestAt: nil)
    @State private var permissionGranted = false

    var body: some View {
        ScreenCaptureStatusView(permissionGranted: permissionGranted, compact: compact,
                                isEnabled: Binding(get: { !model.screenCapturePaused },
                                                   set: { model.setScreenCapturePaused(!$0) }),
                                count: summary.count, latestAt: summary.latestAt) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        .task {
            while !Task.isCancelled {
                refreshStatus()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        permissionGranted = Permissions.screenRecordingState() == .granted
        let today = Calendar.current.startOfDay(for: Date())
        summary = model.observationStore?.summary(since: today) ?? summary
    }
}

struct ScreenCaptureStatusView: View {
    @Environment(\.locale) private var locale
    let permissionGranted: Bool
    var compact = false
    @Binding var isEnabled: Bool
    let count: Int
    let latestAt: Date?
    let openPermissions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("屏幕采集").font(.callout)
                Spacer()
                if permissionGranted {
                    Toggle("启用屏幕采集", isOn: $isEnabled)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            if !permissionGranted {
                if compact {
                    HStack {
                        Label("需屏幕录制权限 · 未采集", systemImage: "exclamationmark.circle")
                            .font(.system(size: 11)).foregroundStyle(RefinedStyle.warning)
                        Spacer(minLength: 4)
                        Button("打开系统设置…", action: openPermissions).controlSize(.small)
                    }
                } else {
                    Label("需要屏幕录制权限", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    Text("当前不会保存屏幕画面").font(.caption).foregroundStyle(.secondary)
                    Button("打开系统设置…", action: openPermissions).controlSize(.small)
                }
            } else {
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: String {
        guard isEnabled else { return String(localized: "已暂停") }
        guard let latestAt else { return String(localized: "已启用 · 等待首张画面") }
        return String(localized: "已启用 · 今日 \(count) 张 · 最近 \(latestAt.formatted(.dateTime.hour().minute().locale(locale)))")
    }
}

/// Cloud sync at a glance, only once an account is signed in. `SyncEngine`
/// is `@Observable`, so the line follows a running pass; the signed-in
/// check is a Keychain read, taken when the popover opens.
struct CloudSyncRow: View {
    let model: AppModel
    @State private var signedIn = false

    var body: some View {
        Group {
            if signedIn, let sync = model.sync {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("云端同步").font(.callout)
                        Text(statusLine(sync)).font(.caption2)
                            .foregroundStyle(sync.lastError == nil ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    if sync.isSyncing { ProgressView().controlSize(.mini) }
                }
            }
        }
        .onAppear {
            signedIn = CloudConfig.isConfigured && model.cloudAuth?.isSignedIn == true
            model.sync?.refreshPending()
        }
    }

    private func statusLine(_ sync: SyncEngine) -> String {
        if !model.settings.cloudSyncEnabled { return String(localized: "未开启") }
        if sync.isSyncing { return String(localized: "正在同步 · 已上传 \(sync.passPushed) 条") }
        if sync.lastError != nil { return String(localized: "上次同步失败") }
        guard let last = sync.lastSyncAt else { return String(localized: "还没有同步过") }
        return String(localized: "上次 \(model.time(last)) · 待上传 \(sync.pending) 条")
    }
}
