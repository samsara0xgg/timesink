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

    /// A <30s sliver contiguous with the previous block (small gap) is
    /// absorbed into it — the previous block's end extends to cover it.
    func testContiguousSliverIsAbsorbedIntoPreviousBlock() {
        let items = [
            CategorizedSpan(span: mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z"), categoryID: "work"),
            CategorizedSpan(span: mkSpan("2026-08-23T09:30:05Z", "2026-08-23T09:30:20Z"), categoryID: "chat"),
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: categories)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].label, "Work")
        XCTAssertEqual(blocks[0].end, mkSpan("2026-08-23T09:30:05Z", "2026-08-23T09:30:20Z").end)
    }

    /// A <30s sliver hours after the previous block (large gap) is dropped
    /// entirely rather than teleporting the previous block's end forward.
    func testDistantSliverIsDropped() {
        let items = [
            CategorizedSpan(span: mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z"), categoryID: "work"),
            CategorizedSpan(span: mkSpan("2026-08-23T14:00:00Z", "2026-08-23T14:00:10Z"), categoryID: "chat"),
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: categories)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].label, "Work")
        XCTAssertEqual(blocks[0].end, mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z").end)
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

    /// Pins the actual bug: `TitleRuleInput.affected`/`Classifier.scopeMatches`
    /// compare a rule's scopeKey against `span.domain ?? span.appBundleID`.
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

        let viaEntityID = TitleRuleInput.affected(items: [item], pattern: "pull", scopeKey: row.id)
        XCTAssertEqual(viaEntityID.count, 0)

        let viaReassignKey = TitleRuleInput.affected(items: [item], pattern: "pull", scopeKey: row.reassignKey)
        XCTAssertEqual(viaReassignKey.count, 1)
        XCTAssertEqual(viaReassignKey.seconds, 600)
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
}
