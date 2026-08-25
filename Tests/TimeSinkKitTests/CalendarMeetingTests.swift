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

    // MARK: - Review round 1, IMPORTANT 9: pin the 50% boundary and the
    // seconds/re-check semantics `tagged()` doesn't otherwise have coverage
    // pinning (empirically: shifting the threshold, or dropping the
    // `isMeeting` re-check, or counting overlap instead of full-span
    // duration all still passed every pre-existing test).

    /// Overlap == exactly 50% of the span's own duration must count -- the
    /// predicate is `>=`, not `>`.
    func testTaggedExactlyHalfOverlapCounts() {
        let meeting = ev(0, 500)
        let span = CategorizedSpan(span: Span(id: 4, start: ts(0), end: ts(1000), appBundleID: "z",
            appName: "zoom", title: nil, url: nil, domain: "zoom.us"), categoryID: "communication")
        let r = MeetingTagger.tagged(items: [span], events: [meeting])
        XCTAssertEqual(r.spanIDs, [4])   // 重叠 500s == 1000s 的 50%，>= 计入
        XCTAssertEqual(r.seconds, 1000)
    }

    /// One second under 50% must NOT count -- pins the boundary from the
    /// other side.
    func testTaggedJustUnderHalfOverlapExcludes() {
        let meeting = ev(0, 499)
        let span = CategorizedSpan(span: Span(id: 5, start: ts(0), end: ts(1000), appBundleID: "z",
            appName: "zoom", title: nil, url: nil, domain: "zoom.us"), categoryID: "communication")
        let r = MeetingTagger.tagged(items: [span], events: [meeting])
        XCTAssertEqual(r.spanIDs, [])
        XCTAssertEqual(r.seconds, 0)
    }

    /// `tagged()` must re-check `isMeeting` on the events it's handed, not
    /// trust the caller -- `recompute` feeds it the raw fetched event list,
    /// which includes declined/all-day events with >= 2 attendees. Without
    /// the internal `.filter(\.isMeeting)`, both would wrongly tag a fully
    /// overlapping span.
    func testTaggedIgnoresDeclinedAndAllDayEventsInRawList() {
        let declinedMeeting = ev(0, 1000, declined: true)   // 2 人，但已拒绝
        let allDayMeeting = ev(0, 1000, allDay: true)       // 2 人，但全天
        let span = CategorizedSpan(span: Span(id: 6, start: ts(0), end: ts(1000), appBundleID: "z",
            appName: "zoom", title: nil, url: nil, domain: "zoom.us"), categoryID: "communication")
        let r = MeetingTagger.tagged(items: [span], events: [declinedMeeting, allDayMeeting])
        XCTAssertEqual(r.spanIDs, [])
        XCTAssertEqual(r.seconds, 0)
    }

    /// A span only PARTIALLY inside a qualifying meeting (overlap between
    /// 50% and 100% of its duration, not full containment) still counts its
    /// FULL duration toward `seconds`, not just the overlapping portion --
    /// current, brief-faithful semantics ("命中即整段计入"), pinned here so
    /// it isn't silently narrowed to overlap-only later.
    func testTaggedSecondsCountsFullSpanDurationNotJustOverlap() {
        let meeting = ev(0, 1400)
        let span = CategorizedSpan(span: Span(id: 7, start: ts(600), end: ts(1800), appBundleID: "z",
            appName: "zoom", title: nil, url: nil, domain: "zoom.us"), categoryID: "communication")
        let r = MeetingTagger.tagged(items: [span], events: [meeting])
        XCTAssertEqual(r.spanIDs, [7])
        // 重叠 800s（区间 [600,1400)，>= 1200s 的 50%）即计入整段 1200s，
        // 而非仅重叠部分。
        XCTAssertEqual(r.seconds, 1200)
    }
}
