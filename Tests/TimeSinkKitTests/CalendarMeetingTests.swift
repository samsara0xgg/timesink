import XCTest
@testable import TimeSinkKit

final class CalendarMeetingTests: XCTestCase {
    private func ev(_ s: TimeInterval, _ e: TimeInterval, attendees: Int = 2, title: String = "Sync",
                    allDay: Bool = false, declined: Bool = false) -> CalendarEvent {
        CalendarEvent(id: UUID().uuidString, title: title, start: ts(s), end: ts(e),
                      isAllDay: allDay, attendeeCount: attendees, isDeclined: declined,
                      calendarTitle: "工作", colorHex: "#3478F6")
    }
    func testIsMeetingPredicate() {
        XCTAssertTrue(ev(0, 3600).isMeeting)                                   // 2 人
        XCTAssertTrue(ev(0, 3600, attendees: 0, title: "团队组会").isMeeting)   // 关键词
        XCTAssertFalse(ev(0, 3600, attendees: 0, title: "写代码").isMeeting)    // 单人非会议
        XCTAssertFalse(ev(0, 3600, allDay: true).isMeeting)                    // 全天排除
        XCTAssertFalse(ev(0, 3600, declined: true).isMeeting)                  // 已拒绝排除
    }
    func testTaggedRequiresHalfOverlap() {
        let meeting = ev(0, 1800)
        let inside = CategorizedSpan(span: Span(id: 1, start: ts(0), end: ts(1000), appBundleID: "z",
            appName: "zoom", title: nil, url: nil, domain: "zoom.us"), categoryID: "communication")
        let brushing = CategorizedSpan(span: Span(id: 2, start: ts(1700), end: ts(3500), appBundleID: "z",
            appName: "zoom", title: nil, url: nil, domain: "zoom.us"), categoryID: "communication")
        let r = MeetingTagger.tagged(items: [inside, brushing], events: [meeting])
        XCTAssertEqual(r.spanIDs, [1])          // brushing 重叠 100s < 1800s 的 50%
        XCTAssertEqual(r.seconds, 1000)
    }
    func testInMeetingWindow() {
        XCTAssertTrue(MeetingTagger.inMeeting(at: ts(100), events: [ev(0, 600)]))
        XCTAssertFalse(MeetingTagger.inMeeting(at: ts(700), events: [ev(0, 600)]))
        XCTAssertFalse(MeetingTagger.inMeeting(at: ts(100), events: [ev(0, 600, declined: true)]))
    }
}
