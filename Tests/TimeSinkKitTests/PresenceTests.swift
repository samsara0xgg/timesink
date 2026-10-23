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
                       Presence(kind: .call, bundleID: "us.zoom.xos", appName: "zoom.us", onScreen: false, output: false))
    }

    func testCallOutputIsTheSameRootAppPlayingAudio() {
        let input = proc(11, "us.zoom.CptHost", input: true)
        XCTAssertEqual(decide([input])?.output, false, "mic only")
        XCTAssertEqual(decide([input, proc(12, "us.zoom.ZoomCefHelper", output: true)])?.output, true, "output from another process of the app")
        XCTAssertEqual(decide([input, proc(13, "us.zoom.CptHost", output: true)])?.output, true, "the audio helper itself")
        XCTAssertEqual(decide([input, proc(21, "com.google.Chrome.helper", output: true)])?.output, false, "another app's output")
    }

    func testTencentMeetingAndQQAreCallApps() {
        let more = apps + [M.App(pid: 60, bundleID: "com.tencent.meeting", name: "腾讯会议", regular: true),
                           M.App(pid: 70, bundleID: "com.tencent.qq", name: "QQ", regular: true)]
        func call(_ audio: [M.AudioProcess]) -> Presence? {
            M.decide(audio: audio, displayAssertionPIDs: [], apps: more, ownPID: 999)
        }
        XCTAssertEqual(call([proc(61, "com.tencent.meeting", input: true)])?.appName, "腾讯会议")
        XCTAssertEqual(call([proc(71, "com.tencent.qq.helper", input: true)])?.bundleID, "com.tencent.qq")
        XCTAssertNil(call([proc(80, "com.tencent.QQMusicMac", input: true)]))
        XCTAssertEqual(call([proc(61, "com.tencent.meeting", input: true), proc(62, "com.tencent.meeting.WemeetLauncher", output: true)])?.output, true)
        XCTAssertEqual(call([proc(71, "com.tencent.qq.helper", input: true), proc(72, "com.tencent.qq.helper.Renderer", output: true)])?.output, true)
    }

    func testDiscordHelperOutputOpensTheCall() {
        let discord = apps + [M.App(pid: 90, bundleID: "com.hnc.Discord", name: "Discord", regular: true)]
        let presence = M.decide(audio: [proc(91, "com.hnc.Discord.helper", input: true), proc(92, "com.hnc.Discord.helper.Renderer", output: true)],
                                displayAssertionPIDs: [], apps: discord, ownPID: 999)
        XCTAssertEqual(presence, Presence(kind: .call, bundleID: "com.hnc.Discord", appName: "Discord", onScreen: false, output: true))
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

    func testCallSpanOpensExtendsAndClosesAtLastSeenAfterTwoMisses() async throws {
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
        XCTAssertEqual(try calls.spans(overlapping: all)[0].end, ts(90), "first miss: still open")
        await engine.tickAsync(now: ts(105))
        rows = try calls.spans(overlapping: all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].end, ts(95), "second miss closes at the last tick that saw the call")
        XCTAssertEqual(rows[0].appBundleID, "us.zoom.xos")
    }

    /// Ticks every 5 s from `from` to `through` with `presence`.
    private func run(_ engine: TrackerEngine, _ presence: Presence?, _ from: TimeInterval, _ through: TimeInterval) async {
        engine.presenceProvider = { presence }
        for t in stride(from: from, through: through, by: 5) { await engine.tickAsync(now: ts(t)) }
    }

    func testOneMissedReadKeepsOneRow() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.idleSecondsProvider = { 0 }
        await run(engine, zoom, 0, 20)
        await run(engine, nil, 25, 25)
        await run(engine, zoom, 30, 60)
        let rows = try calls.spans(overlapping: all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].end, ts(60))
    }

    func testSameAppBackWithinSixtySecondsExtendsTheOldRowAndAfterThatOpensANewOne() async throws {
        for (backAt, expectedRows) in [(80.0, 1), (85.0, 2)] {
            let (engine, _, calls) = try makeEngine()
            engine.idleSecondsProvider = { 0 }
            await run(engine, zoom, 0, 20)             // last seen at 20
            await run(engine, nil, 25, backAt - 5)
            await run(engine, zoom, backAt, backAt)
            let rows = try calls.spans(overlapping: all)
            XCTAssertEqual(rows.count, expectedRows, "back at \(backAt)")
            XCTAssertEqual(rows.last?.end, ts(backAt))
            XCTAssertEqual(rows[0].end, expectedRows == 1 ? ts(backAt) : ts(20))
        }
    }

    func testRestartContinuesTheRecentRow() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.idleSecondsProvider = { 0 }
        let old = try calls.open(at: ts(0), bundleID: "us.zoom.xos", appName: "zoom.us")
        try calls.extend(id: old.id!, end: ts(100))
        await run(engine, zoom, 130, 130)
        let rows = try calls.spans(overlapping: all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].end, ts(130))
    }

    func testAnotherAppsRowIsNotContinued() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.idleSecondsProvider = { 0 }
        let old = try calls.open(at: ts(0), bundleID: "com.hnc.Discord", appName: "Discord")
        try calls.extend(id: old.id!, end: ts(100))
        await run(engine, zoom, 110, 110)
        XCTAssertEqual(try calls.spans(overlapping: all).count, 2)
    }

    func testNewCallNeedsInputAndOutputButAnOpenOneOnlyInput() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.idleSecondsProvider = { 0 }
        let silent = Presence(kind: .call, bundleID: "us.zoom.xos", appName: "zoom.us", output: false)
        await run(engine, silent, 0, 40)
        XCTAssertTrue(try calls.spans(overlapping: all).isEmpty, "mic alone does not open a call")
        await run(engine, zoom, 45, 50)
        XCTAssertEqual(try calls.spans(overlapping: all).count, 1)
        await run(engine, silent, 55, 140)
        let rows = try calls.spans(overlapping: all)
        XCTAssertEqual(rows.count, 1, "silence does not split the call")
        XCTAssertEqual(rows[0].end, ts(135), "and keeps it extending")
    }

    func testVideoIsNotACallSpan() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.presenceProvider = { self.chromeVideo }
        for t in stride(from: 0.0, through: 60, by: 10) { await engine.tickAsync(now: ts(t)) }
        XCTAssertTrue(try calls.spans(overlapping: all).isEmpty)
    }

    func testLockKeepsTheCallAndSleepClosesItAtLastSeen() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.idleSecondsProvider = { 0 }
        await run(engine, zoom, 0, 40)
        engine.suspend(at: ts(45))
        await run(engine, zoom, 50, 100)
        XCTAssertTrue(engine.isSuspended)
        var rows = try calls.spans(overlapping: all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].end, ts(90), "locked ticks keep extending the call")
        engine.suspend(at: ts(103), source: .sleep)
        rows = try calls.spans(overlapping: all)
        XCTAssertEqual(rows[0].end, ts(100), "sleep closes at the last tick that saw the call")
        await run(engine, zoom, 105, 200)
        XCTAssertEqual(try calls.spans(overlapping: all).count, 1, "ticks while asleep do not reopen it")
        XCTAssertEqual(try calls.spans(overlapping: all)[0].end, ts(100))
    }

    func testCallEndingWhileLockedClosesAfterTwoMisses() async throws {
        let (engine, _, calls) = try makeEngine()
        engine.idleSecondsProvider = { 0 }
        await run(engine, zoom, 0, 20)
        engine.suspend(at: ts(22))
        await run(engine, nil, 25, 35)
        XCTAssertEqual(try calls.spans(overlapping: all)[0].end, ts(20))
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

@MainActor
final class TrackerEngineLockHealTests: XCTestCase {
    func testLockedSuspensionHealsWhenUnlockedAndInputIsRecent() async throws {
        let db = try AppDatabase.openInMemory()
        let observations = ObservationStore(db)
        let engine = TrackerEngine(spanStore: SpanStore(db), settings: SettingsStore(db), observations: observations)
        engine.windowSampleProvider = { Sample(timestamp: $0, appBundleID: "com.apple.finder", appName: "Finder", windowTitle: "Desktop", url: nil) }
        var locked = true
        var idle: TimeInterval = 1
        engine.screenLockedProvider = { locked }
        engine.idleSecondsProvider = { idle }
        await engine.tickAsync(now: ts(0))
        engine.suspend(at: ts(1))
        await engine.tickAsync(now: ts(2))
        XCTAssertTrue(engine.isSuspended, "still locked")
        locked = false; idle = 30
        await engine.tickAsync(now: ts(13))
        XCTAssertTrue(engine.isSuspended, "unlocked but no input just now")
        idle = 2
        await engine.tickAsync(now: ts(14))
        XCTAssertFalse(engine.isSuspended)
        XCTAssertNotNil(engine.latestSample, "sampling again")
        let events = try observations.stateEvents(in: DateInterval(start: ts(-1), end: ts(20)))
        XCTAssertEqual(events.map(\.kind), ["lock", "unlock"])
        XCTAssertEqual(events.last?.at, ts(14))
    }

    func testFreshLockIsNotHealedUntilTenSecondsOld() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = TrackerEngine(spanStore: SpanStore(db), settings: SettingsStore(db))
        engine.windowSampleProvider = { Sample(timestamp: $0, appBundleID: "com.apple.finder", appName: "Finder", windowTitle: "Desktop", url: nil) }
        engine.screenLockedProvider = { false }
        engine.idleSecondsProvider = { 0 }
        engine.suspend(at: ts(0))
        await engine.tickAsync(now: ts(1))
        XCTAssertTrue(engine.isSuspended, "lock flag may lag the notification")
        await engine.tickAsync(now: ts(11))
        XCTAssertFalse(engine.isSuspended)
    }

    func testSleepIsNotHealedByATick() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = TrackerEngine(spanStore: SpanStore(db), settings: SettingsStore(db))
        engine.windowSampleProvider = { Sample(timestamp: $0, appBundleID: "com.apple.finder", appName: "Finder", windowTitle: "Desktop", url: nil) }
        engine.screenLockedProvider = { false }
        engine.idleSecondsProvider = { 0 }
        engine.suspend(at: ts(0), source: .sleep)
        await engine.tickAsync(now: ts(1))
        XCTAssertTrue(engine.isSuspended)
    }
}

@MainActor
final class TrackerEngineHandsOffTests: XCTestCase {
    private let zoom = Presence(kind: .call, bundleID: "us.zoom.xos", appName: "zoom.us")
    private var idle: TimeInterval = 0

    private func makeEngine() throws -> (TrackerEngine, SpanStore, ObservationStore) {
        let db = try AppDatabase.openInMemory()
        let observations = ObservationStore(db), store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db), observations: observations)
        engine.windowSampleProvider = { Sample(timestamp: $0, appBundleID: "us.zoom.xos", appName: "zoom.us", windowTitle: "Standup", url: nil) }
        engine.idleSecondsProvider = { self.idle }
        engine.screenLockedProvider = { true }
        engine.presenceProvider = { self.zoom }
        return (engine, store, observations)
    }
    private func events(_ observations: ObservationStore) throws -> [String] {
        try observations.stateEvents(in: DateInterval(start: ts(-1), end: ts(10_000))).map { "\($0.kind)@\(Int($0.at.timeIntervalSince(ts(0))))" }
    }

    func testHandsOffAtLastInputAndHandsOnWhenInputReturnsWithoutDroppingScreenTime() async throws {
        let (engine, store, observations) = try makeEngine()
        for t in stride(from: 0.0, through: 100, by: 10) { idle = t; await engine.tickAsync(now: ts(t)) }
        XCTAssertEqual(try events(observations), [], "under the threshold")
        for t in stride(from: 110.0, through: 400, by: 10) { idle = t - 20; await engine.tickAsync(now: ts(t)) }
        idle = 0
        await engine.tickAsync(now: ts(410))
        await engine.tickAsync(now: ts(420))
        XCTAssertEqual(try events(observations), ["hands_off@20", "hands_on@410"])
        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(1000)))
        XCTAssertEqual(rows.count, 1, "one unbroken span")
        XCTAssertGreaterThan(rows[0].duration, 400)
    }

    func testExemptionEndingWhileHandsOffLeavesItToIdle() async throws {
        let (engine, _, observations) = try makeEngine()
        idle = 200
        await engine.tickAsync(now: ts(300))
        engine.presenceProvider = { nil }
        idle = 400
        await engine.tickAsync(now: ts(500))
        XCTAssertEqual(try events(observations), ["hands_off@100", "idle@500"])
        idle = 0
        await engine.tickAsync(now: ts(510))
        XCTAssertEqual(try events(observations), ["hands_off@100", "idle@500", "active@510"], "no hands_on")
    }

    func testLockWhileHandsOffWritesNoHandsOn() async throws {
        let (engine, _, observations) = try makeEngine()
        idle = 200
        await engine.tickAsync(now: ts(300))
        engine.suspend(at: ts(310))
        engine.resume(source: .unlock, at: ts(320))
        idle = 0
        await engine.tickAsync(now: ts(330))
        let kinds = try events(observations)
        XCTAssertEqual(kinds, ["hands_off@100", "lock@310", "unlock@320"])
    }

    func testNoHandsOffWithoutAPresenceExemption() async throws {
        let (engine, _, observations) = try makeEngine()
        engine.presenceProvider = { Presence(kind: .call, bundleID: "us.zoom.xos", appName: "zoom.us", onScreen: false) }
        idle = 200
        await engine.tickAsync(now: ts(300))
        XCTAssertEqual(try events(observations), ["idle@100"])
    }
}

