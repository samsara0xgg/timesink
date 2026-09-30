import XCTest
@testable import TimeSinkKit

@MainActor
final class AwayNoteTests: XCTestCase {
    private func makeModel() throws -> (AppModel, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let settings = SettingsStore(db)
        let model = AppModel(categoryStore: categoryStore, spanStore: spanStore, settings: settings,
                             resolver: CategoryResolver(categoryStore: categoryStore),
                             engine: TrackerEngine(spanStore: spanStore, settings: settings))
        model.observationStore = ObservationStore(db)
        return (model, spanStore)
    }

    /// Recorded until `left`, then a tick at `back`: the ticks before and after.
    private func away(_ model: AppModel, _ store: SpanStore, left: Date, back: Date) throws {
        try store.insert(Span(start: left.addingTimeInterval(-600), end: left, appBundleID: "com.test", appName: "Test",
                              title: nil, url: nil, domain: nil))
        model.observeForAway(now: left)
        model.observeForAway(now: back)
    }

    func testAStretchOfTenMinutesOrMoreIsOffered() throws {
        let (model, store) = try makeModel()
        let left = Date().addingTimeInterval(-1500)
        try away(model, store, left: left, back: Date())
        XCTAssertEqual(model.awayOffer?.start.timeIntervalSince1970 ?? 0, left.timeIntervalSince1970, accuracy: 0.01)
    }

    func testShortAndOvernightStretchesAreNotOffered() throws {
        var (model, store) = try makeModel()
        try away(model, store, left: Date().addingTimeInterval(-500), back: Date())
        XCTAssertNil(model.awayOffer, "under 10 minutes")
        (model, store) = try makeModel()
        try away(model, store, left: Date().addingTimeInterval(-5 * 3600), back: Date())
        XCTAssertNil(model.awayOffer, "over 4 hours")
    }

    func testAtMostFiveADay() throws {
        let (model, store) = try makeModel()
        var asked = 0
        for round in 0..<7 {
            let back = Date().addingTimeInterval(Double(round - 7) * 60)
            model.awayOffer = nil
            model.lastTickAt = nil
            try away(model, store, left: back.addingTimeInterval(-900), back: back)
            if model.awayOffer != nil { asked += 1 }
        }
        XCTAssertEqual(asked, 5)
    }

    func testAnAnswerIsKeptAndSkippingKeepsNothing() throws {
        let (model, store) = try makeModel()
        let left = Date().addingTimeInterval(-1500)
        try away(model, store, left: left, back: Date())
        model.answerAway(label: "午饭", symbol: "fork.knife")
        XCTAssertNil(model.awayOffer)
        let day = DateInterval(start: left.addingTimeInterval(-60), end: Date().addingTimeInterval(60))
        XCTAssertEqual(try model.observationStore?.awayNotes(overlapping: day).map(\.label), ["午饭"])

        try away(model, store, left: Date().addingTimeInterval(-1200), back: Date().addingTimeInterval(1))
        model.answerAway(label: nil, symbol: "")
        XCTAssertEqual(try model.observationStore?.awayNotes(overlapping: day).count, 1)
    }
}
