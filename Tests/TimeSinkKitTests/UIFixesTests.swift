import XCTest
import GRDB
@testable import TimeSinkKit

/// Audit #24-#33 and #17's UI half: reclassification undo and redo, the
/// day rolling over after days asleep, 不记录 for past records, toasts.
@MainActor
final class UIFixesTests: XCTestCase {
    private func makeModel() throws -> (AppModel, CategoryStore, SpanStore, ObservationStore) {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db), categories = CategoryStore(db), settings = SettingsStore(db)
        let model = AppModel(categoryStore: categories, spanStore: spans, settings: settings,
                             resolver: CategoryResolver(categoryStore: categories),
                             engine: TrackerEngine(spanStore: spans, settings: settings))
        let observations = ObservationStore(db)
        model.observationStore = observations
        return (model, categories, spans, observations)
    }

    private let day = Calendar.current.startOfDay(for: Date())

    private func span(_ app: String, at minutes: Double, domain: String? = nil, title: String? = nil) -> Span {
        let start = day.addingTimeInterval(minutes * 60)
        return Span(start: start, end: start.addingTimeInterval(600), appBundleID: app, appName: app, title: title,
                    url: domain.map { "https://\($0)/" }, domain: domain)
    }

    // MARK: - Undo and redo (#33)

    /// A title rule lives under the span's site or app, not under its own
    /// pattern: the batch undo finds it there.
    func testUndoingATitleEditInABatchRemovesItsRule() throws {
        let (_, categories, _, _) = try makeModel()
        let page = span("browser", at: 0, domain: "example.org", title: "Design review")
        let edit = try categories.reclassify(span: page, scope: .title, categoryID: "writing", pattern: "Design")
        XCTAssertEqual(edit.activityKey, "example.org")
        try categories.undoReclassifications([edit])
        XCTAssertFalse(try categories.titleRules().contains { $0.pattern == edit.key && $0.scopeKey == "example.org" })
    }

    /// #29: every saved piece of the session at once, one override per row,
    /// and one undo for all of them.
    func testSegmentsAreReclassifiedAndUndoneTogether() throws {
        let (_, categories, spans, _) = try makeModel()
        let first = try spans.insert(span("editor", at: 0))
        let second = try spans.insert(span("editor", at: 10))
        var clipped = first
        clipped.end = first.start.addingTimeInterval(60)   // a clipped piece of the same row
        let unsaved = span("editor", at: 20)
        let edits = try categories.reclassifySegments([first, clipped, second, unsaved], categoryID: "news")
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(try categories.segmentOverrides(), [first.id!: "news", second.id!: "news"])
        try categories.undoReclassifications(edits)
        XCTAssertTrue(try categories.segmentOverrides().isEmpty)
    }

    func testRedoAppliesAnUndoneEditAgain() throws {
        let (_, categories, _, _) = try makeModel()
        let edit = try categories.reclassify(span: span("editor", at: 0), scope: .activity, categoryID: "learning")
        try categories.undoReclassifications([edit])
        XCTAssertNil(try categories.appMap()["editor"])
        let again = try categories.redoReclassifications([edit])
        XCTAssertEqual(try categories.appMap()["editor"]?.categoryID, "learning")
        try categories.undoReclassifications(again)
        XCTAssertNil(try categories.appMap()["editor"])
    }

    func testRedoLeavesANewerChangeAlone() throws {
        let (_, categories, spans, _) = try makeModel()
        let saved = try spans.insert(span("editor", at: 0))
        let edit = try categories.reclassify(span: saved, scope: .segment, categoryID: "news")
        try categories.undoReclassifications([edit])
        _ = try categories.reclassify(span: saved, scope: .segment, categoryID: "learning")
        XCTAssertThrowsError(try categories.redoReclassifications([edit]))
        XCTAssertEqual(try categories.segmentOverrides()[saved.id!], "learning")
    }

    /// ⌘Z then ⇧⌘Z then ⌘Z on the window's stack.
    func testTheWindowUndoesAndRedoesAReclassification() throws {
        let (model, categories, spans, _) = try makeModel()
        let saved = try spans.insert(span("editor", at: 0))
        let edit = try categories.reclassify(span: saved, scope: .segment, categoryID: "news")
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        model.registerReclassificationUndo([edit], on: manager) { message in XCTFail(message) }
        manager.endUndoGrouping()
        manager.undo()
        XCTAssertNil(try categories.segmentOverrides()[saved.id!])
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(try categories.segmentOverrides()[saved.id!], "news")
        manager.undo()
        XCTAssertNil(try categories.segmentOverrides()[saved.id!])
    }

    func testAnUndoThatCannotApplySaysSo() throws {
        let (model, categories, spans, _) = try makeModel()
        let saved = try spans.insert(span("editor", at: 0))
        let edit = try categories.reclassify(span: saved, scope: .segment, categoryID: "news")
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        let failures = Tally()
        model.registerReclassificationUndo([edit], on: manager) { _ in failures.count += 1 }
        manager.endUndoGrouping()
        _ = try categories.reclassify(span: saved, scope: .segment, categoryID: "learning")
        manager.undo()
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try categories.segmentOverrides()[saved.id!], "learning")
    }

    func testANoticeHasNothingToUndo() {
        let activities = ActivitiesModel()
        activities.showNotice("没能撤销")
        XCTAssertEqual(activities.undoToast?.message, "没能撤销")
        XCTAssertTrue(activities.undoToast?.undo == nil)
        activities.performUndo()
        XCTAssertEqual(activities.undoToast?.message, "没能撤销", "撤销 on a notice does nothing")
    }

    func testTheToastsUndoDropsTheWindowsStepForIt() throws {
        let (model, _, _, _) = try makeModel()
        let activities = ActivitiesModel()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        let undone = Tally()
        activities.offerUndo("已拆开", name: "拆开", model: model, undoManager: manager, undo: { undone.count += 1 }, redo: {})
        manager.endUndoGrouping()
        XCTAssertTrue(manager.canUndo)
        activities.performUndo()
        XCTAssertEqual(undone.count, 1)
        if manager.canUndo { manager.undo() }
        XCTAssertEqual(undone.count, 1, "⌘Z must not undo it a second time")
    }

    // MARK: - Days asleep (#31)

    /// Closed on Friday, opened on Monday: what showed Friday shows Monday.
    func testWakingDaysLaterMovesWhatShowedTheLastDaySeen() throws {
        let (model, _, _, _) = try makeModel()
        let now = Date()
        let calendar = Calendar.current
        let friday = calendar.date(byAdding: .day, value: -3, to: now)!
        model.lastSeenDay = calendar.startOfDay(for: friday)
        model.range = DateRangeSelection(kind: .day, anchor: friday)
        model.dayChanged(now: now)
        XCTAssertTrue(calendar.isDate(model.range.anchor, inSameDayAs: now))

        let thursday = calendar.date(byAdding: .day, value: -4, to: now)!
        model.lastSeenDay = calendar.startOfDay(for: friday)
        model.range = DateRangeSelection(kind: .day, anchor: thursday)
        model.dayChanged(now: now)
        XCTAssertTrue(calendar.isDate(model.range.anchor, inSameDayAs: thursday), "a day chosen before stays")

        // No day passed (a time zone change): nothing moves.
        model.range = DateRangeSelection(kind: .day, anchor: thursday)
        model.dayChanged(now: now)
        XCTAssertTrue(calendar.isDate(model.range.anchor, inSameDayAs: thursday))
    }

    // MARK: - Small routes (#33)

    func testOpeningActivitiesClearsAnOldSearch() throws {
        let (model, _, _, _) = try makeModel()
        model.activitySearch = "old"
        model.openActivities(category: nil, range: .today())
        XCTAssertEqual(model.activitySearch, "")
    }

    func testSessionOverridesBumpTheirVersion() throws {
        let (model, _, _, _) = try makeModel()
        let before = model.sessionOverridesVersion
        model.sessionOverrides = ["x": SessionNameRow(signature: "x", name: "Deep work", project: nil, updatedAt: Date())]
        XCTAssertGreaterThan(model.sessionOverridesVersion, before)
    }

    // MARK: - 不记录 past records (#17)

    func testPurgingAnAppAndASiteDeletesTheirSpansAndCaptures() throws {
        let (_, _, spans, observations) = try makeModel()
        let secret = try spans.insert(span("com.secret", at: 0))
        _ = try spans.insert(span("com.secret", at: 10))
        let kept = try spans.insert(span("com.keep", at: 20))
        let bank = try spans.insert(span("browser", at: 30, domain: "bank.com"))
        _ = try spans.insert(span("browser", at: 40, domain: "login.bank.com"))
        _ = try spans.insert(span("browser", at: 50, domain: "notbank.com"))
        _ = try spans.insert(span("browser", at: 60, domain: "bank.com.example.net"))
        func capture(_ span: Span, image: String?) throws {
            _ = try observations.insert(Capture(at: span.start, lastSeenAt: span.end, appBundleID: span.appBundleID, appName: span.appName,
                                                windowID: 1, title: nil, spanID: span.id, text: "text", imagePath: image))
        }
        try capture(secret, image: "day/1.jpg")
        try capture(kept, image: "day/2.jpg")
        try capture(bank, image: nil)

        let deleted = try AppModel.purgeRecords(writer: spans.writer, apps: ["com.secret"], domains: ["bank.com"])
        XCTAssertEqual(deleted.spans, 4)
        XCTAssertEqual(deleted.imagePaths, ["day/1.jpg"])
        let left: [String] = try spans.writer.read { db in
            try String.fetchAll(db, sql: "SELECT appBundleID || ':' || COALESCE(domain, '') FROM span ORDER BY start")
        }
        XCTAssertEqual(left, ["com.keep:", "browser:notbank.com", "browser:bank.com.example.net"])
        let captures: [Int64] = try spans.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT COALESCE(spanID, -1) FROM capture")
        }
        XCTAssertEqual(captures, [kept.id!])
    }

    func testDeletingNothingDoesNothing() async throws {
        let (model, _, spans, _) = try makeModel()
        _ = try spans.insert(span("com.keep", at: 0))
        let count = try await model.deleteRecords(apps: [], domains: [])
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try spanCount(spans), 1)
    }

    /// Synchronous on purpose: in an async test the read would pick GRDB's async overload.
    private func spanCount(_ spans: SpanStore) throws -> Int {
        try spans.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM span") ?? 0 }
    }
}

/// Counts calls from the undo closures, which are `@Sendable`.
@MainActor private final class Tally {
    var count = 0
}
