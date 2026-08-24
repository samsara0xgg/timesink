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
