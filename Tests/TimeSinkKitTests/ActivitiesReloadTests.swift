import XCTest
@testable import TimeSinkKit

/// The off-main load must publish exactly what the synchronous one does, and
/// must never publish a result that a later change has made stale.
@MainActor
final class ActivitiesReloadTests: XCTestCase {
    private func makeModel() throws -> (AppModel, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let settings = SettingsStore(db)
        let model = AppModel(categoryStore: categoryStore, spanStore: spanStore, settings: settings,
                             resolver: CategoryResolver(categoryStore: categoryStore),
                             engine: TrackerEngine(spanStore: spanStore, settings: settings))
        return (model, spanStore)
    }

    private let apps: [(id: String, name: String, domain: String?, url: String?, title: String)] = [
        ("com.apple.dt.Xcode", "Xcode", nil, nil, "TimeSink.swift"),
        ("com.google.Chrome", "Chrome", "github.com", "https://github.com/a/b", "a/b"),
        ("com.google.Chrome", "Chrome", "youtube.com", "https://youtube.com/watch?v=1", "A video"),
        ("com.tinyspeck.slackmacgap", "Slack", nil, nil, "general"),
        ("com.apple.Terminal", "Terminal", nil, nil, "zsh"),
        ("com.example.unknown", "Unknown", nil, nil, "(no title)"),
    ]

    /// Three days of mixed, partly overlapping-the-edge spans.
    private func fixture(_ store: SpanStore, days: [Date]) throws {
        var n = 0
        for day in days {
            var cursor = day.addingTimeInterval(8 * 3600 - 600)
            for index in 0..<90 {
                let app = apps[(index * 7 + n) % apps.count]
                let length = TimeInterval(20 + (index * 53) % 600)
                try store.insert(Span(start: cursor, end: cursor.addingTimeInterval(length), appBundleID: app.id, appName: app.name,
                                      title: app.title + (index % 3 == 0 ? " \(index)" : ""), url: app.url, domain: app.domain,
                                      keySeconds: index % 5))
                cursor = cursor.addingTimeInterval(length + TimeInterval((index * 17) % 90))
                n += 1
            }
        }
    }

    private func settle(_ activities: ActivitiesModel) async {
        await activities.loadTask?.value
    }

    private func compare(_ model: AppModel, events: [CalendarEvent] = [], setup: () -> Void = {},
                         file: StaticString = #filePath, line: UInt = #line) async {
        setup()
        let sync = ActivitiesModel()
        sync.recompute(model: model, events: events)
        model.dataChanged()  // the off-main load starts from a cold cache, like a first visit
        let off = ActivitiesModel()
        off.reload(model: model, events: events)
        await settle(off)
        XCTAssertNotNil(off.shownRange, file: file, line: line)
        XCTAssertFalse(off.showsPlaceholder, file: file, line: line)
        XCTAssertEqual(ActivitiesFingerprint.text(off), ActivitiesFingerprint.text(sync), file: file, line: line)
        XCTAssertGreaterThan(sync.rangeCount ?? 0, 0, file: file, line: line)
    }

    func testOffMainLoadMatchesSynchronousRecompute() async throws {
        let (model, store) = try makeModel()
        let today = Calendar.current.startOfDay(for: Date())
        let days = (0..<3).map { today.addingTimeInterval(-Double($0) * 86400) }
        try fixture(store, days: days)

        let three = DateRangeSelection(kind: .custom, anchor: today, customStart: days[2], customEnd: days[0])
        await compare(model) { model.range = three }
        await compare(model) { model.activitySearch = "git" }
        await compare(model) {
            model.activitySearch = ""
            model.activityFilter = "uncategorized"
        }
        await compare(model) {
            model.activityFilter = nil
            model.activityTimeInterval = DateInterval(start: days[0].addingTimeInterval(9 * 3600), duration: 3600)
        }
        // A single day: the timeline, its calendar lane and the meeting tags.
        let event = CalendarEvent(id: "e1", title: "Team sync", start: days[0].addingTimeInterval(9 * 3600),
                                  end: days[0].addingTimeInterval(10 * 3600), isAllDay: false, attendeeCount: 3,
                                  isDeclined: false, calendarTitle: "Work", colorHex: "#3366FF")
        await compare(model, events: [event]) {
            model.activityTimeInterval = nil
            model.range = DateRangeSelection(kind: .day, anchor: days[0])
        }
    }

    func testPlaceholderShowsUntilTheFirstLoadLands() async throws {
        let (model, store) = try makeModel()
        try fixture(store, days: [Calendar.current.startOfDay(for: Date())])
        let activities = ActivitiesModel()
        XCTAssertNil(activities.shownRange)
        activities.reload(model: model)
        XCTAssertNil(activities.shownRange, "nothing is published before the load lands")
        XCTAssertTrue(activities.showsPlaceholder)
        await settle(activities)
        XCTAssertEqual(activities.shownRange, model.range)
        XCTAssertFalse(activities.showsPlaceholder)
    }

    func testNewerReloadWinsOverAnOlderOne() async throws {
        let (model, store) = try makeModel()
        let today = Calendar.current.startOfDay(for: Date())
        try fixture(store, days: [today, today.addingTimeInterval(-86400)])
        let activities = ActivitiesModel()
        model.range = DateRangeSelection(kind: .last7, anchor: Date())
        activities.reload(model: model)
        model.range = DateRangeSelection(kind: .day, anchor: today.addingTimeInterval(-86400))
        activities.reload(model: model)
        await settle(activities)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(activities.shownRange?.window, model.range.window)
        let sync = ActivitiesModel()
        sync.recompute(model: model)
        XCTAssertEqual(ActivitiesFingerprint.text(activities), ActivitiesFingerprint.text(sync))
    }

    /// A synchronous `recompute` is the latest word too: a slower reload that
    /// finishes after it must not replace it.
    func testRecomputeCancelsAReloadInFlight() async throws {
        let (model, store) = try makeModel()
        let today = Calendar.current.startOfDay(for: Date())
        try fixture(store, days: [today])
        let activities = ActivitiesModel()
        model.range = DateRangeSelection(kind: .last7, anchor: Date())
        activities.reload(model: model)
        let inFlight = activities.loadTask
        model.range = DateRangeSelection(kind: .day, anchor: today)
        activities.recompute(model: model)
        let expected = ActivitiesFingerprint.text(activities)
        await inFlight?.value
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(ActivitiesFingerprint.text(activities), expected)
        XCTAssertEqual(activities.shownRange?.window, model.range.window)
    }

    func testOffMainSpansEqualSynchronousSpans() async throws {
        let (model, store) = try makeModel()
        let today = Calendar.current.startOfDay(for: Date())
        try fixture(store, days: [today, today.addingTimeInterval(-86400)])
        let interval = DateInterval(start: today.addingTimeInterval(-86400 + 9 * 3600), end: today.addingTimeInterval(12 * 3600))
        let loaded = await model.rangedSpansOffMain(for: interval)
        let off = try XCTUnwrap(loaded)
        model.dataChanged()
        let sync = model.rangedSpans(for: interval)
        XCTAssertEqual(off.map(\.span), sync.map(\.span))
        XCTAssertEqual(off.map(\.categoryID), sync.map(\.categoryID))
        XCTAssertGreaterThan(off.count, 50)
        // It was cached for the next caller.
        let cached = await model.rangedSpansOffMain(for: interval)
        let again = try XCTUnwrap(cached)
        XCTAssertEqual(again.map(\.span), off.map(\.span))
    }

    func testUserEditDuringAnOffMainLoadDiscardsIt() async throws {
        let (model, store) = try makeModel()
        let today = Calendar.current.startOfDay(for: Date())
        try fixture(store, days: [today])
        let interval = DateInterval(start: today, end: today.addingTimeInterval(86400))
        let loading = Task { @MainActor in await model.rangedSpansOffMain(for: interval) }
        await Task.yield()  // the load has started and is waiting on its worker
        let before = model.rangedSpans(for: interval).count  // (the sync path may fill the cache first)
        model.dataChanged()
        let late = Span(start: today.addingTimeInterval(23 * 3600), end: today.addingTimeInterval(23 * 3600 + 60),
                        appBundleID: "com.late", appName: "Late", title: nil, url: nil, domain: nil)
        try store.insert(late)
        model.dataChanged()
        let result = await loading.value
        XCTAssertNil(result, "a load that began before an edit is not published")
        XCTAssertEqual(model.rangedSpans(for: interval).count, before + 1, "and it did not poison the cache")
    }

    func testTrackerWriteAfterTheWindowKeepsAnOffMainLoad() async throws {
        let (model, store) = try makeModel()
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = DateInterval(start: today.addingTimeInterval(-86400), end: today)
        try fixture(store, days: [today.addingTimeInterval(-86400)])
        let loading = Task { @MainActor in await model.rangedSpansOffMain(for: yesterday) }
        await Task.yield()
        model.engineDataChangedForTesting(writtenFrom: today.addingTimeInterval(3600))
        let result = await loading.value
        XCTAssertNotNil(result, "a write from today on cannot change yesterday")
        XCTAssertGreaterThan(result?.count ?? 0, 50)
    }
}
