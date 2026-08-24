import AppKit

@MainActor
public final class SystemMonitor {
    public var onSuspend: ((Date) -> Void)?
    public var onResume: ((Date) -> Void)?
    private var lastLockEvent = Date.distantPast
    public init() {}

    public func start() {
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSuspend?(Date()) }
        }
        wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResume?(Date()) }
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
        if suspend { onSuspend?(now) } else { onResume?(now) }
    }
}
