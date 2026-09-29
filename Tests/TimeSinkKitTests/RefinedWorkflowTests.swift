import XCTest
import os
@testable import TimeSinkKit

@MainActor final class RefinedWorkflowTests: XCTestCase {
    func testWeekPreferenceSurvivesNavigationAndMatchesSelectedWeek() throws {
        let db = try AppDatabase.openInMemory(), settings = SettingsStore(db), spans = SpanStore(db), categories = CategoryStore(db)
        let model = AppModel(categoryStore: categories, spanStore: spans, settings: settings, resolver: CategoryResolver(categoryStore: categories), engine: TrackerEngine(spanStore: spans, settings: settings))
        model.firstWeekday = 1
        model.range = DateRangeSelection(kind: .week, anchor: Date())
        XCTAssertEqual(Calendar.current.component(.weekday, from: model.range.interval.start), 1)
        model.firstWeekday = 2
        XCTAssertEqual(Calendar.current.component(.weekday, from: model.range.interval.start), 2)
        XCTAssertEqual(settings.get("firstWeekday"), "2")
    }

    func testTitleSheetPreviewAndWinningRuleAgreeWithSave() throws {
        let db = try AppDatabase.openInMemory(), categories = CategoryStore(db), store = SpanStore(db)
        try categories.setUserApp("editor", categoryID: "utilities")
        let span = try store.insert(Span(start: ts(0), end: ts(90), appBundleID: "editor", appName: "Editor", title: "Design course", url: nil, domain: nil))
        try categories.upsertUserTitleRule(pattern: "Design", scopeKey: "editor", categoryID: "writing")
        let resolver = CategoryResolver(categoryStore: categories)
        let affected = resolver.previewEdit(span: span, scope: .title, categoryID: "learning", pattern: "course", items: resolver.categorized([span]), titleScope: "", titlePriority: 0)
        XCTAssertTrue(affected.isEmpty, "Global title rule must not displace a scoped rule")
        try categories.upsertUserTitleRule(pattern: "course", scopeKey: "", categoryID: "learning")
        resolver.refresh()
        XCTAssertEqual(resolver.categoryID(for: span), "writing")
        let winner = try XCTUnwrap(try categories.titleRules().first { $0.pattern == "Design" }?.id)
        XCTAssertEqual(resolver.matchingRuleKey(for: span), "title:\(winner)")
        _ = try categories.reclassify(span: span, scope: .segment, categoryID: "news")
        resolver.refresh()
        XCTAssertNil(resolver.matchingRuleKey(for: span))
    }

    func testCSVPreservesTextAndDiagnosticsContainNoContent() throws {
        let db = try AppDatabase.openInMemory(), store = SpanStore(db)
        try store.insert(Span(start: ts(0), end: ts(90), appBundleID: "private.editor", appName: "应用", title: "=secret,\"quoted\"\nline", url: "https://private.example/account", domain: "private.example"))
        let csv = try store.exportCSV()
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(csv.contains("\"'=secret,\"\"quoted\"\"\nline\""))
        let diagnostics = try store.diagnosticSummary()
        XCTAssertFalse(diagnostics.contains("private.example"))
        XCTAssertFalse(diagnostics.contains("secret"))
        XCTAssertFalse(diagnostics.contains("private.editor"))
    }

    func testPermissionLossInvalidatesTrackingAndCanResume() async throws {
        let db = try AppDatabase.openInMemory(), store = SpanStore(db), settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: store, settings: settings)
        engine.idleSecondsProvider = { 0 }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        engine.windowSampleProvider = { date in
            calls.withLock { $0 += 1 }
            return Sample(timestamp: date, appBundleID: "editor", appName: "Editor", windowTitle: "A", url: nil)
        }
        await engine.tickAsync(now: ts(0))
        engine.setPermissionGranted(false, at: ts(1))
        await engine.tickAsync(now: ts(2))
        XCTAssertNil(engine.currentActivity)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        engine.setPermissionGranted(true, at: ts(3))
        await engine.tickAsync(now: ts(3))
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(engine.currentActivity?.start, ts(3))
    }

    func testSegmentOverrideFlowsThroughResolverSnapshotAndDailySummary() throws {
        let db = try AppDatabase.openInMemory(), categories = CategoryStore(db), store = SpanStore(db)
        try categories.setUserApp("editor", categoryID: "softwareDev")
        let today = Calendar.current.startOfDay(for: Date())
        let first = try store.insert(Span(start: today, end: today.addingTimeInterval(1800), appBundleID: "editor", appName: "Editor", title: "same", url: nil, domain: nil))
        let second = try store.insert(Span(start: today.addingTimeInterval(1800), end: today.addingTimeInterval(3600), appBundleID: "editor", appName: "Editor", title: "same", url: nil, domain: nil))
        let resolver = CategoryResolver(categoryStore: categories)
        let edit = try categories.reclassify(span: first, scope: .segment, categoryID: "entertainment")
        resolver.refresh()
        XCTAssertEqual(resolver.categoryID(for: first), "entertainment")
        XCTAssertEqual(resolver.categoryID(for: second), "softwareDev")
        var snapshot = resolver.snapshot()
        XCTAssertEqual(snapshot.categoryID(for: first), "entertainment")
        let pulses = try DailyPulseSummary.compute(store: store, days: 1, endingAt: Date(), calendar: .current, categories: resolver.categoriesByID) { resolver.categoryID(for: $0) }
        XCTAssertEqual(pulses, [50], "SQL grouping must keep segment overrides distinct even when all metadata is identical")
        try categories.undoReclassification(edit, activityKey: "editor")
        resolver.refresh()
        XCTAssertEqual(resolver.categoryID(for: first), "softwareDev")
    }

    func testDomainAndTitleUndoRestoreProvenanceWithoutDatePrecisionFailure() throws {
        let db = try AppDatabase.openInMemory(), categories = CategoryStore(db)
        try categories.importSeedDomains([("example.org", "news")])
        let span = Span(start: ts(0), end: ts(90), appBundleID: "browser", appName: "Browser", title: "Design system", url: "https://example.org/read?q=1", domain: "example.org")
        let edit = try categories.reclassify(span: span, scope: .activity, categoryID: "learning")
        try categories.undoReclassification(edit, activityKey: "example.org")
        XCTAssertEqual(try categories.domainMap()["example.org"], DomainEntry(categoryID: "news", source: "seed"))
        let titleEdit = try categories.reclassify(span: span, scope: .title, categoryID: "writing", pattern: "Design")
        try categories.undoReclassification(titleEdit, activityKey: "example.org")
        XCTAssertFalse(try categories.titleRules().contains { $0.pattern == "Design" && $0.scopeKey == "example.org" })
    }

    /// A new rule lands above every earlier user rule in its scope, even one
    /// dragged to the top, and the preview agrees with what saving does.
    func testNewTitleRuleRanksFirstAndPreviewAgreesAndSegmentOverrideWins() throws {
        let db = try AppDatabase.openInMemory(), categories = CategoryStore(db), store = SpanStore(db)
        let span = try store.insert(Span(start: ts(0), end: ts(90), appBundleID: "editor", appName: "Editor", title: "Design course", url: nil, domain: nil))
        try categories.upsertUserTitleRule(pattern: "course", scopeKey: "editor", categoryID: "learning")
        try db.write { try $0.execute(sql: "UPDATE titleRule SET priority = 200 WHERE pattern = ? AND scopeKey = ?", arguments: ["course", "editor"]) }
        let resolver = CategoryResolver(categoryStore: categories)
        let before = resolver.categorized([span])
        let preview = resolver.previewEdit(span: span, scope: .title, categoryID: "writing", pattern: "Design", items: before)
        _ = try categories.reclassify(span: span, scope: .title, categoryID: "writing", pattern: "Design")
        resolver.refresh()
        XCTAssertEqual(preview.count, 1)
        XCTAssertEqual(resolver.categoryID(for: span), "writing")
        _ = try categories.reclassify(span: span, scope: .segment, categoryID: "news")
        resolver.refresh()
        XCTAssertTrue(resolver.previewEdit(span: span, scope: .activity, categoryID: "writing", pattern: "", items: resolver.categorized([span])).isEmpty)
    }

    func testUndoDoesNotOverwriteNewerCategory() throws {
        let db = try AppDatabase.openInMemory(), categories = CategoryStore(db)
        let span = Span(start: ts(0), end: ts(90), appBundleID: "editor", appName: "Editor", title: nil, url: nil, domain: nil)
        let edit = try categories.reclassify(span: span, scope: .activity, categoryID: "writing")
        try categories.setUserApp("editor", categoryID: "learning")
        XCTAssertThrowsError(try categories.undoReclassification(edit, activityKey: "editor"))
        XCTAssertEqual(try categories.appMap()["editor"]?.categoryID, "learning")
    }

    func testPauseStopsSamplingAndLeavesUnrecordedGap() async throws {
        let db = try AppDatabase.openInMemory(), store = SpanStore(db), settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: store, settings: settings)
        engine.idleSecondsProvider = { 0 }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        engine.windowSampleProvider = { date in
            calls.withLock { $0 += 1 }
            return Sample(timestamp: date, appBundleID: "editor", appName: "Editor", windowTitle: "A", url: nil)
        }
        for second in 0..<30 { await engine.tickAsync(now: ts(Double(second))) }
        engine.setUserPaused(true, at: ts(30))
        await engine.tickAsync(now: ts(40)); await engine.tickAsync(now: ts(50))
        XCTAssertEqual(calls.withLock { $0 }, 30)
        XCTAssertNil(engine.currentActivity)
        engine.setUserPaused(false, at: ts(60))
        for second in 60..<90 { await engine.tickAsync(now: ts(Double(second))) }
        engine.setUserPaused(true, at: ts(90))
        let spans = try store.spans(overlapping: .init(start: ts(-1), end: ts(100)))
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].end, ts(30))
        XCTAssertEqual(spans[1].start, ts(60))
        XCTAssertEqual(spans.reduce(0) { $0 + $1.duration }, 60)
        XCTAssertEqual(calls.withLock { $0 }, 60)
    }

    func testExcludedApplicationNeverOpensSpan() async throws {
        let db = try AppDatabase.openInMemory(), store = SpanStore(db), settings = SettingsStore(db)
        settings.setExcludedApps(["private.app"])
        let engine = TrackerEngine(spanStore: store, settings: settings)
        engine.idleSecondsProvider = { 0 }
        engine.windowSampleProvider = { date in Sample(timestamp: date, appBundleID: "private.app", appName: "Private", windowTitle: "secret", url: nil) }
        await engine.tickAsync(now: ts(0)); await engine.tickAsync(now: ts(60))
        XCTAssertNil(engine.currentActivity)
        XCTAssertNil(engine.latestSample)
        XCTAssertTrue(try store.spans(overlapping: .init(start: ts(-1), end: ts(120))).isEmpty)
    }

    func testFocusExtensionAndExactDestination() throws {
        let db = try AppDatabase.openInMemory(), settings = SettingsStore(db), store = FocusSessionStore(db)
        settings.setFocusBlockedCategories(["entertainment"])
        let focus = FocusSessionController(store: store, settings: settings)
        focus.categoryForDomain = { _, _ in "entertainment" }
        var blockURL: String?
        focus.redirectChrome = { blockURL = $0; return true }
        try focus.start(minutes: 25)
        let original = "https://video.example/watch?v=42#chapter2"
        let sample = Sample(timestamp: Date(), appBundleID: "com.google.Chrome", appName: "Chrome", windowTitle: "Video", url: original)
        _ = focus.intercept(sample: sample, at: Date())
        XCTAssertEqual(focus.allowedDestination(for: "video.example"), original)
        XCTAssertNil(focus.allowedDestination(for: "unseen.example"))
        XCTAssertTrue(blockURL?.contains("endsAt=") == true)
        try focus.extend()
        XCTAssertEqual(focus.running?.plannedSeconds, 2100)
        XCTAssertEqual(try store.sessions(overlapping: .init(start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(60))).first?.plannedSeconds, 2100)
        focus.finish(completed: false)
    }

    func testHoverTriangleMirrorsToEitherSide() {
        XCTAssertTrue(PanelHost.contains(.init(x: 5, y: 4), triangle: (.init(x: 0, y: 5), .init(x: 10, y: 0), .init(x: 10, y: 10))))
        XCTAssertTrue(PanelHost.contains(.init(x: 5, y: 4), triangle: (.init(x: 10, y: 5), .init(x: 0, y: 0), .init(x: 0, y: 10))))
        XCTAssertFalse(PanelHost.contains(.init(x: 5, y: 12), triangle: (.init(x: 0, y: 5), .init(x: 10, y: 0), .init(x: 10, y: 10))))
    }
}
