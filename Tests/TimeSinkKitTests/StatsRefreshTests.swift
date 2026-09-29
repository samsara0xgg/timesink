import XCTest
@testable import TimeSinkKit

@MainActor
final class StatsRefreshTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let categories = CategoryStore(db)
        try categories.setUserApp("editor", categoryID: "softwareDev")
        let settings = SettingsStore(db)
        let model = AppModel(categoryStore: categories, spanStore: store, settings: settings,
                             resolver: CategoryResolver(categoryStore: categories),
                             engine: TrackerEngine(spanStore: store, settings: settings))
        // Yesterday is wholly elapsed even when this test runs just after midnight.
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        model.range = DateRangeSelection(kind: .day, anchor: day)
        let start = model.range.interval.start.addingTimeInterval(12 * 3600)
        try store.insert(Span(start: start, end: start.addingTimeInterval(1800), appBundleID: "editor",
                              appName: "Editor", title: nil, url: nil, domain: nil))
        return model
    }

    func testReturningReusesSnapshotAndEngineWritesRefreshOnlySummary() async throws {
        let model = try makeModel()
        let stats = StatsModel()
        await stats.recompute(model: model)
        let update = try XCTUnwrap(stats.lastHeavyUpdate)
        XCTAssertEqual(stats.total, 1800)
        await stats.recompute(model: model)
        XCTAssertEqual(stats.lastHeavyUpdate, update)
        let start = model.range.interval.start.addingTimeInterval(13 * 3600)
        try model.spanStore.insert(Span(start: start, end: start.addingTimeInterval(600), appBundleID: "editor",
                                        appName: "Editor", title: nil, url: nil, domain: nil))
        model.engineDataChangedForTesting()
        await stats.recompute(model: model)
        XCTAssertEqual(stats.total, 2400)
        let sidebar = try await stats.sidebarRows(model: model)
        XCTAssertEqual(sidebar.reduce(0) { $0 + $1.seconds }, 2400)
        XCTAssertEqual(stats.lastHeavyUpdate, update)
        XCTAssertEqual(stats.heatmapData?.cells.reduce(0) { $0 + $1.seconds }, 1800)
        await stats.recompute(model: model, forceHeavy: true)
        XCTAssertEqual(stats.heatmapData?.cells.reduce(0) { $0 + $1.seconds }, 2400)
    }

    func testRuleAndProductivityEditsInvalidateWorkerMemoAndHeatmap() async throws {
        let model = try makeModel()
        let stats = StatsModel()
        await stats.recompute(model: model)
        XCTAssertEqual(stats.pulse, 100)
        try model.categoryStore.setUserApp("editor", categoryID: "entertainment")
        model.resolver.refresh()
        model.dataChanged()
        await stats.recompute(model: model)
        XCTAssertEqual(stats.pulse, 0)
        XCTAssertEqual(stats.heatmapData?.cells.first { $0.seconds > 0 }?.pulse, 0)
        var category = try XCTUnwrap(model.resolver.categoriesByID["entertainment"])
        category.productivity = 2
        try model.categoryStore.updateCategory(category)
        model.resolver.refreshCategories()
        model.categoryMetadataChanged()
        await stats.recompute(model: model)
        XCTAssertEqual(stats.pulse, 100)
        XCTAssertEqual(stats.heatmapData?.cells.first { $0.seconds > 0 }?.pulse, 100)
    }

    func testCancelledRequestDoesNotPublishAndCanBeRetried() async throws {
        let model = try makeModel()
        let stats = StatsModel()
        let request = Task { await stats.recompute(model: model) }
        request.cancel()
        await request.value
        XCTAssertFalse(stats.hasLoaded)
        XCTAssertFalse(stats.isLoading)
        XCTAssertNil(stats.lastHeavyUpdate)
        XCTAssertNil(stats.loadError)
        await stats.recompute(model: model)
        XCTAssertTrue(stats.hasLoaded)
        XCTAssertEqual(stats.total, 1800)
    }

    func testRapidRangeChangesFinishOnLatestRange() async throws {
        let model = try makeModel()
        let stats = StatsModel()
        let old = Task { await stats.recompute(model: model) }
        await Task.yield()
        model.range.shift(-1)
        await stats.recompute(model: model)
        await old.value
        XCTAssertTrue(stats.hasLoaded)
        XCTAssertEqual(stats.total, 0)
    }

    func testMenuStreakUsesSameTotalsAndRefreshesAfterRuleEdit() async throws {
        let model = try makeModel()
        let dashboard = TodayDashboardModel()
        await dashboard.recompute(model: model, forceStreak: false)
        XCTAssertEqual(dashboard.streakLookbackPulses,
                       model.dailyPulses(days: 30, endingAt: Date(), calendar: .current))
        XCTAssertTrue(dashboard.streakLookbackPulses.contains(100))
        try model.categoryStore.setUserApp("editor", categoryID: "entertainment")
        model.resolver.refresh()
        model.dataChanged()
        await dashboard.recompute(model: model, forceStreak: false)
        XCTAssertFalse(dashboard.streakLookbackPulses.contains(100))
        XCTAssertTrue(dashboard.streakLookbackPulses.contains(0))
    }
}
