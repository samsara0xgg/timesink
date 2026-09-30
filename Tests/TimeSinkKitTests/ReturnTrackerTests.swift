import XCTest
@testable import TimeSinkKit

final class ReturnTrackerTests: XCTestCase {
    private func span(_ app: String, from start: Double, keys: Int = 0) -> Span {
        Span(start: ts(start), end: ts(start + 1), appBundleID: app, appName: app, title: app + " doc", url: nil, domain: nil, keySeconds: keys)
    }

    private func run(_ steps: [(Span?, Int, Bool, Double)], focusing: Bool = false) -> ReturnTracker {
        var tracker = ReturnTracker()
        for (current, productivity, distracting, now) in steps {
            tracker.observe(current: current, productivity: productivity, distracting: distracting, now: ts(now),
                            rule: InterruptionRule(), focusing: focusing)
        }
        return tracker
    }

    func testStayingPastTheThresholdOffersTheWindowLeft() {
        let chat = span("chat", from: 60)
        let tracker = run([(span("xcode", from: 0), 2, false, 59), (chat, -1, true, 61), (chat, -1, true, 76)])
        XCTAssertEqual(tracker.offer?.bundleID, "xcode")
        XCTAssertEqual(tracker.offer?.title, "xcode doc")
    }

    func testAPeekNeverOffers() {
        let tracker = run([(span("xcode", from: 0), 2, false, 59), (span("chat", from: 60), -1, true, 70),
                           (span("xcode", from: 71), 2, false, 72)])
        XCTAssertNil(tracker.offer)
    }

    func testTypingOffersAtOnce() {
        let tracker = run([(span("xcode", from: 0), 2, false, 59), (span("chat", from: 60, keys: 2), -1, true, 63)])
        XCTAssertEqual(tracker.offer?.bundleID, "xcode")
    }

    func testGoingBackOrTwoMinutesOrFocusClearsIt() {
        let chat = span("chat", from: 60)
        let base: [(Span?, Int, Bool, Double)] = [(span("xcode", from: 0), 2, false, 59), (chat, -1, true, 80)]
        XCTAssertNil(run(base + [(span("xcode", from: 90), 2, false, 90)]).offer)
        XCTAssertNil(run(base + [(chat, -1, true, 80 + ReturnTracker.offerLifetime)]).offer)
        XCTAssertNil(run(base, focusing: true).offer)
    }

    func testAwayTimeForgetsTheOrigin() {
        let tracker = run([(span("xcode", from: 0), 2, false, 59), (nil, 0, false, 600), (span("chat", from: 601), -1, true, 700)])
        XCTAssertNil(tracker.offer)
    }
}
