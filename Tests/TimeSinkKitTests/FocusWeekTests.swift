import XCTest
@testable import TimeSinkKit

/// F4: the focus history by week.
final class FocusWeekTests: XCTestCase {
    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        c.firstWeekday = firstWeekday
        return c
    }

    /// Wednesday 2026-09-30, 12:00.
    private func date(_ day: Int, month: Int = 9, hour: Int = 10, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func focus(_ start: Date, minutes: Int) -> FocusSession {
        FocusSession(start: start, end: start.addingTimeInterval(Double(minutes) * 60), plannedSeconds: minutes * 60)
    }

    func testAWeekStartsOnTheChosenFirstWeekday() {
        let now = date(30, calendar: calendar(firstWeekday: 2))
        let monday = calendar(firstWeekday: 2), sunday = calendar(firstWeekday: 1)
        XCTAssertEqual(FocusWeek.interval(weeksBack: 0, now: now, calendar: monday).start, date(28, hour: 0, calendar: monday))
        XCTAssertEqual(FocusWeek.interval(weeksBack: 0, now: now, calendar: sunday).start, date(27, hour: 0, calendar: sunday))
        XCTAssertEqual(FocusWeek.interval(weeksBack: 1, now: now, calendar: monday).start, date(21, hour: 0, calendar: monday))
    }

    func testSessionsLandOnTheirDayAndOnlyInTheirWeek() {
        let c = calendar(firstWeekday: 2)
        let interval = FocusWeek.interval(weeksBack: 0, now: date(30, calendar: c), calendar: c)
        let week = FocusWeek.make([
            focus(date(28, calendar: c), minutes: 30),             // Monday
            focus(date(28, hour: 15, calendar: c), minutes: 20),   // Monday, later
            focus(date(30, calendar: c), minutes: 45),             // Wednesday
            focus(date(27, hour: 23, calendar: c), minutes: 60),   // Sunday before: the week before
            focus(date(5, month: 10, hour: 9, calendar: c), minutes: 25),   // Monday after
        ], in: interval, calendar: c)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.perDay.map { Int($0 / 60) }, [50, 0, 45, 0, 0, 0, 0])
        XCTAssertEqual(week.sessions.count, 3)
        XCTAssertEqual(week.sessions.first?.start, date(30, calendar: c), "newest first")
        XCTAssertEqual(week.total, 95 * 60)
        XCTAssertEqual(week.longest, 45 * 60)
    }

    func testAnEmptyWeekIsAllZero() {
        let c = calendar(firstWeekday: 2)
        let week = FocusWeek.make([], in: FocusWeek.interval(weeksBack: 3, now: date(30, calendar: c), calendar: c), calendar: c)
        XCTAssertEqual(week.perDay, Array(repeating: 0, count: 7))
        XCTAssertEqual(week.total, 0)
        XCTAssertEqual(week.longest, 0)
    }

    func testTheArrowsStopAtTheWeekOfTheFirstSession() {
        let c = calendar(firstWeekday: 2)
        let now = date(30, calendar: c)
        XCTAssertEqual(FocusWeek.weeksBack(of: nil, now: now, calendar: c), 0)
        XCTAssertEqual(FocusWeek.weeksBack(of: date(29, calendar: c), now: now, calendar: c), 0)
        XCTAssertEqual(FocusWeek.weeksBack(of: date(27, hour: 23, calendar: c), now: now, calendar: c), 1)
        XCTAssertEqual(FocusWeek.weeksBack(of: date(1, hour: 9, calendar: c), now: now, calendar: c), 4)
        // Sunday-first: the 27th already belongs to this week.
        let sunday = calendar(firstWeekday: 1)
        XCTAssertEqual(FocusWeek.weeksBack(of: date(27, hour: 23, calendar: sunday), now: now, calendar: sunday), 0)
    }

    func testTheStoreKnowsWhereTheHistoryBegins() throws {
        let store = FocusSessionStore(try AppDatabase.openInMemory())
        XCTAssertNil(try store.earliestStart())
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        try store.start(at: early.addingTimeInterval(86400), plannedSeconds: 60)
        try store.start(at: early, plannedSeconds: 60)
        XCTAssertEqual(try store.earliestStart()?.timeIntervalSince1970 ?? 0, early.timeIntervalSince1970, accuracy: 0.01)
    }
}
