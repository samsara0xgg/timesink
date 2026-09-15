import Foundation
import Observation

/// Computes every StatsView card's data from a single `rangedSpans()` call.
/// `recompute` does one pass over the fetched spans (fanning out into several
/// pure `Aggregator` calls plus a couple of local groupings), never issuing
/// its own DB queries — callers re-invoke it on `onAppear` and whenever
/// `AppModel.dataVersion`/`range` change.
@MainActor
@Observable
final class StatsModel {
    enum Granularity: String, CaseIterable, Hashable {
        case day, week
    }

    struct ProfilePoint: Identifiable, Hashable {
        var id: String { label }
        let label: String
        let hours: Double
    }

    struct StackedPoint: Identifiable {
        var id: String { "\(bucketStart.timeIntervalSince1970)_\(categoryID)" }
        let bucketStart: Date
        let categoryID: String
        let categoryName: String
        let colorHex: String
        let hours: Double
    }

    struct RankingRow: Identifiable {
        let id: String
        let name: String
        let colorHex: String
        let seconds: TimeInterval
    }

    private static let weekdayLabels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static let streakThreshold = 70

    var total: TimeInterval = 0
    var avgPerDay: TimeInterval = 0
    var pulse: Int?
    var focus: TimeInterval = 0
    /// Same-elapsed-time-of-day comparison against the previous period; nil
    /// when the previous period has no tracked time at all. See
    /// `recomputeDeltas`.
    var totalDelta: TimeInterval?
    var focusDelta: TimeInterval?
    /// Whole-period ratio comparison (unclipped, unlike `totalDelta`/
    /// `focusDelta`) -- see `recomputeDeltas`.
    var pulseDelta: Int?

    var hourProfile: [ProfilePoint] = []
    var weekdayProfile: [ProfilePoint] = []
    var prodHourProfile: [ProfilePoint] = []
    var prodWeekdayProfile: [ProfilePoint] = []

    var stackedByDay: [StackedPoint] = []
    var stackedByWeek: [StackedPoint] = []
    var stackedDomainNames: [String] = []
    var stackedDomainColorHex: [String] = []

    var appRows: [RankingRow] = []
    var categoryRows: [RankingRow] = []

    /// 30-day trailing score trend (tail = today, nil for untracked days),
    /// its >= `streakThreshold` trailing streak, and the 7x24 weekday-by-hour
    /// productivity heatmap. Refreshed only when `recompute`'s `forceHeavy`
    /// is set or the calendar day has changed -- see
    /// `recomputeHeavyIfNeeded`.
    var scoreTrend: [Int?] = []
    var trendStreak: Int = 0
    var heatmap: [[(pulse: Int?, seconds: TimeInterval)]] = []
    /// How many times each weekday (row index, Monday=0...Sunday=6 -- same
    /// convention as `heatmap`) occurs as a whole calendar day inside the
    /// 30-day lookback window. A trailing 30-day window has either 4 or 5
    /// occurrences of a given weekday depending on where it falls, so
    /// `HeatmapCard` needs this to normalize a cell's summed seconds (across
    /// every occurrence) down to a per-occurrence average before mapping to
    /// intensity -- see fix round 1, IMPORTANT 1.
    var heatmapOccurrences: [Int] = Array(repeating: 0, count: 7)

    /// Calendar day (startOfDay) the 30-day trend/heatmap lookback last ran
    /// for. That lookback is a full-month fetch+classify+day/hour-split --
    /// expensive enough that re-running it on every `recompute` (every
    /// `dataVersion` bump) would cost the main actor for numbers that change
    /// at most once a day. Mirrors `TodayDashboardModel.lastStreakDay`'s
    /// gating. `@ObservationIgnored`: never read by the view, so it must not
    /// register through `@Observable`.
    @ObservationIgnored
    private var lastHeavyDay: Date?

    /// `AppModel.dataEditVersion` as of the last heavy run. A user edit
    /// (reassignment, rule change, a category's productivity) does change the
    /// 30-day numbers, so the day gate alone would leave the trend and
    /// heatmap showing pre-edit values until midnight. Comparing the edit
    /// counter here rather than adding a second `onChange` in `StatsView`
    /// keeps one recompute per bump: an edit bumps `dataVersion` and
    /// `dataEditVersion` together, and two handlers would each fire.
    /// Starts at -1 so the first run is never mistaken for up to date.
    @ObservationIgnored
    private var lastHeavyEditVersion: Int = -1

    /// Light part runs every call (cheap -- `AppModel.rangedSpans(for:)`
    /// memoizes between `dataChanged()` bumps); the heavy part (30-day trend
    /// + heatmap) is gated by `forceHeavy` -- see `recomputeHeavyIfNeeded`.
    func recompute(model: AppModel, forceHeavy: Bool) {
        let items = model.rangedSpans()
        let calendar = Calendar.current
        let categories = model.resolver.categoriesByID

        total = Aggregator.totalDuration(items.map(\.span))
        let days = max(1, Int((model.range.interval.duration / 86400).rounded()))
        avgPerDay = total / Double(days)

        let byCategory = Aggregator.durationByCategory(items)
        pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories)
        focus = Aggregator.focusTime(durationByCategory: byCategory, categories: categories)

        hourProfile = Self.densifyHours(Aggregator.profileByHourOfDay(items, calendar: calendar))
        weekdayProfile = Self.densifyWeekdays(Aggregator.profileByWeekday(items, calendar: calendar))
        prodHourProfile = Self.densifyHours(
            Aggregator.productivityProfileByHourOfDay(items, categories: categories, calendar: calendar)
        )
        prodWeekdayProfile = Self.densifyWeekdays(
            Aggregator.productivityProfileByWeekday(items, categories: categories, calendar: calendar)
        )

        let dayStacks = Aggregator.stackedSeries(items, bucket: .day, calendar: calendar)
        let weekStacks = Aggregator.stackedSeries(items, bucket: .weekOfYear, calendar: calendar)
        stackedByDay = Self.stackedPoints(dayStacks, categories: categories)
        stackedByWeek = Self.stackedPoints(weekStacks, categories: categories)

        let presentCategoryIDs = Set(dayStacks.map(\.categoryID)).union(weekStacks.map(\.categoryID))
        let orderedCategories = presentCategoryIDs
            .compactMap { categories[$0] }
            .sorted { $0.sortOrder < $1.sortOrder }
        stackedDomainNames = orderedCategories.map(\.name)
        stackedDomainColorHex = orderedCategories.map(\.colorHex)

        // Ranking rows are colored by category, not per-app icons (ruling R4).
        // For apps, use each app's single largest-duration category.
        var appCategorySeconds: [String: [String: TimeInterval]] = [:]
        for item in items {
            appCategorySeconds[item.span.appBundleID, default: [:]][item.categoryID, default: 0] += item.span.duration
        }
        appRows = Aggregator.durationByApp(items.map(\.span))
            .prefix(10)
            .map { entry in
                let dominant = appCategorySeconds[entry.bundleID]?.max { $0.value < $1.value }?.key
                let colorHex = dominant.flatMap { categories[$0]?.colorHex } ?? "#98989D"
                return RankingRow(id: entry.bundleID, name: entry.appName, colorHex: colorHex, seconds: entry.seconds)
            }

        categoryRows = Array(
            byCategory
                .compactMap { categoryID, seconds -> RankingRow? in
                    guard let category = categories[categoryID] else { return nil }
                    return RankingRow(id: category.id, name: category.name, colorHex: category.colorHex, seconds: seconds)
                }
                .sorted { $0.seconds > $1.seconds }
                .prefix(10)
        )

        recomputeDeltas(model: model, categories: categories)
        recomputeHeavyIfNeeded(model: model, calendar: calendar, categories: categories, force: forceHeavy)
    }

    /// Delta semantics (spec §6 ruling): `prev` is the previous period's raw
    /// spans; empty -> all three deltas nil (cards hide their chip).
    /// Duration-based deltas (`total`/`focus`) compare against `prev` clipped
    /// to the SAME elapsed time-of-day when `range.containsNow` -- comparing
    /// a still-running partial period against the full preceding one would be
    /// biased by construction; `pulseDelta` is a whole-period ratio
    /// comparison and always uses the unclipped `prev`.
    private func recomputeDeltas(model: AppModel, categories: [String: Category]) {
        let range = model.range
        let prevItems = model.rangedSpans(for: range.previousInterval)
        guard !prevItems.isEmpty else {
            totalDelta = nil
            focusDelta = nil
            pulseDelta = nil
            return
        }

        let prevFullByCategory = Aggregator.durationByCategory(prevItems)
        let prevFullPulse = Aggregator.pulse(durationByCategory: prevFullByCategory, categories: categories)
        if let pulse, let prevFullPulse {
            pulseDelta = pulse - prevFullPulse
        } else {
            pulseDelta = nil
        }

        let durationPrevItems: [CategorizedSpan]
        if range.containsNow {
            let elapsed = Date().timeIntervalSince(range.interval.start)
            durationPrevItems = Aggregator.clippedToElapsed(
                prevItems, windowStart: range.previousInterval.start, elapsed: elapsed)
        } else {
            durationPrevItems = prevItems
        }
        totalDelta = total - Aggregator.totalDuration(durationPrevItems.map(\.span))
        let prevDurationByCategory = Aggregator.durationByCategory(durationPrevItems)
        focusDelta = focus - Aggregator.focusTime(durationByCategory: prevDurationByCategory, categories: categories)
    }

    /// Runs the 30-day score-trend + heatmap lookback when `force` is true --
    /// NOT range changes, since this lookback is a fixed `.last30` window,
    /// independent of `model.range`; see fix round 1, IMPORTANT 5 -- or when
    /// the calendar day has rolled over since the last run; skipped otherwise
    /// (dataVersion-driven refreshes within the same day).
    ///
    /// This used to share its `rangedSpans(for:)` call with
    /// `TodayDashboardModel`'s streak lookback (identical `.last30` interval,
    /// so the same `AppModel.rangeCache` key), making it near-free whenever
    /// the menu bar dashboard had already populated that entry. It no longer
    /// does: that lookback moved onto `AppModel.dailyPulses`, a SQL-bucketed
    /// path that never touches `rangeCache`. This is now the sole caller of
    /// that key and runs cold whenever `dataChanged()` has cleared the cache,
    /// so the day gate is the only thing keeping it off the interactive path.
    /// That in turn is why `StatsView`'s model is owned by `MainWindowView`:
    /// a per-switch rebuild would reset `lastHeavyDay` and defeat the gate.
    private func recomputeHeavyIfNeeded(
        model: AppModel, calendar: Calendar, categories: [String: Category], force: Bool
    ) {
        let todayStart = calendar.startOfDay(for: Date())
        guard force
                || lastHeavyDay != todayStart
                || lastHeavyEditVersion != model.dataEditVersion
        else { return }
        lastHeavyDay = todayStart
        lastHeavyEditVersion = model.dataEditVersion

        let last30 = DateRangeSelection(kind: .last30, anchor: Date())
        let lookback = model.rangedSpans(for: last30)
        scoreTrend = Aggregator.dailyPulses(
            items: lookback, categories: categories, days: 30, endingAt: Date(), calendar: calendar)
        trendStreak = Aggregator.streak(dailyPulses: scoreTrend, threshold: Self.streakThreshold)
        heatmap = Aggregator.pulseByWeekdayHour(lookback, categories: categories, calendar: calendar)
        heatmapOccurrences = Self.weekdayOccurrences(in: last30.interval, calendar: calendar)
    }

    /// Counts how many times each weekday (Monday=0...Sunday=6, matching
    /// `Aggregator.pulseByWeekdayHour`'s row convention) occurs as a whole
    /// calendar day inside `interval`. `pulseByWeekdayHour`'s `seconds` is a
    /// SUM across every occurrence of that weekday in the window, so a
    /// renderer dividing by a fixed 3600s (one hour) saturates any weekday
    /// with as little as ~12 min/day tracked, once 4-5 occurrences are
    /// summed -- this must be counted from the actual window, not assumed.
    private static func weekdayOccurrences(in interval: DateInterval, calendar: Calendar) -> [Int] {
        var counts = Array(repeating: 0, count: 7)
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            let weekday = calendar.component(.weekday, from: day) // 1 = Sunday
            counts[(weekday + 5) % 7] += 1 // 0 = Monday ... 6 = Sunday
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return counts
    }

    private static func densifyHours(_ profile: [Int: TimeInterval]) -> [ProfilePoint] {
        (0..<24).map { hour in
            ProfilePoint(label: "\(hour)", hours: (profile[hour] ?? 0) / 3600.0)
        }
    }

    private static func densifyWeekdays(_ profile: [Int: TimeInterval]) -> [ProfilePoint] {
        (0..<7).map { day in
            ProfilePoint(label: weekdayLabels[day], hours: (profile[day] ?? 0) / 3600.0)
        }
    }

    private static func stackedPoints(
        _ series: [(bucketStart: Date, categoryID: String, seconds: TimeInterval)],
        categories: [String: Category]
    ) -> [StackedPoint] {
        series.map { entry in
            let category = categories[entry.categoryID]
            return StackedPoint(
                bucketStart: entry.bucketStart,
                categoryID: entry.categoryID,
                categoryName: category?.name ?? entry.categoryID,
                colorHex: category?.colorHex ?? "#98989D",
                hours: entry.seconds / 3600.0
            )
        }
    }
}
