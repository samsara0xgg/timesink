import Foundation
import os

/// OCR failures since the last success, in memory. On 2026-10-17 macOS emptied
/// the Vision model caches and every OCR run failed for two days until a manual
/// restart; this is what lets the app notice and restart itself.
public struct OCRStreak: Equatable, Sendable {
    public private(set) var failures = 0
    public private(set) var lastSuccess: Date
    /// The most recent screenshot attempt worked: a relaunch is only a cure
    /// when capture itself is fine and just the text reading is broken.
    public private(set) var screenshotsOK = true

    /// `since` stands in for the last success until there is one (process start).
    public init(since: Date) { lastSuccess = since }

    /// True for the first failure of a streak: the one worth logging.
    public mutating func noteFailure() -> Bool {
        failures += 1
        return failures == 1
    }

    /// The length of the streak this success ended, nil when there was none.
    public mutating func noteSuccess(at now: Date) -> Int? {
        defer { failures = 0; lastSuccess = now }
        return failures > 0 ? failures : nil
    }

    public mutating func noteScreenshot(ok: Bool) { screenshotsOK = ok }
}

public enum SelfHeal {
    /// Consecutive OCR failures. Normal days never show more than 2 in a row
    /// (captureHealth, 2026-09-21 to 10-22); both known bad episodes had 11+.
    public static let minFailures = 20
    /// Time since the last OCR success. Well under the 2-day outage, a few
    /// ticks past the 10-minute health windows a transient fits in.
    public static let minSilence: TimeInterval = 15 * 60
    /// A relaunch this recent that did not cure it means restarting is not the fix.
    public static let relaunchGuard: TimeInterval = 6 * 3600
    public static let relaunchKey = "selfHealRelaunchAt"

    public enum Action: Equatable, Sendable { case none, relaunch, notify }

    /// All four conditions, then: relaunch once, and tell the user instead
    /// when a recent relaunch already happened.
    public static func decide(streak: OCRStreak, now: Date, focusRunning: Bool, lastRelaunch: Date?) -> Action {
        guard streak.failures >= minFailures,
              now.timeIntervalSince(streak.lastSuccess) >= minSilence,
              streak.screenshotsOK, !focusRunning else { return .none }
        if let lastRelaunch, now.timeIntervalSince(lastRelaunch) < relaunchGuard { return .notify }
        return .relaunch
    }

    /// Opens `bundleURL` again once process `pid` (this one) has exited. A new instance exits
    /// when an older one of the same bundle is still alive (`TimeSinkApp.init`), and `open` of a
    /// running app only activates it, so the shell waits for the old pid instead of a fixed
    /// delay, and opens anyway after `maxWait` seconds. It runs in a session of its own
    /// (`POSIX_SPAWN_SETSID`) with no terminal, so it outlives the quitting app.
    public static func reopen(bundleURL: URL, afterExitOf pid: pid_t, maxWait: Int = 60, opener: String = "/usr/bin/open") {
        let script = "n=0; while kill -0 \"$1\" 2>/dev/null && [ $n -lt $2 ]; do sleep 0.2; n=$((n+1)); done; exec \"$3\" \"$0\""
        let args = ["sh", "-c", script, bundleURL.path, String(pid), String(maxWait * 5), opener]
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) }
        let argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        posix_spawn(&child, "/bin/sh", &actions, &attr, argv, environ)
    }
}

/// Acts on `SelfHeal.decide`. The real quit-and-reopen is injected, so tests
/// never touch the running app.
@MainActor
public final class SelfHealMonitor {
    private let defaults: UserDefaults
    private let notifier: any Notifying
    private let isFocusRunning: () -> Bool
    private let relaunch: () -> Void
    private let now: () -> Date
    private let delay: Duration
    private var pending = false
    private var notified = false
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "selfheal")

    public init(defaults: UserDefaults = .standard, notifier: any Notifying, isFocusRunning: @escaping () -> Bool,
                relaunch: @escaping () -> Void, now: @escaping () -> Date = Date.init,
                delay: Duration = .seconds(5)) {
        self.defaults = defaults; self.notifier = notifier; self.isFocusRunning = isFocusRunning
        self.relaunch = relaunch; self.now = now; self.delay = delay
    }

    /// Called after every OCR failure.
    public func ocrStreakChanged(_ streak: OCRStreak) {
        // UserDefaults, not the database: if the database cannot be written the marker would be lost and the relaunch could loop.
        let lastRelaunch = (defaults.object(forKey: SelfHeal.relaunchKey) as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        switch SelfHeal.decide(streak: streak, now: now(), focusRunning: isFocusRunning(), lastRelaunch: lastRelaunch) {
        case .none:
            return
        case .notify:
            guard !notified else { return }
            notified = true
            notifier.post(id: "selfheal.ocr", title: String(localized: "屏幕文字识别持续失败"),
                          body: String(localized: "重启 TimeSink 后仍然识别不了屏幕文字，可能需要清理系统的文字识别缓存。"), route: nil)
        case .relaunch:
            guard !pending else { return }
            pending = true
            logger.error("OCR failing for \(streak.failures) runs, relaunching")
            Task {
                try? await Task.sleep(for: delay)
                // A focus session may have started during the delay.
                guard !isFocusRunning() else { pending = false; return }
                defaults.set(now().timeIntervalSince1970, forKey: SelfHeal.relaunchKey)
                relaunch()
            }
        }
    }
}
