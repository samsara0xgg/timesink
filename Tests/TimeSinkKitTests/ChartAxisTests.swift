import XCTest
@testable import TimeSinkKit

final class ChartAxisTests: XCTestCase {
    func testHourScaleUsesFourHourStepsWithEightHourFloor() {
        XCTAssertEqual(ChartAxis.hourScale(maxHours: 0).top, 8)
        XCTAssertEqual(ChartAxis.hourScale(maxHours: 6.5).top, 8)
        XCTAssertEqual(ChartAxis.hourScale(maxHours: 9).top, 12)
        XCTAssertEqual(ChartAxis.hourScale(maxHours: 12).top, 12)
        XCTAssertEqual(ChartAxis.hourScale(maxHours: 9).step, 4)
        // Weekly sums widen the step instead of drawing a dozen grid lines.
        XCTAssertEqual(ChartAxis.hourScale(maxHours: 45).step, 12)
        XCTAssertEqual(ChartAxis.hourScale(maxHours: 45).top, 48)
    }

    func testMinuteScaleRoundsToQuarterHoursWithinAnHour() {
        XCTAssertEqual(ChartAxis.minuteScale(maxMinutes: 0).top, 30)
        XCTAssertEqual(ChartAxis.minuteScale(maxMinutes: 31).top, 45)
        XCTAssertEqual(ChartAxis.minuteScale(maxMinutes: 45).top, 45)
        XCTAssertEqual(ChartAxis.minuteScale(maxMinutes: 60).top, 60)
        XCTAssertEqual(ChartAxis.minuteScale(maxMinutes: 60).step, 15)
        let summed = ChartAxis.minuteScale(maxMinutes: 400)
        XCTAssertEqual(summed.step, 120)
        XCTAssertEqual(summed.top, 480)
    }

    func testHourSpanCoversOnlyHoursWithData() {
        XCTAssertEqual(ChartAxis.hourSpan([7, 9, 17]), 7..<18)
        XCTAssertEqual(ChartAxis.hourSpan([10]), 10..<13)
        XCTAssertEqual(ChartAxis.hourSpan([23]), 21..<24)
        XCTAssertNil(ChartAxis.hourSpan([Int]()))
    }

    func testDayLabelsCarryWeekdayAndDateAndTodayWord() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!
        XCTAssertEqual(ChartAxis.dayLabel(thursday, now: now, calendar: calendar, locale: Locale(identifier: "zh_CN")), "四 24")
        XCTAssertEqual(ChartAxis.dayLabel(thursday, now: now, calendar: calendar, locale: Locale(identifier: "en_US")), "T 24")
        XCTAssertEqual(ChartAxis.dayLabel(calendar.startOfDay(for: now), now: now, calendar: calendar), String(localized: "今天"))
    }

    func testLabeledDaysThinsLongRangesButKeepsTheLastDay() {
        let days = (0..<30).map { Date(timeIntervalSince1970: Double($0) * 86400) }
        XCTAssertEqual(ChartAxis.labeledDays(Array(days.prefix(7))).count, 7)
        let thinned = ChartAxis.labeledDays(days)
        XCTAssertLessThanOrEqual(thinned.count, 10)
        XCTAssertEqual(thinned.last, days.last)
    }

    func testMinuteDeltaMatchesDisplayedMinutes() {
        // 6h 36m 50s vs 5h 49m 10s: shown as 6h 36m and 5h 49m, so the delta reads +47m.
        let delta = Format.minuteDelta(6 * 3600 + 36 * 60 + 50, 5 * 3600 + 49 * 60 + 10)
        XCTAssertEqual(delta, 47 * 60)
        XCTAssertEqual(Format.durationDelta(delta), "+47m")
    }
}
