import XCTest
@testable import TimeSinkKit

final class DayOverviewTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }
    private var categories: [String: TimeSinkKit.Category] {
        ["work": .init(id: "work", name: "工作", colorHex: "#3D6090", productivity: 2, sortOrder: 0),
         "other": .init(id: "other", name: "其他", colorHex: "#888888", productivity: 0, sortOrder: 1)]
    }
    private func date(_ hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: hour, minute: minute))!
    }
    private func item(_ start: Date, _ end: Date, category: String = "work", title: String = "项目") -> CategorizedSpan {
        .init(span: Span(start: start, end: end, appBundleID: "editor", appName: "Editor",
                         title: title, url: nil, domain: nil), categoryID: category)
    }

    func testGapsDoNotBecomeActivityAndFocusIsIndependentOfEngagement() {
        let overview = DayOverview(items: [item(date(9), date(10)), item(date(11), date(12), category: "other")],
            categories: categories, sessions: [.init(start: date(9, minute: 15), end: date(9, minute: 40), plannedSeconds: 1500, completed: true)],
            now: date(13), calendar: calendar)
        XCTAssertEqual(overview.total, 7200)
        XCTAssertEqual(overview.engaged, 3600)
        XCTAssertEqual(overview.sessionSeconds, 1500)
        XCTAssertEqual(overview.gapSeconds, 3600)
        XCTAssertEqual(overview.pieces.count, 3)
        XCTAssertNil(overview.pieces[1].item)
        XCTAssertEqual(overview.categories.reduce(0) { $0 + $1.seconds }, overview.total)
    }

    func testClipAtMidnightAndNowAndKeepUnknownCategories() {
        let overview = DayOverview(items: [item(date(0).addingTimeInterval(-3600), date(1)),
                                          item(date(15), date(18), category: "removed")],
            categories: categories, sessions: [.init(start: date(0).addingTimeInterval(-1800), end: date(0, minute: 15), plannedSeconds: 2700)],
            now: date(16), calendar: calendar)
        XCTAssertEqual(overview.total, 7200)
        XCTAssertEqual(overview.sessionSeconds, 900)
        XCTAssertEqual(overview.categories.count, 2)
        XCTAssertEqual(overview.pieces.first?.start, date(0))
        XCTAssertEqual(overview.pieces.last?.end, date(16))
        XCTAssertEqual(overview.displayInterval.start, date(0))
    }

    func testTitlesOfOneRowFoldButRealGapsStay() {
        let overview = DayOverview(items: [item(date(9), date(9, minute: 30)), item(date(9, minute: 30), date(10)),
                                          item(date(10, minute: 1), date(10, minute: 2)), item(date(10, minute: 2), date(11), title: "别的项目")],
            categories: categories, sessions: [], now: date(12), calendar: calendar)
        XCTAssertEqual(overview.pieces.count, 3)
        XCTAssertEqual(overview.pieces[0].seconds, 3600)
        XCTAssertNil(overview.pieces[1].item)
        XCTAssertEqual(overview.gapSeconds, 60)
        XCTAssertEqual(overview.pieces[2].seconds, 3540)
        XCTAssertEqual(overview.pieces[2].segment?.firstStarts.count, 2)
    }

    /// A window switch every 20 seconds is one row per stretch, not one per
    /// switch, and every recorded second is still accounted for.
    func testHighChurnFoldsWithoutLosingTime() {
        let items = (0..<90).map { index -> CategorizedSpan in
            let start = date(9).addingTimeInterval(Double(index) * 20)
            return .init(span: Span(start: start, end: start.addingTimeInterval(20),
                                    appBundleID: index % 3 == 0 ? "chat" : "editor", appName: index % 3 == 0 ? "Chat" : "Editor",
                                    title: "t\(index % 5)", url: nil, domain: nil), categoryID: index % 3 == 0 ? "other" : "work")
        }
        let overview = DayOverview(items: items, categories: categories, sessions: [], now: date(12), calendar: calendar)
        XCTAssertLessThanOrEqual(overview.pieces.count, 6)
        XCTAssertEqual(overview.pieces.compactMap(\.segment).reduce(0) { $0 + $1.recorded }, overview.total)
        XCTAssertEqual(overview.pieces.first?.segment?.dominant.appName, "Editor")
    }

    func testDSTDayAndLongDayRibbonNeverClipsRecordedTime() {
        for (month, dayNumber, expectedHours) in [(3, 9, 23), (11, 2, 25)] {
            let start = calendar.date(from: DateComponents(year: 2025, month: month, day: dayNumber))!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let now = end.addingTimeInterval(-1)
            let overview = DayOverview(items: [item(start, now)], categories: categories, sessions: [], now: now, calendar: calendar)
            XCTAssertEqual(overview.day.duration, Double(expectedHours * 3600))
            XCTAssertEqual(overview.displayInterval.start, start)
            XCTAssertEqual(overview.displayInterval.end, end)
        }
    }

    func testEmptyDayDoesNotInventGapsOrSessions() {
        let overview = DayOverview(items: [], categories: categories, sessions: [], now: date(7), calendar: calendar)
        XCTAssertEqual(overview.total, 0)
        XCTAssertEqual(overview.gapSeconds, 0)
        XCTAssertTrue(overview.pieces.isEmpty)
        XCTAssertNil(overview.firstRecord)
        XCTAssertLessThanOrEqual(overview.displayInterval.start, date(7))
    }

    /// The ribbon starts at the first recorded hour and stops a little after
    /// now instead of running to a fixed evening hour or midnight.
    func testDisplayIntervalRunsFromFirstRecordToJustAfterNow() {
        let overview = DayOverview(items: [item(date(9, minute: 10), date(16, minute: 40))],
            categories: categories, sessions: [], now: date(16, minute: 40), calendar: calendar)
        XCTAssertEqual(overview.displayInterval, DateInterval(start: date(9), end: date(18)))
        let late = DayOverview(items: [item(date(9), date(16, minute: 20))],
            categories: categories, sessions: [], now: date(16, minute: 20), calendar: calendar)
        XCTAssertEqual(late.displayInterval.end, date(17))
    }

    /// "6h 36m" today and "5h 49m" yesterday read as 47 minutes more, even
    /// when the raw seconds differ by 46m 20s.
    func testMinuteDeltaAgreesWithTheDurationsShown() {
        let today: TimeInterval = 6 * 3600 + 36 * 60 + 10
        let yesterday: TimeInterval = 5 * 3600 + 49 * 60 + 50
        XCTAssertEqual(Format.duration(today), "6h 36m")
        XCTAssertEqual(Format.duration(yesterday), "5h 49m")
        XCTAssertEqual(Format.minuteDelta(today, yesterday), 47 * 60)
        XCTAssertEqual(Format.minuteDelta(yesterday, today), -47 * 60)
        XCTAssertEqual(Format.minuteDelta(59, 0), 0)
    }

    func testLimitStatusCaptions() {
        let hour: TimeInterval = 3600
        XCTAssertEqual(LimitStatus(spent: hour + 12 * 60 + 30, limit: hour, warningPercent: 20), .over(minutes: 12))
        XCTAssertEqual(LimitStatus(spent: 50 * 60, limit: hour, warningPercent: 20), .near(minutes: 10))
        XCTAssertEqual(LimitStatus(spent: 60 * 60 + 30, limit: hour, warningPercent: 20), .near(minutes: 0))
        XCTAssertEqual(LimitStatus(spent: 20 * 60, limit: hour, warningPercent: 20), .within(minutes: 60))
    }
}
