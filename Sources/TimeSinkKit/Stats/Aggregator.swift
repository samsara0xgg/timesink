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

    public static func split(_ span: Span, by component: Calendar.Component, calendar: Calendar) -> [(bucketStart: Date, seconds: TimeInterval)] {
        guard span.end > span.start else { return [] }
        guard var interval = calendar.dateInterval(of: component, for: span.start) else { return [] }

        var result: [(bucketStart: Date, seconds: TimeInterval)] = []
        while interval.start < span.end {
            let partStart = max(interval.start, span.start)
            let partEnd = min(interval.end, span.end)
            let seconds = partEnd.timeIntervalSince(partStart)
            if seconds > 0 {
                result.append((bucketStart: interval.start, seconds: seconds))
            }
            guard let next = calendar.dateInterval(of: component, for: interval.end) else { break }
            interval = next
        }
        return result
    }

    // MARK: - Profiles

    public static func profileByHourOfDay(_ items: [CategorizedSpan], calendar: Calendar) -> [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        for item in items {
            for part in split(item.span, by: .hour, calendar: calendar) {
                let hour = calendar.component(.hour, from: part.bucketStart)
                result[hour, default: 0] += part.seconds
            }
        }
        return result
    }

    public static func profileByWeekday(_ items: [CategorizedSpan], calendar: Calendar) -> [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        for item in items {
            for part in split(item.span, by: .day, calendar: calendar) {
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
        for item in items {
            let sign = productivitySign(for: item.categoryID, categories: categories)
            guard sign != 0 else { continue }
            for part in split(item.span, by: .hour, calendar: calendar) {
                let hour = calendar.component(.hour, from: part.bucketStart)
                result[hour, default: 0] += sign * part.seconds
            }
        }
        return result
    }

    public static func productivityProfileByWeekday(_ items: [CategorizedSpan], categories: [String: Category], calendar: Calendar) -> [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        for item in items {
            let sign = productivitySign(for: item.categoryID, categories: categories)
            guard sign != 0 else { continue }
            for part in split(item.span, by: .day, calendar: calendar) {
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
        for item in items {
            for part in split(item.span, by: bucket, calendar: calendar) {
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
        for item in items {
            for part in split(item.span, by: .hour, calendar: calendar) {
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
        for item in items {
            for part in Aggregator.split(item.span, by: .day, calendar: calendar) {
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
