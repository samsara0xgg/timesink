import XCTest
@testable import TimeSinkKit

final class InterruptionRoseTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func episode(hour: Int, minute: Int = 0, app: String, reason: SwitchEpisode.Reason = .stayed, dwell: TimeInterval = 60) -> SwitchEpisode {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: hour, minute: minute))!
        return SwitchEpisode(start: start, end: start.addingTimeInterval(dwell), dwell: dwell, keySeconds: 0, destination: app, destinationLabel: app,
                             destinationBundleID: app, destinationDomain: nil, destinationCategoryID: "social", originCategoryID: "softwareDev",
                             kind: .interruption, reason: reason, visits: 1, returned: true)
    }

    func testCountsAreByHourAndByApp() {
        let data = DayInterruptions(episodes: [
            episode(hour: 11, app: "wechat"), episode(hour: 11, minute: 20, app: "wechat"), episode(hour: 11, minute: 40, app: "discord"),
            episode(hour: 14, app: "discord"), episode(hour: 15, app: "wechat"),
        ])
        let rose = InterruptionRose(data: data, calendar: calendar)
        XCTAssertEqual(rose.total, 5)
        XCTAssertEqual(rose.hourTotals[11], 3)
        XCTAssertEqual(rose.hourTotals[14], 1)
        XCTAssertEqual(rose.sourceIDs, ["wechat", "discord"])
        XCTAssertEqual(rose.counts[11][0], 2)
        XCTAssertEqual(rose.counts[11][1], 1)
        XCTAssertEqual(rose.top(inHour: 11)?.label, "wechat")
        XCTAssertNil(rose.top(inHour: 3))
    }

    func testAppsPastTheFifthShareOneColumn() {
        let apps = (0..<7).map { "app\($0)" }
        // app0 six times down to app6 once, so the order is by count.
        let episodes = apps.enumerated().flatMap { index, app in (0..<(7 - index)).map { _ in episode(hour: 9, app: app) } }
        let rose = InterruptionRose(data: DayInterruptions(episodes: episodes), calendar: calendar)
        XCTAssertEqual(rose.sourceIDs.count, InterruptionRose.maxSources)
        XCTAssertEqual(rose.counts[9][InterruptionRose.maxSources], 2 + 1)
        XCTAssertEqual(rose.total, rose.hourTotals.reduce(0, +))
    }

    func testDotsStackFromTheCentreByAppThenTime() {
        let data = DayInterruptions(episodes: [
            episode(hour: 10, minute: 30, app: "a", reason: .typed, dwell: 120), episode(hour: 10, minute: 5, app: "a"),
            episode(hour: 10, minute: 15, app: "b"),
        ])
        let dots = InterruptionRose(data: data, calendar: calendar).dots.filter { $0.hour == 10 }
        XCTAssertEqual(dots.map(\.slot).sorted(), [0, 1, 2])
        // The leading app's earlier one is the innermost unit; the other app starts after both.
        XCTAssertEqual(dots.first { $0.fraction == 5.0 / 60 }?.slot, 0)
        XCTAssertEqual(dots.first { $0.source == 1 }?.slot, 2)
        XCTAssertEqual(dots.first { $0.typed }?.dwell, 120)
    }

    func testNiceMaxKeepsTheHalfWhole() {
        XCTAssertEqual(InterruptionRose.niceMax(0), 2)
        XCTAssertEqual(InterruptionRose.niceMax(9), 10)
        XCTAssertEqual(InterruptionRose.niceMax(11), 12)
        XCTAssertEqual(InterruptionRose.niceMax(1500), 1500)
        for value in 0...200 { XCTAssertEqual(InterruptionRose.niceMax(value) % 2, 0) }
    }

    func testNoonIsUpAndMidnightIsDown() {
        let center = CGPoint(x: 100, y: 100)
        func hour(_ dx: CGFloat, _ dy: CGFloat) -> Int? {
            InterruptionRose.hour(at: CGPoint(x: center.x + dx, y: center.y + dy), center: center, inner: 30, outer: 90)
        }
        XCTAssertEqual(hour(3, -60), 12)       // just right of straight up: the noon hour
        XCTAssertEqual(hour(-3, -60), 11)      // just left of it: 11 to 12
        XCTAssertEqual(hour(60, 3), 18)        // right: 18
        XCTAssertEqual(hour(3, 60), 23)        // the hours run clockwise: 23 ends at the bottom...
        XCTAssertEqual(hour(-3, 60), 0)        // ...and midnight's hour starts there
        XCTAssertEqual(hour(-60, -3), 6)       // left is 6 o'clock; just above it is 6 to 7
        XCTAssertEqual(hour(-60, 3), 5)        // and just below it is the hour before
        XCTAssertNil(hour(5, 5))               // over the centre disc
        XCTAssertNil(hour(0, -95))             // outside the rim
    }

    func testRestrictingToAnHour() {
        let data = DayInterruptions(episodes: [episode(hour: 11, app: "a"), episode(hour: 12, app: "a")],
                                    blocked: [calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 11, minute: 5))!])
        let only = data.restricted(toHour: 11, calendar: calendar)
        XCTAssertEqual(only.episodes.count, 1)
        XCTAssertEqual(only.blocked.count, 1)
        XCTAssertEqual(data.restricted(toHour: 12, calendar: calendar).blocked.count, 0)
    }
}
