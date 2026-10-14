import Foundation

/// Immutable result assembled on StatsWorker, then published once on the main actor.
struct StatsSummary: Sendable {
    typealias StackedPoint = StatsModel.StackedPoint
    typealias RankingRow = StatsModel.RankingRow
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

    var stackedByDay: [StackedPoint] = []
    var stackedByWeek: [StackedPoint] = []
    var stackedDomainNames: [String] = []
    /// Every day of the selected range, the daily chart's x domain.
    var chartDays: [Date] = []
    /// Labelled days (thinned for long ranges), placed at midday so the label sits under its bar.
    var dayMarks: [(midday: Date, label: String, isToday: Bool)] = []
    var dayHourScale = ChartAxis.hourScale(maxHours: 0)
    var weekHourScale = ChartAxis.hourScale(maxHours: 0)
    var stackedDomainColorHex: [String] = []

    var appRows: [RankingRow] = []
    var categoryRows: [RankingRow] = []
    var categoryDeltas: [String: TimeInterval] = [:]
    /// Per app or site against the same stretch of the previous period, by
    /// row id; empty when there is no previous period.
    var appDeltas: [String: TimeInterval] = [:]
    var appMovers = AppMovers()

    init(items: [CategorizedSpan] = [], previous: [CategorizedSpan] = [],
         range: DateRangeSelection = .today(), categories: [String: Category] = [:],
         now: Date = Date(), calendar: Calendar = .current) {
        total = Aggregator.totalDuration(items.map(\.span))
        // A still-running period has only elapsed as far as `now`; dividing a
        // partial total by the FULL calendar window is biased by construction
        // (Monday's `.week` divided 1 day of data by 7). Same clipping
        // `recomputeDeltas` already applies to its duration deltas. Today
        // counts as the part of it that has passed: a rounded day count made
        // 近 7 天's divisor jump from 6 to 7 at noon. At least one day, so an
        // early morning is not multiplied up.
        let until = range.contains(now) ? now : range.interval.end
        avgPerDay = total / max(1, Self.elapsedDays(from: range.interval.start, to: until, calendar: calendar))

        let byCategory = Aggregator.durationByCategory(items)
        pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories)
        focus = Aggregator.focusTime(durationByCategory: byCategory, categories: categories)

        let dayStacks = Aggregator.stackedSeries(items, bucket: .day, calendar: calendar)
        let weekStacks = Aggregator.stackedSeries(items, bucket: .weekOfYear, calendar: calendar)
        stackedByDay = Self.stackedPoints(dayStacks, categories: categories)
        stackedByWeek = Self.stackedPoints(weekStacks, categories: categories)
        chartDays = ChartAxis.days(in: range.interval, calendar: calendar)
        dayMarks = ChartAxis.labeledDays(chartDays).map { day in
            (day.addingTimeInterval(12 * 3600), ChartAxis.dayLabel(day, now: now, calendar: calendar),
             calendar.isDate(day, inSameDayAs: now))
        }
        dayHourScale = Self.hourScale(stackedByDay)
        weekHourScale = Self.hourScale(stackedByWeek)

        let presentCategoryIDs = Set(dayStacks.map(\.categoryID)).union(weekStacks.map(\.categoryID))
        let orderedCategories = presentCategoryIDs
            .compactMap { categories[$0] }
            .sorted { $0.sortOrder < $1.sortOrder }
        stackedDomainNames = orderedCategories.map(\.name)
        stackedDomainColorHex = orderedCategories.map(\.colorHex)

        // Websites and native apps share the same non-overlapping ranking.
        var appCategorySeconds: [String: [String: TimeInterval]] = [:]
        var domains: Set<String> = []
        for item in items {
            let key = item.span.domain ?? item.span.appBundleID
            if item.span.domain != nil { domains.insert(key) }
            appCategorySeconds[key, default: [:]][item.categoryID, default: 0] += item.span.duration
        }
        let apps = Aggregator.durationByDomainOrApp(items)
        appRows = StatsModel.distributionRows(apps.map { entry in
            let dominant = appCategorySeconds[entry.key]?.max { $0.value < $1.value }?.key
            let colorHex = dominant.flatMap { categories[$0]?.colorHex } ?? "#98989D"
            return RankingRow(id: entry.key, name: entry.label, colorHex: colorHex, seconds: entry.seconds,
                              categoryID: dominant, isDomain: domains.contains(entry.key))
        })
        categoryRows = StatsModel.distributionRows(byCategory.map { categoryID, seconds in
            let category = categories[categoryID]
            return RankingRow(id: categoryID, name: category?.name ?? String(localized: "未分类"),
                              colorHex: category?.colorHex ?? "#98989D", seconds: seconds)
        })

        recomputeDeltas(prevItems: previous, apps: apps, range: range, categories: categories, now: now, calendar: calendar)
    }

    /// Local days from `start` (a midnight) to `until`, the last day's part
    /// as a fraction of that day's own length, so a DST day is still one day.
    static func elapsedDays(from start: Date, to until: Date, calendar: Calendar) -> Double {
        let dayStart = calendar.startOfDay(for: until)
        let whole = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: dayStart).day ?? 0
        guard let day = calendar.dateInterval(of: .day, for: until), day.duration > 0 else { return Double(whole) }
        return Double(whole) + until.timeIntervalSince(day.start) / day.duration
    }

    /// The moment in the previous period (from `previousStart`) that matches
    /// `now` in the current one (from `currentStart`): as many local days in,
    /// at the same wall-clock time, as the popover's yesterday comparison
    /// does. Elapsed seconds land an hour off when a DST change falls
    /// between the two.
    static func previousCutoff(currentStart: Date, previousStart: Date, now: Date, calendar: Calendar) -> Date {
        let shift = calendar.dateComponents([.day], from: previousStart, to: currentStart).day ?? 0
        return calendar.date(byAdding: .day, value: -shift, to: now)
            ?? previousStart.addingTimeInterval(now.timeIntervalSince(currentStart))
    }

    private mutating func recomputeDeltas(prevItems: [CategorizedSpan], apps: [AppMovers.Total], range: DateRangeSelection,
                                         categories: [String: Category], now: Date, calendar: Calendar) {
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
        if range.contains(now) {
            let previousStart = range.previousInterval.start
            let cutoff = Self.previousCutoff(currentStart: range.interval.start, previousStart: previousStart,
                                             now: now, calendar: calendar)
            durationPrevItems = Aggregator.clippedToElapsed(
                prevItems, windowStart: previousStart, elapsed: cutoff.timeIntervalSince(previousStart))
        } else {
            durationPrevItems = prevItems
        }
        totalDelta = total - Aggregator.totalDuration(durationPrevItems.map(\.span))
        let prevDurationByCategory = Aggregator.durationByCategory(durationPrevItems)
        focusDelta = focus - Aggregator.focusTime(durationByCategory: prevDurationByCategory, categories: categories)
        categoryDeltas = Dictionary(uniqueKeysWithValues: categoryRows.map { ($0.id, Format.minuteDelta($0.seconds, prevDurationByCategory[$0.id] ?? 0)) })
        let prevApps = Aggregator.durationByDomainOrApp(durationPrevItems)
        let prevSeconds = Dictionary(prevApps.map { ($0.key, $0.seconds) }, uniquingKeysWith: { first, _ in first })
        appDeltas = Dictionary(uniqueKeysWithValues: appRows.filter { $0.id != StatsModel.remainderID }.map { ($0.id, Format.minuteDelta($0.seconds, prevSeconds[$0.id] ?? 0)) })
        appMovers = AppMovers(current: apps, previous: prevApps)
    }

    private static func hourScale(_ points: [StackedPoint]) -> (top: Double, step: Double) {
        let totals = Dictionary(grouping: points, by: \.bucketStart).values.map { $0.reduce(0) { $0 + $1.hours } }
        return ChartAxis.hourScale(maxHours: totals.max() ?? 0)
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
