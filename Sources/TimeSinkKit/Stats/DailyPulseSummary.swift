import Foundation

/// Shared SQL-bucketed calculation; callers choose their own execution context.
enum DailyPulseSummary {
    static func compute(store: SpanStore, days: Int, endingAt: Date, calendar: Calendar,
                        categories: [String: Category], classify: (Span) -> String) throws -> [Int?] {
        // days + 1 ascending boundaries, built with the same
        // `date(byAdding: .day)` walk `Aggregator.dailyPulses` uses for its
        // per-day lookup keys, so bucket i is the same calendar day it would
        // have looked up -- including DST days, which are 23 or 25 hours long
        // here and in `Aggregator.split` alike.
        let todayStart = calendar.startOfDay(for: endingAt)
        let boundaries = ((-1)...(days - 1)).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: todayStart)
        }
        guard boundaries.count == days + 1 else { return Array(repeating: nil, count: days) }

        let (totals, straddlers) = try store.dailyTupleTotals(dayBoundaries: boundaries)
        var byDay = Array(repeating: [String: TimeInterval](), count: days)
        for total in totals {
            // `CategoryResolver.categoryID(for:)` reads only these four
            // fields (they are its memo key), so a probe span with
            // placeholder timestamps classifies identically to the rows
            // it stands for -- and the resolver's memo means each tuple
            // costs a dictionary hit after its first day.
            let probe = Span(start: todayStart, end: todayStart, appBundleID: total.appBundleID,
                             appName: "", title: total.title, url: total.url, domain: total.domain)
            byDay[total.dayIndex][total.categoryOverride ?? classify(probe), default: 0] += total.seconds
        }
        // Boundary-crossing spans, split across the buckets they touch.
        // Clipping is implicit: a part outside [first, last] boundary
        // never matches, which is what `rangedSpans`' clip-to-interval
        // did at both ends of the window.
        for span in straddlers {
            let categoryID = classify(span)
            for index in 0..<days {
                let start = max(span.start, boundaries[index])
                let end = min(span.end, boundaries[index + 1])
                guard end > start else { continue }
                byDay[index][categoryID, default: 0] += end.timeIntervalSince(start)
            }
        }
        return byDay.map { Aggregator.pulse(durationByCategory: $0, categories: categories) }
    }
}
