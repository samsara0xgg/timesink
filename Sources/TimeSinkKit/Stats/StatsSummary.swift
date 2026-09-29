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
    var stackedDomainColorHex: [String] = []

    var appRows: [RankingRow] = []
    var categoryRows: [RankingRow] = []
    var categoryDeltas: [String: TimeInterval] = [:]

    init(items: [CategorizedSpan] = [], previous: [CategorizedSpan] = [],
         range: DateRangeSelection = .today(), categories: [String: Category] = [:],
         now: Date = Date(), calendar: Calendar = .current) {
        total = Aggregator.totalDuration(items.map(\.span))
        // A still-running period has only elapsed as far as `now`; dividing a
        // partial total by the FULL calendar window is biased by construction
        // (Monday's `.week` divided 1 day of data by 7). Same `containsNow`
        // clipping `recomputeDeltas` already applies to its duration deltas.
        let elapsed = range.containsNow
            ? now.timeIntervalSince(range.interval.start)
            : range.interval.duration
        let days = max(1, Int((elapsed / 86400).rounded()))
        avgPerDay = total / Double(days)

        let byCategory = Aggregator.durationByCategory(items)
        pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories)
        focus = Aggregator.focusTime(durationByCategory: byCategory, categories: categories)

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

        // Websites and native apps share the same non-overlapping ranking.
        var appCategorySeconds: [String: [String: TimeInterval]] = [:]
        var domains: Set<String> = []
        for item in items {
            let key = item.span.domain ?? item.span.appBundleID
            if item.span.domain != nil { domains.insert(key) }
            appCategorySeconds[key, default: [:]][item.categoryID, default: 0] += item.span.duration
        }
        appRows = StatsModel.distributionRows(Aggregator.durationByDomainOrApp(items).map { entry in
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

        recomputeDeltas(prevItems: previous, range: range, categories: categories, now: now)
    }

    private mutating func recomputeDeltas(prevItems: [CategorizedSpan], range: DateRangeSelection,
                                         categories: [String: Category], now: Date) {
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
            let elapsed = now.timeIntervalSince(range.interval.start)
            durationPrevItems = Aggregator.clippedToElapsed(
                prevItems, windowStart: range.previousInterval.start, elapsed: elapsed)
        } else {
            durationPrevItems = prevItems
        }
        totalDelta = total - Aggregator.totalDuration(durationPrevItems.map(\.span))
        let prevDurationByCategory = Aggregator.durationByCategory(durationPrevItems)
        focusDelta = focus - Aggregator.focusTime(durationByCategory: prevDurationByCategory, categories: categories)
        categoryDeltas = Dictionary(uniqueKeysWithValues: categoryRows.map { ($0.id, $0.seconds - (prevDurationByCategory[$0.id] ?? 0)) })
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
