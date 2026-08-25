import XCTest
@testable import TimeSinkKit

final class ChromeThrottleTests: XCTestCase {
    func testFetchOnTitleChangeOrTimeout() {
        var t = ChromeThrottle(interval: 5)
        XCTAssertTrue(t.shouldFetch(title: "A", at: ts(0)))
        t.noteFetched(title: "A", at: ts(0))
        XCTAssertFalse(t.shouldFetch(title: "A", at: ts(2)))   // 同标题未超时
        XCTAssertTrue(t.shouldFetch(title: "B", at: ts(2)))    // 标题变了
        XCTAssertTrue(t.shouldFetch(title: "A", at: ts(6)))    // 超时
    }
}

/// Regression coverage for the lock/sleep-vs-idle suspension bug: a single
/// shared `isSuspended` flag used to be cleared by the very next tick after
/// a lock/sleep (idle reads ~0-1s right after), silently reopening a span
/// behind the lock screen. `SuspensionState` splits the two causes so that
/// can't happen; these tests exercise it directly, without any of
/// `TrackerEngine`'s OS-dependent sampling machinery.
final class SuspensionStateTests: XCTestCase {
    func testLockSuspends() {
        var s = SuspensionState()
        XCTAssertTrue(s.suspendSystem())
        XCTAssertTrue(s.isSuspended)
        XCTAssertTrue(s.systemSuspended)
    }

    func testSuspendSystemIsIdempotent() {
        var s = SuspensionState()
        XCTAssertTrue(s.suspendSystem())
        XCTAssertFalse(s.suspendSystem())
    }

    /// The actual bug: a tick with low idle seconds, while system-suspended,
    /// must not sample and must not touch `idleSuspended`.
    func testTickWhileSystemSuspendedStaysSuspendedAndDoesNotSample() {
        var s = SuspensionState()
        s.suspendSystem()
        XCTAssertEqual(s.tick(idleSeconds: 1, threshold: 180), .systemSuspended)
        XCTAssertTrue(s.systemSuspended)
        XCTAssertFalse(s.idleSuspended)
        XCTAssertTrue(s.isSuspended)
        // Repeated ticks (simulating many seconds locked) keep behaving the
        // same way -- no churn clears it.
        XCTAssertEqual(s.tick(idleSeconds: 3, threshold: 180), .systemSuspended)
        XCTAssertTrue(s.isSuspended)
    }

    func testUnlockResumes() {
        var s = SuspensionState()
        s.suspendSystem()
        s.unlock()
        XCTAssertFalse(s.isSuspended)
        XCTAssertEqual(s.tick(idleSeconds: 0, threshold: 180), .active)
    }

    /// Wake recalibration: a `didWakeNotification` alone must not resume if
    /// the screen is still locked -- only the later `screenIsUnlocked`
    /// (modeled here as `unlock()`) clears it.
    func testWakeWhileStillLockedStaysSuspended() {
        var s = SuspensionState()
        s.suspendSystem()
        s.wake(screenStillLocked: true)
        XCTAssertTrue(s.isSuspended)
        XCTAssertEqual(s.tick(idleSeconds: 0, threshold: 180), .systemSuspended)
        s.unlock()
        XCTAssertFalse(s.isSuspended)
    }

    func testWakeWhileUnlockedResumes() {
        var s = SuspensionState()
        s.suspendSystem()
        s.wake(screenStillLocked: false)
        XCTAssertFalse(s.isSuspended)
    }

    /// The idle path is unaffected by the system/idle split: crossing the
    /// threshold sets `idleSuspended` (once), and dropping back below it
    /// clears `idleSuspended` -- `systemSuspended` never enters into it.
    func testIdlePathUnaffectedBySystemSplit() {
        var s = SuspensionState()
        XCTAssertEqual(s.tick(idleSeconds: 200, threshold: 180), .becameIdle)
        XCTAssertTrue(s.idleSuspended)
        XCTAssertFalse(s.systemSuspended)
        XCTAssertEqual(s.tick(idleSeconds: 200, threshold: 180), .stillIdle)
        XCTAssertEqual(s.tick(idleSeconds: 5, threshold: 180), .active)
        XCTAssertFalse(s.idleSuspended)
        XCTAssertFalse(s.isSuspended)
    }
}

final class ChromeFetchBackoffTests: XCTestCase {
    func testFirstTwoFailuresDoNotDelay() {
        var b = ChromeFetchBackoff()
        XCTAssertTrue(b.shouldAttempt(at: ts(0)))
        b.noteFailure(at: ts(0))
        XCTAssertTrue(b.shouldAttempt(at: ts(1)))
        b.noteFailure(at: ts(1))
        XCTAssertTrue(b.shouldAttempt(at: ts(2)))
    }

    func testThirdFailureStartsExponentialDelay() {
        var b = ChromeFetchBackoff()
        b.noteFailure(at: ts(0)); b.noteFailure(at: ts(1)); b.noteFailure(at: ts(2))
        // 3 次失败后延迟 2s：3s 时仍在退避窗口内，4s 后放行
        XCTAssertFalse(b.shouldAttempt(at: ts(3)))
        XCTAssertTrue(b.shouldAttempt(at: ts(4.1)))
    }

    func testDelayCapsAt60Seconds() {
        var b = ChromeFetchBackoff()
        for i in 0..<20 { b.noteFailure(at: ts(Double(i))) }
        XCTAssertFalse(b.shouldAttempt(at: ts(20 + 59)))
        XCTAssertTrue(b.shouldAttempt(at: ts(19 + 61)))
    }

    func testSuccessResets() {
        var b = ChromeFetchBackoff()
        for i in 0..<6 { b.noteFailure(at: ts(Double(i))) }
        XCTAssertTrue(b.isDegraded)
        b.noteSuccess()
        XCTAssertFalse(b.isDegraded)
        XCTAssertTrue(b.shouldAttempt(at: ts(6)))
    }

    func testDegradedAfterFiveConsecutiveFailures() {
        var b = ChromeFetchBackoff()
        for i in 0..<4 { b.noteFailure(at: ts(Double(i))) }
        XCTAssertFalse(b.isDegraded)
        b.noteFailure(at: ts(4))
        XCTAssertTrue(b.isDegraded)
    }
}

@MainActor
final class TrackerEngineChromeCacheTests: XCTestCase {
    private func makeEngine() throws -> (TrackerEngine, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        // Hermetic: without this, tick(now:) reads the host's real idle time
        // and, whenever the machine has actually been idle past the default
        // threshold, returns before sampling -- making these tests pass or
        // fail depending on whether the person running them stepped away.
        engine.idleSecondsProvider = { 0 }
        return (engine, store)
    }

    private func chromeSample(at date: Date) -> Sample {
        Sample(timestamp: date, appBundleID: "com.google.Chrome",
               appName: "Google Chrome", windowTitle: "AX Title", url: nil)
    }

    func testFetchFailureFallsBackToAXTitleInsteadOfStaleURL() throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { [self] in chromeSample(at: Date()) }
        // Automation is authorized in this scenario -- the AX-title fallback
        // is only safe to observe when we can confirm the window isn't
        // incognito, and being authorized is what lets a successful fetch
        // confirm that.
        engine.chromeAutomationAuthorizedProvider = { true }

        // 先成功一次：缓存 github.com
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://github.com/a/b", title: "PR #1", isIncognito: false)
        }
        engine.tick(now: ts(0))
        XCTAssertEqual(engine.latestSample?.url, "https://github.com/a/b")
        XCTAssertEqual(engine.latestSample?.windowTitle, "PR #1")

        // 再失败：不得沿用旧 URL，标题回退到 AX 标题
        engine.chromeTabProvider = { nil }
        engine.tick(now: ts(6))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertEqual(engine.latestSample?.windowTitle, "AX Title")
    }

    func testIncognitoStillSuppressesTitle() throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { [self] in chromeSample(at: Date()) }
        // Seam set even though this test doesn't assert on it: the fetch
        // attempt now unconditionally refreshes the cached authorization
        // answer, so without a seam this would hit the real TCC check.
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: nil, title: nil, isIncognito: true)
        }
        engine.tick(now: ts(0))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertNil(engine.latestSample?.windowTitle)
    }

    /// Regression: a fetch failure right after a confirmed-incognito window
    /// must not un-suppress it by falling back to the AX title -- the AX
    /// title of an incognito Chrome window IS the private page title.
    func testFetchFailureAfterIncognitoPreservesSuppression() throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { [self] in chromeSample(at: Date()) }
        engine.chromeAutomationAuthorizedProvider = { true }

        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: nil, title: nil, isIncognito: true)
        }
        engine.tick(now: ts(0))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertNil(engine.latestSample?.windowTitle)

        engine.chromeTabProvider = { nil }
        engine.tick(now: ts(6))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertNil(engine.latestSample?.windowTitle)
    }

    /// Regression: with Chrome Automation not authorized, a fetch failure
    /// must suppress both title and url even though an AX title exists --
    /// without automation we can't confirm the window isn't incognito, so
    /// leaking the raw AX title would be a privacy regression versus the
    /// pre-change build (which never wrote a Chrome title without a
    /// successful fetch).
    func testFetchFailureWithoutAutomationSuppressesAXTitle() throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { [self] in chromeSample(at: Date()) }
        engine.chromeAutomationAuthorizedProvider = { false }
        engine.chromeTabProvider = { nil }
        engine.tick(now: ts(0))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertNil(engine.latestSample?.windowTitle)
    }

    /// Regression for the false-alarm: 5+ consecutive fetch failures alone
    /// (e.g. Chrome frontmost with zero windows) must NOT flip
    /// `chromeCaptureDegraded` when Automation is actually authorized --
    /// that combination used to mislabel a window-less Chrome as a
    /// permissions problem.
    func testChromeCaptureDegradedStaysFalseWhenAuthorizedDespiteRepeatedFailures() throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { [self] in chromeSample(at: Date()) }
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.chromeTabProvider = { nil }
        for t in [0.0, 6, 12, 18, 24, 30] {
            engine.tick(now: ts(t))
        }
        XCTAssertFalse(engine.chromeCaptureDegraded)
    }

    /// Same repeated-failure sequence, but Automation is NOT authorized --
    /// this is the real permissions-revoked case, and the flag must flip.
    func testChromeCaptureDegradedBecomesTrueWhenNotAuthorized() throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { [self] in chromeSample(at: Date()) }
        engine.chromeAutomationAuthorizedProvider = { false }
        engine.chromeTabProvider = { nil }
        for t in [0.0, 6, 12, 18, 24, 30] {
            engine.tick(now: ts(t))
        }
        XCTAssertTrue(engine.chromeCaptureDegraded)
    }

    /// A subsequent successful fetch clears the degraded flag, same as it
    /// clears the underlying backoff.
    func testChromeCaptureDegradedClearsOnSubsequentSuccess() throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { [self] in chromeSample(at: Date()) }
        engine.chromeAutomationAuthorizedProvider = { false }
        engine.chromeTabProvider = { nil }
        for t in [0.0, 6, 12, 18, 24, 30] {
            engine.tick(now: ts(t))
        }
        XCTAssertTrue(engine.chromeCaptureDegraded)

        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://example.com", title: "Example", isIncognito: false)
        }
        engine.tick(now: ts(40))
        XCTAssertFalse(engine.chromeCaptureDegraded)
    }
}

/// C3 idle-exemption seam: meetings suppress `becameIdle` so a real-world
/// idle stretch (hands off keyboard during a video call) never suspends
/// tracking mid-meeting. Both tests below drive `windowSampleProvider` and
/// `tick(now:)` off a single shared `currentTime` var -- feeding the sample
/// a real `Date()` while driving `tick` off a fake `ts(N)` (the original
/// version of this file) desyncs `SpanBuilder`'s span start/end from the
/// suspension/heartbeat timeline it's supposed to share, which is exactly
/// what let the CRITICAL un-exemption bug below hide undetected.
@MainActor
final class TrackerEngineMeetingExemptionTests: XCTestCase {
    private func sampleAt(_ date: Date) -> Sample {
        Sample(timestamp: date, appBundleID: "com.example.app", appName: "Example",
               windowTitle: "T", url: nil)
    }

    private func makeEngine() throws -> (TrackerEngine, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        return (engine, store)
    }

    private func allSpans(_ store: SpanStore) throws -> [Span] {
        try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(1000)))
    }

    /// Repaired: asserts the span is actually open/extending by querying the
    /// persisted row (via a heartbeat-triggered insert) instead of only
    /// `engine.isSuspended` -- `isSuspended` alone can't distinguish "still
    /// extending" from "never opened".
    func testMeetingExemptionKeepsSpanOpenAndExtending() throws {
        let (engine, store) = try makeEngine()
        var currentTime = ts(0)
        engine.windowSampleProvider = { [self] in sampleAt(currentTime) }
        engine.idleSecondsProvider = { 300 }         // > 默认阈值 180，模拟手离键盘
        engine.isInMeetingProvider = { true }

        for t in stride(from: 0.0, through: 30, by: 10) {
            currentTime = ts(t)
            engine.tick(now: currentTime)
        }

        let rows = try allSpans(store)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].start, ts(0))
        XCTAssertEqual(rows[0].end, ts(31))   // 30s 心跳写入时刻 + SpanBuilder 的 1s tick 余量
        XCTAssertFalse(engine.isSuspended)    // 会议期间空闲豁免：未挂起
    }

    /// CRITICAL regression: un-exempting mid-idle-stretch must not backdate
    /// the idle-close using the FULL raw idle duration -- right after a
    /// meeting, that duration includes the entire meeting itself (hands were
    /// off the keyboard throughout), which without `exemptionEndedAt`
    /// collapses the just-persisted meeting span down to ~0s the instant the
    /// meeting ends while still idle (probed: a real ~30min meeting
    /// collapsed to 0s). Simulates the full sequence via the seams --
    /// meeting ticks extending + a heartbeat persisting the row, then the
    /// un-exemption tick -- and asserts the PERSISTED span's duration
    /// survives by querying the store, not just `engine.isSuspended`.
    func testUnExemptionAfterMeetingPreservesPersistedSpanDuration() throws {
        let (engine, store) = try makeEngine()
        var currentTime = ts(0)
        engine.windowSampleProvider = { [self] in sampleAt(currentTime) }
        engine.isInMeetingProvider = { true }
        engine.idleSecondsProvider = { 9999 }   // 会中手一直离键盘

        // 开会：每 5s 一 tick，持续到 595s -- 跨过多次 30s 心跳，span 被写入
        // 并持续延长（tick 间隔 5s < maxGap 15s，SpanBuilder 视为同一 span）。
        for t in stride(from: 0.0, through: 595, by: 5) {
            currentTime = ts(t)
            engine.tick(now: currentTime)
        }

        let midMeetingRows = try allSpans(store)
        XCTAssertEqual(midMeetingRows.count, 1)
        XCTAssertGreaterThan(midMeetingRows[0].end.timeIntervalSince(midMeetingRows[0].start), 500)

        // 会议结束，手仍未动：isInMeetingProvider 翻 false，idleSecondsProvider
        // 报告整段真实空闲 600s（>= 阈值 180）——这正是 bug 复现条件：不打
        // 补丁的话，close(at: 600 - 600 = ts(0)) 会把 end 拍扁回 span.start。
        engine.isInMeetingProvider = { false }
        engine.idleSecondsProvider = { 600 }
        currentTime = ts(600)
        engine.tick(now: currentTime)

        XCTAssertTrue(engine.isSuspended)   // 真实空闲照常触发挂起（会议已结束）

        let finalRows = try allSpans(store)
        XCTAssertEqual(finalRows.count, 1)
        XCTAssertEqual(finalRows[0].start, ts(0))
        // exemptionEndedAt 钳制：close 被限制在会议刚结束的时刻，span 保留
        // 会议期间最后一次延长的位置（t=595 的 ingest 令 cur.end = 596），
        // 而不是被 backdate 拍扁到 0。
        XCTAssertEqual(finalRows[0].end, ts(596))
    }
}

/// C4 focus session engine seam: `focusInterceptor`, when it returns true,
/// must short-circuit the tick before the sample ever reaches
/// `SpanBuilder.ingest` -- this is the "block-page sample never enters
/// stats" guarantee, exercised here purely at the engine-seam level (the
/// actual intercept() decision logic is covered by FocusSessionTests).
@MainActor
final class TrackerEngineFocusInterceptorTests: XCTestCase {
    func testFocusInterceptorSkipsRecording() throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        // Deliberately NOT a Chrome sample: touching the Chrome branch
        // without a `chromeTabProvider` seam would construct a real
        // `SBApplication` (forbidden in tests, see ChromeSampler/ChromeBlocker
        // docs) -- this test only cares about the interceptor short-circuit,
        // not Chrome-specific enrichment.
        engine.windowSampleProvider = {
            Sample(timestamp: ts(0), appBundleID: "com.hnc.Discord", appName: "Discord",
                   windowTitle: FocusBlockPage.pageMarkerTitle, url: nil)
        }
        engine.focusInterceptor = { _, _ in true }
        engine.tick(now: ts(0))
        // SpanBuilder never ingested the sample -- no current span opened.
        XCTAssertNil(engine.latestSample)
    }

    // MARK: - Fix round 1, I4/R-T12a: seam placement + AX-title regression

    /// (a) proves the seam sits AFTER Chrome URL enrichment, not before: a
    /// blocked-domain sample delivered via `chromeTabProvider` must
    /// actually redirect through the REAL engine tick -- if the interceptor
    /// were consulted before enrichment (the brief's literal placement),
    /// `sample.url` would be `nil` and this domain block could never fire.
    @MainActor func testChromeDomainBlockFiresThroughRealEngineSeam() throws {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: spanStore, settings: settings)
        engine.idleSecondsProvider = { 0 }
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.windowSampleProvider = {
            Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                   windowTitle: "AX Title", url: nil)
        }
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://bilibili.com/video/x", title: "B 站", isIncognito: false)
        }

        let focusStore = FocusSessionStore(db)
        settings.setFocusBlockedCategories(["entertainment"])
        let controller = FocusSessionController(store: focusStore, settings: settings)
        controller.categoryForDomain = { domain, _ in domain == "bilibili.com" ? "entertainment" : "misc" }
        var redirected: [String] = []
        controller.redirectChrome = { redirected.append($0); return true }
        try controller.start(minutes: 25)

        engine.focusInterceptor = { sample, now in controller.intercept(sample: sample, at: now) }
        engine.tick(now: ts(0))

        XCTAssertEqual(redirected.count, 1)
        XCTAssertEqual(controller.siteBlocks, 1)
    }

    /// (b) an intercepted sample is never ingested NOR persisted -- run
    /// enough ticks to cross both the 1s min-write-duration and the 30s
    /// heartbeat threshold, and assert directly against the store (not
    /// `latestSample`, which only proves the sample wasn't cached, not that
    /// nothing was written).
    @MainActor func testInterceptedSamplesNeverPersist() throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        engine.windowSampleProvider = {
            Sample(timestamp: ts(0), appBundleID: "com.hnc.Discord", appName: "Discord",
                   windowTitle: nil, url: nil)
        }
        engine.focusInterceptor = { _, _ in true }
        for t in stride(from: 0.0, through: 40, by: 1) {
            engine.tick(now: ts(t))
        }
        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.count, 0)
    }

    /// Pins the R-T12a mechanism directly: the AX title read fresh THIS
    /// tick already matches the block page's marker title, but the
    /// (stale-simulated) ScriptingBridge fetch reports a DIFFERENT title --
    /// without the fix, the SB title would silently overwrite the fresh AX
    /// marker and decision 2 would lose its title-based signal.
    @MainActor func testBlockPageAXTitlePreservedOverStaleSBTitle() throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.windowSampleProvider = {
            Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                   windowTitle: FocusBlockPage.pageMarkerTitle, url: nil)
        }
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "file:///tmp/blocked.html", title: "上一个页面标题", isIncognito: false)
        }
        var sawSample: Sample?
        engine.focusInterceptor = { sample, _ in sawSample = sample; return false }
        engine.tick(now: ts(0))
        XCTAssertEqual(sawSample?.windowTitle, FocusBlockPage.pageMarkerTitle)
    }

    // MARK: - Fold-in 4: heartbeat must run even when the interceptor short-circuits

    /// Regression for the reviewer's probe (120 intercepted ticks -> 0
    /// heartbeat writes): once a real span is open and has been heartbeat-
    /// written at least once, subsequent INTERCEPTED ticks must still let
    /// the 30s heartbeat fire for that already-open span -- proven via
    /// `engine.onChange`, which only ever fires from a successful
    /// `SpanStore` write.
    @MainActor func testHeartbeatContinuesDuringInterceptedDwell() throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        engine.windowSampleProvider = {
            Sample(timestamp: ts(0), appBundleID: "com.apple.dt.Xcode", appName: "Xcode",
                   windowTitle: "main.swift", url: nil)
        }
        var onChangeCount = 0
        engine.onChange = { onChangeCount += 1 }

        // Normal activity: opens a span and crosses the first 30s heartbeat.
        for t in stride(from: 0.0, through: 35, by: 5) {
            engine.tick(now: ts(t))
        }
        XCTAssertGreaterThan(onChangeCount, 0)

        // Now the user lands on the block page: every subsequent sample is
        // intercepted (never ingested), but the already-open span must
        // still get checkpointed every 30s throughout the dwell.
        engine.focusInterceptor = { _, _ in true }
        onChangeCount = 0
        for t in stride(from: 40.0, through: 100, by: 30) {
            engine.tick(now: ts(t))
        }
        XCTAssertGreaterThan(onChangeCount, 0)
    }
}
