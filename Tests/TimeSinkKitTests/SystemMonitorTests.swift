import XCTest
@testable import TimeSinkKit

@MainActor
final class SystemMonitorTests: XCTestCase {
    /// A Touch ID unlock can land under a second after the lock; it must
    /// not be dropped, or tracking stays suspended while the Mac is in use.
    func testFastUnlockAfterLockIsDelivered() {
        let monitor = SystemMonitor()
        var events: [String] = []
        monitor.onSuspend = { _, _ in events.append("lock") }
        monitor.onResume = { _, _ in events.append("unlock") }
        let t = Date()
        monitor.debouncedLock(suspend: true, at: t)
        monitor.debouncedLock(suspend: false, at: t.addingTimeInterval(0.84))
        monitor.debouncedLock(suspend: false, at: t.addingTimeInterval(1.0)) // duplicate, dropped
        XCTAssertEqual(events, ["lock", "unlock"])
    }
}
