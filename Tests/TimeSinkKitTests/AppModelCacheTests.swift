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

    /// A tracking write only touches spans from where it started, so a Stats
    /// window that ends before it stays cached.
    func testStatsWorkerKeepsWindowsThatEndBeforeATrackingWrite() async throws {
        let (model, store) = try makeModel()
        let today = DateRangeSelection.today()
        let yesterday = DateRangeSelection(kind: .day, anchor: today.interval.start.addingTimeInterval(-3600))
        func record(_ day: DateRangeSelection, hour: Double) -> Span {
            let start = day.interval.start.addingTimeInterval(hour * 3600)
            return Span(start: start, end: start.addingTimeInterval(300), appBundleID: "com.test", appName: "Test",
                        title: nil, url: nil, domain: nil)
        }
        let worker = StatsWorker()
        func seconds(_ day: DateRangeSelection) async throws -> TimeInterval {
            try await worker.categoryRows(store: store, classification: model.resolver.snapshot(),
                                          categories: model.resolver.categoriesByID, editVersion: model.dataEditVersion,
                                          dataVersion: model.dataVersion, interval: day.interval,
                                          writes: model.writeLog).reduce(0) { $0 + $1.seconds }
        }
        try store.insert(record(yesterday, hour: 10))
        model.dataChanged()
        let first = try await seconds(yesterday)
        XCTAssertEqual(first, 300)
        let emptyToday = try await seconds(today)
        XCTAssertEqual(emptyToday, 0)

        // Behind the worker's back: a record on each day, then a tracking
        // write that starts at today's.
        try store.insert(record(yesterday, hour: 11))
        let written = record(today, hour: 12)
        try store.insert(written)
        model.engineDataChangedForTesting(writtenFrom: written.start)
        let kept = try await seconds(yesterday)
        XCTAssertEqual(kept, 300, "yesterday ends before the write: still cached")
        let refetched = try await seconds(today)
        XCTAssertEqual(refetched, 300, "today reaches past it: read again")

        model.engineDataChangedForTesting()
        let reread = try await seconds(yesterday)
        XCTAssertEqual(reread, 600, "a write that could touch any day drops every window")
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

    /// `dataEditVersion` exists so a view can tell a user edit apart from the
    /// tracker's own span writes, which arrive about every 1.5s. If an engine
    /// write ever started bumping it, `StatsModel`'s 30-day trend and heatmap
    /// would go back to recomputing on the tracking cadence -- the cost the
    /// day gate exists to avoid. If a user edit ever stopped bumping it, that
    /// trend would show pre-edit numbers until midnight.
    func testDataEditVersionSeparatesUserEditsFromEngineWrites() throws {
        let (model, _) = try makeModel()
        let startData = model.dataVersion
        let startEdit = model.dataEditVersion

        model.dataChanged()
        XCTAssertEqual(model.dataVersion, startData + 1)
        XCTAssertEqual(model.dataEditVersion, startEdit + 1, "a user edit must bump the edit counter")

        // Productivity lives on Category, and both the pulse score and the
        // heatmap are weighted by it, so a metadata edit counts as an edit
        // even though it re-categorizes nothing.
        model.categoryMetadataChanged()
        XCTAssertEqual(model.dataVersion, startData + 2)
        XCTAssertEqual(model.dataEditVersion, startEdit + 2, "a productivity/colour edit must bump it too")

        // The engine's own path: same invalidation, no edit signal.
        model.engineDataChangedForTesting()
        XCTAssertEqual(model.dataVersion, startData + 3, "an engine write must still invalidate")
        XCTAssertEqual(model.dataEditVersion, startEdit + 2, "an engine write must NOT count as an edit")
    }

    /// The tracker only ever writes the span it is recording, so a window
    /// that ended before that span started keeps its cached rows.
    func testTrackerWritesKeepEarlierWindowsCached() throws {
        let (model, store) = try makeModel()
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = DateRangeSelection(kind: .day, anchor: today.addingTimeInterval(-43200))
        XCTAssertEqual(model.rangedSpans(for: yesterday).count, 0)
        XCTAssertEqual(model.rangedSpans(for: .today()).count, 0)

        try store.insert(span(hourOffset: -12))  // yesterday, bypassing the model
        try store.insert(span(hourOffset: 12))
        model.engineDataChangedForTesting(writtenFrom: today.addingTimeInterval(12 * 3600))
        XCTAssertEqual(model.rangedSpans(for: yesterday).count, 0, "a window before the write stays cached")
        XCTAssertEqual(model.rangedSpans(for: .today()).count, 1, "the window holding the write is re-read")

        model.dataChanged()
        XCTAssertEqual(model.rangedSpans(for: yesterday).count, 1, "a user edit still clears everything")
    }

    func testMidnightMovesTodayButNotAnOlderDay() throws {
        let (model, _) = try makeModel()
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        model.range = DateRangeSelection(kind: .day, anchor: yesterday)
        model.dayChanged(now: now)
        XCTAssertTrue(Calendar.current.isDate(model.range.anchor, inSameDayAs: now))

        let older = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        model.range = DateRangeSelection(kind: .day, anchor: older)
        model.dayChanged(now: now)
        XCTAssertTrue(Calendar.current.isDate(model.range.anchor, inSameDayAs: older))

        model.range = DateRangeSelection(kind: .last7, anchor: yesterday)
        model.dayChanged(now: now)
        XCTAssertEqual(model.range.kind, .last7)
        XCTAssertTrue(Calendar.current.isDate(model.range.anchor, inSameDayAs: now), "the last 7 days roll forward too")
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
