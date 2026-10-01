import XCTest
@testable import TimeSinkKit

@MainActor
final class MenuProductiveTests: XCTestCase {
    private func makeModel() throws -> (AppModel, SpanStore, CategoryStore, CategoryResolver) {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let resolver = CategoryResolver(categoryStore: categoryStore)
        let settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: spanStore, settings: settings)
        let model = AppModel(categoryStore: categoryStore, spanStore: spanStore,
                             settings: settings, resolver: resolver, engine: engine)
        return (model, spanStore, categoryStore, resolver)
    }

    /// Ends `endingAgo` seconds before now, clamped to today so the test holds just after midnight.
    private func span(app: String, endingAgo: TimeInterval, seconds: TimeInterval) -> Span {
        let midnight = Calendar.current.startOfDay(for: Date())
        let start = max(midnight, Date().addingTimeInterval(-endingAgo - seconds))
        return Span(start: start, end: start.addingTimeInterval(seconds),
                    appBundleID: app, appName: app, title: nil, url: nil, domain: nil)
    }

    func testProductiveTitleMatchesTodayEngagedAndDiffersFromTotal() throws {
        let (model, store, categories, resolver) = try makeModel()
        try categories.setUserApp("com.work", categoryID: "learning")
        resolver.refresh()
        try store.insert(span(app: "com.work", endingAgo: 0, seconds: 1800))
        try store.insert(span(app: "com.other", endingAgo: 1800, seconds: 3600))
        model.dataChanged()

        model.refreshMenu()

        let items = model.rangedSpans(for: .today())
        let focus = Aggregator.focusTime(durationByCategory: Aggregator.durationByCategory(items),
                                         categories: resolver.categoriesByID)
        XCTAssertGreaterThan(focus, 0)
        XCTAssertEqual(model.menuProductiveTitle, "投入 " + Format.duration(focus))
        XCTAssertNotEqual(model.menuProductiveTitle, "投入 " + model.todayTotalTitle)
    }

    func testFreshModelDefaultsToProductive() throws {
        let (model, _, _, _) = try makeModel()
        XCTAssertEqual(model.menuDisplayMode, "productive")
    }
}
