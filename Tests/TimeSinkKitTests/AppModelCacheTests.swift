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

    private func span(start: TimeInterval, end: TimeInterval) -> Span {
        Span(start: Date(timeIntervalSinceNow: start), end: Date(timeIntervalSinceNow: end),
             appBundleID: "com.test", appName: "Test", title: nil, url: nil, domain: nil)
    }

    func testRangedSpansIsCachedUntilDataChanged() throws {
        let (model, store) = try makeModel()
        try store.insert(span(start: -600, end: -300))

        XCTAssertEqual(model.rangedSpans().count, 1)

        // 缓存生效：绕过 dataChanged 直接插入，读到的仍是旧结果
        try store.insert(span(start: -200, end: -100))
        XCTAssertEqual(model.rangedSpans().count, 1)

        // dataChanged 失效缓存后读到新数据
        model.dataChanged()
        XCTAssertEqual(model.rangedSpans().count, 2)
    }
}
