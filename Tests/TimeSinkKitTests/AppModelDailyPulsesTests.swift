import XCTest
@testable import TimeSinkKit

/// `AppModel.dailyPulses` replaced the popover streak lookback's
/// "fetch+classify every span of the last 30 days, then
/// `Aggregator.dailyPulses`" with a SQL aggregation down to one row per
/// (day, classification tuple). It is a PERFORMANCE change only, so the one
/// thing that matters is that the two paths still produce the same `[Int?]`.
@MainActor
final class AppModelDailyPulsesTests: XCTestCase {
    private func makeModel() throws -> (AppModel, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let settings = SettingsStore(db)
        let model = AppModel(categoryStore: categoryStore, spanStore: spanStore, settings: settings,
                             resolver: CategoryResolver(categoryStore: categoryStore),
                             engine: TrackerEngine(spanStore: spanStore, settings: settings))
        return (model, spanStore)
    }

    /// The old path, verbatim: what `refreshStreakIfDayChanged` used to run.
    private func legacyDailyPulses(_ model: AppModel, days: Int, endingAt: Date, calendar: Calendar) -> [Int?] {
        let lookback = model.rangedSpans(for: DateRangeSelection(kind: .last30, anchor: endingAt))
        return Aggregator.dailyPulses(items: lookback, categories: model.resolver.categoriesByID,
                                      days: days, endingAt: endingAt, calendar: calendar)
    }

    /// Equivalence on a fixture built to hit all three traps the SQL
    /// aggregation could get wrong, with per-day values chosen so each one
    /// has a DIFFERENT pulse if it is handled wrong:
    ///
    ///  - day 0 holds a span that starts BEFORE the window: it must be
    ///    clipped to the window start (50), not summed whole (67);
    ///  - day 28/29 share a span straddling local midnight: it must be split
    ///    (67 / 50), not booked whole to the day it starts in (75 / 0) or
    ///    ends in (0 / 75);
    ///  - days 1...27 have no spans at all and must stay `nil` (untracked),
    ///    which is what breaks a streak -- never 0, which would merely be a
    ///    bad day.
    func testDailyPulsesMatchesTheSpanBySpanAggregatorPath() throws {
        let (model, store) = try makeModel()
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        // Bucket 0 of a 30-day lookback ending today.
        let windowStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -29, to: todayStart))

        // com.apple.dt.Xcode -> softwareDev (+2 -> 100 points),
        // com.spotify.client -> entertainment (-2 -> 0 points): both from the
        // builtin app map, no rule setup needed.
        func insert(_ start: Date, _ end: Date, productive: Bool) throws {
            try store.insert(Span(start: start, end: end,
                                  appBundleID: productive ? "com.apple.dt.Xcode" : "com.spotify.client",
                                  appName: productive ? "Xcode" : "Spotify",
                                  title: nil, url: nil, domain: nil))
        }
        // Day 0: 1h of the straddling span survives clipping, + 1h inside.
        try insert(windowStart.addingTimeInterval(-3600), windowStart.addingTimeInterval(3600), productive: true)
        try insert(windowStart.addingTimeInterval(7200), windowStart.addingTimeInterval(10800), productive: false)
        // Day 28 (yesterday) / 29 (today): 1h before midnight + 30min after.
        try insert(todayStart.addingTimeInterval(-3600), todayStart.addingTimeInterval(1800), productive: true)
        try insert(todayStart.addingTimeInterval(-7200), todayStart.addingTimeInterval(-5400), productive: false)
        try insert(todayStart.addingTimeInterval(3600), todayStart.addingTimeInterval(5400), productive: false)

        let new = model.dailyPulses(days: 30, endingAt: now, calendar: calendar)
        let legacy = legacyDailyPulses(model, days: 30, endingAt: now, calendar: calendar)

        XCTAssertEqual(new, legacy)
        XCTAssertEqual(new.count, 30)
        XCTAssertEqual(new[0], 50)          // clipped at the window start
        XCTAssertEqual(new[1], nil)         // untracked day stays nil, not 0
        XCTAssertEqual(new[28], 67)         // (3600*100 + 1800*0) / 5400
        XCTAssertEqual(new[29], 50)         // (1800*100 + 1800*0) / 3600
    }

    /// The distinct-tuple collapse is the whole point: one classification per
    /// (day, tuple) instead of one per span. Twenty spans of the same tuple
    /// in one day must still total 20x their duration -- i.e. the SUM is
    /// summing, not deduplicating -- and a second tuple in the same day must
    /// stay a separate group rather than folding into the first.
    func testRepeatedTuplesInOneDayAreSummedNotDeduplicated() throws {
        let (model, store) = try makeModel()
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)

        // 20 x 60s of the same (bundleID, title, url, domain) tuple -> 1200s
        // softwareDev, + 400s entertainment: pulse (1200*100)/1600 = 75.
        for index in 0..<20 {
            let start = todayStart.addingTimeInterval(Double(index) * 120)
            try store.insert(Span(start: start, end: start.addingTimeInterval(60),
                                  appBundleID: "com.apple.dt.Xcode", appName: "Xcode",
                                  title: "same title", url: nil, domain: nil))
        }
        try store.insert(Span(start: todayStart.addingTimeInterval(7200),
                              end: todayStart.addingTimeInterval(7600),
                              appBundleID: "com.spotify.client", appName: "Spotify",
                              title: nil, url: nil, domain: nil))

        let new = model.dailyPulses(days: 2, endingAt: now, calendar: calendar)
        XCTAssertEqual(new.last ?? nil, 75)
        XCTAssertEqual(new, legacyDailyPulses(model, days: 2, endingAt: now, calendar: calendar))

        // Pulse is a duration-weighted RATIO, so it cannot see a units error
        // in the SUM (milliseconds left unconverted would score the same 75).
        // Assert the seconds directly, on the one row the 20 spans collapse
        // to.
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: todayStart))
        let (totals, straddlers) = try store.dailyTupleTotals(dayBoundaries: [todayStart, tomorrow])
        XCTAssertTrue(straddlers.isEmpty)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.first { $0.title == "same title" }?.seconds, 1200)
        XCTAssertEqual(totals.first { $0.appBundleID == "com.spotify.client" }?.seconds, 400)
    }
}
