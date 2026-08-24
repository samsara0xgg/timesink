import XCTest
@testable import TimeSinkKit

@MainActor
final class AppModelCacheTests: XCTestCase {
    private func makeModel() throws -> (AppModel, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let resolver = CategoryResolver(categoryStore: categoryStore)
        let settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: spanStore, settings: settings)
        let model = AppModel(categoryStore: categoryStore, spanStore: spanStore,
                             settings: settings, resolver: resolver, engine: engine)
        return (model, spanStore)
    }

    // Anchored to midday of "today" rather than an offset from `Date()`: a
    // `Date(timeIntervalSinceNow: -600)` fixture falls in *yesterday* for the
    // ~10 minutes after local midnight, since `.today()`'s window is
    // calendar-day-quantized, not a trailing time window. Midday offsets stay
    // inside today's window regardless of what time the test actually runs.
    private func span(hourOffset: Double) -> Span {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(hourOffset * 3600)
        return Span(start: start, end: start.addingTimeInterval(300),
             appBundleID: "com.test", appName: "Test", title: nil, url: nil, domain: nil)
    }

    func testRangedSpansIsCachedUntilDataChanged() throws {
        let (model, store) = try makeModel()
        try store.insert(span(hourOffset: 12))

        XCTAssertEqual(model.rangedSpans().count, 1)

        // 缓存生效：绕过 dataChanged 直接插入，读到的仍是旧结果
        try store.insert(span(hourOffset: 13))
        XCTAssertEqual(model.rangedSpans().count, 1)

        // dataChanged 失效缓存后读到新数据
        model.dataChanged()
        XCTAssertEqual(model.rangedSpans().count, 2)
    }
}
