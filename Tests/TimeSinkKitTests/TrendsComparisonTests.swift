import XCTest
@testable import TimeSinkKit

final class TrendsComparisonTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let categories = [
        "dev": Category(id: "dev", name: "Development", colorHex: "#111111", productivity: 2, sortOrder: 0),
        "chat": Category(id: "chat", name: "Chat", colorHex: "#222222", productivity: 0, sortOrder: 1),
    ]
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 15))! }

    /// One entry per day: `ago` days before today.
    private func entry(_ ago: Int, _ id: String, minutes: Double) -> (bucketStart: Date, categoryID: String, seconds: TimeInterval) {
        (calendar.date(byAdding: .day, value: -ago, to: calendar.startOfDay(for: today))!, id, minutes * 60)
    }

    func testHeadlineNamesTheCategoryThatMovedMostTheSameWay() {
        let daily = [entry(0, "dev", minutes: 300), entry(5, "chat", minutes: 60),
                     entry(20, "dev", minutes: 120), entry(21, "chat", minutes: 100)]
        let result = FourWeekComparison(daily: daily, today: today, categories: categories, calendar: calendar)
        // 360 recent against 220 before: +140 minutes, dev +180, chat -40.
        XCTAssertEqual(result.headline, .changed(delta: 140 * 60, category: "Development"))
    }

    func testHeadlineSaysLessAndSkipsACategoryThatOnlyMovedTheOtherWay() {
        let daily = [entry(1, "dev", minutes: 60), entry(2, "chat", minutes: 90), entry(15, "dev", minutes: 300)]
        let result = FourWeekComparison(daily: daily, today: today, categories: categories, calendar: calendar)
        XCTAssertEqual(result.headline, .changed(delta: -150 * 60, category: "Development"))
    }

    func testSmallDifferenceReadsAsTheSameAndNoPastMeansNoHeadline() {
        let same = FourWeekComparison(daily: [entry(0, "dev", minutes: 100), entry(14, "dev", minutes: 98)],
                                      today: today, categories: categories, calendar: calendar)
        XCTAssertEqual(same.headline, .same)
        let none = FourWeekComparison(daily: [entry(0, "dev", minutes: 100)], today: today, categories: categories, calendar: calendar)
        XCTAssertNil(none.headline)
    }

    func testWeeksRunOldestFirstAndOlderDaysAreLeftOut() {
        let daily = [entry(0, "dev", minutes: 10), entry(6, "dev", minutes: 20), entry(7, "dev", minutes: 30),
                     entry(14, "dev", minutes: 40), entry(27, "dev", minutes: 50), entry(28, "dev", minutes: 999)]
        let row = FourWeekComparison(daily: daily, today: today, categories: categories, calendar: calendar).rows[0]
        let expected: [TimeInterval] = [3000, 2400, 1800, 1800]
        XCTAssertEqual(row.weeks, expected)
        XCTAssertEqual(row.delta, 0)
    }

    func testOnlyTheSixLeadingCategoriesAreRowsOrderedByTime() {
        let ids = (0..<8).map { "c\($0)" }
        let daily = ids.enumerated().map { entry(1, $0.element, minutes: Double($0.offset + 1) * 10) }
        let rows = FourWeekComparison(daily: daily, today: today, categories: [:], calendar: calendar).rows
        XCTAssertEqual(rows.map(\.id), ["c7", "c6", "c5", "c4", "c3", "c2"])
    }

    func testMoversCountEveryAppAndIgnoreSmallChanges() {
        let current: [AppMovers.Total] = [("xcode", "Xcode", 200 * 60), ("msg", "Messages", 10 * 60), ("tiny", "Tiny", 62 * 60)]
        let previous: [AppMovers.Total] = [("xcode", "Xcode", 120 * 60), ("msg", "Messages", 40 * 60), ("gone", "Gone", 90 * 60), ("tiny", "Tiny", 60 * 60)]
        let movers = AppMovers(current: current, previous: previous)
        XCTAssertEqual(movers.riser, .init(name: "Xcode", delta: 80 * 60))
        // An app that left the list altogether can be the biggest faller.
        XCTAssertEqual(movers.faller, .init(name: "Gone", delta: -90 * 60))
        XCTAssertEqual(AppMovers(current: current, previous: current), AppMovers())
    }
}
