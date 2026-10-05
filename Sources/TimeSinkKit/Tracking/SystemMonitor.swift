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
    private var lastLock = Date.distantPast
    private var lastUnlock = Date.distantPast
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

    /// Debounced per direction: a Touch ID unlock can land under a second
    /// after the lock, and dropping it left tracking suspended until the
    /// next lock/unlock pair. Internal so a test can drive it.
    func debouncedLock(suspend: Bool, at now: Date = Date()) {
        if suspend {
            guard now.timeIntervalSince(lastLock) > 1 else { return }
            lastLock = now
            onSuspend?(now, .lock)
        } else {
            guard now.timeIntervalSince(lastUnlock) > 1 else { return }
            lastUnlock = now
            onResume?(now, .unlock)
        }
    }
}
