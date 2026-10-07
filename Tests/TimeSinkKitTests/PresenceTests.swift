import XCTest
@testable import TimeSinkKit

final class PresenceDecisionTests: XCTestCase {
    typealias M = PresenceMonitor
    private let apps = [
        M.App(pid: 10, bundleID: "us.zoom.xos", name: "zoom.us", regular: true),
        M.App(pid: 20, bundleID: "com.google.Chrome", name: "Google Chrome", regular: true),
        M.App(pid: 30, bundleID: "com.netease.163music", name: "NetEase Music", regular: true),
        M.App(pid: 40, bundleID: "com.apple.finder", name: "Finder", regular: true),
        M.App(pid: 50, bundleID: "org.python.jarvis", name: "python", regular: false),
    ]
    private func proc(_ pid: pid_t, _ id: String, input: Bool = false, output: Bool = false) -> M.AudioProcess {
        .init(pid: pid, bundleID: id, input: input, output: output)
    }
    private func decide(_ audio: [M.AudioProcess], assertions: [pid_t] = []) -> Presence? {
        M.decide(audio: audio, displayAssertionPIDs: assertions, apps: apps, ownPID: 999)
    }

    func testZoomHelperInputIsCallReportedAsMainApp() {
        XCTAssertEqual(decide([proc(11, "us.zoom.CptHost", input: true)]),
                       Presence(kind: .call, bundleID: "us.zoom.xos", appName: "zoom.us", onScreen: false))
    }

    func testCallIsOnScreenOnlyWhileItsAppKeepsTheDisplayAwake() {
        let input = proc(11, "us.zoom.CptHost", input: true)
        XCTAssertEqual(decide([input])?.onScreen, false, "voice only")
        XCTAssertEqual(decide([input], assertions: [10])?.onScreen, true, "video meeting")
        XCTAssertEqual(decide([input], assertions: [20])?.onScreen, false, "another app's assertion")
    }

    func testAlwaysOnAssistantMicIsNotACall() {
        XCTAssertNil(decide([proc(50, "org.python.jarvis", input: true)]))
    }

    func testVideoNeedsDisplayAssertionAndAudioOutputFromSameApp() {
        let helper = proc(21, "com.google.Chrome.helper", output: true)
        XCTAssertEqual(decide([helper], assertions: [20]), Presence(kind: .video, bundleID: "com.google.Chrome", appName: "Google Chrome"))
        XCTAssertNil(decide([helper], assertions: []), "audio alone")
        XCTAssertNil(decide([], assertions: [20]), "caffeinate-style display assertion, no audio")
        XCTAssertNil(decide([proc(30, "com.netease.163music", output: true)], assertions: [20]), "audio from another app")
    }

    func testAssertionHeldByHelperResolvesToItsApp() {
        let helper = proc(21, "com.google.Chrome.helper", output: true)
        XCTAssertEqual(decide([helper], assertions: [21])?.bundleID, "com.google.Chrome")
    }

    func testOwnAssertionIgnored() {
        XCTAssertNil(M.decide(audio: [proc(20, "com.google.Chrome", output: true)], displayAssertionPIDs: [20], apps: apps, ownPID: 20))
    }

    func testCallWinsOverVideo() {
        let audio = [proc(21, "com.google.Chrome.helper", output: true), proc(11, "us.zoom.CptHost", input: true)]
        XCTAssertEqual(decide(audio, assertions: [20])?.kind, .call)
    }
}

@MainActor
final class TrackerEnginePresenceTests: XCTestCase {
    private let zoom = Presence(kind: .call, bundleID: "us.zoom.xos", appName: "zoom.us")
    private let chromeVideo = Presence(kind: .video, bundleID: "com.google.Chrome", appName: "Google Chrome")
    private let voiceCall = Presence(kind: .call, bundleID: "com.hnc.Discord", appName: "Discord", onScreen: false)

    func testVoiceOnlyCallIsALaneNotScreenTime() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.presenceProvider = { self.voiceCall }
        engine.idleSecondsProvider = { 120 }
        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(engine.latestSample?.appBundleID, "com.apple.finder", "no hands-off swap")
        engine.idleSecondsProvider = { 600 }
        await engine.tickAsync(now: ts(1))
        XCTAssertTrue(engine.isSuspended, "idle as usual")
        XCTAssertEqual(try calls.spans(overlapping: all).count, 1, "still drawn on the call lane")
    }

    private func makeEngine() throws -> (TrackerEngine, SpanStore, CallSpanStore) {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db), calls = CallSpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.callStore = calls
        engine.windowSampleProvider = { Sample(timestamp: $0, appBundleID: "com.apple.finder", appName: "Finder", windowTitle: "Desktop", url: nil) }
        return (engine, store, calls)
    }
    private let all = DateInterval(start: ts(-1), end: ts(100_000))

    func testPresenceExemptsIdle() async throws {
        let (engine, _, _) = try makeEngine()
        engine.idleSecondsProvider = { 600 }
        engine.presenceProvider = { self.chromeVideo }
        await engine.tickAsync(now: ts(0))
        XCTAssertFalse(engine.isSuspended)
        engine.presenceProvider = { nil }
        await engine.tickAsync(now: ts(1))
        XCTAssertTrue(engine.isSuspended)
    }

    func testHandsOffTimeGoesToPresenceAppOnlyAfterSixtySeconds() async throws {
        let (engine, _, _) = try makeEngine()
        engine.presenceProvider = { self.zoom }
        engine.idleSecondsProvider = { 59 }
        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(engine.latestSample?.appBundleID, "com.apple.finder")
        engine.idleSecondsProvider = { 60 }
        await engine.tickAsync(now: ts(1))
        XCTAssertEqual(engine.latestSample?.appBundleID, "us.zoom.xos")
        XCTAssertEqual(engine.latestSample?.appName, "zoom.us")
        XCTAssertNil(engine.latestSample?.windowTitle)
    }

    func testPresenceAppFrontmostKeepsItsRealSample() async throws {
        let (engine, _, _) = try makeEngine()
        engine.windowSampleProvider = { Sample(timestamp: $0, appBundleID: "us.zoom.xos", appName: "zoom.us", windowTitle: "Standup", url: nil) }
        engine.presenceProvider = { self.zoom }
        engine.idleSecondsProvider = { 500 }
        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(engine.latestSample?.windowTitle, "Standup")
    }

    func testExemptionEndKeepsPresenceSpan() async throws {
        let (engine, store, _) = try makeEngine()
        engine.presenceProvider = { self.zoom }
        engine.idleSecondsProvider = { 9999 }
        for t in stride(from: 0.0, through: 595, by: 5) { await engine.tickAsync(now: ts(t)) }
        engine.presenceProvider = { nil }
        engine.idleSecondsProvider = { 600 }
        await engine.tickAsync(now: ts(600))
        XCTAssertTrue(engine.isSuspended)
        let rows = try store.spans(overlapping: all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].appBundleID, "us.zoom.xos")
        XCTAssertGreaterThan(rows[0].duration, 500)
    }

    func testCallSpanOpensExtendsAndClosesAtCallEnd() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.idleSecondsProvider = { 0 }
        engine.presenceProvider = { self.zoom }
        for t in stride(from: 0.0, through: 95, by: 5) { await engine.tickAsync(now: ts(t)) }
        var rows = try calls.spans(overlapping: all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].start, ts(0))
        XCTAssertEqual(rows[0].end, ts(90), "extended only every 30 s")
        engine.presenceProvider = { nil }
        await engine.tickAsync(now: ts(100))
        rows = try calls.spans(overlapping: all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].end, ts(100))
        XCTAssertEqual(rows[0].appBundleID, "us.zoom.xos")
    }

    func testVideoIsNotACallSpan() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.presenceProvider = { self.chromeVideo }
        for t in stride(from: 0.0, through: 60, by: 10) { await engine.tickAsync(now: ts(t)) }
        XCTAssertTrue(try calls.spans(overlapping: all).isEmpty)
    }

    func testSuspendClosesCallAndLockedTicksDoNotReopenIt() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.idleSecondsProvider = { 0 }
        engine.presenceProvider = { self.zoom }
        for t in stride(from: 0.0, through: 40, by: 10) { await engine.tickAsync(now: ts(t)) }
        engine.suspend(at: ts(45))
        await engine.tickAsync(now: ts(50))
        await engine.tickAsync(now: ts(90))
        let rows = try calls.spans(overlapping: all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].end, ts(45))
    }
}

final class CallSpanStoreTests: XCTestCase {
    func testMigrationCreatesTable() throws {
        let db = try AppDatabase.openInMemory()
        XCTAssertTrue(try db.read { try $0.tableExists("callSpan") })
    }

    func testOverlapQueryAndMeetingTagging() throws {
        let store = CallSpanStore(try AppDatabase.openInMemory())
        let call = try store.open(at: ts(0), bundleID: "us.zoom.xos", appName: "zoom.us")
        try store.extend(id: call.id!, end: ts(1800))
        XCTAssertEqual(try store.spans(overlapping: DateInterval(start: ts(900), end: ts(2000))).count, 1)
        XCTAssertTrue(try store.spans(overlapping: DateInterval(start: ts(1800), end: ts(2000))).isEmpty)

        let stored = try store.spans(overlapping: DateInterval(start: ts(0), end: ts(2000)))
        let item = CategorizedSpan(span: Span(id: 1, start: ts(0), end: ts(1000), appBundleID: "us.zoom.xos",
                                              appName: "zoom.us", title: nil, url: nil, domain: nil), categoryID: "communication")
        let tagged = MeetingTagger.tagged(items: [item], events: stored.map(\.asMeetingEvent))
        XCTAssertEqual(tagged.spanIDs, [1])
        XCTAssertEqual(tagged.seconds, 1000)
    }
}
