import XCTest
@testable import TimeSinkKit



final class ScreenCapturePolicyTests: XCTestCase {
    let a = WindowKey(bundleID: "app.a", windowID: 1)
    let b = WindowKey(bundleID: "app.b", windowID: 2)

    func testFirstCheckWaitsForSettle() {
        var p = ScreenCapturePolicy(settleSeconds: 3, checkInterval: 30)
        XCTAssertFalse(p.tick(now: ts(0), window: a))
        XCTAssertFalse(p.tick(now: ts(2), window: a))
        XCTAssertTrue(p.tick(now: ts(3), window: a))
    }

    func testSwitchingWindowsRestartsSettle() {
        var p = ScreenCapturePolicy(settleSeconds: 3, checkInterval: 30)
        _ = p.tick(now: ts(0), window: a)
        XCTAssertFalse(p.tick(now: ts(2), window: b))
        XCTAssertFalse(p.tick(now: ts(4), window: b))   // 2s on b
        XCTAssertTrue(p.tick(now: ts(5), window: b))
    }

    func testSameWindowRechecksEveryInterval() {
        var p = ScreenCapturePolicy(settleSeconds: 3, checkInterval: 30)
        var checks: [Int] = []
        for t in 0...70 where p.tick(now: ts(TimeInterval(t)), window: a) { checks.append(t) }
        XCTAssertEqual(checks, [3, 33, 63])
    }

    func testNilWindowNeverChecksAndResets() {
        var p = ScreenCapturePolicy(settleSeconds: 3, checkInterval: 30)
        _ = p.tick(now: ts(0), window: a)
        XCTAssertFalse(p.tick(now: ts(1), window: nil))
        XCTAssertFalse(p.tick(now: ts(10), window: nil))
        XCTAssertFalse(p.tick(now: ts(11), window: a))  // settle restarted
        XCTAssertTrue(p.tick(now: ts(14), window: a))
    }

    func testStaleTickIsIgnored() {
        var p = ScreenCapturePolicy(settleSeconds: 3, checkInterval: 30)
        _ = p.tick(now: ts(10), window: a)
        XCTAssertFalse(p.tick(now: ts(5), window: a))
        XCTAssertTrue(p.tick(now: ts(13), window: a))
    }

    func testSegmentAdvancesOnWindowChangeAndTickGap() {
        var p = ScreenCapturePolicy(settleSeconds: 3, checkInterval: 30, maxTickGap: 3)
        _ = p.tick(now: ts(0), window: a)
        let first = p.segment
        for t in 1...3 { _ = p.tick(now: ts(TimeInterval(t)), window: a) }
        XCTAssertEqual(p.segment, first)                     // steady ticks: same segment
        _ = p.tick(now: ts(4), window: nil)                  // paused / excluded app
        _ = p.tick(now: ts(5), window: a)
        XCTAssertEqual(p.segment, first + 2)
        for t in 6...8 { _ = p.tick(now: ts(TimeInterval(t)), window: a) }
        XCTAssertEqual(p.segment, first + 2)
        XCTAssertFalse(p.tick(now: ts(60), window: a))       // no ticks while locked: new segment, settle restarts
        XCTAssertEqual(p.segment, first + 3)
        XCTAssertFalse(p.tick(now: ts(62), window: a))
        XCTAssertTrue(p.tick(now: ts(63), window: a))
        XCTAssertEqual(p.segment, first + 3)
    }
}

/// Content dedupe is separate from the observation segment: the same frame
/// seen again after leaving the window, pausing, or a lock gap is a new row.
final class ScreenCollectorSegmentTests: XCTestCase {
    let a = WindowKey(bundleID: "app.a", windowID: 1)
    let b = WindowKey(bundleID: "app.b", windowID: 2)

    static func frame(gray: UInt8) -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: CGFloat(gray) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    func makeCollector() throws -> (ScreenCollector, ObservationStore) {
        let store = ObservationStore(try AppDatabase.openInMemory())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (ScreenCollector(store: store, imagesRoot: root, paused: false), store)
    }

    /// Every window always shows the same unchanging frame, so any new row
    /// comes from the segment logic, never from a content change.
    func install(_ collector: ScreenCollector) async {
        let frame = Self.frame(gray: 100)
        await collector.install { key in (image: frame, text: key.bundleID) }
    }

    func tick(_ collector: ScreenCollector, _ key: WindowKey, _ seconds: ClosedRange<Int>) async {
        for t in seconds {
            let sample = Sample(timestamp: ts(TimeInterval(t)), appBundleID: key.bundleID, appName: key.bundleID,
                                windowTitle: nil, url: nil, windowID: key.windowID)
            await collector.tick(now: ts(TimeInterval(t)), sample: sample, spanID: nil)
        }
    }

    func rows(_ store: ObservationStore) throws -> [(String, TimeInterval, TimeInterval)] {
        try store.captures(overlapping: DateInterval(start: ts(-1), end: ts(10_000))).map {
            ($0.appBundleID, $0.at.timeIntervalSince(ts(0)), $0.lastSeenAt.timeIntervalSince(ts(0)))
        }
    }

    func testReturningToAWindowStartsANewRow() async throws {
        let (collector, store) = try makeCollector()
        await install(collector)
        await tick(collector, a, 0...3)      // A settles at 3: row 1
        await tick(collector, b, 4...7)      // B settles at 7: row 2
        await tick(collector, a, 8...40)     // back on A: settles at 11: row 3, re-check at 41 extends it
        await tick(collector, a, 41...41)
        XCTAssertEqual(try rows(store).map { "\($0.0) \(Int($0.1))-\(Int($0.2))" },
                       ["app.a 3-3", "app.b 7-7", "app.a 11-41"])
    }

    func testPauseAndResumeStartsANewRow() async throws {
        let (collector, store) = try makeCollector()
        await install(collector)
        await tick(collector, a, 0...3)
        await collector.setPaused(true)
        await tick(collector, a, 4...20)
        await collector.setPaused(false)
        await tick(collector, a, 21...24)
        XCTAssertEqual(try rows(store).map { "\(Int($0.1))-\(Int($0.2))" }, ["3-3", "24-24"])
        let events = try store.stateEvents(in: DateInterval(start: ts(-1), end: Date().addingTimeInterval(60)))
        XCTAssertEqual(events.map(\.kind), ["pause", "resume"])
    }

    func testTickGapAsWhileLockedStartsANewRow() async throws {
        let (collector, store) = try makeCollector()
        await install(collector)
        await tick(collector, a, 0...33)     // row 1 at 3, extended by the 33 s re-check
        await tick(collector, a, 300...303)  // the engine did not tick while locked
        XCTAssertEqual(try rows(store).map { "\(Int($0.1))-\(Int($0.2))" }, ["3-33", "303-303"])
    }
}

final class ScreenSignatureTests: XCTestCase {
    func testSmallLocalChangeIsNotNewContent() {
        let base = [UInt8](repeating: 100, count: 640)
        var cursor = base
        for i in 0..<30 { cursor[i] = 255 }            // ~4.7% of cells
        XCTAssertFalse(ScreenSignature.changed(base, cursor))
    }

    func testTenPercentIsNewContent() {
        let base = [UInt8](repeating: 100, count: 640)
        var page = base
        for i in 0..<64 { page[i] = 255 }              // exactly 10%
        XCTAssertTrue(ScreenSignature.changed(base, page))
    }

    func testTinyLuminanceDriftIsIgnored() {
        let base = [UInt8](repeating: 100, count: 640)
        let dim = [UInt8](repeating: 110, count: 640)  // below cellDelta everywhere
        XCTAssertFalse(ScreenSignature.changed(base, dim))
    }

    func testMismatchedSizesCountAsChanged() {
        XCTAssertTrue(ScreenSignature.changed([1, 2], [1, 2, 3]))
    }
}

final class CaptureRetentionTests: XCTestCase {
    func testDayFoldersOlderThanSevenDaysExpire() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 15))!
        XCTAssertTrue(CaptureRetention.isExpired(dayFolder: "2026-09-12", now: now, calendar: cal, days: 7))
        XCTAssertFalse(CaptureRetention.isExpired(dayFolder: "2026-09-13", now: now, calendar: cal, days: 7))
        XCTAssertFalse(CaptureRetention.isExpired(dayFolder: "2026-09-20", now: now, calendar: cal, days: 7))
    }
}

final class ObservationStoreTests: XCTestCase {
    func testCaptureRoundTripExtendAndForgetImages() throws {
        let db = try AppDatabase.openInMemory()
        let store = ObservationStore(db)
        let old = ts(0), recent = ts(10 * 86400)
        let a = try store.insert(Capture(at: old, lastSeenAt: old, appBundleID: "x", appName: "X",
                                         windowID: 7, title: "t", spanID: 3, text: "hello", imagePath: "d/1.jpg"))
        try store.insert(Capture(at: recent, lastSeenAt: recent, appBundleID: "x", appName: "X",
                                 windowID: 7, title: nil, spanID: nil, text: "", imagePath: "d/2.jpg"))
        try store.extend(id: a.id!, lastSeenAt: ts(100))
        try store.forgetImages(before: ts(86400))

        let rows = try store.captures(overlapping: DateInterval(start: ts(50), end: ts(11 * 86400)))
        XCTAssertEqual(rows.map(\.id), [a.id, rows[1].id])
        XCTAssertEqual(rows[0].lastSeenAt, ts(100))
        XCTAssertNil(rows[0].imagePath)          // old image forgotten, text kept
        XCTAssertEqual(rows[0].text, "hello")
        XCTAssertEqual(rows[1].imagePath, "d/2.jpg")
        XCTAssertEqual(store.summary(since: ts(5 * 86400)).count, 1)
    }

    func testStateEventsAreOrdered() throws {
        let db = try AppDatabase.openInMemory()
        let store = ObservationStore(db)
        store.logState("lock", at: ts(5))
        store.logState("start", at: ts(1))
        let events = try store.stateEvents(in: DateInterval(start: ts(0), end: ts(10)))
        XCTAssertEqual(events.map(\.kind), ["start", "lock"])
    }
}

/// The engine writes a reason for every stop/resume it decides itself.
@MainActor
final class TrackerEngineStateEventTests: XCTestCase {
    func testIdleLockAndUnlockAreLogged() async throws {
        let db = try AppDatabase.openInMemory()
        let store = ObservationStore(db)
        let settings = SettingsStore(db)
        settings.setIdleThreshold(60)
        let engine = TrackerEngine(spanStore: SpanStore(db), settings: settings, observations: store)
        var idle: TimeInterval = 0
        engine.idleSecondsProvider = { idle }
        engine.windowSampleProvider = { now in
            Sample(timestamp: now, appBundleID: "x", appName: "X", windowTitle: nil, url: nil)
        }

        await engine.tickAsync(now: ts(0))
        idle = 61
        await engine.tickAsync(now: ts(61))      // becomes idle, backdated to ts(0)
        await engine.tickAsync(now: ts(62))      // still idle: no second event
        idle = 0
        await engine.tickAsync(now: ts(63))      // active again
        engine.suspend(at: ts(70), source: .sleep)
        engine.resume(source: .unlock)

        let events = try store.stateEvents(in: DateInterval(start: ts(-1), end: Date().addingTimeInterval(60)))
        XCTAssertEqual(events.map(\.kind), ["idle", "active", "sleep", "unlock"])
        XCTAssertEqual(events[0].at, ts(0))
    }
}
