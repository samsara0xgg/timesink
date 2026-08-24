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
}
