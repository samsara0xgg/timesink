import XCTest
@testable import TimeSinkKit

final class DateRangeTests: XCTestCase {
    func testDayInterval() {
        var sel = DateRangeSelection.today()
        let cal = Calendar.current
        XCTAssertEqual(sel.interval.start, cal.startOfDay(for: Date()))
        XCTAssertEqual(sel.interval.duration, 86400, accuracy: 3700)  // 容忍 DST
        sel.shift(-1)
        XCTAssertEqual(sel.label, "昨天")
        sel.shift(1)
        XCTAssertEqual(sel.label, "今天")
        sel.shift(1)   // 不进未来
        XCTAssertEqual(sel.label, "今天")
    }
    func testLast7Covers7Days() {
        var sel = DateRangeSelection.today()
        sel.kind = .last7
        let days = sel.interval.duration / 86400
        XCTAssertEqual(days, 7, accuracy: 0.1)
    }
}
