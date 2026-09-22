import AppKit

@MainActor
public final class SystemMonitor {
    /// Distinguishes a resume signal's origin. `wake` comes from
    /// `NSWorkspace.didWakeNotification`, which is NOT trustworthy evidence
    /// the screen is actually unlocked -- macOS can fire it while the
    /// screen is still locked after a deep sleep. `unlock` comes from the
    /// `com.apple.screenIsUnlocked` distributed notification, which is
    /// authoritative.
    public enum ResumeSource {
        case wake
        case unlock
    }

    public enum SuspendSource {
        case sleep
        case lock
    }

    public var onSuspend: ((Date, SuspendSource) -> Void)?
    public var onResume: ((Date, ResumeSource) -> Void)?
    private var lastLockEvent = Date.distantPast
    public init() {}

    public func start() {
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSuspend?(Date(), .sleep) }
        }
        wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResume?(Date(), .wake) }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.debouncedLock(suspend: true) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.debouncedLock(suspend: false) }
        }
    }

    private func debouncedLock(suspend: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastLockEvent) > 1 else { return }
        lastLockEvent = now
        if suspend { onSuspend?(now, .lock) } else { onResume?(now, .unlock) }
    }
}
