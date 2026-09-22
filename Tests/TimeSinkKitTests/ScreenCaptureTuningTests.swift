import XCTest
@testable import TimeSinkKit

/// A title change inside one window is checked soon after it, not at the
/// next interval; the interval schedule is untouched otherwise.
final class ScreenCapturePolicyTitleTests: XCTestCase {
    let a = WindowKey(bundleID: "app.a", windowID: 1)

    func testTitleChangeIsCheckedAfterTitleSettle() {
        var p = ScreenCapturePolicy(settleSeconds: 3, checkInterval: 30, titleSettleSeconds: 1)
        var checks: [Int] = []
        for t in 0...45 {
            let title = t < 10 ? "Weixin" : "Eva Wang Resume.pdf"
            if p.tick(now: ts(TimeInterval(t)), window: a, title: title) { checks.append(t) }
        }
        XCTAssertEqual(checks, [3, 11, 41])   // first check; title change at 10 checked at 11; interval restarts there
    }

    func testTitleChangeDuringSettleDoesNotDoubleCheck() {
        var p = ScreenCapturePolicy(settleSeconds: 3, checkInterval: 30, titleSettleSeconds: 1)
        var checks: [Int] = []
        for t in 0...8 {
            let title = t < 2 ? "loading" : "loaded"
            if p.tick(now: ts(TimeInterval(t)), window: a, title: title) { checks.append(t) }
        }
        XCTAssertEqual(checks, [3])
    }

    func testTitleFlapBackWithinSettleStillChecksOnce() {
        var p = ScreenCapturePolicy(settleSeconds: 3, checkInterval: 30, titleSettleSeconds: 2)
        var checks: [Int] = []
        let titles = [5: "b", 6: "a"]  // a → b at 5, back to a at 6
        for t in 0...12 {
            if p.tick(now: ts(TimeInterval(t)), window: a, title: titles[t] ?? (t > 6 ? "a" : (t == 5 ? "b" : "a"))) { checks.append(t) }
        }
        XCTAssertEqual(checks, [3, 8])
    }

    func testDefaultsAreTheTunedValues() {
        let p = ScreenCapturePolicy()
        XCTAssertEqual(p.settleSeconds, 3)
        XCTAssertEqual(p.checkInterval, 10)
        XCTAssertEqual(p.titleSettleSeconds, 1)
    }
}

/// Idle is not absence: the engine keeps handing idle ticks to the collector,
/// so a page being read without input stays observed (and its row extends).
@MainActor
final class TrackerEngineIdleCaptureTests: XCTestCase {
    func testCollectorKeepsLookingWhileIdle() async throws {
        let db = try AppDatabase.openInMemory()
        let store = ObservationStore(db)
        let settings = SettingsStore(db)
        settings.setIdleThreshold(60)
        let engine = TrackerEngine(spanStore: SpanStore(db), settings: settings, observations: store)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let collector = ScreenCollector(store: store, imagesRoot: root, paused: false,
                                        policy: ScreenCapturePolicy(settleSeconds: 3, checkInterval: 10))
        let frame = ScreenCollectorDedupeTests.frame(lit: 0)
        await collector.install { _ in (image: frame, text: "a page being read") }
        engine.screenCollector = collector
        var idle: TimeInterval = 0
        engine.idleSecondsProvider = { idle }
        engine.windowSampleProvider = { now in
            Sample(timestamp: now, appBundleID: "x", appName: "X", windowTitle: "Book", url: nil, windowID: 7)
        }
        for t in 0...3 { await engine.tickAsync(now: ts(TimeInterval(t))) }
        idle = 100                                  // hands off the keyboard, keeps reading
        for t in 4...73 { await engine.tickAsync(now: ts(TimeInterval(t))) }
        // The engine offers ticks fire-and-forget; wait for the actor to drain them.
        for _ in 0..<200 where await collector.health.checks < 8 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // The idle event is backdated by the idle reading (here 100 s before the tick).
        let events = try store.stateEvents(in: DateInterval(start: ts(-1000), end: ts(1000)))
        XCTAssertEqual(events.map(\.kind), ["idle"])
        let rows = try store.captures(overlapping: DateInterval(start: ts(-1), end: ts(1000)))
        XCTAssertEqual(rows.map { "\(Int($0.at.timeIntervalSince(ts(0))))-\(Int($0.lastSeenAt.timeIntervalSince(ts(0))))" }, ["3-73"])
        let health = await collector.health
        XCTAssertEqual(health.checks, 8)
        XCTAssertEqual(health.unchanged, 7)
    }
}

/// Content is judged by signature first and by OCR text second; unchanged
/// content is re-read on the refresh clock so small text changes are caught.
final class ScreenCollectorDedupeTests: XCTestCase {
    let a = WindowKey(bundleID: "app.a", windowID: 1)

    /// A 32x20 grayscale image (one pixel per signature cell) with the first
    /// `lit` cells white on a gray background.
    static func frame(lit: Int) -> CGImage {
        let w = ScreenSignature.columns, h = ScreenSignature.rows
        var cells = [UInt8](repeating: 100, count: w * h)
        for i in 0..<lit { cells[i] = 255 }
        let context = CGContext(data: &cells, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return context.makeImage()!
    }

    final class Scene: @unchecked Sendable {
        var lit = 0
        var text = "hello"
        var ocrRuns = 0
    }

    func makeCollector(refresh: TimeInterval = 120) throws -> (ScreenCollector, ObservationStore, Scene) {
        let store = ObservationStore(try AppDatabase.openInMemory())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let collector = ScreenCollector(store: store, imagesRoot: root, paused: false,
                                        policy: ScreenCapturePolicy(settleSeconds: 3, checkInterval: 10),
                                        refreshInterval: refresh)
        let scene = Scene()
        // The seam stands in for screenshot + OCR: text is what OCR would read now.
        return (collector, store, scene)
    }

    func install(_ collector: ScreenCollector, _ scene: Scene) async {
        await collector.install { _ in (image: Self.frame(lit: scene.lit), text: scene.text) }
    }

    func tick(_ collector: ScreenCollector, _ seconds: ClosedRange<Int>, title: String? = nil) async {
        for t in seconds {
            let sample = Sample(timestamp: ts(TimeInterval(t)), appBundleID: a.bundleID, appName: a.bundleID,
                                windowTitle: title, url: nil, windowID: a.windowID)
            await collector.tick(now: ts(TimeInterval(t)), sample: sample, spanID: nil)
        }
    }

    func rows(_ store: ObservationStore) throws -> [(text: String, at: Int, seen: Int)] {
        try store.captures(overlapping: DateInterval(start: ts(-1), end: ts(10_000))).map {
            ($0.text, Int($0.at.timeIntervalSince(ts(0))), Int($0.lastSeenAt.timeIntervalSince(ts(0))))
        }
    }

    func testSmallVisualChangeWithNewTextIsANewRow() async throws {
        let (collector, store, scene) = try makeCollector()
        await install(collector, scene)
        await tick(collector, 0...3)                 // row 1 at 3
        scene.lit = 20; scene.text = "hello\nnew line"   // 20/640 = 3.1%: under changedFraction, over ocrFraction
        await tick(collector, 4...13)                // re-check at 13: OCR, text differs → row 2
        XCTAssertEqual(try rows(store).map { "\($0.text.count) \($0.at)-\($0.seen)" }, ["5 3-3", "14 13-13"])
    }

    func testSmallVisualChangeWithSameTextExtends() async throws {
        let (collector, store, scene) = try makeCollector()
        await install(collector, scene)
        await tick(collector, 0...3)
        scene.lit = 20                               // cursor moved, clock ticked: same text
        await tick(collector, 4...13)
        XCTAssertEqual(try rows(store).map { "\($0.at)-\($0.seen)" }, ["3-13"])
        let health = await collector.health
        XCTAssertEqual(health.textSame, 1)
        XCTAssertEqual(health.inserted, 1)
        XCTAssertEqual(health.extended, 1)
    }

    func testBigVisualChangeIsANewRowEvenWithSameText() async throws {
        let (collector, store, scene) = try makeCollector()
        await install(collector, scene)
        await tick(collector, 0...3)
        scene.lit = 100                              // 15.6%: an image changed, a page scrolled
        await tick(collector, 4...13)
        XCTAssertEqual(try rows(store).count, 2)
    }

    func testUnchangedSignatureSkipsOCRUntilRefreshThenCatchesTheText() async throws {
        let (collector, store, scene) = try makeCollector(refresh: 30)
        await install(collector, scene)
        await tick(collector, 0...3)                 // row 1 at 3 (read at 3)
        scene.text = "hello\nquiet new line"         // text changed, pixels did not move enough to see
        await tick(collector, 4...23)                // checks at 13 and 23: unchanged signature, not yet stale
        XCTAssertEqual(try rows(store).map { "\($0.at)-\($0.seen)" }, ["3-23"])
        await tick(collector, 24...33)               // check at 33: 30 s since the read → OCR → new row
        XCTAssertEqual(try rows(store).map { "\($0.at)-\($0.seen)" }, ["3-23", "33-33"])
        let health = await collector.health
        XCTAssertEqual(health.checks, 4)
        XCTAssertEqual(health.unchanged, 2)
        XCTAssertEqual(health.inserted, 2)
    }

    func testRefreshWithSameTextOnlyExtendsAndRestartsTheClock() async throws {
        let (collector, store, scene) = try makeCollector(refresh: 30)
        await install(collector, scene)
        await tick(collector, 0...63)                // reads at 3, 33 (refresh, same text), 63 (refresh)
        XCTAssertEqual(try rows(store).map { "\($0.at)-\($0.seen)" }, ["3-63"])
        let health = await collector.health
        XCTAssertEqual(health.textSame, 2)
        XCTAssertEqual(health.unchanged, 4)          // 13, 23, 43, 53
    }

    func testHealthWindowIsWrittenOnInterrupt() async throws {
        let (collector, store, scene) = try makeCollector()
        await install(collector, scene)
        await tick(collector, 0...13)
        await collector.interrupt()
        let rows = try store.health(overlapping: DateInterval(start: ts(-1), end: Date().addingTimeInterval(60)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].checks, 2)
        XCTAssertEqual(rows[0].inserted, 1)
        XCTAssertEqual(rows[0].unchanged, 1)
        XCTAssertEqual(rows[0].windowStart, ts(0))
        let afterwards = await collector.health
        XCTAssertEqual(afterwards.checks, 0)
    }

    func testFailedFramesAreCountedNotStored() async throws {
        let (collector, store, _) = try makeCollector()
        await collector.install { _ in nil }          // the screenshot never comes back
        await tick(collector, 0...13)
        XCTAssertEqual(try rows(store).count, 0)
        let health = await collector.health
        XCTAssertEqual(health.checks, 2)
        XCTAssertEqual(health.screenshotFailed, 2)
        XCTAssertEqual(health.inserted, 0)
    }

    func testTitleChangeInsideAWindowIsCapturedEarly() async throws {
        let (collector, store, scene) = try makeCollector()
        await install(collector, scene)
        await tick(collector, 0...4, title: "Weixin")
        scene.lit = 200; scene.text = "Eva Wang Resume"
        await tick(collector, 5...6, title: "Eva Wang Resume.pdf")   // title change at 5, checked at 6
        XCTAssertEqual(try rows(store).map { "\($0.text) \($0.at)" }, ["hello 3", "Eva Wang Resume 6"])
    }
}
