import XCTest
@testable import TimeSinkKit

final class UIDataIntegrityTests: XCTestCase {
    @MainActor
    func testDistributionPreservesAllTwelveItemsAndTotal() {
        let rows = (1...12).map {
            StatsModel.RankingRow(id: "\($0)", name: "App \($0)", colorHex: "#123456", seconds: Double($0 * 60))
        }
        let display = StatsModel.distributionRows(rows)
        XCTAssertEqual(display.count, 11)
        XCTAssertEqual(display.map(\.seconds).reduce(0, +), 4680)
        XCTAssertEqual(display.last?.seconds, 180)
        XCTAssertEqual(display.last?.name, "其余（2 项）")
        XCTAssertEqual(Set(display.map(\.id)).count, 11)
        XCTAssertEqual(StatsModel.distributionRows(Array(rows.prefix(10))).count, 10)
        XCTAssertTrue(StatsModel.distributionRows([]).isEmpty)
    }

    func testTimelinePreservesAppAndTitleWithinSameCategory() {
        let items = [
            item(start: 0, end: 600, app: "editor", title: "A"),
            item(start: 600, end: 1200, app: "browser", title: "A"),
            item(start: 1200, end: 1800, app: "browser", title: "B")
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: [:])
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.map { $0.activity?.rowID }, ["editor", "browser", "browser"])
        XCTAssertEqual(blocks.map { $0.activity?.title }, ["A", "A", "B"])
        XCTAssertEqual(blocks.map(\.id), ActivitiesModel.timelineBlocks(items, categories: [:]).map(\.id))
    }

    func testAppendingSameActivityKeepsIdentityButIdleGapIsNotPainted() {
        let first = item(start: 0, end: 600, app: "editor", title: "A")
        let blocks = ActivitiesModel.timelineBlocks([
            first, item(start: 600, end: 900, app: "editor", title: "A"),
            item(start: 920, end: 1200, app: "editor", title: "A")
        ], categories: [:])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].duration, 900)
        XCTAssertEqual(blocks[0].id, ActivitiesModel.timelineBlocks([first], categories: [:])[0].id)
    }

    func testFilterDoesNotHighlightOtherURLWithSameTitle() {
        let first = item(start: 0, end: 600, app: "browser", title: "Docs", url: "https://example.com/one")
        let second = item(start: 600, end: 1200, app: "browser", title: "Docs", url: "https://example.com/two")
        let blocks = ActivitiesModel.timelineBlocks([first, second], categories: [:]) {
            ActivitiesModel.matches($0, query: "/one")
        }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.matchesFilter), [true, false])
    }

    func testDocumentAndEntitySelectionsMatchListKeys() {
        var document = item(start: 0, end: 60, app: "editor", title: "Readme")
        document.span.document = "/work/repo"
        let browser = CategorizedSpan(span: Span(
            start: date(0), end: date(60), appBundleID: "chrome", appName: "Chrome", title: "PR",
            url: "https://github.com/acme/project/pull/1", domain: "github.com"), categoryID: "work")
        for entry in [document, browser] {
            let selection = ActivitiesModel.selection(for: entry)
            XCTAssertEqual(selection.rowID, ActivitiesModel.rows(for: [entry])[0].id)
            XCTAssertTrue(selection.row.matches(selection))
        }
    }

    func testInitialScrollUsesRelevantDayAndRecord() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: date(0))
        let first = today.addingTimeInterval(14 * 3600)
        let latest = today.addingTimeInterval(17 * 3600)
        XCTAssertEqual(TimelineNavigation.initialDate(day: today, starts: [first, latest],
                       now: today.addingTimeInterval(18 * 3600), calendar: calendar), latest)
        XCTAssertEqual(TimelineNavigation.initialDate(day: today, starts: [latest, first],
                       now: today.addingTimeInterval(2 * 86400), calendar: calendar), first)
    }

    func testHourAnchorsHandleDSTWithoutLosingRepeatedHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        let spring = calendar.date(from: DateComponents(year: 2025, month: 3, day: 9))!
        let fall = calendar.date(from: DateComponents(year: 2025, month: 11, day: 2))!
        XCTAssertEqual(TimelineNavigation.hourAnchors(day: spring, calendar: calendar).count, 23)
        let repeated = TimelineNavigation.hourAnchors(day: fall, calendar: calendar)
        XCTAssertEqual(repeated.count, 25)
        XCTAssertEqual(Set(repeated).count, 25)
    }

    @MainActor
    func testHourlyChartUsesAbsoluteStackBoundsAndOmitsZeroMarks() {
        let bars = [
            HourlyBigView.Bar(hour: 14, categoryID: "a", colorHex: "#000000", seconds: 1200),
            HourlyBigView.Bar(hour: 14, categoryID: "b", colorHex: "#000000", seconds: 1800),
            HourlyBigView.Bar(hour: 15, categoryID: "a", colorHex: "#000000", seconds: 600),
            HourlyBigView.Bar(hour: 16, categoryID: "a", colorHex: "#000000", seconds: 0)
        ]
        let segments = HourlyActivityChart.segments(for: bars)
        XCTAssertEqual(segments.map(\.startMinutes), [0, 20, 0])
        XCTAssertEqual(segments.map(\.endMinutes), [20, 50, 10])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.endMinutes - $1.startMinutes }, 60)
    }

    @MainActor
    func testSelectingIntervalRevealsItsListRowAndHonorsFilter() {
        let activities = ActivitiesModel()
        let first = item(start: 0, end: 60, app: "editor", title: "A")
        let second = item(start: 120, end: 180, app: "editor", title: "A")
        activities.timelineBlocks = ActivitiesModel.timelineBlocks([first, second], categories: [:])
        let selection = ActivitiesModel.selection(for: first)
        activities.collapsedCategories.insert("work")
        activities.select(selection, start: second.span.start)
        XCTAssertEqual(activities.selectedStart, second.span.start)
        XCTAssertTrue(activities.expandedRows.contains(selection.row))
        XCTAssertFalse(activities.collapsedCategories.contains("work"))
        activities.timelineBlocks[0].matchesFilter = false
        activities.select(selection.row)
        XCTAssertEqual(activities.selectedStart, second.span.start)
    }

    private func date(_ offset: Double) -> Date { Date(timeIntervalSince1970: 1_777_593_600 + offset) }

    private func item(start: Double, end: Double, app: String, title: String, url: String? = nil) -> CategorizedSpan {
        CategorizedSpan(span: Span(start: date(start), end: date(end), appBundleID: app, appName: app,
                                  title: title, url: url, domain: url == nil ? nil : "example.com"), categoryID: "work")
    }
}
