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
}
