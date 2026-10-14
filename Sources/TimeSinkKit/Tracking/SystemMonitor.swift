import AppKit
import CoreGraphics

@MainActor
public final class SystemMonitor {
    /// Distinguishes a resume signal's origin. `wake` comes from
    /// `NSWorkspace.didWakeNotification`, which is NOT trustworthy evidence
    /// the screen is actually unlocked -- macOS can fire it while the
    /// screen is still locked after a deep sleep. `unlock` comes from the
    /// `com.apple.screenIsUnlocked` distributed notification (or this
    /// session becoming the active one again after a user switch), which is
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
    /// The last lock-direction signal delivered, and when.
    private var lastLockSignal: (suspend: Bool, at: Date)?
    public init() {}

    public func start() {
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSuspend?(Date(), .sleep) }
        }
        wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResume?(Date(), .wake) }
        }
        // Fast user switching: another user's session takes the console.
        // A lock notification is not promised for it, and while it lasts
        // the idle reading is the other user's input.
        wc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.debouncedLock(suspend: true) }
        }
        wc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.debouncedLock(suspend: false) }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.debouncedLock(suspend: true) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.debouncedLock(suspend: false) }
        }
    }

    /// Drops only a true duplicate: the same direction as the signal just
    /// delivered, within a second of it (macOS can post a lock or an unlock
    /// twice). Anything else goes through, however fast -- a Touch ID unlock
    /// can land under a second after the lock (f0f16c6), and a lock right
    /// after that unlock is a real lock. The handlers are idempotent; the
    /// debounce only keeps duplicate state rows out of the log. Internal so
    /// a test can drive it.
    func debouncedLock(suspend: Bool, at now: Date = Date()) {
        if let last = lastLockSignal, last.suspend == suspend, now.timeIntervalSince(last.at) <= 1 { return }
        lastLockSignal = (suspend, now)
        if suspend {
            onSuspend?(now, .lock)
        } else {
            onResume?(now, .unlock)
        }
    }

    /// Reads `CGSSessionScreenIsLocked` from the current window-server
    /// session dictionary. That key isn't in the public `CGSession.h`
    /// header, but reading it via `CGSessionCopyCurrentDictionary` is the
    /// long-standing, widely-used way to answer "is the screen locked right
    /// now" without extra permissions. A session that is not on the console
    /// (another user switched in) counts as locked: nobody here is using it.
    /// No session dictionary at all (no window server) reads as unlocked.
    public nonisolated static func isScreenLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (info["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        return (info["kCGSSessionOnConsoleKey"] as? Bool) == false
    }
}
