import Foundation

/// Pure, stateless statistics aggregation over spans and categorized spans.
/// Every function here is a static pure function: no I/O, no shared state.
public enum Aggregator {

    // MARK: - Basic totals

    public static func totalDuration(_ spans: [Span]) -> TimeInterval {
        spans.reduce(0) { $0 + $1.duration }
    }

    public static func durationByCategory(_ items: [CategorizedSpan]) -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        for item in items {
            result[item.categoryID, default: 0] += item.span.duration
        }
        return result
    }

    public static func durationByApp(_ spans: [Span]) -> [(bundleID: String, appName: String, seconds: TimeInterval)] {
        var totals: [String: TimeInterval] = [:]
        var names: [String: String] = [:]
        for span in spans {
            totals[span.appBundleID, default: 0] += span.duration
            if names[span.appBundleID] == nil {
                names[span.appBundleID] = span.appName
            }
        }
        return totals
            .map { (bundleID: $0.key, appName: names[$0.key] ?? $0.key, seconds: $0.value) }
            .sorted { lhs, rhs in
                lhs.seconds != rhs.seconds ? lhs.seconds > rhs.seconds : lhs.bundleID < rhs.bundleID
            }
    }

    public static func durationByDomainOrApp(_ items: [CategorizedSpan]) -> [(key: String, label: String, seconds: TimeInterval)] {
        var totals: [String: TimeInterval] = [:]
        var labels: [String: String] = [:]
        for item in items {
            let span = item.span
            let key: String
            let label: String
            if let domain = span.domain {
                key = domain
                label = domain
            } else {
                key = span.appBundleID
                label = span.appName
            }
            totals[key, default: 0] += span.duration
            if labels[key] == nil {
                labels[key] = label
            }
        }
        return totals
            .map { (key: $0.key, label: labels[$0.key] ?? $0.key, seconds: $0.value) }
            .sorted { lhs, rhs in
                lhs.seconds != rhs.seconds ? lhs.seconds > rhs.seconds : lhs.key < rhs.key
            }
    }

    // MARK: - Pulse / focus

    private static func points(forProductivity productivity: Int) -> Double {
        let raw = 50.0 + Double(productivity) * 25.0
        return min(100, max(0, raw))
    }

    public static func pulse(durationByCategory: [String: TimeInterval], categories: [String: Category]) -> Int? {
        let totalSeconds = durationByCategory.values.reduce(0, +)
        guard totalSeconds > 0 else { return nil }
        var weightedSum: Double = 0
        for (categoryID, seconds) in durationByCategory {
            let productivity = categories[categoryID]?.productivity ?? 0
            weightedSum += seconds * points(forProductivity: productivity)
        }
        return Int((weightedSum / totalSeconds).rounded())
    }

    public static func focusTime(durationByCategory: [String: TimeInterval], categories: [String: Category]) -> TimeInterval {
        durationByCategory.reduce(0) { sum, entry in
            let productivity = categories[entry.key]?.productivity ?? 0
            return productivity >= 1 ? sum + entry.value : sum
        }
    }

    // MARK: - Splitting spans across calendar buckets

    /// Splits spans into calendar buckets, remembering the last bucket it
    /// resolved. Every `Aggregator` function that splits a whole array keeps
    /// one of these for the pass instead of calling `Calendar` per span.
    ///
    /// `Calendar.dateInterval(of:for:)` is the dominant cost of every profile
    /// and stacked-series card. Measured in a release build over the live
    /// database's 32,128 spans:
    ///
    ///     component      per-call   one-entry cache
    ///     .hour             7.6 ms          5.8 ms
    ///     .day            100.6 ms          5.9 ms
    ///     .weekOfYear     248.2 ms          5.8 ms
    ///
    /// `.weekOfYear` is the worst because it reaches ICU for `firstWeekday`
    /// and `minimumDaysInFirstWeek`; `.hour` is nearly arithmetic already.
    ///
    /// The cache works because `SpanStore.spans(overlapping:)` returns spans
    /// in `start` order and consecutive spans almost always share a bucket --
    /// measured on the live database, 32,105 of 32,127 consecutive pairs
    /// (99.93%) share a calendar day and 31,813 (99.02%) share an hour. Note
    /// this is the opposite of the result that killed a one-entry cache in
    /// front of `CategoryResolver`'s memo (only 2% of spans repeat the
    /// preceding classification tuple) -- bucket locality and tuple locality
    /// are unrelated, and each had to be measured separately.
    struct BucketSplitter {
        private let component: Calendar.Component
        private let calendar: Calendar
        private var start: Date = .distantPast
        private var end: Date = .distantPast

        init(component: Calendar.Component, calendar: Calendar) {
            self.component = component
            self.calendar = calendar
        }

        /// Deliberately not `DateInterval.contains(_:)`, which is inclusive
        /// of `end`: a timestamp landing exactly on a bucket boundary belongs
        /// to the next bucket, and `contains` would hand back the previous
        /// one. The cached pair is always whatever `Calendar` last returned,
        /// so DST's 23- and 25-hour days stay correct -- nothing here assumes
        /// a bucket's length.
        private mutating func interval(containing date: Date) -> DateInterval? {
            if date >= start && date < end {
                return DateInterval(start: start, end: end)
            }
            guard let resolved = calendar.dateInterval(of: component, for: date) else { return nil }
            start = resolved.start
            end = resolved.end
            return resolved
        }

        mutating func split(_ span: Span) -> [(bucketStart: Date, seconds: TimeInterval)] {
            guard span.end > span.start else { return [] }
            guard var bucket = interval(containing: span.start) else { return [] }

            var result: [(bucketStart: Date, seconds: TimeInterval)] = []
            while true {
                let partStart = max(bucket.start, span.start)
                let partEnd = min(bucket.end, span.end)
                let seconds = partEnd.timeIntervalSince(partStart)
                if seconds > 0 {
                    result.append((bucketStart: bucket.start, seconds: seconds))
                }
                // Resolve the next bucket only when the span actually reaches
                // into it. The previous formulation looked it up at the end of
                // every iteration and let `while interval.start < span.end`
                // reject it, which doubled the `Calendar` calls for the ~99%
                // of spans that fit in one bucket -- and, once a cache sits
                // behind this, evicted the entry the next span was about to
                // hit. Exiting here is equivalent: the rejected `next` starts
                // at `interval.end >= span.end`, so the old condition was
                // already false for it.
                if bucket.end >= span.end { break }
                // `next.start > bucket.start` is this loop's termination
                // invariant, not a hypothetical: the advance depends on the
                // cache above answering `bucket.end` with the FOLLOWING
                // bucket. Any containment test that hands back the current
                // one instead -- e.g. `DateInterval.contains`, which is
                // inclusive of `end` -- turns this into an infinite loop that
                // hangs the main actor mid-aggregation. Stating it costs a
                // comparison and converts that hang into a short result.
                guard let next = interval(containing: bucket.end),
                      next.start > bucket.start else { break }
                bucket = next
            }
            return result
        }
    }

    /// One-shot split, kept for callers (and tests) that split a single span.
    /// Array callers should hold a `BucketSplitter` across the pass instead --
    /// a splitter built per span can never hit its cache.
    public static func split(_ span: Span, by component: Calendar.Component, calendar: Calendar) -> [(bucketStart: Date, seconds: TimeInterval)] {
        var splitter = BucketSplitter(component: component, calendar: calendar)
        return splitter.split(span)
    }

    // MARK: - Profiles

    public static func profileByHourOfDay(_ items: [CategorizedSpan], calendar: Calendar) -> [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        var splitter = BucketSplitter(component: .hour, calendar: calendar)
        for item in items {
            for part in splitter.split(item.span) {
                let hour = calendar.component(.hour, from: part.bucketStart)
                result[hour, default: 0] += part.seconds
            }
        }
        return result
    }

    public static func profileByWeekday(_ items: [CategorizedSpan], calendar: Calendar) -> [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        var splitter = BucketSplitter(component: .day, calendar: calendar)
        for item in items {
            for part in splitter.split(item.span) {
                let weekday = calendar.component(.weekday, from: part.bucketStart) // 1 = Sunday
                let key = (weekday + 5) % 7 // 0 = Monday ... 6 = Sunday
                result[key, default: 0] += part.seconds
            }
        }
        return result
    }

    private static func productivitySign(for categoryID: String, categories: [String: Category]) -> TimeInterval {
        let productivity = categories[categoryID]?.productivity ?? 0
        if productivity >= 1 { return 1 }
        if productivity <= -1 { return -1 }
        return 0
    }

    public static func productivityProfileByHourOfDay(_ items: [CategorizedSpan], categories: [String: Category], calendar: Calendar) -> [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        var splitter = BucketSplitter(component: .hour, calendar: calendar)
        for item in items {
            let sign = productivitySign(for: item.categoryID, categories: categories)
            guard sign != 0 else { continue }
            for part in splitter.split(item.span) {
                let hour = calendar.component(.hour, from: part.bucketStart)
                result[hour, default: 0] += sign * part.seconds
            }
        }
        return result
    }

    public static func productivityProfileByWeekday(_ items: [CategorizedSpan], categories: [String: Category], calendar: Calendar) -> [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        var splitter = BucketSplitter(component: .day, calendar: calendar)
        for item in items {
            let sign = productivitySign(for: item.categoryID, categories: categories)
            guard sign != 0 else { continue }
            for part in splitter.split(item.span) {
                let weekday = calendar.component(.weekday, from: part.bucketStart) // 1 = Sunday
                let key = (weekday + 5) % 7 // 0 = Monday ... 6 = Sunday
                result[key, default: 0] += sign * part.seconds
            }
        }
        return result
    }

    // MARK: - Stacked series

    private struct BucketCategoryKey: Hashable {
        let bucketStart: Date
        let categoryID: String
    }

    public static func stackedSeries(_ items: [CategorizedSpan], bucket: Calendar.Component, calendar: Calendar) -> [(bucketStart: Date, categoryID: String, seconds: TimeInterval)] {
        var totals: [BucketCategoryKey: TimeInterval] = [:]
        var splitter = BucketSplitter(component: bucket, calendar: calendar)
        for item in items {
            for part in splitter.split(item.span) {
                let key = BucketCategoryKey(bucketStart: part.bucketStart, categoryID: item.categoryID)
                totals[key, default: 0] += part.seconds
            }
        }
        return totals
            .map { (bucketStart: $0.key.bucketStart, categoryID: $0.key.categoryID, seconds: $0.value) }
            .sorted { lhs, rhs in
                lhs.bucketStart != rhs.bucketStart ? lhs.bucketStart < rhs.bucketStart : lhs.categoryID < rhs.categoryID
            }
    }

    // MARK: - Weekday x hour grid (heatmap)

    /// 7x24 grid of (pulse, seconds), row order Monday=0, columns hour-of-day.
    /// For the heatmap card.
    public static func pulseByWeekdayHour(_ items: [CategorizedSpan], categories: [String: Category], calendar: Calendar) -> [[(pulse: Int?, seconds: TimeInterval)]] {
        var buckets: [[[String: TimeInterval]]] = Array(repeating: Array(repeating: [:], count: 24), count: 7)
        var splitter = BucketSplitter(component: .hour, calendar: calendar)
        for item in items {
            for part in splitter.split(item.span) {
                let weekday = calendar.component(.weekday, from: part.bucketStart) // 1 = Sunday
                let row = (weekday + 5) % 7 // 0 = Monday ... 6 = Sunday
                let hour = calendar.component(.hour, from: part.bucketStart)
                buckets[row][hour][item.categoryID, default: 0] += part.seconds
            }
        }
        return buckets.map { row in
            row.map { byCategory in
                let seconds = byCategory.values.reduce(0, +)
                return (pulse: pulse(durationByCategory: byCategory, categories: categories), seconds: seconds)
            }
        }
    }

    // MARK: - Lifted from TodayDashboardModel (Task 7 C2): shared by
    // TodayDashboardModel and StatsModel, both of which forward to these.

    /// Per-day pulse over the trailing `days` days (last element = the day
    /// containing `endingAt`); nil for days with no tracked time.
    public static func dailyPulses(items: [CategorizedSpan], categories: [String: Category],
                            days: Int, endingAt: Date, calendar: Calendar) -> [Int?] {
        var perDay: [Date: [String: TimeInterval]] = [:]
        var splitter = BucketSplitter(component: .day, calendar: calendar)
        for item in items {
            for part in splitter.split(item.span) {
                perDay[part.bucketStart, default: [:]][item.categoryID, default: 0] += part.seconds
            }
        }
        let todayStart = calendar.startOfDay(for: endingAt)
        return (0..<days).reversed().map { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let byCategory = perDay[day] else { return nil }
            return Aggregator.pulse(durationByCategory: byCategory, categories: categories)
        }
    }

    /// Clips `items` to `[windowStart, windowStart + elapsed]`: each span's
    /// start/end is clamped to the window and spans with no overlap left are
    /// dropped.
    public static func clippedToElapsed(
        _ items: [CategorizedSpan], windowStart: Date, elapsed: TimeInterval
    ) -> [CategorizedSpan] {
        let windowEnd = windowStart.addingTimeInterval(elapsed)
        return items.compactMap { item in
            let start = max(item.span.start, windowStart)
            let end = min(item.span.end, windowEnd)
            guard start < end else { return nil }
            var span = item.span
            span.start = start
            span.end = end
            return CategorizedSpan(span: span, categoryID: item.categoryID)
        }
    }

    /// Trailing run of days (ending at the array's last element) whose pulse
    /// is >= threshold. A nil (untracked) day breaks the run.
    public static func streak(dailyPulses: [Int?], threshold: Int) -> Int {
        var count = 0
        for pulse in dailyPulses.reversed() {
            guard let pulse, pulse >= threshold else { break }
            count += 1
        }
        return count
    }
}
