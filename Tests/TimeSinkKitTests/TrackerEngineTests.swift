import XCTest
import os
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

/// The Apple Event reply timeout went 60 ticks (1s) -> 15 (0.25s), which is a
/// real behavior change: a Chrome reply between 0.25s and 1s now counts as a
/// failure and feeds `chromeBackoff`. Nothing else pins the constant, so this
/// does -- asserted in seconds, since that (matching `WindowSampler`'s 0.25s
/// AX messaging timeout) is the property that matters, not the tick count.
final class ChromeSamplerTimeoutTests: XCTestCase {
    func testAppleEventTimeoutIsQuarterSecond() {
        XCTAssertEqual(Double(ChromeSampler.timeoutTicks) / 60, 0.25, accuracy: 0.001)
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

/// Hoisted out of the test class: `windowSampleProvider` is `@Sendable`
/// (it runs off the main actor in `tickAsync`), so its closure cannot
/// capture a `@MainActor` XCTestCase `self`.
private func chromeSample(at date: Date) -> Sample {
    Sample(timestamp: date, appBundleID: "com.google.Chrome",
           appName: "Google Chrome", windowTitle: "AX Title", url: nil)
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

    func testFetchFailureFallsBackToAXTitleInsteadOfStaleURL() async throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { chromeSample(at: $0) }
        // Automation is authorized in this scenario -- the AX-title fallback
        // is only safe to observe when we can confirm the window isn't
        // incognito, and being authorized is what lets a successful fetch
        // confirm that.
        engine.chromeAutomationAuthorizedProvider = { true }

        // 先成功一次：缓存 github.com
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://github.com/a/b", title: "PR #1", isIncognito: false)
        }
        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(engine.latestSample?.url, "https://github.com/a/b")
        XCTAssertEqual(engine.latestSample?.windowTitle, "PR #1")

        // 再失败：不得沿用旧 URL，标题回退到 AX 标题
        engine.chromeTabProvider = { nil }
        await engine.tickAsync(now: ts(6))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertEqual(engine.latestSample?.windowTitle, "AX Title")
    }

    func testIncognitoStillSuppressesTitle() async throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { chromeSample(at: $0) }
        // Seam set even though this test doesn't assert on it: the fetch
        // attempt now unconditionally refreshes the cached authorization
        // answer, so without a seam this would hit the real TCC check.
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: nil, title: nil, isIncognito: true)
        }
        await engine.tickAsync(now: ts(0))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertNil(engine.latestSample?.windowTitle)
    }

    /// Regression: a fetch failure right after a confirmed-incognito window
    /// must not un-suppress it by falling back to the AX title -- the AX
    /// title of an incognito Chrome window IS the private page title.
    func testFetchFailureAfterIncognitoPreservesSuppression() async throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { chromeSample(at: $0) }
        engine.chromeAutomationAuthorizedProvider = { true }

        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: nil, title: nil, isIncognito: true)
        }
        await engine.tickAsync(now: ts(0))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertNil(engine.latestSample?.windowTitle)

        engine.chromeTabProvider = { nil }
        await engine.tickAsync(now: ts(6))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertNil(engine.latestSample?.windowTitle)
    }

    /// Regression: with Chrome Automation not authorized, a fetch failure
    /// must suppress both title and url even though an AX title exists --
    /// without automation we can't confirm the window isn't incognito, so
    /// leaking the raw AX title would be a privacy regression versus the
    /// pre-change build (which never wrote a Chrome title without a
    /// successful fetch).
    func testFetchFailureWithoutAutomationSuppressesAXTitle() async throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { chromeSample(at: $0) }
        engine.chromeAutomationAuthorizedProvider = { false }
        engine.chromeTabProvider = { nil }
        await engine.tickAsync(now: ts(0))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertNil(engine.latestSample?.windowTitle)
    }

    /// Regression for the false-alarm: 5+ consecutive fetch failures alone
    /// (e.g. Chrome frontmost with zero windows) must NOT flip
    /// `chromeCaptureDegraded` when Automation is actually authorized --
    /// that combination used to mislabel a window-less Chrome as a
    /// permissions problem.
    func testChromeCaptureDegradedStaysFalseWhenAuthorizedDespiteRepeatedFailures() async throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { chromeSample(at: $0) }
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.chromeTabProvider = { nil }
        for t in [0.0, 6, 12, 18, 24, 30] {
            await engine.tickAsync(now: ts(t))
        }
        XCTAssertFalse(engine.chromeCaptureDegraded)
    }

    /// Same repeated-failure sequence, but Automation is NOT authorized --
    /// this is the real permissions-revoked case, and the flag must flip.
    func testChromeCaptureDegradedBecomesTrueWhenNotAuthorized() async throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { chromeSample(at: $0) }
        engine.chromeAutomationAuthorizedProvider = { false }
        engine.chromeTabProvider = { nil }
        for t in [0.0, 6, 12, 18, 24, 30] {
            await engine.tickAsync(now: ts(t))
        }
        XCTAssertTrue(engine.chromeCaptureDegraded)
    }

    /// A subsequent successful fetch clears the degraded flag, same as it
    /// clears the underlying backoff.
    func testChromeCaptureDegradedClearsOnSubsequentSuccess() async throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { chromeSample(at: $0) }
        engine.chromeAutomationAuthorizedProvider = { false }
        engine.chromeTabProvider = { nil }
        for t in [0.0, 6, 12, 18, 24, 30] {
            await engine.tickAsync(now: ts(t))
        }
        XCTAssertTrue(engine.chromeCaptureDegraded)

        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://example.com", title: "Example", isIncognito: false)
        }
        await engine.tickAsync(now: ts(40))
        XCTAssertFalse(engine.chromeCaptureDegraded)
    }
}

/// C3 idle-exemption seam: meetings suppress `becameIdle` so a real-world
/// idle stretch (hands off keyboard during a video call) never suspends
/// tracking mid-meeting. Both tests below keep the sampled timestamp and
/// `tick(now:)` on one timeline -- feeding the sample a real `Date()` while
/// driving `tick` off a fake `ts(N)` (the original version of this file)
/// desyncs `SpanBuilder`'s span start/end from the suspension/heartbeat
/// timeline it's supposed to share, which is exactly what let the CRITICAL
/// un-exemption bug below hide undetected. The seam now hands the provider
/// the tick's own `now`, so the two cannot drift apart by construction
/// (they used to be kept in sync by hand through a shared `currentTime`
/// var, which a `@Sendable` seam can no longer capture).
private func meetingSample(at date: Date) -> Sample {
    Sample(timestamp: date, appBundleID: "com.example.app", appName: "Example",
           windowTitle: "T", url: nil)
}

@MainActor
final class TrackerEngineMeetingExemptionTests: XCTestCase {
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
    func testMeetingExemptionKeepsSpanOpenAndExtending() async throws {
        let (engine, store) = try makeEngine()
        var currentTime = ts(0)
        engine.windowSampleProvider = { meetingSample(at: $0) }
        engine.idleSecondsProvider = { 300 }         // > 默认阈值 180，模拟手离键盘
        engine.isInMeetingProvider = { true }

        for t in stride(from: 0.0, through: 30, by: 10) {
            currentTime = ts(t)
            await engine.tickAsync(now: currentTime)
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
    func testUnExemptionAfterMeetingPreservesPersistedSpanDuration() async throws {
        let (engine, store) = try makeEngine()
        var currentTime = ts(0)
        engine.windowSampleProvider = { meetingSample(at: $0) }
        engine.isInMeetingProvider = { true }
        engine.idleSecondsProvider = { 9999 }   // 会中手一直离键盘

        // 开会：每 5s 一 tick，持续到 595s -- 跨过多次 30s 心跳，span 被写入
        // 并持续延长（tick 间隔 5s < maxGap 15s，SpanBuilder 视为同一 span）。
        for t in stride(from: 0.0, through: 595, by: 5) {
            currentTime = ts(t)
            await engine.tickAsync(now: currentTime)
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
        await engine.tickAsync(now: currentTime)

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
    func testFocusInterceptorSkipsRecording() async throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        // Deliberately NOT a Chrome sample: touching the Chrome branch
        // without a `chromeTabProvider` seam would construct a real
        // `SBApplication` (forbidden in tests, see ChromeSampler/ChromeBlocker
        // docs) -- this test only cares about the interceptor short-circuit,
        // not Chrome-specific enrichment.
        engine.windowSampleProvider = { _ in
            Sample(timestamp: ts(0), appBundleID: "com.hnc.Discord", appName: "Discord",
                   windowTitle: FocusBlockPage.pageMarkerTitle, url: nil)
        }
        engine.focusInterceptor = { _, _ in true }
        await engine.tickAsync(now: ts(0))
        // SpanBuilder never ingested the sample -- no current span opened.
        XCTAssertNil(engine.latestSample)
    }

    // MARK: - Fix round 1, I4/R-T12a: seam placement + AX-title regression

    /// (a) proves the seam sits AFTER Chrome URL enrichment, not before: a
    /// blocked-domain sample delivered via `chromeTabProvider` must
    /// actually redirect through the REAL engine tick -- if the interceptor
    /// were consulted before enrichment (the brief's literal placement),
    /// `sample.url` would be `nil` and this domain block could never fire.
    @MainActor func testChromeDomainBlockFiresThroughRealEngineSeam() async throws {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: spanStore, settings: settings)
        engine.idleSecondsProvider = { 0 }
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.windowSampleProvider = { _ in
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
        await engine.tickAsync(now: ts(0))

        XCTAssertEqual(redirected.count, 1)
        XCTAssertEqual(controller.siteBlocks, 1)
    }

    /// (b) an intercepted sample is never ingested NOR persisted -- run
    /// enough ticks to cross both the 1s min-write-duration and the 30s
    /// heartbeat threshold, and assert directly against the store (not
    /// `latestSample`, which only proves the sample wasn't cached, not that
    /// nothing was written).
    @MainActor func testInterceptedSamplesNeverPersist() async throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        engine.windowSampleProvider = { _ in
            Sample(timestamp: ts(0), appBundleID: "com.hnc.Discord", appName: "Discord",
                   windowTitle: nil, url: nil)
        }
        engine.focusInterceptor = { _, _ in true }
        for t in stride(from: 0.0, through: 40, by: 1) {
            await engine.tickAsync(now: ts(t))
        }
        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.count, 0)
    }

    /// Pins the R-T12a mechanism directly: the AX title read fresh THIS
    /// tick already matches the block page's marker title, but the
    /// (stale-simulated) ScriptingBridge fetch reports a DIFFERENT title --
    /// without the fix, the SB title would silently overwrite the fresh AX
    /// marker and decision 2 would lose its title-based signal.
    @MainActor func testBlockPageAXTitlePreservedOverStaleSBTitle() async throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.windowSampleProvider = { _ in
            Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                   windowTitle: FocusBlockPage.pageMarkerTitle, url: nil)
        }
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "file:///tmp/blocked.html", title: "上一个页面标题", isIncognito: false)
        }
        var sawSample: Sample?
        engine.focusInterceptor = { sample, _ in sawSample = sample; return false }
        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(sawSample?.windowTitle, FocusBlockPage.pageMarkerTitle)
    }

    // MARK: - Fold-in 4: heartbeat must run even when the interceptor short-circuits

    /// Regression for the reviewer's probe (120 intercepted ticks -> 0
    /// heartbeat writes): once a real span is open and has been heartbeat-
    /// written at least once, subsequent INTERCEPTED ticks must still let
    /// the 30s heartbeat fire for that already-open span -- proven via
    /// `engine.onChange`, which only ever fires from a successful
    /// `SpanStore` write.
    @MainActor func testHeartbeatContinuesDuringInterceptedDwell() async throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        engine.windowSampleProvider = { _ in
            Sample(timestamp: ts(0), appBundleID: "com.apple.dt.Xcode", appName: "Xcode",
                   windowTitle: "main.swift", url: nil)
        }
        var onChangeCount = 0
        engine.onChange = { onChangeCount += 1 }

        // Normal activity: opens a span and crosses the first 30s heartbeat.
        for t in stride(from: 0.0, through: 35, by: 5) {
            await engine.tickAsync(now: ts(t))
        }
        XCTAssertGreaterThan(onChangeCount, 0)

        // Now the user lands on the block page: every subsequent sample is
        // intercepted (never ingested), but the already-open span must
        // still get checkpointed every 30s throughout the dwell.
        engine.focusInterceptor = { _, _ in true }
        onChangeCount = 0
        for t in stride(from: 40.0, through: 100, by: 30) {
            await engine.tickAsync(now: ts(t))
        }
        XCTAssertGreaterThan(onChangeCount, 0)
    }
}

// MARK: - Task B: off-main-actor sampling

/// The 1s tick used to make both `AXUIElementCopyAttributeValue` calls (0.25s
/// messaging timeout each) and Chrome's synchronous Apple Event on the main
/// actor, so a beachballing frontmost app stalled the menu bar along with it.
/// `tickAsync` now runs that IPC off-actor, which introduces a suspension
/// point mid-tick -- and with it the reentrancy hazard these tests pin down.
@MainActor
final class TrackerEngineAsyncTickTests: XCTestCase {
    private func makeEngine() throws -> (TrackerEngine, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }   // hermetic: ignore the host's real idle time
        return (engine, store)
    }

    /// Both halves of the Task B guarantee, in one run:
    ///
    /// (a) the main actor is never blocked by the sampler -- while the
    ///     provider sleeps 250ms off-actor, the test body keeps running main-
    ///     actor work to completion and measurably finishes before the tick
    ///     does;
    /// (b) the ticks that fire during that window are SKIPPED, not queued --
    ///     the provider is entered exactly once, `latestSample` only ever
    ///     shows the first tick's sample, and the run persists exactly one
    ///     span whose start/end are the uncorrupted values for that single
    ///     sample.
    ///
    /// The provider call count is the load-bearing assertion: without the
    /// in-flight guard, all six ticks enter the sampler concurrently and
    /// their continuations interleave over `builder.current`, `currentRowID`
    /// and `lastHeartbeat`.
    func testSlowSamplerRunsOffMainActorAndOverlappingTicksAreSkipped() async throws {
        let (engine, store) = try makeEngine()
        // OSAllocatedUnfairLock is genuinely `Sendable` (no `@unchecked`):
        // the counter is mutated from the cooperative pool by the sampler and
        // read back on the main actor.
        let calls = OSAllocatedUnfairLock(initialState: 0)
        engine.windowSampleProvider = { date in
            calls.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.25)   // stand-in for a hung AX read
            return Sample(timestamp: date, appBundleID: "com.apple.dt.Xcode",
                          appName: "Xcode", windowTitle: "main.swift", url: nil)
        }

        let slow = Task { await engine.tickAsync(now: ts(0)) }
        // Hand the main actor to `slow` so it reaches its off-actor hop; it
        // runs synchronously up to that `await`, so when control comes back
        // here the tick is provably in flight and off the main actor.
        await Task.yield()

        let mainActorStart = Date()
        for t in 1...5 {
            await engine.tickAsync(now: ts(Double(t)))
        }
        let mainActorElapsed = Date().timeIntervalSince(mainActorStart)
        await slow.value
        let totalElapsed = Date().timeIntervalSince(mainActorStart)

        // (a) five ticks' worth of main-actor work completed while the
        // sampler was still sleeping. If the sampler ran on the main actor,
        // `mainActorElapsed` would itself be >= 0.25s (and `calls` would be 6).
        XCTAssertLessThan(mainActorElapsed, 0.1)
        XCTAssertGreaterThan(totalElapsed, 0.2)

        // (b) skipped, not queued.
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(engine.latestSample?.timestamp, ts(0))

        // The open span is the first tick's and only the first tick's. Drive
        // it past the 30s heartbeat with a fast sampler so it actually hits
        // the store, then assert on the persisted row.
        engine.windowSampleProvider = { date in
            Sample(timestamp: date, appBundleID: "com.apple.dt.Xcode",
                   appName: "Xcode", windowTitle: "main.swift", url: nil)
        }
        for t in stride(from: 5.0, through: 35, by: 5) {
            await engine.tickAsync(now: ts(t))
        }
        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].start, ts(0))     // no stale sample dragged the start
        XCTAssertEqual(rows[0].end, ts(31))      // 30s heartbeat + SpanBuilder's 1s tick
    }

    /// A sample that comes back from IPC after the screen locked must be
    /// DROPPED, not ingested: the main actor stayed live during the hop, so
    /// `suspend(at:)` already closed and persisted the span, and applying the
    /// sample now would reopen one behind the lock screen -- the bug class
    /// `SuspensionState` exists to prevent, re-entering through the new
    /// suspension point.
    func testSampleArrivingAfterLockIsDropped() async throws {
        let (engine, store) = try makeEngine()
        let locked = OSAllocatedUnfairLock(initialState: false)
        engine.windowSampleProvider = { date in
            Thread.sleep(forTimeInterval: 0.1)
            locked.withLock { $0 = true }
            return Sample(timestamp: date, appBundleID: "com.apple.dt.Xcode",
                          appName: "Xcode", windowTitle: "main.swift", url: nil)
        }

        let slow = Task { await engine.tickAsync(now: ts(0)) }
        await Task.yield()
        // Screen locks while the AX read is still out.
        engine.suspend(at: ts(0))
        await slow.value

        XCTAssertTrue(locked.withLock { $0 })   // the sampler really did run
        XCTAssertNil(engine.latestSample)       // ... and its sample was dropped
        XCTAssertTrue(engine.isSuspended)
        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.count, 0)
    }

    /// The case a post-`await` `isSuspended` READ cannot catch: the machine
    /// sleeps AND wakes while one tick is parked on IPC, so by the time the
    /// sample comes back the flag reads `false` again -- yet `suspend(at:)`
    /// has already closed and persisted the span underneath it, and the
    /// sample in hand is stamped before all of that. Only a change detector
    /// (`suspensionEpoch`) drops it.
    func testSampleArrivingAfterSuspendResumePairIsDropped() async throws {
        let (engine, store) = try makeEngine()
        let fast: @Sendable (Date) -> Sample? = { date in
            Sample(timestamp: date, appBundleID: "com.apple.dt.Xcode",
                   appName: "Xcode", windowTitle: "main.swift", url: nil)
        }
        // A completed tick first, so `latestSample` and the open span are
        // both non-nil going in: without that, "dropped" and "never ran" look
        // identical and the assertions below prove nothing.
        engine.windowSampleProvider = fast
        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(engine.latestSample?.timestamp, ts(0))

        let entered = OSAllocatedUnfairLock(initialState: false)
        engine.windowSampleProvider = { date in
            entered.withLock { $0 = true }
            Thread.sleep(forTimeInterval: 0.1)   // stand-in for a hung AX read
            return fast(date)
        }
        let slow = Task { await engine.tickAsync(now: ts(40)) }
        await Task.yield()   // let the tick reach its off-actor hop
        // Sleep and wake both land inside that 0.1s window.
        engine.suspend(at: ts(40))
        engine.resume(source: .unlock)
        await slow.value

        XCTAssertTrue(entered.withLock { $0 })    // the sampler really did run
        XCTAssertFalse(engine.isSuspended)        // ... and the pair cancelled out
        // Dropped: `latestSample` is still the first tick's.
        XCTAssertEqual(engine.latestSample?.timestamp, ts(0))

        // And the drop reached `SpanBuilder`, not just the cached sample: the
        // suspend closed the ts(0) span, so the next tick must open a fresh
        // span at ts(41). If the ts(40) sample had been ingested, that tick
        // would extend ITS span instead and this row would start at ts(40).
        engine.windowSampleProvider = fast
        await engine.tickAsync(now: ts(41))
        engine.suspend(at: ts(42))

        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].start, ts(0))
        XCTAssertEqual(rows[0].end, ts(1))
        XCTAssertEqual(rows[1].start, ts(41))
        XCTAssertEqual(rows[1].end, ts(42))
    }

    /// Same drop, triggered by `stop()` rather than a lock: it closes and
    /// persists the current span, so a tick still parked on IPC must not come
    /// back and reopen one. Both production callers quit the app, but
    /// `NSApp.terminate` still spins the run loop, so that continuation can
    /// land before the process is gone.
    func testSampleArrivingAfterStopIsDropped() async throws {
        let (engine, store) = try makeEngine()
        let fast: @Sendable (Date) -> Sample? = { date in
            Sample(timestamp: date, appBundleID: "com.apple.dt.Xcode",
                   appName: "Xcode", windowTitle: "main.swift", url: nil)
        }
        engine.windowSampleProvider = fast
        await engine.tickAsync(now: ts(0))

        engine.windowSampleProvider = { date in
            Thread.sleep(forTimeInterval: 0.1)
            return fast(date)
        }
        let slow = Task { await engine.tickAsync(now: ts(40)) }
        await Task.yield()
        engine.stop()
        await slow.value

        XCTAssertEqual(engine.latestSample?.timestamp, ts(0))
        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].start, ts(0))
        XCTAssertEqual(rows[0].end, ts(1))
    }

    /// The Chrome Apple Event is a second, separately parked window, and it
    /// needs the same guard as the AX read: a sleep/wake pair landing inside
    /// IT must drop the sample too.
    func testSampleIsDroppedWhenSuspensionChangesDuringChromeFetch() async throws {
        let (engine, store) = try makeEngine()
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.windowSampleProvider = { chromeSample(at: $0) }
        let inFetch = OSAllocatedUnfairLock(initialState: false)
        engine.chromeTabProvider = {
            inFetch.withLock { $0 = true }
            Thread.sleep(forTimeInterval: 0.2)   // stand-in for a slow Apple Event
            return ChromeSampler.TabInfo(url: "https://github.com/a/b", title: "PR #1",
                                         isIncognito: false)
        }

        let slow = Task { await engine.tickAsync(now: ts(0)) }
        // Yield until the tick is provably parked in the SECOND hop -- one
        // `Task.yield()` only gets it as far as the first.
        while !inFetch.withLock({ $0 }) { await Task.yield() }
        engine.suspend(at: ts(0))
        engine.resume(source: .unlock)
        await slow.value

        XCTAssertFalse(engine.isSuspended)   // the pair cancelled out again
        XCTAssertNil(engine.latestSample)    // ... and the sample was dropped
        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.count, 0)
    }
}

/// A before t=5, B after: the window switch at 5 is the ⌘⇥ tick.
private func switchingSample(at date: Date) -> Sample {
    date < ts(5)
        ? Sample(timestamp: date, appBundleID: "com.example.a", appName: "A", windowTitle: "A", url: nil)
        : Sample(timestamp: date, appBundleID: "com.example.b", appName: "B", windowTitle: "B", url: nil)
}

@MainActor
final class TrackerEngineKeySecondTests: XCTestCase {
    /// Counts ticks with a new keyDown, never the span's opening tick, and
    /// never the same keyDown twice.
    func testKeySecondsSkipTheOpeningTickAndCountEachKeyOnce() async throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        engine.windowSampleProvider = { switchingSample(at: $0) }
        // Seconds since the last keyDown, per tick: a key in ticks 0-5, 7, 8.
        let sinceKey: [TimeInterval] = [0.2, 0.2, 0.2, 0.2, 0.2, 0.3, 1.3, 0.5, 0.1, 1.1, 2.1]
        var tick = 0
        engine.keyDownSecondsProvider = { sinceKey[tick] }
        for t in 0..<sinceKey.count {
            tick = t
            await engine.tickAsync(now: ts(Double(t)))
        }
        engine.stop()
        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.map(\.appName), ["A", "B"])
        XCTAssertEqual(rows.map(\.keySeconds), [4, 2])
    }

    /// The heartbeat rewrites the running count, not only the end.
    func testHeartbeatWritesTheRunningCount() async throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        engine.idleSecondsProvider = { 0 }
        engine.windowSampleProvider = { meetingSample(at: $0) }
        engine.keyDownSecondsProvider = { 0.2 }
        for t in 0...61 { await engine.tickAsync(now: ts(Double(t))) }
        let rows = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(100)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].keySeconds, 60)
    }
}
