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
    func testPulseFormula() {
        // 2h softwareDev(+2=100分) + 1h entertainment(-2=0分) → (7200*100+3600*0)/10800 = 66.67 → 67
        let by = ["softwareDev": 7200.0, "entertainment": 3600.0]
        XCTAssertEqual(Aggregator.pulse(durationByCategory: by, categories: cats), 67)
        XCTAssertNil(Aggregator.pulse(durationByCategory: [:], categories: cats))
    }
    func testFocusTime() {
        let by = ["softwareDev": 7200.0, "business": 600.0, "communication": 900.0, "entertainment": 3600.0]
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
        XCTAssertEqual(Format.duration(3661), "1h 1m")
        XCTAssertEqual(Format.duration(540), "9m")
        XCTAssertEqual(Format.duration(30), "<1m")
        XCTAssertEqual(Format.duration(0), "0m")
    }
}
