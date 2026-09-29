import XCTest
@testable import TimeSinkKit

/// Covers the day-timeline block builder's merge/absorb gap guard: a
/// same-category span across a real idle gap must stay its own block rather
/// than being painted as one continuous active span.
final class ActivitiesModelTests: XCTestCase {
    private let categories: [String: TimeSinkKit.Category] = [
        "work": TimeSinkKit.Category(id: "work", name: "Work", colorHex: "#000000", productivity: 1, sortOrder: 0),
        "chat": TimeSinkKit.Category(id: "chat", name: "Chat", colorHex: "#111111", productivity: -1, sortOrder: 1),
    ]

    private func mkSpan(_ startISO: String, _ endISO: String, app: String = "App") -> Span {
        let formatter = ISO8601DateFormatter()
        return Span(
            start: formatter.date(from: startISO)!,
            end: formatter.date(from: endISO)!,
            appBundleID: "com.example.\(app)",
            appName: app,
            title: nil,
            url: nil,
            domain: nil
        )
    }

    /// Xcode 09:00-09:30, idle until 14:00, Xcode 14:00-14:10: same category
    /// either side of a 4.5h gap must NOT merge into one 09:00-14:10 block.
    func testLargeGapBetweenSameCategorySpansStaysTwoBlocks() {
        let items = [
            CategorizedSpan(span: mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z"), categoryID: "work"),
            CategorizedSpan(span: mkSpan("2026-08-23T14:00:00Z", "2026-08-23T14:10:00Z"), categoryID: "work"),
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: categories)
        XCTAssertEqual(blocks.count, 2)
    }

    /// Short records remain independently selectable rather than being
    /// absorbed into a different application's/category's interval.
    func testShortActivityRemainsSelectable() {
        let items = [
            CategorizedSpan(span: mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z"), categoryID: "work"),
            CategorizedSpan(span: mkSpan("2026-08-23T09:30:05Z", "2026-08-23T09:30:20Z", app: "Chat"), categoryID: "chat"),
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: categories)
        XCTAssertEqual(blocks.count, 2)
        // Sub-bridge jitter is tiled over, but never counted as recorded time.
        XCTAssertEqual(blocks[0].end, blocks[1].start)
        XCTAssertEqual(blocks[0].segment?.recorded, 1800)
        XCTAssertEqual(blocks[1].activity?.rowID, "com.example.Chat")
        XCTAssertEqual(blocks[1].duration, 15)
    }

    /// Zoomed out, the same sliver folds into its neighbour but stays findable.
    func testFoldedShortActivityStaysFindable() {
        let items = [
            CategorizedSpan(span: mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z"), categoryID: "work"),
            CategorizedSpan(span: mkSpan("2026-08-23T09:30:05Z", "2026-08-23T09:30:20Z", app: "Chat"), categoryID: "chat"),
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: categories, resolution: 450)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].activity?.categoryID, "work")
        let chat = ActivitiesModel.selection(for: items[1])
        XCTAssertTrue(blocks[0].contains(chat))
        XCTAssertEqual(blocks[0].start(of: chat), items[1].span.start)
        XCTAssertEqual(blocks[0].segment?.recorded, 1815)
    }

    func testDistantShortActivityIsNotDropped() {
        let items = [
            CategorizedSpan(span: mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z"), categoryID: "work"),
            CategorizedSpan(span: mkSpan("2026-08-23T14:00:00Z", "2026-08-23T14:00:10Z"), categoryID: "chat"),
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: categories)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1].duration, 10)
        XCTAssertEqual(blocks[1].activity?.categoryID, "chat")
    }

    func testSearchMatchesAcrossFields() {
        let item = CategorizedSpan(span: Span(start: ts(0), end: ts(60), appBundleID: "c",
            appName: "Chrome", title: "Fix span clipping — Pull Request #42",
            url: "https://github.com/a/b/pull/42", domain: "github.com"), categoryID: "softwareDev")
        XCTAssertTrue(ActivitiesModel.matches(item, query: "pull request"))   // title 大小写不敏感
        XCTAssertTrue(ActivitiesModel.matches(item, query: "GITHUB.COM"))     // domain
        XCTAssertTrue(ActivitiesModel.matches(item, query: "chrome"))         // appName
        XCTAssertFalse(ActivitiesModel.matches(item, query: "youtube"))
    }
    func testFilterComposesAndNormalizes() {
        XCTAssertNil(ActivitiesModel.normalizedQuery("   "))
        XCTAssertEqual(ActivitiesModel.normalizedQuery(" Pull "), "Pull")
        let hit = CategorizedSpan(span: Span(start: ts(0), end: ts(60), appBundleID: "c",
            appName: "Chrome", title: "Pull Request #42", url: "https://github.com/a/b", domain: "github.com"),
            categoryID: "softwareDev")
        let miss = CategorizedSpan(span: Span(start: ts(60), end: ts(120), appBundleID: "m",
            appName: "Music", title: "Daily Mix", url: nil, domain: nil), categoryID: "entertainment")
        XCTAssertEqual(ActivitiesModel.filter([hit, miss], query: "pull").count, 1)
        XCTAssertEqual(ActivitiesModel.filter([hit, miss], query: nil).count, 2)
    }
    func testEntityRowKeepsDomainReassignKey() {
        let item = CategorizedSpan(span: Span(start: ts(0), end: ts(600), appBundleID: "c",
            appName: "Chrome", title: "PR", url: "https://github.com/alllllenshi/timesink/pull/1",
            domain: "github.com"), categoryID: "softwareDev")
        let rows = ActivitiesModel.rows(for: [item])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "github.com/alllllenshi/timesink")
        XCTAssertEqual(rows[0].reassignKey, "github.com")
        XCTAssertTrue(rows[0].isEntity)
        // R-T9d: a flip here would silently route reassignment through
        // `setUserApp("github.com")` instead of `setUserDomain` — wrong
        // CategoryStore table entirely.
        XCTAssertTrue(rows[0].isDomain)
    }

    // MARK: - Fix round 1, CRITICAL 1: entity rows must scope title rules by
    // reassignKey, not the finer-grained display id

    /// Pins the actual bug: `Classifier.scopeMatches` compares a rule's
    /// scopeKey against `span.domain ?? span.appBundleID`.
    /// An entity row's `id` (e.g. a specific github repo) never equals that,
    /// so a rule scoped to `id` silently affects zero items forever — while
    /// `reassignKey` (what the fixed `TitleRowView` now hands
    /// `PendingTitleRule.scopeKey`) does match.
    func testEntityRowReassignKeyScopesTitleRuleMatchesButRowIDDoesNot() {
        let item = CategorizedSpan(span: Span(start: ts(0), end: ts(600), appBundleID: "c",
            appName: "Chrome", title: "Fix span clipping — Pull Request #42",
            url: "https://github.com/alllllenshi/timesink/pull/1", domain: "github.com"),
            categoryID: "softwareDev")
        let rows = ActivitiesModel.rows(for: [item])
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]

        let itemScope = item.span.domain ?? item.span.appBundleID
        XCTAssertFalse(Classifier.scopeMatches(ruleScopeKey: row.id, scopeKey: itemScope))
        XCTAssertTrue(Classifier.scopeMatches(ruleScopeKey: row.reassignKey, scopeKey: itemScope))
    }

    // MARK: - Fix round 1, R-T9d: matches() url branch

    func testMatchesURLOnlyBranch() {
        let item = CategorizedSpan(span: Span(start: ts(0), end: ts(60), appBundleID: "c",
            appName: "Chrome", title: "Untitled", url: "https://example.com/secret-repo/path",
            domain: "example.com"), categoryID: "softwareDev")
        XCTAssertTrue(ActivitiesModel.matches(item, query: "secret-repo"))
        XCTAssertFalse(ActivitiesModel.matches(item, query: "nonexistent-term"))
    }

    // MARK: - Fix round 1, R-T9d: non-entity rows(for:) parity (the
    // hand-rolled Accum path had zero direct coverage)

    func testRowsForNonEntityMixKeepsOldLabelsIsDomainAndTitleFallback() {
        let items = [
            CategorizedSpan(span: Span(start: ts(0), end: ts(60), appBundleID: "com.apple.dt.Xcode",
                appName: "Xcode", title: nil, url: nil, domain: nil), categoryID: "softwareDev"),
            CategorizedSpan(span: Span(start: ts(0), end: ts(600), appBundleID: "c",
                appName: "Chrome", title: "Docs", url: nil, domain: "example.com"), categoryID: "softwareDev"),
        ]
        let rows = ActivitiesModel.rows(for: items)
        XCTAssertEqual(rows.count, 2)

        // seconds-desc: example.com (600s) before Xcode (60s).
        XCTAssertEqual(rows[0].id, "example.com")
        XCTAssertEqual(rows[0].label, "example.com")
        XCTAssertTrue(rows[0].isDomain)
        XCTAssertEqual(rows[0].reassignKey, "example.com")
        XCTAssertFalse(rows[0].isEntity)
        XCTAssertEqual(rows[0].titles.first?.title, "Docs")

        XCTAssertEqual(rows[1].id, "com.apple.dt.Xcode")
        XCTAssertEqual(rows[1].label, "Xcode")
        XCTAssertFalse(rows[1].isDomain)
        XCTAssertEqual(rows[1].reassignKey, "com.apple.dt.Xcode")
        XCTAssertFalse(rows[1].isEntity)
        XCTAssertEqual(rows[1].titles.first?.title, "(无标题)")
    }

    func testRowsForOrdersBySecondsDescThenKeyAscOnTies() {
        let items = [
            CategorizedSpan(span: Span(start: ts(0), end: ts(60), appBundleID: "z.app",
                appName: "Z", title: nil, url: nil, domain: nil), categoryID: "softwareDev"),
            CategorizedSpan(span: Span(start: ts(0), end: ts(60), appBundleID: "a.app",
                appName: "A", title: nil, url: nil, domain: nil), categoryID: "softwareDev"),
        ]
        let rows = ActivitiesModel.rows(for: items)
        XCTAssertEqual(rows.map(\.id), ["a.app", "z.app"])
    }

    // MARK: - Fix round 1, R-T9a / IMPORTANT 2: matchCount/matchSeconds
    // through a real recompute() -- integration-level, over an in-memory
    // AppModel, since the bug was in how `recompute` composed
    // `model.activityFilter` with the search-filtered items, not in `filter`
    // or `matches` themselves.

    @MainActor
    private func makeActivitiesAppModel() throws -> (AppModel, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let catStore = CategoryStore(db)
        let model = AppModel(categoryStore: catStore, spanStore: store,
                             settings: SettingsStore(db),
                             resolver: CategoryResolver(categoryStore: catStore),
                             engine: TrackerEngine(spanStore: store, settings: SettingsStore(db)))
        return (model, store)
    }

    /// midday-of-today anchored (not `Date()`-relative), matching
    /// `AppModelCacheTests.span(hourOffset:)`'s rationale: stays inside
    /// `.today()`'s window regardless of what time the test actually runs.
    private func todaySpan(hourOffset: Double, appBundleID: String, appName: String, title: String?) -> Span {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(hourOffset * 3600)
        return Span(start: start, end: start.addingTimeInterval(300),
                    appBundleID: appBundleID, appName: appName, title: title, url: nil, domain: nil)
    }

    @MainActor func testMatchCountAndSecondsAreNilWithoutAnActiveQuery() throws {
        let (model, store) = try makeActivitiesAppModel()
        try store.insert(todaySpan(hourOffset: 10, appBundleID: "com.apple.dt.Xcode", appName: "Xcode",
                                    title: "Pull request review"))
        let activities = ActivitiesModel()
        activities.recompute(model: model)
        XCTAssertNil(activities.matchCount)
        XCTAssertNil(activities.matchSeconds)
    }

    @MainActor func testMatchCountAndSecondsReflectActiveQuery() throws {
        let (model, store) = try makeActivitiesAppModel()
        try store.insert(todaySpan(hourOffset: 10, appBundleID: "com.apple.dt.Xcode", appName: "Xcode",
                                    title: "Pull request review"))       // softwareDev
        try store.insert(todaySpan(hourOffset: 11, appBundleID: "com.spotify.client", appName: "Spotify",
                                    title: "Daily Mix"))                 // entertainment, no match
        model.activitySearch = "pull"
        let activities = ActivitiesModel()
        activities.recompute(model: model)
        XCTAssertEqual(activities.matchCount, 1)
        XCTAssertEqual(activities.matchSeconds, 300)
    }

    /// R-T9a: with a category chip active, the header count must match what
    /// `ActivityListView` actually displays for that one category, not the
    /// total across every category.
    @MainActor func testMatchCountIsScopedToActiveCategoryFilter() throws {
        let (model, store) = try makeActivitiesAppModel()
        try store.insert(todaySpan(hourOffset: 10, appBundleID: "com.apple.dt.Xcode", appName: "Xcode",
                                    title: "Pull request review"))   // softwareDev
        try store.insert(todaySpan(hourOffset: 11, appBundleID: "com.spotify.client", appName: "Spotify",
                                    title: "Pull My Weight"))        // entertainment
        model.activitySearch = "pull"
        let activities = ActivitiesModel()
        activities.recompute(model: model)
        XCTAssertEqual(activities.matchCount, 2)   // no category filter: both categories' hits count

        model.activityFilter = "softwareDev"
        activities.recompute(model: model)
        XCTAssertEqual(activities.matchCount, 1)   // scoped down to just softwareDev's hit
        XCTAssertEqual(activities.matchSeconds, 300)
    }

    // MARK: - C4 focus session timeline blocks

    /// The local-calendar day containing `date`, i.e. exactly what
    /// `DateRangeSelection(kind: .day)` hands `focusTimelineBlocks`.
    private func dayAround(_ date: Date) -> DateInterval {
        let start = Calendar.current.startOfDay(for: date)
        return DateInterval(start: start, end: start.addingTimeInterval(86400))
    }

    /// Pure mapper: tooltip's distraction count sums app+site blocks, and
    /// the productivity number is computed from `items` clipped to the
    /// session's own window (`Aggregator.clippedToElapsed` + `pulse`), not
    /// the whole day.
    func testFocusTimelineBlocksTooltipReflectsClippedPulse() {
        let session = FocusSession(id: 1, start: ts(0), end: ts(1500), plannedSeconds: 1500,
                                    appBlocks: 2, siteBlocks: 1, completed: true)
        // Fully productive (work) span spanning the whole session window --
        // clippedToElapsed should keep all of it, so pulse should be the
        // "work" category's max score, not diluted by anything outside the
        // window.
        let items = [
            CategorizedSpan(span: Span(start: ts(0), end: ts(1500), appBundleID: "com.apple.dt.Xcode",
                appName: "Xcode", title: nil, url: nil, domain: nil), categoryID: "work"),
            // Outside the session window entirely -- must NOT affect pulse.
            CategorizedSpan(span: Span(start: ts(3000), end: ts(3600), appBundleID: "com.spotify.client",
                appName: "Spotify", title: nil, url: nil, domain: nil), categoryID: "chat"),
        ]
        let blocks = ActivitiesModel.focusTimelineBlocks([session], items: items, categories: categories,
                                                         dayInterval: dayAround(ts(0)))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].start, ts(0))
        XCTAssertEqual(blocks[0].end, ts(1500))
        XCTAssertTrue(blocks[0].tooltip.contains("拦下 3 次分心"))
        // "work" productivity 1 -> points(1) = 75.
        XCTAssertTrue(blocks[0].tooltip.contains("期间分 75"))
    }

    /// No overlapping items at all -> pulse is nil, tooltip falls back to "--".
    func testFocusTimelineBlocksTooltipFallsBackWhenNoOverlap() {
        let session = FocusSession(id: 1, start: ts(0), end: ts(60), plannedSeconds: 60,
                                    appBlocks: 0, siteBlocks: 0, completed: true)
        let blocks = ActivitiesModel.focusTimelineBlocks([session], items: [], categories: categories,
                                                         dayInterval: dayAround(ts(0)))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].tooltip.contains("拦下 0 次分心"))
        XCTAssertTrue(blocks[0].tooltip.contains("期间分 --"))
    }

    /// A session that crosses midnight is returned by
    /// `sessions(overlapping:)` on BOTH days, and `DayTimelineView` positions
    /// blocks off minutes-from-midnight of the block's own date -- so an
    /// unclipped block draws a phantom 23:50 bar on the END day (with its
    /// real 00:00–00:15 slice missing) and overruns the bottom of the START
    /// day's grid. Each day must get only its own slice; the tooltip keeps
    /// reporting the WHOLE session either way.
    func testFocusTimelineBlocksClipCrossMidnightSessionToDisplayedDay() {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: ts(0)).addingTimeInterval(86400)
        let start = midnight.addingTimeInterval(-600)          // 23:50 D1
        let end = midnight.addingTimeInterval(900)             // 00:15 D2
        let session = FocusSession(id: 1, start: start, end: end, plannedSeconds: 1500,
                                    appBlocks: 1, siteBlocks: 1, completed: true)

        let startDay = ActivitiesModel.focusTimelineBlocks([session], items: [], categories: categories,
                                                           dayInterval: dayAround(start))
        XCTAssertEqual(startDay.count, 1)
        XCTAssertEqual(startDay[0].start, start)
        XCTAssertEqual(startDay[0].end, midnight)              // clipped at the grid's bottom

        let endDay = ActivitiesModel.focusTimelineBlocks([session], items: [], categories: categories,
                                                         dayInterval: dayAround(end))
        XCTAssertEqual(endDay.count, 1)
        XCTAssertEqual(endDay[0].start, midnight)              // top of the grid, not 23:50
        XCTAssertEqual(endDay[0].end, end)

        // Tooltip reads the ORIGINAL session on both days: 25 分钟, 2 次分心.
        for block in startDay + endDay {
            XCTAssertTrue(block.tooltip.contains("专注 \(Format.duration(1500))"), block.tooltip)
            XCTAssertTrue(block.tooltip.contains("拦下 2 次分心"), block.tooltip)
        }
    }

    /// A session entirely outside the displayed day contributes no block at
    /// all (rather than a zero-height artifact at the grid's edge).
    func testFocusTimelineBlocksDropSessionOutsideDisplayedDay() {
        let start = Calendar.current.startOfDay(for: ts(0)).addingTimeInterval(10 * 3600)
        let session = FocusSession(id: 1, start: start, end: start.addingTimeInterval(1500),
                                    plannedSeconds: 1500, appBlocks: 0, siteBlocks: 0, completed: true)
        let blocks = ActivitiesModel.focusTimelineBlocks(
            [session], items: [], categories: categories,
            dayInterval: dayAround(start.addingTimeInterval(3 * 86400))
        )
        XCTAssertTrue(blocks.isEmpty)
    }

    /// Integration: `recompute` actually fetches from `model.focusStore` and
    /// populates `focusBlocks` for a single-day-ish range (the default
    /// `.today()`), gated off for wider ranges the same way `timelineBlocks` is.
    @MainActor func testRecomputePopulatesFocusBlocksFromFocusStore() throws {
        let (model, _) = try makeActivitiesAppModel()
        let db = try AppDatabase.openInMemory()
        let focusStore = FocusSessionStore(db)
        model.focusStore = focusStore
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
        let session = try focusStore.start(at: start, plannedSeconds: 1500)
        try focusStore.finish(id: session.id!, end: start.addingTimeInterval(1500), appBlocks: 1, siteBlocks: 0, completed: true)

        let activities = ActivitiesModel()
        activities.recompute(model: model)
        XCTAssertEqual(activities.focusBlocks.count, 1)
        XCTAssertEqual(activities.focusBlocks[0].start, start)
    }
}
