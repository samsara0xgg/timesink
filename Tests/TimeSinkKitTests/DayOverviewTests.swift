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

    func testDSTDayAndLongDayVesselNeverClipRecordedTime() {
        for (month, dayNumber, expectedHours) in [(3, 9, 23), (11, 2, 25)] {
            let start = calendar.date(from: DateComponents(year: 2025, month: month, day: dayNumber))!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let now = end.addingTimeInterval(-1)
            let overview = DayOverview(items: [item(start, now)], categories: categories, sessions: [], now: now, calendar: calendar)
            XCTAssertEqual(overview.day.duration, Double(expectedHours * 3600))
            XCTAssertGreaterThanOrEqual(overview.vesselHours * 3600, overview.total)
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
}
