import XCTest
@testable import TimeSinkKit

final class StatsRangeTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    func testWeekAlignsMonday() {
        let sel = DateRangeSelection(kind: .week, anchor: date(2026, 8, 27))  // 周四
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.weekday, from: sel.interval.start), 2)  // 周一
        XCTAssertEqual(cal.startOfDay(for: sel.interval.start), cal.startOfDay(for: date(2026, 8, 24)))
        XCTAssertEqual(sel.interval.duration, 7 * 86400, accuracy: 3700)      // 容 DST
    }
    func testMonthInterval() {
        let sel = DateRangeSelection(kind: .month, anchor: date(2026, 8, 15))
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.day, from: sel.interval.start), 1)
        XCTAssertEqual(cal.component(.month, from: sel.interval.start), 8)
    }
    func testMonthShiftLandsPreviousMonth() {
        var sel = DateRangeSelection(kind: .month, anchor: date(2026, 8, 31))
        sel.shift(-1)  // 8/31 回退一个月：日历分量步进，不是 -31 天
        XCTAssertEqual(Calendar.current.component(.month, from: sel.anchor), 7)
    }
    func testShiftNeverPassesToday() {
        var sel = DateRangeSelection(kind: .week, anchor: Date())
        sel.shift(1)
        XCTAssertLessThanOrEqual(Calendar.current.startOfDay(for: sel.anchor),
                                 Calendar.current.startOfDay(for: Date()))
    }
    func testCustomSingleDay() {
        var sel = DateRangeSelection(kind: .custom, anchor: date(2026, 8, 10))
        sel.customStart = date(2026, 8, 10); sel.customEnd = date(2026, 8, 10)
        XCTAssertEqual(sel.interval.duration, 86400, accuracy: 3700)
    }
    func testPreviousIntervalWeekIsPreviousCalendarWeek() {
        let sel = DateRangeSelection(kind: .week, anchor: date(2026, 8, 27))
        XCTAssertEqual(sel.previousInterval.end, sel.interval.start)
        XCTAssertEqual(sel.previousInterval.duration, sel.interval.duration, accuracy: 3700)
    }
    func testPreviousIntervalLast7IsEqualLengthPreceding() {
        let sel = DateRangeSelection(kind: .last7, anchor: date(2026, 8, 24))
        XCTAssertEqual(sel.previousInterval.end, sel.interval.start)
        XCTAssertEqual(sel.previousInterval.duration, sel.interval.duration)
    }
    func testLabelForNewKinds() {
        XCTAssertEqual(DateRangeSelection(kind: .week, anchor: Date()).label, "本周")
        XCTAssertEqual(DateRangeSelection(kind: .month, anchor: Date()).label, "本月")
    }
}
