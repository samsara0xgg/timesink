import GRDB
import XCTest
@testable import TimeSinkKit

/// Accessibility reads: counted per health window, flagged after a long unbroken failure run.
final class AXReadHealthTests: XCTestCase {
    func testDegradedNeedsBothTheSpanAndTheCount() {
        var h = AXReadHealth()
        for i in 0..<AXReadHealth.minFailures { h.note(ok: false, at: ts(TimeInterval(i))) }
        XCTAssertFalse(h.isDegraded(at: ts(AXReadHealth.minSpan - 1)), "enough failures, too short")
        XCTAssertTrue(h.isDegraded(at: ts(AXReadHealth.minSpan)))

        var few = AXReadHealth()
        few.note(ok: false, at: ts(0))
        XCTAssertFalse(few.isDegraded(at: ts(AXReadHealth.minSpan * 10)), "long, but too few failures")
    }

    func testOneSuccessClears() {
        var h = AXReadHealth()
        for i in 0..<AXReadHealth.minFailures { h.note(ok: false, at: ts(TimeInterval(i * 10))) }
        XCTAssertTrue(h.isDegraded(at: ts(10_000)))
        h.note(ok: true, at: ts(10_001))
        XCTAssertFalse(h.isDegraded(at: ts(10_002)))
        h.note(ok: false, at: ts(10_003))
        XCTAssertFalse(h.isDegraded(at: ts(10_004)), "the run starts over")
    }

    func testCollectorCountsReadsIntoCaptureHealth() async throws {
        let store = ObservationStore(try AppDatabase.openInMemory())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let collector = ScreenCollector(store: store, imagesRoot: root, paused: false)
        let reads: [Bool?] = [true, false, false, nil, true]       // nil: no AX read this tick
        for (i, read) in reads.enumerated() {
            let sample = Sample(timestamp: ts(TimeInterval(i)), appBundleID: "app.a", appName: "A",
                                windowTitle: nil, url: nil, windowID: 1, axTitleRead: read)
            await collector.tick(now: ts(TimeInterval(i)), sample: sample, spanID: nil)
        }
        await collector.interrupt()
        let rows = try store.health(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.count, 1, "AX reads alone make the window worth keeping")
        XCTAssertEqual(rows[0].axReads, 4)
        XCTAssertEqual(rows[0].axFailed, 2)
    }

    @MainActor
    func testEngineFlagSetAfterThirtyMinutesAndClearedOnSuccess() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = TrackerEngine(spanStore: SpanStore(db), settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        let reads = ReadSwitch()
        engine.windowSampleProvider = { now in
            Sample(timestamp: now, appBundleID: "app.a", appName: "A", windowTitle: nil, url: nil,
                   windowID: 1, axTitleRead: reads.ok)
        }
        reads.ok = false
        for t in stride(from: 0.0, through: AXReadHealth.minSpan - 6, by: 6) { await engine.tickAsync(now: ts(t)) }
        XCTAssertFalse(engine.axReadDegraded)
        await engine.tickAsync(now: ts(AXReadHealth.minSpan))
        XCTAssertTrue(engine.axReadDegraded)
        reads.ok = true
        await engine.tickAsync(now: ts(AXReadHealth.minSpan + 1))
        XCTAssertFalse(engine.axReadDegraded)
    }

    final class ReadSwitch: @unchecked Sendable { var ok = true }
}

final class SelfHealMigrationTests: XCTestCase {
    func testAXCounterColumnsDefaultToZeroAndKeepOldRows() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db, upTo: "v21")
        try db.write { db in
            try db.execute(sql: "INSERT INTO captureHealth (windowStart, windowEnd, checks, ocrFailed) VALUES (?, ?, 7, 3)",
                           arguments: [ts(0), ts(600)])
        }
        try AppDatabase.migrator.migrate(db)
        let rows = try db.read { try CaptureHealth.fetchAll($0) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].checks, 7)
        XCTAssertEqual(rows[0].ocrFailed, 3)
        XCTAssertEqual(rows[0].axReads, 0)
        XCTAssertEqual(rows[0].axFailed, 0)
    }
}
