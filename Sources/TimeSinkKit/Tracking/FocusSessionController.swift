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
    /// Double-tap window for `keepFocusTapped` (HUD "坚持专注" button). Not
    /// `private`: `FocusHUDController` waits exactly this long before
    /// collapsing the HUD on a first tap, so the second tap stays reachable.
    static let doubleTapWindow: TimeInterval = 0.4

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
    /// Production = NSRunningApplication lookup + hide() -- doesn't poll or
    /// retry (`FocusBlockPolicy`'s cooldown already rate-limits repeat
    /// attempts) and doesn't trust `hide()`'s return value (it lies in
    /// practice).
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
    /// No-op (not throwing) if a session is already running -- a second
    /// `start` call would otherwise orphan the first row (never `finish`ed,
    /// its `end` frozen at its last heartbeat) while overwriting `running`
    /// with a brand-new session.
    public func start(minutes: Int) throws {
        guard running == nil else { return }
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
    /// duration), then clears all running state. Public entry point for
    /// every caller OTHER than `tick`'s own auto-completion (HUD/popover
    /// "结束会话", `applicationShouldTerminate`) -- uses the real wall clock
    /// since none of those callers have a `now` to hand in.
    public func finish(completed: Bool) {
        finish(completed: completed, now: Date())
    }

    /// R-T12d: when `completed` is true, `end` is clamped to no later than
    /// `start + plannedSeconds` -- `tick(now:)` calls this with its own
    /// `now`, which on a real `Timer` reflects the wall clock at the moment
    /// the tick actually fires. Without the clamp, a missed-tick gap (e.g.
    /// the lid closes mid-session and the `Timer` doesn't fire again until
    /// wake) persists the row with `end` stamped at the FAR-future `now` the
    /// first post-wake tick observes -- a 25-minute session waking 4 hours
    /// later would otherwise persist as a 4-hour "completed" row. A manual
    /// end (`completed == false`) is never clamped -- `now` there.
    private func finish(completed: Bool, now: Date) {
        guard let running else { return }
        timer?.invalidate()
        timer = nil
        let end = completed
            ? min(now, running.start.addingTimeInterval(TimeInterval(running.plannedSeconds)))
            : now
        do {
            try store.finish(id: running.id, end: end, appBlocks: appBlocks, siteBlocks: siteBlocks, completed: completed)
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
    ///
    /// R-T12c: the block-page check runs BEFORE the `running` guard --
    /// stateless and pure, and TimeSink's own block page is never
    /// meaningful data whether or not a session happens to be running (a
    /// session can end while the block page is still the frontmost tab; the
    /// original `guard let running` placement let that post-session dwell
    /// accrue real "TimeSink 拦截页" spans).
    @discardableResult
    public func intercept(sample: Sample, at now: Date) -> Bool {
        if isBlockPageSample(sample) { return true }

        guard let running else { return false }

        if settings.focusAppBlockEnabled,
           running.blockedApps.contains(sample.appBundleID),
           policy.shouldHide(sample.appBundleID, at: now) {
            hideApp?(sample.appBundleID)
            appBlocks += 1
            lastHiddenAppKey = sample.appBundleID
            showHUD?(sample.appName, appBlocks)
            return false
        }

        // R-T12b: `policy.shouldHide` (the same cooldown decision 3 uses)
        // gates the redirect in addition to `!isAllowed` -- without it, a
        // stale `chromeTabState` replay (the engine's Chrome throttle only
        // re-fetches every 5s, and its backoff can skip fetches for up to
        // 60s without resetting `chromeTabState`) re-fires the redirect on
        // every tick the stale URL is still attached to the sample: a
        // single blocked-domain visit was observed producing 3 redirects
        // off 1 real fetch, and a persistently FAILING redirect would retry
        // unboundedly at 1 synchronous AppleEvent/second from the main
        // actor. `shouldHide` records its own `lastHidden` timestamp on a
        // `true` result, so this reuses `FocusBlockPolicy`'s existing
        // per-key cooldown rather than adding a second one.
        if settings.focusSiteBlockEnabled, sample.appBundleID == Self.chromeBundleID,
           let url = sample.url, let domain = DomainParser.domain(from: url),
           let category = categoryForDomain?(domain, url),
           running.blockedCategories.contains(category),
           !policy.isAllowed(domain, at: now),
           policy.shouldHide(domain, at: now) {
            let target = Self.blockPageURL(domain: domain, remaining: remaining)
            if redirectChrome?(target) == true {
                siteBlocks += 1
            }
            return false
        }

        // R-T12e: gated on a non-empty `blockedCategories` -- otherwise this
        // fires on the default config (site-block enabled, nothing actually
        // chosen to block yet) and announces "already hidden" for a hide
        // that never happened. `hideCount: 0` (not `appBlocks`) signals to
        // the HUD that this is the degraded notice, not an actual hide --
        // see `FocusHUDController.show`.
        if settings.focusSiteBlockEnabled, !running.blockedCategories.isEmpty,
           Self.otherBrowserBundleIDs.contains(sample.appBundleID) {
            if !shownDegradedFor.contains(sample.appBundleID) {
                shownDegradedFor.insert(sample.appBundleID)
                lastHiddenAppKey = sample.appBundleID
                showHUD?(sample.appName + "（无法拦截该浏览器的网站）", 0)
            }
            return false
        }

        return false
    }

    /// "放行 5 分钟" from the block page's own button.
    public func allowDomain(_ domain: String) {
        policy.allow(domain, at: Date())
    }

    /// What a `keepFocusTapped` call decided, so the HUD can respond visibly
    /// to BOTH taps (spec §9's 「坚持专注」= 收 HUD；双击 = 放行 5 分钟).
    public enum KeepFocusOutcome: Equatable, Sendable {
        /// First tap: nothing allowed (yet), but the double-tap window is now
        /// open. The HUD collapses after `doubleTapWindow` so a second tap
        /// stays reachable.
        case armed
        /// Second tap inside the window: the app is allowed for 5 minutes and
        /// the HUD collapses immediately.
        case allowed
    }

    /// HUD "坚持专注" button. Two taps for the same `appKey` within
    /// `doubleTapWindow` allow that app for the rest of the 5-minute
    /// allowance (mirrors the block page's "放行 5 分钟").
    ///
    /// The return value is what makes the button visibly responsive: before
    /// it existed, both taps only mutated invisible state, so the HUD just
    /// sat there until its 4s auto-dismiss and the button read as dead.
    @discardableResult
    public func keepFocusTapped(appKey: String, at now: Date) -> KeepFocusOutcome {
        if let last = lastKeepFocusTap, last.key == appKey,
           now.timeIntervalSince(last.date) <= Self.doubleTapWindow {
            policy.allow(appKey, at: now)
            lastKeepFocusTap = nil
            return .allowed
        }
        lastKeepFocusTap = (appKey, now)
        return .armed
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
            finish(completed: true, now: now)
        }
    }

    /// Pure: `planned` seconds minus elapsed time since `start`, evaluated at
    /// `now`. `nonisolated` so it's callable without a `@MainActor` hop.
    public nonisolated static func remainingSeconds(start: Date, planned: Int, now: Date) -> TimeInterval {
        TimeInterval(planned) - now.timeIntervalSince(start)
    }

    /// R-T12g: uses the pure `FocusBlockPage.location` -- never
    /// `ensureWritten()` -- so the controller (and every test that exercises
    /// this path) never performs the actual file write. `ensureWritten()`
    /// is called exactly once, in the PRODUCTION `redirectChrome` closure
    /// (`TimeSinkApp` assembly), immediately before the real redirect.
    private static func blockPageURL(domain: String, remaining: TimeInterval) -> String {
        let pageURL = FocusBlockPage.location
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

public enum FocusSessionError: Error {
    case missingRowID
}
