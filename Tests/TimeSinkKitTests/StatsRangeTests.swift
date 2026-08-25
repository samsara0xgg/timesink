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

    // MARK: - Fix round 1 (review findings)

    /// CRITICAL 1: `customStart`/`customEnd` are independently settable (the
    /// popover's two DatePickers, or any other caller) and `DateInterval`
    /// fatalErrors on end < start. A reversed pair must normalize instead of
    /// crashing `.interval`.
    func testCustomRangeReversedIsNormalized() {
        var sel = DateRangeSelection(kind: .custom, anchor: date(2026, 8, 10))
        sel.customStart = date(2026, 8, 16)
        sel.customEnd = date(2026, 8, 10)
        let iv = sel.interval
        let cal = Calendar.current
        XCTAssertLessThan(iv.start, iv.end)
        XCTAssertEqual(cal.startOfDay(for: iv.start), cal.startOfDay(for: date(2026, 8, 10)))
        XCTAssertEqual(cal.startOfDay(for: iv.end), cal.startOfDay(for: date(2026, 8, 17)))
    }

    /// CRITICAL 1, second trap path: `customStart` set past `anchor` with
    /// `customEnd` left `nil` (so `customEnd ?? anchor` resolves behind
    /// `customStart`) must also normalize rather than crash.
    func testCustomRangeStartAfterAnchorWithNilEndIsNormalized() {
        var sel = DateRangeSelection(kind: .custom, anchor: date(2026, 8, 10))
        sel.customStart = date(2026, 8, 20)
        let iv = sel.interval
        let cal = Calendar.current
        XCTAssertLessThan(iv.start, iv.end)
        XCTAssertEqual(cal.startOfDay(for: iv.start), cal.startOfDay(for: date(2026, 8, 10)))
        XCTAssertEqual(cal.startOfDay(for: iv.end), cal.startOfDay(for: date(2026, 8, 21)))
    }

    /// IMPORTANT 2 (ruling R-T7a): 2026-03-08 is the US DST "spring forward"
    /// day (2am -> 3am), so this calendar day is only 23 wall-clock hours
    /// long -- `previousInterval` must still land on a calendar-day
    /// boundary, not slip by the missing hour. Meaningful only on a
    /// DST-observing machine timezone (this repo's dev/CI machines are US
    /// Pacific, so this holds); on a non-DST TZ the day is a plain 86400s
    /// and the assertion holds trivially either way.
    func testPreviousIntervalDayAlignedAcrossSpringForwardDST() {
        let sel = DateRangeSelection(kind: .day, anchor: date(2026, 3, 8))
        let cal = Calendar.current
        XCTAssertEqual(cal.startOfDay(for: sel.previousInterval.start), sel.previousInterval.start)
    }

    /// IMPORTANT 2 (ruling R-T7a): 2026-11-01 is the US DST "fall back" day
    /// (2am -> 1am); anchoring `.last7` a few days after it makes the
    /// current 7-day window span that 25-hour day, so its own duration is
    /// inflated by an hour. `previousInterval` must still land on a
    /// calendar-day boundary. Same DST-observing-TZ caveat as above.
    func testPreviousIntervalLast7DayAlignedAcrossFallBackDST() {
        let sel = DateRangeSelection(kind: .last7, anchor: date(2026, 11, 4))
        let cal = Calendar.current
        XCTAssertEqual(cal.startOfDay(for: sel.previousInterval.start), sel.previousInterval.start)
    }

    /// FOLD-IN 5: `containsNow`/`contains(_:)` must be half-open
    /// (`[start, end)`), not `DateInterval.contains(_:)`'s closed-both-ends
    /// semantics -- otherwise two adjacent day selections both report
    /// `true` exactly at midnight.
    func testContainsIsHalfOpenAtIntervalEnd() {
        let sel = DateRangeSelection(kind: .day, anchor: date(2026, 8, 10))
        let iv = sel.interval
        XCTAssertTrue(sel.contains(iv.start))
        XCTAssertTrue(sel.contains(iv.end.addingTimeInterval(-1)))
        XCTAssertFalse(sel.contains(iv.end))
    }
}
