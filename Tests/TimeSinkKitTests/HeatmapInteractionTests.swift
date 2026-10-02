import XCTest
@testable import TimeSinkKit

final class HeatmapInteractionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var categories: [String: TimeSinkKit.Category] {
        Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
    }
    private func date(_ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2025, month: 1, day: day, hour: hour, minute: minute))!
    }
    private func item(_ start: Date, _ end: Date, category: String = "softwareDev", app: String = "editor") -> CategorizedSpan {
        CategorizedSpan(span: Span(start: start, end: end, appBundleID: app, appName: app,
                                  title: "Example", url: nil, domain: nil), categoryID: category)
    }

    func testWeightedScoreCoverageAndAverageIncludeUnrecordedDays() {
        let window = DateInterval(start: date(6), end: date(34))
        let data = HeatmapData.build([
            item(date(6, hour: 14), date(6, hour: 14, minute: 30)),
            item(date(13, hour: 14), date(13, hour: 14, minute: 10), category: "entertainment", app: "player")
        ], categories: categories, window: window, now: window.end, calendar: calendar)
        let cell = data[.init(weekday: 0, hour: 14)]
        XCTAssertEqual(cell.seconds, 2400)
        XCTAssertEqual(cell.pulse, 75) // Duration-weighted, not the average of 100 and 0.
        XCTAssertEqual(cell.availableDays, 4)
        XCTAssertEqual(cell.recordedDays, 2)
        XCTAssertEqual(cell.averageSeconds, 600)
        XCTAssertEqual(cell.categories.first?.name, "编程开发")
        XCTAssertEqual(cell.apps.first?.name, "editor")
        XCTAssertEqual(cell.days.reduce(0) { $0 + $1.seconds }, cell.seconds)
    }

    func testWindowAndHourBoundariesConserveDuration() {
        let window = DateInterval(start: date(6, hour: 23, minute: 30), end: date(7, hour: 0, minute: 30))
        let data = HeatmapData.build([item(date(6, hour: 23), date(7, hour: 1))],
                                    categories: categories, window: window, now: window.end, calendar: calendar)
        XCTAssertEqual(data.cells.reduce(0) { $0 + $1.seconds }, 3600)
        XCTAssertEqual(data[.init(weekday: 0, hour: 23)].seconds, 1800)
        XCTAssertEqual(data[.init(weekday: 1, hour: 0)].days.first?.interval.end, window.end)
    }

    func testFutureHoursDoNotCountAgainstCoverageAndLowSampleIsNotZero() {
        let window = DateInterval(start: date(6), end: date(7))
        let data = HeatmapData.build([item(date(6, hour: 14), date(6, hour: 15))],
                                    categories: categories, window: window, now: date(6, hour: 14, minute: 5), calendar: calendar)
        let cell = data[.init(weekday: 0, hour: 14)]
        XCTAssertEqual(cell.seconds, 300)
        XCTAssertEqual(cell.availableDays, 1)
        XCTAssertTrue(cell.isLowSample)
        XCTAssertEqual(cell.scoreLabel, "样本不足")
        let future = data[.init(weekday: 0, hour: 15)]
        XCTAssertEqual(future.availableDays, 0)
        XCTAssertEqual(future.scoreLabel, "无记录")
        XCTAssertNil(future.pulse)
    }

    func testRepeatedDSTHourKeepsTwoDistinctNavigationIntervals() {
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = pacific.date(from: DateComponents(year: 2025, month: 11, day: 2))!
        let window = pacific.dateInterval(of: .day, for: start)!
        let data = HeatmapData.build([item(start.addingTimeInterval(3600), start.addingTimeInterval(3 * 3600))],
                                    categories: categories, window: window, now: window.end, calendar: pacific)
        let cell = data[.init(weekday: 6, hour: 1)]
        XCTAssertEqual(cell.days.count, 2)
        XCTAssertEqual(Set(cell.days.map(\.id)).count, 2)
        XCTAssertEqual(cell.availableDays, 1)
        XCTAssertEqual(cell.recordedDays, 1)
        XCTAssertEqual(cell.seconds, 7200)
        XCTAssertEqual(cell.days[1].interval.end, cell.days[0].interval.start)
    }

    func testKeyboardSelectionBoundariesPinAndHoverIndependence() {
        let first = HeatmapData.Key(weekday: 0, hour: 0)
        var interaction = HeatmapInteraction()
        interaction.move(horizontal: -1, fallback: first)
        interaction.move(vertical: -1, fallback: first)
        XCTAssertEqual(interaction.cursor, first)
        interaction.select(first)
        interaction.hovered = .init(weekday: 5, hour: 20)
        XCTAssertEqual(interaction.preview(fallback: first), first)
        interaction.move(horizontal: 1, fallback: first)
        XCTAssertEqual(interaction.pinned, .init(weekday: 0, hour: 1))
        interaction.dismiss()
        XCTAssertNil(interaction.pinned)
        XCTAssertNil(interaction.hovered)
        XCTAssertEqual(interaction.cursor, .init(weekday: 0, hour: 1))
    }

    @MainActor
    func testDateDrillDownClipsListAndTimelineAndRestoresOrigin() throws {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let local = Calendar.current
        let day = local.startOfDay(for: date(6, hour: 12))
        let hour = day.addingTimeInterval(14 * 3600)
        try categoryStore.setUserApp("editor", categoryID: "softwareDev")
        _ = try spans.insert(item(hour.addingTimeInterval(-1800), hour.addingTimeInterval(5400)).span)
        let settings = SettingsStore(db)
        let model = AppModel(categoryStore: categoryStore, spanStore: spans, settings: settings,
                             resolver: CategoryResolver(categoryStore: categoryStore),
                             engine: TrackerEngine(spanStore: spans, settings: settings))
        let original = DateRangeSelection(kind: .week, anchor: day)
        model.range = original
        model.activityFilter = "entertainment"
        model.activitySearch = "no match"
        let interval = DateInterval(start: hour, duration: 3600)
        model.openHeatmapActivities(in: interval)
        XCTAssertEqual(model.sidebarSelection, .activities)
        XCTAssertNil(model.activityFilter)
        XCTAssertTrue(model.activitySearch.isEmpty)
        let activities = ActivitiesModel()
        activities.recompute(model: model)
        XCTAssertEqual(activities.groups.reduce(0) { $0 + $1.seconds }, 3600)
        XCTAssertEqual(activities.matchSeconds, 3600)
        // The whole day stays as a dimmed base; the hour is a highlight over it.
        XCTAssertEqual(activities.timelineBlocks.map(\.matchesFilter), [false, true])
        XCTAssertEqual(activities.timelineBlocks.map(\.isHighlight), [false, true])
        XCTAssertEqual(activities.timelineBlocks.map(\.duration), [7200, 3600])
        XCTAssertEqual(activities.timelineBlocks.last?.start, hour)
        XCTAssertEqual(activities.selectedStart, hour)
        model.returnToHeatmap()
        XCTAssertEqual(model.range, original)
        XCTAssertEqual(model.sidebarSelection, .stats)
        XCTAssertNil(model.activityTimeInterval)
    }

    @MainActor
    func testChangingDayAndNormalNavigationClearHourFilter() throws {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db)
        let categories = CategoryStore(db)
        let settings = SettingsStore(db)
        let model = AppModel(categoryStore: categories, spanStore: spans, settings: settings,
                             resolver: CategoryResolver(categoryStore: categories),
                             engine: TrackerEngine(spanStore: spans, settings: settings))
        let interval = DateInterval(start: date(6, hour: 14), duration: 3600)
        model.openHeatmapActivities(in: interval)
        model.range.shift(-1)
        XCTAssertNil(model.activityTimeInterval)
        XCTAssertNil(model.heatmapReturnRange)
        model.openHeatmapActivities(in: interval)
        model.openActivities(category: "softwareDev", range: model.range)
        XCTAssertNil(model.activityTimeInterval)
    }
}
