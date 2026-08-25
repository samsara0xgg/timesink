import XCTest
@testable import TimeSinkKit

final class TodayDashboardModelTests: XCTestCase {
    func testStreakCountsTrailingDaysAtOrAboveThreshold() {
        // 数组末位是今天
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [60, 72, 75, 71], threshold: 70), 3)
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [72, 65], threshold: 70), 0)
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [], threshold: 70), 0)
        // 无数据的天（nil，例如没开机）终止连续
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [80, nil, 75, 80], threshold: 70), 2)
    }

    func testDailyPulsesSplitsAcrossDays() {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        // 昨天一段纯生产力（softwareDev, +2 -> 100 分），今天一段纯娱乐（-2 -> 0 分）
        let categories = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        let items = [
            CategorizedSpan(span: Span(start: todayStart.addingTimeInterval(-3600),
                                       end: todayStart.addingTimeInterval(-1800),
                                       appBundleID: "a", appName: "a", title: nil, url: nil, domain: nil),
                            categoryID: "softwareDev"),
            CategorizedSpan(span: Span(start: todayStart.addingTimeInterval(600),
                                       end: todayStart.addingTimeInterval(1200),
                                       appBundleID: "b", appName: "b", title: nil, url: nil, domain: nil),
                            categoryID: "entertainment"),
        ]
        let pulses = TodayDashboardModel.dailyPulses(
            items: items, categories: categories, days: 2, endingAt: now, calendar: calendar)
        XCTAssertEqual(pulses.count, 2)
        XCTAssertEqual(pulses[0], 100) // 昨天
        XCTAssertEqual(pulses[1], 0)   // 今天
    }

    /// CONTROLLER RULING 14: yesterday's spans must be clipped to the same
    /// elapsed time-of-day as today before comparing, not compared as a full
    /// day. A span straddling the clip boundary contributes only its inside
    /// portion; a span entirely after the boundary contributes nothing.
    func testClippedToElapsedKeepsOnlyThePortionInsideTheWindow() {
        let windowStart = ts(0)
        let straddling = CategorizedSpan(
            span: Span(start: ts(3000), end: ts(4200), appBundleID: "a", appName: "a",
                       title: nil, url: nil, domain: nil),
            categoryID: "softwareDev")
        let after = CategorizedSpan(
            span: Span(start: ts(4000), end: ts(4800), appBundleID: "b", appName: "b",
                       title: nil, url: nil, domain: nil),
            categoryID: "softwareDev")

        let result = TodayDashboardModel.clippedToElapsed(
            [straddling, after], windowStart: windowStart, elapsed: 3600)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].span.start, ts(3000))
        XCTAssertEqual(result[0].span.end, ts(3600)) // clipped at windowStart + elapsed
    }

    /// C1+ 分数环 hover 下钻子窗的数据源：每分类的贡献 (seconds * points)
    /// 降序，points 复用 pulse 公式的每分类换算（+2 → 100，-2 → 0），share 为
    /// 该分类占当日总时长的比例。
    func testScoreContributions() {
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        let rows = TodayDashboardModel.scoreContributions(
            byCategory: ["softwareDev": 3600, "entertainment": 1800], categories: cats)
        XCTAssertEqual(rows[0].id, "softwareDev")                 // 贡献降序
        XCTAssertEqual(rows[0].points, 100)                       // +2 → 100
        XCTAssertEqual(rows[0].share, 3600.0/5400.0, accuracy: 0.001)
        XCTAssertEqual(rows[1].points, 0)                         // -2 → 0
    }
}
