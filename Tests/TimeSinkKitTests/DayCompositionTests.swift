import XCTest
@testable import TimeSinkKit

/// 构成: what each five-minute slot of a day was made of.
final class DayCompositionTests: XCTestCase {
    private let day = DateInterval(start: Date(timeIntervalSince1970: 20_000 * 86400), duration: 86400)
    private func at(_ minutes: Double) -> Date { day.start.addingTimeInterval(minutes * 60) }
    private func item(_ from: Double, _ to: Double, title: String = "a", category: String = "work") -> CategorizedSpan {
        CategorizedSpan(span: Span(start: at(from), end: at(to), appBundleID: "com.test", appName: "Test", title: title, url: nil, domain: nil), categoryID: category)
    }
    private func make(_ items: [CategorizedSpan], assigned: [(interval: DateInterval, project: String)] = [],
                      verdicts: [String: String] = [:]) -> DayComposition {
        DayComposition.make(items: items, day: day, assigned: assigned) { verdicts[$0.title ?? ""] }
    }

    func testSharesOfEachRecordedSlotSumToOne() {
        let composition = make([item(0, 3, title: "a"), item(3, 5, title: "b"), item(5, 10, title: "c")],
                               verdicts: ["a": "Aurora", "b": "Atlas", "c": "Aurora"])
        for slot in composition.slots where slot.total > 0 {
            XCTAssertEqual(slot.project.values.reduce(0, +), slot.total, accuracy: 0.001)
            XCTAssertEqual(slot.category.values.reduce(0, +), slot.total, accuracy: 0.001)
        }
        XCTAssertEqual(composition.slots[0].project["Aurora"] ?? 0, 180, accuracy: 0.001)
        XCTAssertEqual(composition.slots[0].project["Atlas"] ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(composition.slots[1].project["Aurora"] ?? 0, 300, accuracy: 0.001)
    }

    func testAwayGapsLeaveEmptySlots() {
        let composition = make([item(0, 5), item(20, 25)])
        XCTAssertEqual(composition.slots.map(\.total).prefix(6).map { $0 > 0 }, [true, false, false, false, true, false])
        XCTAssertEqual(composition.slots.reduce(0) { $0 + $1.total }, 600, accuracy: 0.001)
    }

    func testSessionAssignmentWinsOverJev() {
        let session = DateInterval(start: at(0), end: at(10))
        let composition = make([item(0, 10, title: "a"), item(10, 15, title: "a")], assigned: [(session, "Mine")], verdicts: ["a": "Aurora"])
        XCTAssertEqual(composition.slots[0].project, ["Mine": 300])
        XCTAssertEqual(composition.slots[1].project, ["Mine": 300])
        XCTAssertEqual(composition.slots[2].project, ["Aurora": 300], "outside the assigned session Jev still decides")
    }

    func testNoVerdictIsNoProject() {
        let composition = make([item(0, 5, title: "x")])
        XCTAssertEqual(composition.slots[0].project, [DayComposition.noProject: 300])
        XCTAssertEqual(composition.projectTotals.map(\.id), [DayComposition.noProject])
    }

    func testSpanCrossingASlotEdgeIsSplit() {
        let composition = make([item(3, 8, category: "work")])
        XCTAssertEqual(composition.slots[0].category["work"] ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(composition.slots[1].category["work"] ?? 0, 180, accuracy: 0.001)
    }

    func testTotalsListMostTimeFirstAndNoProjectLast() {
        let composition = make([item(0, 10, title: "x"), item(10, 15, title: "a"), item(15, 20, title: "b"), item(20, 40, title: "b")],
                               verdicts: ["a": "Aurora", "b": "Atlas"])
        XCTAssertEqual(composition.projectTotals.map(\.id), ["Atlas", "Aurora", DayComposition.noProject])
    }
}
