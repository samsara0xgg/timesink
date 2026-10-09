import XCTest
@testable import TimeSinkKit

final class DistractionHintTests: XCTestCase {
    func testOrangeOnlyAfterFiveMinutesStraight() {
        var streak = DistractionStreak()
        XCTAssertFalse(streak.observe(distracting: true, now: ts(0)))
        XCTAssertFalse(streak.observe(distracting: true, now: ts(299)))
        XCTAssertTrue(streak.observe(distracting: true, now: ts(300)))
    }

    func testLeavingStartsOver() {
        var streak = DistractionStreak()
        _ = streak.observe(distracting: true, now: ts(0))
        XCTAssertFalse(streak.observe(distracting: false, now: ts(200)))
        XCTAssertFalse(streak.observe(distracting: true, now: ts(201)))
        XCTAssertFalse(streak.observe(distracting: true, now: ts(400)))
        XCTAssertTrue(streak.observe(distracting: true, now: ts(501)))
    }
}
