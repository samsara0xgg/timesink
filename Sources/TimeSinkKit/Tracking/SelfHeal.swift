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

    /// Opens the same bundle again after this process has exited. Detached on
    /// purpose: `open` of a running app only activates it, so the shell waits.
    public static func reopen(bundleURL: URL, after seconds: Int = 3) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep \(seconds); /usr/bin/open \"$0\"", bundleURL.path]
        try? shell.run()
    }
}

/// Acts on `SelfHeal.decide`. The real quit-and-reopen is injected, so tests
/// never touch the running app.
@MainActor
public final class SelfHealMonitor {
    private let settings: SettingsStore
    private let notifier: any Notifying
    private let isFocusRunning: () -> Bool
    private let relaunch: () -> Void
    private let now: () -> Date
    private let delay: Duration
    private var pending = false
    private var notified = false
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "selfheal")

    public init(settings: SettingsStore, notifier: any Notifying, isFocusRunning: @escaping () -> Bool,
                relaunch: @escaping () -> Void, now: @escaping () -> Date = Date.init,
                delay: Duration = .seconds(5)) {
        self.settings = settings; self.notifier = notifier; self.isFocusRunning = isFocusRunning
        self.relaunch = relaunch; self.now = now; self.delay = delay
    }

    /// Called after every OCR failure.
    public func ocrStreakChanged(_ streak: OCRStreak) {
        let lastRelaunch = settings.get(SelfHeal.relaunchKey).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
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
                settings.set(SelfHeal.relaunchKey, String(now().timeIntervalSince1970))
                relaunch()
            }
        }
    }
}
