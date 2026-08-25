import Foundation
import os

/// Per-app hide cooldown + 5-minute allowance, a pure value type mirroring
/// `ChromeThrottle`'s testable shape (see `TrackerEngine.swift`).
public struct FocusBlockPolicy: Sendable {
    public var cooldown: TimeInterval = 10
    public var allowance: TimeInterval = 300
    private var lastHidden: [String: Date] = [:]
    private var allowedUntil: [String: Date] = [:]

    public init() {}

    /// True when `key` isn't currently allowed AND at least `cooldown`
    /// seconds have passed since it was last hidden (or it's never been
    /// hidden). A `true` result records `date` as the new `lastHidden` for
    /// `key`.
    public mutating func shouldHide(_ key: String, at date: Date) -> Bool {
        guard !isAllowed(key, at: date) else { return false }
        if let last = lastHidden[key], date.timeIntervalSince(last) < cooldown {
            return false
        }
        lastHidden[key] = date
        return true
    }

    public mutating func allow(_ key: String, at date: Date) {
        allowedUntil[key] = date.addingTimeInterval(allowance)
    }

    public func isAllowed(_ key: String, at date: Date) -> Bool {
        guard let until = allowedUntil[key] else { return false }
        return date < until
    }
}

/// State machine for one focus session: countdown, per-tick blocking
/// decisions (app soft-block / Chrome site hard-block), and the HUD/finish
/// notification hooks. Pure decision logic lives in `intercept(sample:at:)`
/// and `FocusBlockPolicy`; every side effect (hiding an app, redirecting
/// Chrome, showing the HUD, posting a notification) is injected as a closure
/// so this type -- and its tests -- never touch AppKit/ScriptingBridge/
/// UserNotifications directly.
@MainActor
@Observable
public final class FocusSessionController {
    public struct Running: Equatable {
        public var id: Int64
        public var start: Date
        public var plannedSeconds: Int
        public var blockedApps: Set<String>
        public var blockedCategories: Set<String>
    }

    private static let chromeBundleID = "com.google.Chrome"
    /// Non-Chrome browsers whose sites can't be hard-blocked (no
    /// ScriptingBridge/AppleEvents integration) -- decision 5 shows a
    /// once-per-session degraded notice instead.
    private static let otherBrowserBundleIDs: Set<String> = [
        "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser", "com.microsoft.edgemac",
    ]
    private static let heartbeatInterval: TimeInterval = 30
    /// Double-tap window for `keepFocusTapped` (HUD "坚持专注" button).
    private static let doubleTapWindow: TimeInterval = 0.4

    public private(set) var running: Running?
    public private(set) var remaining: TimeInterval = 0
    public private(set) var appBlocks = 0
    public private(set) var siteBlocks = 0
    /// The bundle ID most recently hidden (or, for the non-Chrome-browser
    /// degraded notice, most recently flagged) by `intercept` -- `showHUD`'s
    /// own signature only carries a display `appName`, not a bundle ID, so
    /// production HUD wiring reads this to know what key `keepFocusTapped`'s
    /// "坚持专注" button should allow.
    public private(set) var lastHiddenAppKey: String?

    // Injected (wired up by `TimeSinkApp` assembly):
    public var notifier: (any Notifying)?
    /// Package resolver: domain (+ optional url) -> category id.
    public var categoryForDomain: ((_ domain: String, _ url: String?) -> String)?
    /// Production = NSRunningApplication lookup + hide() (polls isHidden,
    /// doesn't trust the return value).
    public var hideApp: ((String) -> Void)?
    /// Production = ChromeBlocker.setActiveTabURL.
    public var redirectChrome: ((String) -> Bool)?
    public var showHUD: ((_ appName: String, _ hideCount: Int) -> Void)?
    /// Fires on every finish (completed or manual): posts the end
    /// notification and refreshes the timeline.
    public var onFinish: ((_ completed: Bool, _ appBlocks: Int, _ siteBlocks: Int) -> Void)?

    private let store: FocusSessionStore
    private let settings: SettingsStore
    private var policy = FocusBlockPolicy()
    private var timer: Timer?
    private var lastHeartbeat: Date = .distantPast
    /// Degraded-notice-shown flags for non-Chrome browsers (decision 5),
    /// reset every `start(minutes:)` -- "once per session" per bundle ID.
    private var shownDegradedFor: Set<String> = []
    /// `(appKey, date)` of the most recent `keepFocusTapped` call, used to
    /// detect the 0.4s double-tap.
    private var lastKeepFocusTap: (key: String, date: Date)?

    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "focusSession")

    public init(store: FocusSessionStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    /// Reads the current app/category block-list snapshot from `settings`
    /// into `Running`, inserts the session row, and starts the 1s UI timer.
    public func start(minutes: Int) throws {
        let now = Date()
        let plannedSeconds = minutes * 60
        let session = try store.start(at: now, plannedSeconds: plannedSeconds)
        guard let id = session.id else {
            // GRDB's didInsert always assigns id on a successful insert; this
            // branch is unreachable in practice but keeps `start` from
            // silently running with a bogus Running.id if that ever changes.
            throw FocusSessionError.missingRowID
        }
        running = Running(
            id: id, start: now, plannedSeconds: plannedSeconds,
            blockedApps: Set(settings.focusBlockedApps),
            blockedCategories: Set(settings.focusBlockedCategories)
        )
        remaining = TimeInterval(plannedSeconds)
        appBlocks = 0
        siteBlocks = 0
        policy = FocusBlockPolicy()
        shownDegradedFor = []
        lastHeartbeat = now
        lastKeepFocusTap = nil

        startTimer()

        if let notifier {
            Task {
                _ = await notifier.requestAuthorization()
            }
        }
    }

    /// Idempotent: a second call (or a call with no running session) is a
    /// no-op past the guard. Writes the final row, invokes `onFinish` (while
    /// `running` is still readable -- the notification body needs
    /// `running.plannedSeconds`, and `onFinish`'s own signature carries no
    /// duration), then clears all running state.
    public func finish(completed: Bool) {
        guard let running else { return }
        timer?.invalidate()
        timer = nil
        do {
            try store.finish(id: running.id, end: Date(), appBlocks: appBlocks, siteBlocks: siteBlocks, completed: completed)
        } catch {
            logger.error("finish failed: \(String(describing: error))")
        }
        let finalAppBlocks = appBlocks
        let finalSiteBlocks = siteBlocks
        onFinish?(completed, finalAppBlocks, finalSiteBlocks)
        self.running = nil
        remaining = 0
    }

    /// Called once per engine tick (see `TrackerEngine.focusInterceptor`).
    /// Returns `true` only for the block-page's own sample (decision 2) --
    /// every other branch (app hide, site redirect, degraded notice) records
    /// the tick's sample normally (`false`), since the side effect (hiding,
    /// redirecting) takes effect from the NEXT sample on, not retroactively.
    @discardableResult
    public func intercept(sample: Sample, at now: Date) -> Bool {
        guard let running else { return false }

        if isBlockPageSample(sample) { return true }

        if settings.focusAppBlockEnabled,
           running.blockedApps.contains(sample.appBundleID),
           policy.shouldHide(sample.appBundleID, at: now) {
            hideApp?(sample.appBundleID)
            appBlocks += 1
            lastHiddenAppKey = sample.appBundleID
            showHUD?(sample.appName, appBlocks)
            return false
        }

        if settings.focusSiteBlockEnabled, sample.appBundleID == Self.chromeBundleID,
           let url = sample.url, let domain = DomainParser.domain(from: url),
           let category = categoryForDomain?(domain, url),
           running.blockedCategories.contains(category),
           !policy.isAllowed(domain, at: now) {
            let target = Self.blockPageURL(domain: domain, remaining: remaining)
            if redirectChrome?(target) == true {
                siteBlocks += 1
            }
            return false
        }

        if settings.focusSiteBlockEnabled, Self.otherBrowserBundleIDs.contains(sample.appBundleID) {
            if !shownDegradedFor.contains(sample.appBundleID) {
                shownDegradedFor.insert(sample.appBundleID)
                lastHiddenAppKey = sample.appBundleID
                showHUD?(sample.appName + "（无法拦截该浏览器的网站）", appBlocks)
            }
            return false
        }

        return false
    }

    /// "放行 5 分钟" from the block page's own button.
    public func allowDomain(_ domain: String) {
        policy.allow(domain, at: Date())
    }

    /// HUD "坚持专注" button. Two taps for the same `appKey` within
    /// `doubleTapWindow` allow that app for the rest of the 5-minute
    /// allowance (mirrors the block page's "放行 5 分钟").
    public func keepFocusTapped(appKey: String, at now: Date) {
        if let last = lastKeepFocusTap, last.key == appKey,
           now.timeIntervalSince(last.date) <= Self.doubleTapWindow {
            policy.allow(appKey, at: now)
            lastKeepFocusTap = nil
        } else {
            lastKeepFocusTap = (appKey, now)
        }
    }

    // MARK: - 1s timer

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Internal (not `private`) so tests can inject a fake `now` without a
    /// real 1s wait -- mirrors `TrackerEngine.tick(now:)`'s shape. Updates
    /// only this controller's own `@Observable` state; never calls
    /// `AppModel.dataChanged()` (that's the explicit `finish` path's job).
    func tick(now: Date) {
        guard let running else { return }
        remaining = max(0, Self.remainingSeconds(start: running.start, planned: running.plannedSeconds, now: now))
        if now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval {
            lastHeartbeat = now
            do {
                try store.heartbeat(id: running.id, end: now)
            } catch {
                logger.error("heartbeat failed: \(String(describing: error))")
            }
        }
        if remaining <= 0 {
            finish(completed: true)
        }
    }

    /// Pure: `planned` seconds minus elapsed time since `start`, evaluated at
    /// `now`. `nonisolated` so it's callable without a `@MainActor` hop.
    public nonisolated static func remainingSeconds(start: Date, planned: Int, now: Date) -> TimeInterval {
        TimeInterval(planned) - now.timeIntervalSince(start)
    }

    private static func blockPageURL(domain: String, remaining: TimeInterval) -> String {
        let pageURL = FocusBlockPage.ensureWritten()
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "domain", value: domain),
            URLQueryItem(name: "remaining", value: Format.mmss(remaining)),
        ]
        return components?.url?.absoluteString ?? pageURL.absoluteString
    }

    /// Decision 2: the block page's own sample must never be recorded into
    /// stats (it would misattribute the interception itself as browsing
    /// time). Two independent signals -- either is sufficient -- since which
    /// one is actually populated depends on where in `TrackerEngine.tick`
    /// this fires relative to Chrome's own tab enrichment.
    private func isBlockPageSample(_ sample: Sample) -> Bool {
        if let url = sample.url, url.hasPrefix(FocusBlockPage.location.absoluteString) {
            return true
        }
        return sample.windowTitle == FocusBlockPage.pageMarkerTitle
    }
}

enum FocusSessionError: Error {
    case missingRowID
}
