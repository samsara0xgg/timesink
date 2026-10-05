import XCTest
@testable import TimeSinkKit

/// A8: what the session inspector's undo toasts restore.
@MainActor
final class SessionEditUndoTests: XCTestCase {
    private func makeModel() throws -> (AppModel, ObservationStore, CategoryStore, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db), categories = CategoryStore(db), settings = SettingsStore(db)
        let model = AppModel(categoryStore: categories, spanStore: spans, settings: settings,
                             resolver: CategoryResolver(categoryStore: categories),
                             engine: TrackerEngine(spanStore: spans, settings: settings))
        let observations = ObservationStore(db)
        model.observationStore = observations
        return (model, observations, categories, spans)
    }

    private func session(_ start: Date) -> WorkSession {
        WorkSession(start: start, end: start.addingTimeInterval(3600), recorded: 3600, categoryID: "dev", project: nil,
                    projectLabel: nil, apps: [], titles: [], documents: [])
    }

    private let day = Calendar.current.startOfDay(for: Date())
    private var window: DateInterval { DateInterval(start: day, end: day.addingTimeInterval(86400)) }

    func testUndoingASplitRemovesOnlyThatPointAndBumpsTheVersion() throws {
        let (model, store, _, _) = try makeModel()
        let kept = day.addingTimeInterval(3600), added = day.addingTimeInterval(7200)
        model.splitSession(at: kept)
        let before = model.sessionSplitsVersion
        model.splitSession(at: added)
        XCTAssertEqual(try store.sessionSplits(in: window), [kept, added])
        model.unsplitSession(at: added)
        XCTAssertEqual(try store.sessionSplits(in: window), [kept])
        XCTAssertEqual(model.sessionSplitsVersion, before + 2, "the undo refreshes the lists like the split did")
    }

    func testUndoingAProjectRestoresThePreviousOverrideOrRemovesIt() throws {
        let (model, store, _, _) = try makeModel()
        let target = session(day.addingTimeInterval(9 * 3600))
        // No override before: the undo removes the row altogether.
        model.assignSession(target, toProject: "Alpha")
        XCTAssertEqual(model.sessionOverrides[target.signature]?.project, "Alpha")
        model.assignSession(target, toProject: "")
        XCTAssertNil(model.sessionOverrides[target.signature])
        XCTAssertTrue(try store.sessionNames().isEmpty)
        // An override before: the undo brings it back, and keeps the name.
        try store.setSessionName(signature: target.signature, name: "Deep work", project: "Alpha")
        model.sessionOverrides = try store.sessionNames()
        model.assignSession(target, toProject: "Beta")
        model.assignSession(target, toProject: "Alpha")
        XCTAssertEqual(model.sessionOverrides[target.signature]?.project, "Alpha")
        XCTAssertEqual(model.sessionOverrides[target.signature]?.name, "Deep work")
    }

    func testUndoingAReclassificationRestoresEveryOverride() throws {
        let (_, _, categories, spans) = try makeModel()
        try categories.setUserApp("editor", categoryID: "softwareDev")
        let first = try spans.insert(Span(start: day, end: day.addingTimeInterval(1800), appBundleID: "editor", appName: "Editor", title: "a", url: nil, domain: nil))
        let second = try spans.insert(Span(start: day.addingTimeInterval(1800), end: day.addingTimeInterval(3600), appBundleID: "editor", appName: "Editor", title: "b", url: nil, domain: nil))
        // The first span already carried a hand-made override; the second did not.
        _ = try categories.reclassify(span: first, scope: .segment, categoryID: "news")
        let edits = [try categories.reclassify(span: first, scope: .segment, categoryID: "entertainment"),
                     try categories.reclassify(span: second, scope: .segment, categoryID: "entertainment"),
                     try categories.reclassify(span: second, scope: .activity, categoryID: "learning")]
        try categories.undoReclassifications(edits)
        let overrides = try categories.segmentOverrides()
        XCTAssertEqual(overrides[first.id!], "news")
        XCTAssertNil(overrides[second.id!])
        let resolver = CategoryResolver(categoryStore: categories)
        resolver.refresh()
        XCTAssertEqual(resolver.categoryID(for: second), "softwareDev")
    }

    func testTheToastRunsItsUndoOnceAndGoes() {
        let activities = ActivitiesModel()
        var undone = 0
        activities.showUndo("已拆开") { undone += 1 }
        XCTAssertEqual(activities.undoToast?.message, "已拆开")
        activities.performUndo()
        activities.performUndo()
        XCTAssertEqual(undone, 1)
        XCTAssertNil(activities.undoToast)
    }

    func testANewerEditReplacesTheToast() {
        let activities = ActivitiesModel()
        var undone: [String] = []
        activities.showUndo("a") { undone.append("a") }
        activities.showUndo("b") { undone.append("b") }
        activities.performUndo()
        XCTAssertEqual(undone, ["b"])
    }
}
