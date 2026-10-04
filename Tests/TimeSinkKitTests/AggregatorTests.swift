import XCTest
@testable import TimeSinkKit

final class AggregatorTests: XCTestCase {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    // 2026-08-17 是周一; 构造 10:30-12:15 的 span (UTC)
    func mkSpan(_ startISO: String, _ endISO: String, app: String = "a", url: String? = nil) -> Span {
        let f = ISO8601DateFormatter()
        return Span(start: f.date(from: startISO)!, end: f.date(from: endISO)!,
                    appBundleID: app, appName: app, title: nil, url: url,
                    domain: url.flatMap(DomainParser.domain(from:)))
    }
    var cats: [String: TimeSinkKit.Category] {
        Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
    }

    func testSplitAcrossHours() {
        let s = mkSpan("2026-08-17T10:30:00Z", "2026-08-17T12:15:00Z")
        let parts = Aggregator.split(s, by: .hour, calendar: cal)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].seconds, 1800)   // 10:30-11:00
        XCTAssertEqual(parts[1].seconds, 3600)   // 11:00-12:00
        XCTAssertEqual(parts[2].seconds, 900)    // 12:00-12:15
    }
    /// `BucketSplitter` caches the last bucket `Calendar` resolved and reuses
    /// it for the next span, which is only safe if the reuse test is
    /// half-open and nothing assumes a fixed bucket length. Neither condition
    /// is exercised by the live database (its spans never cross a DST
    /// transition) or by the UTC fixtures above, so this drives a sequence
    /// through one splitter across both 2026 US transitions and requires it to
    /// agree with the uncached per-span `split` on every part.
    ///
    /// Fails if the cache goes stale, if the containment test becomes
    /// inclusive of `end` (a span starting exactly on a boundary would then
    /// be attributed to the previous bucket), or if the loop stops crossing
    /// into later buckets.
    func testBucketSplitterMatchesUncachedSplitAcrossDSTTransitions() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let f = ISO8601DateFormatter()

        // 2026-03-08 springs forward (23h), 2026-11-01 falls back (25h).
        for (label, windowStart, expectedHours) in [
            ("spring forward", "2026-03-07T08:00:00Z", 23.0),
            ("fall back", "2026-10-31T07:00:00Z", 25.0),
        ] as [(String, String, Double)] {
            let base = f.date(from: windowStart)!

            // Prove the window really contains the transition, so a calendar
            // or timezone-data change can't silently turn this into a test of
            // ordinary 24-hour days.
            let transitionDay = pacific.startOfDay(for: base.addingTimeInterval(36 * 3600))
            let dayLength = pacific.dateInterval(of: .day, for: transitionDay)!.duration
            XCTAssertEqual(dayLength / 3600, expectedHours, "\(label): window does not contain the DST transition")

            // Every 20 minutes for three days: short spans that mostly stay
            // inside one bucket (so the cache is actually reused), plus some
            // that straddle, plus spans starting exactly on bucket edges.
            var spans: [Span] = []
            for step in 0..<(3 * 72) {
                let start = base.addingTimeInterval(Double(step) * 1200)
                spans.append(Span(start: start, end: start.addingTimeInterval(900),
                                  appBundleID: "a", appName: "a", title: nil, url: nil, domain: nil))
            }
            for hourOffset in [0.0, 23.0, 24.0, 25.0, 47.0, 48.0] {
                let edge = pacific.startOfDay(for: base).addingTimeInterval(hourOffset * 3600)
                spans.append(Span(start: edge, end: edge.addingTimeInterval(5400),
                                  appBundleID: "a", appName: "a", title: nil, url: nil, domain: nil))
            }
            spans.sort { $0.start < $1.start }

            for component in [Calendar.Component.hour, .day, .weekOfYear] {
                var splitter = Aggregator.BucketSplitter(component: component, calendar: pacific)
                for span in spans {
                    let cached = splitter.split(span)
                    let uncached = Aggregator.split(span, by: component, calendar: pacific)
                    XCTAssertEqual(cached.count, uncached.count,
                                   "\(label) .\(component): part count differs at \(span.start)")
                    for (a, b) in zip(cached, uncached) {
                        XCTAssertEqual(a.bucketStart, b.bucketStart,
                                       "\(label) .\(component): bucketStart differs at \(span.start)")
                        XCTAssertEqual(a.seconds, b.seconds,
                                       "\(label) .\(component): seconds differ at \(span.start)")
                    }
                }
            }
        }
    }

    /// A span whose whole duration sits inside one bucket must produce exactly
    /// one part, and a span starting exactly on a bucket boundary belongs to
    /// the bucket that boundary opens -- not the one it closes.
    func testSplitBoundaryExactness() {
        let inside = mkSpan("2026-08-17T10:10:00Z", "2026-08-17T10:50:00Z")
        XCTAssertEqual(Aggregator.split(inside, by: .hour, calendar: cal).count, 1)

        let onEdge = mkSpan("2026-08-17T11:00:00Z", "2026-08-17T11:30:00Z")
        let parts = Aggregator.split(onEdge, by: .hour, calendar: cal)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].bucketStart, ISO8601DateFormatter().date(from: "2026-08-17T11:00:00Z")!)
        XCTAssertEqual(parts[0].seconds, 1800)
    }

    func testPulseFormula() {
        // 2h softwareDev(+2=100分) + 1h entertainment(-2=0分) → (7200*100+3600*0)/10800 = 66.67 → 67
        let by = ["softwareDev": 7200.0, "entertainment": 3600.0]
        XCTAssertEqual(Aggregator.pulse(durationByCategory: by, categories: cats), 67)
        XCTAssertNil(Aggregator.pulse(durationByCategory: [:], categories: cats))
    }
    func testFocusTime() {
        let by = ["softwareDev": 7200.0, "research": 600.0, "communication": 900.0, "entertainment": 3600.0]
        XCTAssertEqual(Aggregator.focusTime(durationByCategory: by, categories: cats), 7800)
    }
    func testProfileWeekdayMondayIndexZero() {
        let s = mkSpan("2026-08-17T10:00:00Z", "2026-08-17T11:00:00Z")   // 周一
        let p = Aggregator.profileByWeekday([CategorizedSpan(span: s, categoryID: "misc")], calendar: cal)
        XCTAssertEqual(p[0], 3600)
    }
    func testProductivityProfileDiverges() {
        let good = mkSpan("2026-08-17T10:00:00Z", "2026-08-17T11:00:00Z")
        let bad = mkSpan("2026-08-17T10:00:00Z", "2026-08-17T10:30:00Z")
        let p = Aggregator.productivityProfileByHourOfDay(
            [CategorizedSpan(span: good, categoryID: "softwareDev"),
             CategorizedSpan(span: bad, categoryID: "entertainment")],
            categories: cats, calendar: cal)
        XCTAssertEqual(p[10], 1800)   // 3600 focus - 1800 distracting
    }
    func testDurationByDomainOrApp() {
        let web = mkSpan("2026-08-17T10:00:00Z", "2026-08-17T10:10:00Z",
                         app: "com.google.Chrome", url: "https://github.com/x")
        let native = mkSpan("2026-08-17T10:10:00Z", "2026-08-17T10:40:00Z", app: "com.apple.dt.Xcode")
        let rows = Aggregator.durationByDomainOrApp(
            [CategorizedSpan(span: web, categoryID: "softwareDev"),
             CategorizedSpan(span: native, categoryID: "softwareDev")])
        XCTAssertEqual(rows[0].label, "com.apple.dt.Xcode")
        XCTAssertEqual(rows[1].label, "github.com")
    }
    func testFormatDuration() {
        let en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")
        XCTAssertEqual(Format.duration(3661, locale: en), "1h 1m")
        XCTAssertEqual(Format.duration(540, locale: en), "9m")
        XCTAssertEqual(Format.duration(30, locale: en), "<1m")
        XCTAssertEqual(Format.duration(0, locale: en), "0m")
        XCTAssertEqual(Format.duration(3661, locale: zh), "1 小时 1 分")
        XCTAssertEqual(Format.duration(660, locale: zh), "11 分")
        XCTAssertEqual(Format.duration(3 * 3600, locale: zh), "3 小时")
        XCTAssertEqual(Format.duration(25 * 3600 + 23 * 60, locale: zh), "25 小时 23 分")
        XCTAssertEqual(Format.duration(30, locale: zh), "不到 1 分")
        XCTAssertEqual(Format.duration(0, locale: zh), "0 分")
        XCTAssertEqual(Format.durationDelta(-96 * 60, locale: zh), "-1 小时 36 分")
    }
    func testPulseByWeekdayHourBuckets() {
        // 周一 10 点 1h softwareDev(+2=100分) + 周一 11 点 30m entertainment(-2=0分)
        let good = mkSpan("2026-08-17T10:00:00Z", "2026-08-17T11:00:00Z")
        let bad = mkSpan("2026-08-17T11:00:00Z", "2026-08-17T11:30:00Z")
        let grid = Aggregator.pulseByWeekdayHour(
            [CategorizedSpan(span: good, categoryID: "softwareDev"),
             CategorizedSpan(span: bad, categoryID: "entertainment")],
            categories: cats, calendar: cal)
        XCTAssertEqual(grid[0][10].pulse, 100)
        XCTAssertEqual(grid[0][10].seconds, 3600)
        XCTAssertEqual(grid[0][11].pulse, 0)
    }
    func testLiftedHelpersStillBehave() {
        // Same behavior as TodayDashboardModelTests, exercised directly
        // against Aggregator now that dailyPulses/clippedToElapsed/streak
        // are lifted there (TodayDashboardModel's versions are one-line
        // forwards -- TodayDashboardModelTests passing unchanged is the
        // proof those forwards preserved behavior).
        XCTAssertEqual(Aggregator.streak(dailyPulses: [70, 71, nil, 80, 90], threshold: 70), 2)
        XCTAssertEqual(Aggregator.streak(dailyPulses: [60, 72, 75, 71], threshold: 70), 3)
        XCTAssertEqual(Aggregator.streak(dailyPulses: [], threshold: 70), 0)

        let straddling = CategorizedSpan(
            span: Span(start: ts(3000), end: ts(4200), appBundleID: "a", appName: "a",
                       title: nil, url: nil, domain: nil),
            categoryID: "softwareDev")
        let clipped = Aggregator.clippedToElapsed([straddling], windowStart: ts(0), elapsed: 3600)
        XCTAssertEqual(clipped.count, 1)
        XCTAssertEqual(clipped[0].span.end, ts(3600))
    }
}
