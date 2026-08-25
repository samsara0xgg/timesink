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

    func testRangeCacheEvictsOldestBeyondCap() throws {
        let (model, store) = try makeModel()
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

        // 9 distinct day-anchors, spaced 10 days apart so their intervals
        // never overlap and each produces a distinct cache key. Querying all
        // 9 fills the cache past its 8-entry cap, evicting the oldest
        // (queried first: index 0, "today").
        let anchors = (0..<9).map { today.addingTimeInterval(Double(-$0) * 10 * 86400) }
        for anchor in anchors {
            _ = model.rangedSpans(for: DateRangeSelection(kind: .day, anchor: anchor))
        }

        // "today"'s entry was queried first, so it's the oldest and should
        // have been evicted. Insert a span into its window directly
        // (bypassing dataChanged, which would trivially clear the whole
        // cache) and confirm a re-query sees it -- if the entry were still
        // cached, this would still read 0.
        try store.insert(span(hourOffset: 12))
        XCTAssertEqual(model.rangedSpans(for: DateRangeSelection(kind: .day, anchor: anchors[0])).count, 1)
    }

    // MARK: - C3 fix round 2, item 1: `refreshCalendarWindows()`'s disabled
    // path must never touch EventKit -- pinned here rather than in
    // `CalendarMeetingTests` since it's `AppModel`-level guard-ordering
    // behavior, not a pure `CalendarEvent`/`MeetingTagger` function.
    //
    // `todayMeetingEvents` (and therefore `isNowInMeeting`) can't be driven
    // to a genuinely non-empty state from a test without either a real
    // `CalendarStore`-backed `EKEventStore` (forbidden -- see Task 10's
    // testing constraints) or reaching into `AppModel`'s private storage, so
    // this doesn't pin a populated->cleared transition. What it DOES pin:
    // the `guard calendarOverlayEnabled, let calendarStore, Permissions
    // .calendarState() == .granted else { ... }` chain's clauses stay in
    // this order -- `calendarOverlayEnabled` first -- so the whole call is
    // safe from a bundle-less test process (a reordering that moved
    // `Permissions.calendarState()` first would still pass this specific
    // assertion, since that read is itself safe/non-crashing here, but
    // would defeat the documented intent and this test's own doc comment).
    @MainActor func testRefreshCalendarWindowsIsSafeAndClearsMeetingStateWhenOverlayDisabled() async throws {
        let (model, _) = try makeModel()
        XCTAssertFalse(model.calendarOverlayEnabled)   // 默认关闭，settings 默认值
        await model.refreshCalendarWindows()
        XCTAssertFalse(model.isNowInMeeting)
    }
}
