import CoreGraphics
import Foundation
import os

/// Throttles Chrome active-tab fetches: only re-fetch when the window or its
/// title changed since the last fetch, or when `interval` seconds have
/// elapsed. The window counts on its own because two windows can share a
/// title (two "New Tab"s), and only one of them may be private.
public struct ChromeThrottle {
    let interval: TimeInterval
    private var lastTitle: String??
    private var lastWindow: UInt32??
    private var lastFetch = Date.distantPast
    public init(interval: TimeInterval = 5) { self.interval = interval }
    public mutating func shouldFetch(title: String?, window: UInt32? = nil, at date: Date) -> Bool {
        title != lastTitle || window != lastWindow || date.timeIntervalSince(lastFetch) >= interval
    }
    public mutating func noteFetched(title: String?, window: UInt32? = nil, at date: Date) {
        lastTitle = title; lastWindow = window; lastFetch = date
    }
}

/// Exponential backoff for Chrome tab fetches. The first two consecutive
/// failures retry freely (transient hiccups); from the third on, attempts
/// are spaced 2^(n-2) seconds apart (capped at 60s) so a persistently
/// failing target -- e.g. Automation permission revoked mid-run -- is not
/// hammered with a denied Apple Event every second forever. Five
/// consecutive failures flip `isDegraded` for UI surfacing.
struct ChromeFetchBackoff {
    private(set) var consecutiveFailures = 0
    private var lastFailure = Date.distantPast

    var isDegraded: Bool { consecutiveFailures >= 5 }

    func shouldAttempt(at date: Date) -> Bool {
        guard consecutiveFailures >= 3 else { return true }
        let delay = min(60, pow(2, Double(consecutiveFailures - 2)))
        // Strict `>`: at exactly `delay` elapsed, still within the backoff
        // window -- the next attempt is permitted only once it's exceeded.
        return date.timeIntervalSince(lastFailure) > delay
    }

    mutating func noteSuccess() {
        consecutiveFailures = 0
    }

    mutating func noteFailure(at date: Date) {
        consecutiveFailures += 1
        lastFailure = date
    }
}

/// Splits suspension into two independent causes so a lock/sleep suspension
/// can't be silently cleared by the next tick's idle check. `idleSuspended`
/// is set/cleared purely by comparing `idleSeconds` against `threshold`
/// every tick; `systemSuspended` is set only by an explicit lock/sleep
/// signal and cleared only by an explicit unlock (or confirmed-unlocked
/// wake) signal -- ticking never touches it.
public struct SuspensionState: Equatable {
    public private(set) var idleSuspended = false
    public private(set) var systemSuspended = false

    public var isSuspended: Bool { idleSuspended || systemSuspended }

    public init() {}

    public enum TickOutcome: Equatable {
        /// `systemSuspended` is set: caller must return early -- no
        /// sampling, and `idleSuspended` is left untouched.
        case systemSuspended
        /// `idleSeconds` just crossed `threshold` this tick: caller should
        /// close+persist the current span, backdated to the last input.
        case becameIdle
        /// Already idle-suspended: no-op, no sampling.
        case stillIdle
        /// Not suspended: caller should sample as normal.
        case active
    }

    /// Evaluates one tick. While `systemSuspended`, always returns
    /// `.systemSuspended` without reading `idleSeconds` at all -- this is
    /// the fix for the bug where idle reading ~0-1s right after a lock/wake
    /// used to clear suspension on a single shared flag.
    public mutating func tick(idleSeconds: TimeInterval, threshold: TimeInterval) -> TickOutcome {
        guard !systemSuspended else { return .systemSuspended }
        if idleSeconds >= threshold {
            if idleSuspended { return .stillIdle }
            idleSuspended = true
            return .becameIdle
        }
        if idleSuspended { idleSuspended = false }
        return .active
    }

    /// Lock or sleep begins. Returns `true` if this call performed the
    /// false->true transition (caller should close the current span);
    /// `false` if already system-suspended (idempotent).
    @discardableResult
    public mutating func suspendSystem() -> Bool {
        guard !systemSuspended else { return false }
        systemSuspended = true
        return true
    }

    /// `com.apple.screenIsUnlocked` -- authoritative, always clears system
    /// suspension.
    public mutating func unlock() {
        systemSuspended = false
    }

    /// `NSWorkspace.didWakeNotification` -- not authoritative on its own
    /// (macOS can wake while the screen is still locked); caller supplies
    /// the `CGSessionCopyCurrentDictionary`-derived answer. Only clears
    /// system suspension if the screen is confirmed unlocked; otherwise the
    /// later `unlock()` call (from `screenIsUnlocked`) is what clears it.
    public mutating func wake(screenStillLocked: Bool) {
        if !screenStillLocked {
            systemSuspended = false
        }
    }
}

/// Drives the 1s sampling loop: samples the frontmost window, throttles Chrome
/// tab lookups, tracks idle/lock/sleep suspension, and persists spans to
/// `SpanStore`.
///
/// Write policy for the current in-progress span: nothing is inserted on the
/// opening tick. The first write happens at whichever comes first: the span's
/// first 30s heartbeat after it opened (only if it has lasted >= 1s by then),
/// or the span closing early with >= 1s duration. This avoids DB churn for
/// sub-second/sub-30s activity flicker. Once a row exists (rowID known),
/// every subsequent write -- 30s heartbeat or final close -- always
/// reconciles that row via `updateEnd`, even if a later idle-backdated close
/// makes the final duration look short (or zero); there is no delete path
/// and no minimum-duration clamp on an already-written row, so a written row
/// must always be corrected rather than abandoned. The same holds for rows
/// already closed: an idle or lock backdate also trims the spans written
/// since the last input (`trimPersisted(after:)`) instead of leaving them
/// with an idle tail.
@MainActor
public final class TrackerEngine {
    private static let chromeBundleID = "com.google.Chrome"
    /// Every browser whose tab is read; see `ChromeSampler.bundleIDs`.
    static let browserBundleIDs = ChromeSampler.bundleIDs
    /// Apps whose window title is a constant and whose real identity is the
    /// conversation inside the web view -- see `ChatSessionSampler`.
    static let chatBundleIDs: Set<String> = [
        "com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop",
    ]
    /// The conversation is re-read at most this often. Unlike Chrome there
    /// is no cheap change signal to gate on: the window title these apps
    /// publish never changes, so the interval is the whole gate.
    private static let chatFetchInterval: TimeInterval = 5
    private static let minWriteDuration: TimeInterval = 1
    private static let heartbeatInterval: TimeInterval = 30
    /// No input for this long when the screen locks or the Mac sleeps means
    /// nobody was there: the close goes back to the last input.
    private static let lockBackdateMinimum: TimeInterval = 30
    /// While locked or asleep by our own account, the real lock state is
    /// re-read this often, so one missed unlock notification cannot stop
    /// recording for hours.
    private static let lockRecheckInterval: TimeInterval = 10

    private let spanStore: SpanStore
    private let settings: SettingsStore
    /// Where state reasons land (migration v5); nil keeps tests store-free.
    private let observations: ObservationStore?
    /// Fed one sample per tick, including idle ticks: reading without
    /// touching the keyboard is still activity worth seeing.
    public var screenCollector: ScreenCollector?

    private let builder = SpanBuilder()
    private let windowSampler = WindowSampler()
    private let chromeSampler = ChromeSampler()
    private let chatSampler = ChatSessionSampler()
    private let idleMonitor = IdleMonitor()
    private let systemMonitor = SystemMonitor()
    private var throttle = ChromeThrottle()

    public private(set) var currentRowID: Int64?
    /// Read-only presentation state; reading this never starts sampling.
    public var currentActivity: Span? { builder.current }
    public var isRunning: Bool { timer != nil }
    public private(set) var userPaused = false
    private var permissionGranted = true
    public func setPermissionGranted(_ granted: Bool, at date: Date = Date()) {
        guard granted != permissionGranted else { return }
        permissionGranted = granted; suspensionEpoch += 1
        if !granted, let closed = builder.close(at: date) { persist(closed) }
        interruptCollector()
    }

    /// Keep the timer and lock state alive, but stop every sampling path.
    /// In-flight samples are invalidated by the same epoch as lock and sleep.
    public func setUserPaused(_ paused: Bool, at date: Date = Date()) {
        guard userPaused != paused else { return }
        userPaused = paused
        suspensionEpoch += 1
        if paused, let closed = builder.close(at: date) { persist(closed) }
        throttle = ChromeThrottle()
        chromeTabState = .none
        chromeTabWindowID = nil
        chromeTabBundleID = nil
        chatSession = nil
        lastChatFetch = .distantPast
        observations?.logState(paused ? "tracking_pause" : "tracking_resume", at: date)
        interruptCollector()
    }
    private var lastHeartbeat = Date.distantPast

    /// Chrome tab capture state, for the window `chromeTabWindowID`. `.none`
    /// (fetch failed / never fetched) never carries a URL -- the pre-fix code
    /// kept applying the last successful URL forever, misattributing days of
    /// browsing to one stale domain once fetches started failing. It keeps
    /// the AX window title only for a window an earlier read found not
    /// private (`browserWindowPrivacy`); any other window may be private, so
    /// both are suppressed. A failure never overwrites a prior `.incognito`
    /// -- that suppression is sticky until the next successful,
    /// non-incognito fetch. `blockURL` is a private tab's address, read only
    /// while focus blocking needs it (`focusNeedsPrivateTab`) and handed to
    /// `focusInterceptor` alone; it is never recorded.
    private enum ChromeTabState {
        case none
        case tab(url: String?, title: String?)
        case incognito(blockURL: String?)
    }
    private var chromeTabState: ChromeTabState = .none
    /// The CGWindowID `chromeTabState` was read from. Another window of the
    /// same browser gets nothing from it: a cached page or a "not private"
    /// answer belongs to the window it was read from.
    private var chromeTabWindowID: UInt32?
    /// Whether a browser window was found private (true) or not (false), by
    /// CGWindowID. A window is one or the other for its whole life, so this
    /// answers for it when a read fails, is backed off, or was of another
    /// window. A private answer is never overwritten: a read can race the
    /// user switching windows, and the race may only ever err toward
    /// recording less.
    private var browserWindowPrivacy: [UInt32: Bool] = [:]
    private static let browserWindowPrivacyLimit = 512
    /// The browser `chromeTabState`, `throttle` and the cached authorization
    /// describe. Switching browsers drops all three, so Chrome's page can
    /// never be filed under Arc, nor Arc's private window outlive the switch
    /// -- the same stale-value failure `chatSession` is keyed against.
    private var chromeTabBundleID: String?
    /// One per browser: a browser that was never granted Automation backs
    /// off on its own, without delaying the others.
    private var chromeBackoffs: [String: ChromeFetchBackoff] = [:]

    /// Last conversation read, and which app it was read from. Keyed by
    /// bundle ID so a switch between ChatGPT and Claude can never file one
    /// app's conversation under the other -- the same stale-value failure
    /// the Chrome tab cache was fixed for, where a cached value outlived
    /// what it described.
    private var chatSession: (bundleID: String, title: String?)?
    private var lastChatFetch = Date.distantPast

    /// Chrome Automation authorization, refreshed at most once per fetch
    /// attempt -- inside the same `chromeBackoffs` gate that
    /// spaces out attempts -- rather than on every tick.
    /// `AEDeterminePermissionToAutomateTarget` is a slow IPC round-trip to
    /// tccd; `chromeCaptureDegraded` used to call it fresh every second,
    /// forever, for anyone who declined the permission (`.none` is the
    /// permanent steady state in that case). It now only ever reads this
    /// cached value.
    private var cachedChromeAutomationAuthorized = false

    /// Test seams: when set, replace the real AX / ScriptingBridge samplers.
    /// The two sampler seams are `@Sendable` and take the tick's own `now`
    /// because `tickAsync` invokes them off the main actor, exactly where the
    /// real samplers run. `chromeAutomationAuthorizedProvider` stays
    /// main-actor because the real check behind it
    /// (`Permissions.chromeAutomationStatus`) is `@MainActor`, and the
    /// throttle+backoff gate already keeps it to at most once per 5s.
    var windowSampleProvider: (@Sendable (Date) -> Sample?)?
    var chromeTabProvider: (@Sendable () -> ChromeSampler.TabInfo?)?
    var chatSessionProvider: (@Sendable () -> String?)?
    var chromeAutomationAuthorizedProvider: (() -> Bool)?
    var idleSecondsProvider: (() -> TimeInterval)?
    /// Seconds since the last keyDown; the real reading is one
    /// `CGEventSource` call, the same kind `IdleMonitor` already makes.
    var keyDownSecondsProvider: (() -> TimeInterval)?
    /// True while the user is currently in a calendar meeting -- when set,
    /// `tick` forces `idleSeconds` to 0 regardless of the real idle reading,
    /// so hands-off-keyboard time during a video call never triggers
    /// `becameIdle` (C3 idle exemption). Only while not already idle: the
    /// exemption keeps an active span from going idle, it never brings an
    /// idle one back (left for lunch at 11:50, a 12:00 all-hands on the
    /// calendar is not the user at the Mac). Lock/sleep suspension is
    /// untouched by this -- it only ever affects the idle branch of
    /// `SuspensionState.tick`.
    var isInMeetingProvider: (() -> Bool)?
    /// Whether the screen is locked right now; replaces the window-server
    /// read (`SystemMonitor.isScreenLocked`) in tests.
    var screenLockedProvider: (() -> Bool)?

    /// C4 focus session seam: consulted once per sampled tick, after Chrome
    /// tab-URL enrichment and before the private-window, left-out and idle
    /// checks that skip recording -- none of those may be a way around a
    /// focus session. Returning `true` skips this tick's sample entirely
    /// (the focus block page's own synthetic Chrome tab -- see
    /// `FocusSessionController.intercept`'s decision 2); every other
    /// intercept outcome (app hidden, site redirected) returns `false` and
    /// the sample is recorded normally. Deliberately placed AFTER Chrome
    /// enrichment rather than immediately after the sample guard: Chrome
    /// site-category blocking needs `sample.url`, which `WindowSampler`
    /// always leaves `nil` -- only the Chrome branch above ever populates it
    /// from `chromeTabState`. A private window's sample carries its
    /// `blockURL` here and nowhere else. Placed here it still never touches
    /// the calendar idle-exemption logic above the sample guard. Paused
    /// recording reads no window at all, so it is not consulted then.
    var focusInterceptor: ((Sample, Date) -> Bool)?
    /// Whether focus blocking wants to see sites in `browser` right now; only
    /// then is a private window's address read (see `ChromeTabState`).
    var focusNeedsPrivateTab: ((String) -> Bool)?

    /// True when 5+ consecutive Chrome tab fetch failures coincide with
    /// Chrome Automation not being authorized; cleared by the next success.
    /// Read by the menu bar dashboard to drive a permission-specific
    /// warning. Deliberately NOT just "5 consecutive failures": Chrome can
    /// also fail every fetch while frontmost with zero windows (e.g. all
    /// windows closed, or a picture-in-picture-only state) -- that is not a
    /// permissions problem and must not trigger a warning that tells the
    /// user to check a permission that's actually fine.
    public private(set) var chromeCaptureDegraded = false

    private var timer: Timer?

    /// Reentrancy guard for `tickAsync`. The 1s timer keeps firing while a
    /// tick is parked on off-actor IPC, and a tick's worst case is ~0.75s
    /// (two 0.25s AX reads + one 0.25s Apple Event) -- more with a hung app
    /// still inside its timeout. Without this guard a slow tick's
    /// continuation interleaves with the next tick and both mutate
    /// `builder.current`, `chromeTabState`, `throttle`, `chromeBackoffs`,
    /// `currentRowID` and `lastHeartbeat`: that double-inserts a span or
    /// corrupts the open one, which is a data-integrity bug, not a perf nit.
    ///
    /// Overlapping ticks are SKIPPED, never queued. Queuing would turn one
    /// slow app into an unbounded backlog of stale samples, each applied with
    /// a timestamp the state machine has already moved past --
    /// `SpanBuilder.ingest` sets `cur.end = sample.timestamp + tick`
    /// unconditionally, so a late sample applied after a newer one drags the
    /// open span's end backwards. Skipping keeps sample order monotonic by
    /// construction: at most one tick is ever in flight, and each one starts
    /// at a later wall time than the last one finished.
    ///
    /// Cost of a skip: one lost 1s sample and a heartbeat checkpoint deferred
    /// to the next tick, both well inside the existing 30s heartbeat slack.
    private var tickInFlight = false

    public var onChange: (() -> Void)?
    /// Every recorded tick, with the open span: 回到刚才 watches it.
    public var onTick: ((Span?, Date) -> Void)?
    /// Start of the span the last `onChange` wrote: nothing before it changed.
    public private(set) var lastWriteStart: Date?
    private var suspensionState = SuspensionState()

    /// Bumped by every suspension-context change: `suspend(at:)`,
    /// `resume(source:)` and `stop()`. `tickAsync` captures it immediately
    /// before each `await` and drops the sample if it moved.
    ///
    /// A CHANGE detector, not a state read. Reading `isSuspended` after the
    /// await answers "am I suspended now", which a suspend/resume pair landing
    /// entirely inside one IPC window (the machine sleeps and wakes while a
    /// tick is parked) answers `false` to -- waving through exactly the stale
    /// sample the recheck exists to stop. The epoch also subsumes the flag
    /// read: `beginTick` only returns `true` when nothing is suspended, so any
    /// suspension after it necessarily arrives with a bump.
    ///
    /// Why a recheck at all: the main actor stays live while a tick is parked
    /// on IPC, so `suspend(at:)` -- screen lock or sleep, delivered by
    /// `SystemMonitor`, not by ticking -- can have closed and persisted the
    /// current span in between. Ingesting the sample afterwards would reopen a
    /// span behind the lock screen: the exact bug class `SuspensionState`
    /// exists to prevent, reintroduced through the back door of a suspension
    /// point.
    ///
    /// A late sample is DROPPED, never re-timestamped to "now": its `now` is
    /// the timestamp every state-machine decision earlier in this tick was
    /// already made against (idle backdating, the Chrome throttle window,
    /// `focusInterceptor`), and re-stamping it would silently disagree with
    /// all of them. Dropping costs one 1s sample; the reentrancy guard
    /// guarantees the next tick starts from a clean state.
    private var suspensionEpoch = 0

    public var isSuspended: Bool { suspensionState.isSuspended }
    public private(set) var latestSample: Sample?

    /// Whether the previous tick applied the meeting idle-exemption -- used
    /// only to detect the true->false transition below.
    private var wasExempt = false
    /// Set on the tick where the meeting idle-exemption transitions
    /// true->false (the moment it stops zeroing `idleSeconds`). CRITICAL
    /// fix: without this, un-exempting mid-idle-stretch backdates
    /// `builder.close(at:)` using the FULL raw idle duration -- which, right
    /// after a meeting, includes the entire meeting itself (hands were off
    /// the keyboard throughout) -- collapsing the just-persisted meeting
    /// span's duration down to ~0s the instant the meeting ends while still
    /// idle. Clamping the close to no earlier than this moment preserves
    /// the span's real extent. Consumed (cleared) the next time it's read.
    private var exemptionEndedAt: Date?
    /// This tick's idle reading (0 in a meeting), handed to the screen
    /// collector so an untouched window is checked less often.
    private var idleSeconds: TimeInterval = 0
    /// Previous tick's `now`, and whether a key went down since then. A
    /// key-second is a tick with a new keyDown; the span's opening tick never
    /// counts (see `SpanBuilder.noteKeySecond`), which drops the ⌘⇥ that
    /// switched into it and any single shortcut like ⌘W.
    private var lastTickAt = Date.distantPast
    private var keyDownThisTick = false
    /// The last input as of the latest tick, and the rows of the spans
    /// closed since then: what an idle or lock backdate has to trim besides
    /// the open span.
    private var lastInputAt = Date.distantPast
    private var rowsSinceInput: [Int64] = []
    /// Last time the lock state was re-read while system-suspended.
    private var lastLockCheck = Date.distantPast

    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "tracker")

    public init(spanStore: SpanStore, settings: SettingsStore, observations: ObservationStore? = nil) {
        self.spanStore = spanStore
        self.settings = settings
        self.observations = observations
    }

    public func start() {
        observations?.logState("start")
        systemMonitor.onSuspend = { [weak self] date, source in self?.suspend(at: date, source: source) }
        systemMonitor.onResume = { [weak self] _, source in self?.resume(source: source) }
        systemMonitor.start()
        // Launched behind the lock screen (a login item, an update relaunch):
        // no lock notification is coming, so start suspended.
        if screenLockedProvider?() ?? isScreenLocked() { suspend(at: Date(), source: .lock) }

        // `now` is captured at timer-fire time, not inside the tick, so span
        // timestamps stay on the 1s grid regardless of how long the IPC
        // takes. The `Task` inherits MainActor isolation, so the state
        // machine still starts (and ends) on the main actor.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                Task { await self.tickAsync(now: now) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Closes the current span (if any) and writes it, then stops ticking.
    public func stop() {
        timer?.invalidate()
        timer = nil
        // Same bump as a suspension, for the same reason: a tick parked on IPC
        // right now must not come back and reopen a span after this close.
        // Both callers quit the app, but `NSApp.terminate` still spins the run
        // loop, so that continuation can land.
        suspensionEpoch += 1
        if let closed = builder.close(at: Date()) {
            persist(closed)
        }
        observations?.logState("stop")
        interruptCollector()
    }

    /// The collector paces itself; it only needs to know the observation broke.
    private func interruptCollector() {
        guard let screenCollector else { return }
        Task { await screenCollector.interrupt() }
    }

    /// The one state-machine entry point -- production and tests both drive
    /// this, so there is no second copy of the phase ordering to drift.
    /// Everything that touches engine state stays on the main actor,
    /// including the `NSWorkspace` frontmost-app read; only the AX Mach IPC
    /// and the Chrome Apple Event leave it.
    ///
    /// Two hops rather than one because the Chrome fetch gate
    /// (`shouldFetchChromeTab`) depends on the AX window title AND on
    /// `throttle`/`chromeBackoffs`, which live here. Keeping the decision on
    /// the actor avoids shipping copies of that state across the boundary,
    /// and the second hop only happens when Chrome is frontmost and the 5s
    /// throttle allows -- at most once per 5s, not once per tick.
    func tickAsync(now: Date = Date()) async {
        guard !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        let phase = beginTick(now: now)
        guard phase != .suspended else { return }

        // AppKit on the actor (see `WindowSampler.frontmostApp`). Skipped
        // entirely when a seam is installed, so tests never depend on whichever
        // app happens to be frontmost on the machine running them.
        let frontmost = windowSampleProvider == nil ? windowSampler.frontmostApp() : nil
        let epochBeforeSample = suspensionEpoch
        guard var sample = await offActorWindowSample(
            now: now, provider: windowSampleProvider, app: frontmost
        ) else { return }
        guard suspensionEpoch == epochBeforeSample else { return }

        // What is known about the browser window in front: nil for any
        // other app.
        var frontTab: ChromeTabState?
        let axTitle = sample.windowTitle
        if Self.browserBundleIDs.contains(sample.appBundleID) {
            let browser = sample.appBundleID
            if chromeTabBundleID != browser {
                chromeTabBundleID = browser
                chromeTabState = .none
                chromeTabWindowID = nil
                throttle = ChromeThrottle()
                cachedChromeAutomationAuthorized = false
            }
            if settings.get("chromeTrackingEnabled") == "false" {
                // Turned off in Settings: browsers record app time only.
                chromeTabState = .none
                cachedChromeAutomationAuthorized = false
                sample.url = nil
                sample.windowTitle = nil
                frontTab = ChromeTabState.none
            } else {
                if shouldFetchChromeTab(browser: browser, title: sample.windowTitle, window: sample.windowID, at: now) {
                    // Refresh the cached authorization answer once per attempt,
                    // regardless of whether the fetch itself succeeds -- this is
                    // the only place that ever calls the real TCC check.
                    cachedChromeAutomationAuthorized = chromeAutomationAuthorized(browser: browser)
                    let readPrivateURL = focusNeedsPrivateTab?(browser) == true
                    let epochBeforeChrome = suspensionEpoch
                    let fetched = await offActorChromeTab(
                        provider: chromeTabProvider, browser: browser, readPrivateURL: readPrivateURL
                    )
                    guard suspensionEpoch == epochBeforeChrome else { return }
                    noteChromeFetch(fetched, browser: browser, title: sample.windowTitle,
                                    window: sample.windowID, readPrivateURL: readPrivateURL, at: now)
                }
                let state = tabState(forWindow: sample.windowID)
                applyChromeTabState(state, to: &sample)
                frontTab = state
            }
        } else if Self.chatBundleIDs.contains(sample.appBundleID) {
            // Refetch when the cached answer belongs to a different app, or
            // when it has simply aged out; otherwise reuse it, exactly as
            // the Chrome branch reuses `chromeTabState` between fetches.
            if chatSession?.bundleID != sample.appBundleID
                || now.timeIntervalSince(lastChatFetch) >= Self.chatFetchInterval {
                lastChatFetch = now
                let epochBeforeChat = suspensionEpoch
                let fetched = await offActorChatSession(provider: chatSessionProvider, app: frontmost)
                guard suspensionEpoch == epochBeforeChat else { return }
                chatSession = (sample.appBundleID, fetched)
            }
            sample.document = chatSession?.title
        }

        // Focus blocking sees every sampled tick, recorded or not: a private
        // window, an app or site left out of the record, or a stretch away
        // from the keyboard must not be a way around it. Its sample is the
        // recorded one, plus what blocking alone may see: a private tab's
        // address, and the block page's own marker title.
        var focusSample = sample
        var isPrivate = false
        if case .incognito(let blockURL)? = frontTab {
            isPrivate = true
            focusSample.url = blockURL
        }
        if axTitle == FocusBlockPage.pageMarkerTitle { focusSample.windowTitle = axTitle }
        let intercepted = focusInterceptor?(focusSample, now) == true

        if isPrivate || settings.excludes(sample) {
            if let closed = builder.close(at: now) { persist(closed) }
            latestSample = nil
            interruptCollector()
            return
        }
        if phase == .idle {
            offerToCollector(sample, frontTab: frontTab, now: now, spanID: nil)
            return
        }
        finishTick(sample, intercepted: intercepted, now: now)
        offerToCollector(sample, frontTab: frontTab, now: now, spanID: currentRowID)
    }

    /// Fire-and-forget: the collector paces and dedupes itself, and a tick
    /// must never wait on a screenshot or OCR.
    private func offerToCollector(_ sample: Sample, frontTab: ChromeTabState?, now: Date, spanID: Int64?) {
        guard let screenCollector, !settings.excludes(sample) else { return }
        if Self.browserBundleIDs.contains(sample.appBundleID) {
            // Only a page read from this very window: a tab without a URL is
            // also how a browser that can't say whether the window is
            // private comes back, and a window nothing was read from may be
            // private. No screenshot then.
            guard case .tab(let url, _)? = frontTab, url != nil else { return }
        }
        let idleSeconds = idleSeconds
        Task { await screenCollector.tick(now: now, sample: sample, spanID: spanID, idleSeconds: idleSeconds) }
    }

    /// Runs on the cooperative pool: a `nonisolated async` function does not
    /// inherit its caller's isolation (SE-0338), so the `await` at the call
    /// site IS the hop off the main thread -- `TrackerEngineAsyncTickTests`
    /// measures that hop rather than assuming it, so a toolchain change
    /// undoing it shows up as a red test, not as a beachball. The provider and
    /// the app identity are passed in because reading them through `self`
    /// would hop straight back.
    ///
    /// Blocking Mach IPC on a cooperative-pool thread is only acceptable
    /// because `tickInFlight` bounds it to one such thread at a time: do not
    /// remove that guard without revisiting this.
    nonisolated private func offActorWindowSample(
        now: Date, provider: (@Sendable (Date) -> Sample?)?, app: WindowSampler.FrontmostApp?
    ) async -> Sample? {
        if let provider { return provider(now) }
        guard let app else { return nil }
        return windowSampler.sample(at: now, app: app)
    }

    /// Off-actor counterpart for the chat app's AX walk. Same reasoning as
    /// `offActorWindowSample`: it is blocking Mach IPC and must not run on
    /// the main actor. Measured 2026-09-22 at 2.8ms (ChatGPT) and 6.6ms
    /// (Claude) for the whole walk, and it runs at most once per
    /// `chatFetchInterval`.
    nonisolated private func offActorChatSession(
        provider: (@Sendable () -> String?)?, app: WindowSampler.FrontmostApp?
    ) async -> String? {
        if let provider { return provider() }
        guard let app else { return nil }
        return chatSampler.session(pid: app.pid, appName: app.name)
    }

    /// Off-actor counterpart for the Chrome Apple Event -- likewise bounded to
    /// one cooperative-pool thread by `tickInFlight`. See
    /// `offActorWindowSample`.
    nonisolated private func offActorChromeTab(
        provider: (@Sendable () -> ChromeSampler.TabInfo?)?, browser: String, readPrivateURL: Bool
    ) async -> ChromeSampler.TabInfo? {
        provider.map { $0() } ?? chromeSampler.activeTab(bundleID: browser, readPrivateURL: readPrivateURL)
    }

    enum TickPhase { case suspended, idle, active }

    /// Tick phase 1 (main actor, no IPC): meeting idle-exemption and the
    /// idle/lock/sleep suspension state machine. `.active` samples as
    /// normal, `.idle` samples for the screen collector only.
    private func beginTick(now: Date) -> TickPhase {
        guard !userPaused, permissionGranted else { return .suspended }
        let rawIdle = idleSecondsProvider?() ?? idleMonitor.idleSeconds()
        let sinceKey = keyDownSecondsProvider?() ?? idleMonitor.secondsSinceKeyDown()
        keyDownThisTick = now.addingTimeInterval(-sinceKey) > lastTickAt
        lastTickAt = now
        noteInput(at: now.addingTimeInterval(-rawIdle))
        recheckLock(at: now)
        let isInMeetingNow = isInMeetingProvider?() == true
        // Never for an already-idle state: see `isInMeetingProvider`.
        let exemptNow = isInMeetingNow && !suspensionState.idleSuspended
        if wasExempt, !exemptNow {
            exemptionEndedAt = now
        }
        wasExempt = exemptNow
        let idleSeconds = exemptNow ? 0 : rawIdle
        self.idleSeconds = idleSeconds

        let wasIdle = suspensionState.idleSuspended
        switch suspensionState.tick(idleSeconds: idleSeconds, threshold: settings.idleThreshold) {
        case .systemSuspended:
            return .suspended
        case .stillIdle:
            return .idle
        case .becameIdle:
            let backdated = now.addingTimeInterval(-idleSeconds)
            let closeAt = exemptionEndedAt.map { max(backdated, $0) } ?? backdated
            exemptionEndedAt = nil
            if let closed = builder.close(at: closeAt) {
                persist(closed)
            }
            trimPersisted(after: closeAt)
            observations?.logState("idle", at: closeAt)
            return .idle
        case .active:
            if wasIdle { observations?.logState("active", at: now) }
            return .active
        }
    }

    /// Chrome tab-fetch gate: the 5s/window-or-title-change throttle AND the
    /// failure backoff must both allow it. Pure read -- neither call mutates.
    private func shouldFetchChromeTab(browser: String, title: String?, window: UInt32?, at now: Date) -> Bool {
        throttle.shouldFetch(title: title, window: window, at: now)
            && chromeBackoffs[browser, default: ChromeFetchBackoff()].shouldAttempt(at: now)
    }

    /// Folds one browser tab fetch result into `throttle`, `chromeBackoffs`,
    /// `chromeTabState`, `browserWindowPrivacy` and `chromeCaptureDegraded`.
    /// `title` and `window` are the AX window title and CGWindowID of the
    /// sample that triggered the fetch (what the throttle keys on, and the
    /// window the answer is filed under).
    private func noteChromeFetch(_ fetched: ChromeSampler.TabInfo?, browser: String, title: String?,
                                 window: UInt32?, readPrivateURL: Bool, at now: Date) {
        if let tab = fetched {
            throttle.noteFetched(title: title, window: window, at: now)
            chromeBackoffs[browser, default: ChromeFetchBackoff()].noteSuccess()
            chromeTabWindowID = window
            chromeTabState = tab.isIncognito
                ? .incognito(blockURL: readPrivateURL ? tab.url : nil)
                : .tab(url: tab.url, title: tab.title)
            if let window, tab.isIncognito || tab.privacyKnown, browserWindowPrivacy[window] != true {
                if browserWindowPrivacy.count >= Self.browserWindowPrivacyLimit { browserWindowPrivacy.removeAll() }
                browserWindowPrivacy[window] = tab.isIncognito
            }
        } else {
            chromeBackoffs[browser, default: ChromeFetchBackoff()].noteFailure(at: now)
            // A failed re-fetch must not un-suppress a window we
            // already confirmed is incognito -- only .tab/.none
            // collapse to .none; .incognito is sticky until the next
            // successful (non-incognito) fetch.
            if case .incognito = chromeTabState {} else { chromeTabState = .none }
            if chromeBackoffs[browser]?.isDegraded == true, !cachedChromeAutomationAuthorized {
                logger.error("\(browser, privacy: .public) capture degraded: automation likely revoked")
            }
        }
        // 5+ failures while window-less (Chrome frontmost, zero
        // windows) is not a permissions problem -- only surface the
        // warning when authorization is actually the cause.
        // The menu bar warning names Chrome, so only Chrome's own attempts move it.
        if browser == Self.chromeBundleID {
            chromeCaptureDegraded = chromeBackoffs[browser]?.isDegraded == true && !cachedChromeAutomationAuthorized
        }
    }

    /// What is known about browser window `windowID`: the last read of it,
    /// or, when that read failed or was of another window, only whether an
    /// earlier read found it private.
    private func tabState(forWindow windowID: UInt32?) -> ChromeTabState {
        if windowID == chromeTabWindowID {
            switch chromeTabState {
            case .tab, .incognito: return chromeTabState
            case .none: break
            }
        }
        return isKnownPrivate(windowID) ? .incognito(blockURL: nil) : .none
    }

    private func isKnownPrivate(_ windowID: UInt32?) -> Bool {
        windowID.flatMap { browserWindowPrivacy[$0] } == true
    }

    private func isKnownNotPrivate(_ windowID: UInt32?) -> Bool {
        windowID.flatMap { browserWindowPrivacy[$0] } == false
    }

    /// Overlays the front window's tab state onto a browser sample. Runs on
    /// every browser tick, whether or not this tick fetched.
    private func applyChromeTabState(_ state: ChromeTabState, to sample: inout Sample) {
        // R-T12a: the AX title read fresh THIS tick, captured before
        // anything below can overwrite `sample.windowTitle` with a
        // ScriptingBridge title that can be stale (the throttle only
        // re-fetches every 5s, and backoff can skip fetches for up to
        // 60s without resetting `chromeTabState`). Used just below to
        // keep the focus block page's marker title from being silently
        // replaced by a stale SB title -- decision 2's block-page
        // detection would otherwise lose its title signal.
        let axTitle = sample.windowTitle
        switch state {
        case .tab(let url, let title):
            sample.url = url
            // R-T12a: keep the fresh AX title instead of the (possibly
            // stale) SB title when the AX title already IS the block
            // page's marker -- zero effect on every non-focus tab,
            // since a real Chrome tab essentially never coincides with
            // this exact literal title.
            sample.windowTitle = (axTitle == FocusBlockPage.pageMarkerTitle) ? axTitle : title
        case .incognito:
            sample.url = nil
            sample.windowTitle = nil
        case .none:
            // Nothing read from this window this time: the read failed, was
            // backed off, or was of another window. One an earlier read
            // found not private keeps its AX window title (classification
            // degrades to app-level, but nothing private leaks -- the AX
            // title of a normal window is just the page title). Any other
            // window may be private, so it keeps neither, as the privacy
            // note in Settings promises. A slow or failing read is not
            // evidence that a window is normal.
            sample.url = nil
            if !isKnownNotPrivate(sample.windowID) { sample.windowTitle = nil }
        }
    }

    /// Tick phase 3 (main actor, no IPC): span ingest and heartbeat, given
    /// the focus intercept's answer for this tick.
    private func finishTick(_ sample: Sample, intercepted: Bool, now: Date) {
        // Heartbeat runs regardless of whether this tick's sample is
        // intercepted (fold-in fix): the interceptor only ever skips
        // INGESTING the current sample, but the span already open in
        // `builder` from BEFORE the interception (e.g. real activity right
        // up to the moment a redirect landed on the block page) still needs
        // its 30s checkpoint written while the user dwells there -- a naive
        // early-return here left that open span's row un-checkpointed for
        // the entire dwell (observed: 120 intercepted ticks, 0 heartbeat
        // writes).
        guard !intercepted else {
            heartbeat(now: now)
            return
        }

        latestSample = sample

        if let closed = builder.ingest(sample) {
            persist(closed)
        }
        if keyDownThisTick { builder.noteKeySecond(at: sample.timestamp) }
        heartbeat(now: now)
        onTick?(builder.current, now)
    }

    /// True when Chrome Automation is currently authorized. Backed by the
    /// real `Permissions` check (no prompt: `ask: false`); when a test seam
    /// is present it answers instead and the real check is never invoked.
    /// Only called from the cached-refresh site inside the
    /// `shouldFetchChromeTab` gate in `tickAsync(now:)` -- never call this
    /// directly elsewhere, or the whole point of caching is lost. Stays on the
    /// main actor because `Permissions.chromeAutomationStatus` is
    /// `@MainActor`; the gate already keeps it to at most once per 5s.
    private func chromeAutomationAuthorized(browser: String) -> Bool {
        chromeAutomationAuthorizedProvider?() ?? (Permissions.automationStatus(bundleID: browser, ask: false) == 0)
    }

    /// Internal rather than private so a test can simulate the screen
    /// locking mid-tick, which is what `SystemMonitor.onSuspend` does in
    /// production (see `testSampleArrivingAfterLockIsDropped`).
    func suspend(at date: Date, source: SystemMonitor.SuspendSource = .lock) {
        // Bumped before the idempotence guard: the epoch only has to be a
        // superset of "the suspension context moved", and a redundant signal
        // costs at most one dropped 1s sample.
        suspensionEpoch += 1
        guard suspensionState.suspendSystem() else { return }
        lastLockCheck = date
        let closeAt = lockBackdate(at: date)
        if let closed = builder.close(at: closeAt) {
            persist(closed)
        }
        if closeAt < date { trimPersisted(after: closeAt) }
        observations?.logState(source == .sleep ? "sleep" : "lock", at: closeAt)
        interruptCollector()
    }

    /// When the user left, for a lock or sleep at `date`. An unattended Mac
    /// locks minutes after the last input (the display sleeps, then "require
    /// password" locks it), so closing at the notification would hand that
    /// stretch to the front app -- all of it below the idle threshold, which
    /// `.becameIdle` never got to see. With no input for
    /// `lockBackdateMinimum`, the close goes back to the last input, under
    /// `.becameIdle`'s meeting rules: not while the exemption holds, and
    /// never before the moment it ended. `date` itself when already idle:
    /// the idle close has been made.
    private func lockBackdate(at date: Date) -> Date {
        guard !suspensionState.idleSuspended, isInMeetingProvider?() != true else { return date }
        let rawIdle = idleSecondsProvider?() ?? idleMonitor.idleSeconds()
        guard rawIdle >= Self.lockBackdateMinimum else { return date }
        let backdated = date.addingTimeInterval(-rawIdle)
        let closeAt = exemptionEndedAt.map { max(backdated, $0) } ?? backdated
        exemptionEndedAt = nil
        return min(closeAt, date)
    }

    /// Starts a new "since the last input" stretch when the input moved.
    /// Half a second of slack: `now` minus the idle reading jitters by a few
    /// milliseconds for one and the same input. A move backwards (the clock
    /// went back) restarts the stretch too, so rows from before the jump are
    /// never measured against a cutoff from after it.
    private func noteInput(at inputAt: Date) {
        guard abs(inputAt.timeIntervalSince(lastInputAt)) > 0.5 else { return }
        lastInputAt = inputAt
        rowsSinceInput.removeAll()
    }

    /// Self-healing for a missed `screenIsUnlocked`: while system-suspended
    /// and ticking (so awake), the real lock state is re-read every
    /// `lockRecheckInterval`, the first time no sooner than that after the
    /// suspension began -- `willSleep` arrives a moment before the Mac
    /// actually sleeps, unlocked. Unlocked means resumed.
    private func recheckLock(at now: Date) {
        guard suspensionState.systemSuspended,
              abs(now.timeIntervalSince(lastLockCheck)) >= Self.lockRecheckInterval else { return }
        lastLockCheck = now
        guard !(screenLockedProvider?() ?? isScreenLocked()) else { return }
        logger.info("screen found unlocked while suspended: resuming")
        resume(source: .unlock)
    }

    /// Idle backdating for rows already written: a span closed since the
    /// last input -- a title that changed by itself while the user was away
    /// (an unread count, the next song, a finished build) -- is cut back to
    /// `cutoff` like the open one, and its captures from the cut-off tail are
    /// unfiled (taken while idle). A trimmed row is marked unsynced again
    /// (`remoteSeq = NULL`): the sync engine pushes those, and the server
    /// overwrites a row by its origin id.
    private func trimPersisted(after cutoff: Date) {
        let ids = rowsSinceInput
        rowsSinceInput.removeAll()
        guard !ids.isEmpty else { return }
        let list = ids.map { String($0) }.joined(separator: ",")
        do {
            let earliest = try spanStore.writer.write { db -> Date? in
                let first = try Date.fetchOne(
                    db, sql: "SELECT MIN(start) FROM span WHERE id IN (\(list)) AND \"end\" > ?",
                    arguments: [cutoff])
                guard let first else { return nil }
                try db.execute(
                    sql: """
                        UPDATE span SET "end" = MAX(start, ?), remoteSeq = NULL \
                        WHERE id IN (\(list)) AND "end" > ?
                        """,
                    arguments: [cutoff, cutoff])
                return first
            }
            try observations?.detachCaptures(fromSpans: ids, since: cutoff)
            if let earliest {
                lastWriteStart = earliest
                onChange?()
            }
        } catch {
            logger.error("idle trim failed: \(String(describing: error))")
        }
    }

    /// `.unlock` (from `com.apple.screenIsUnlocked`) always resumes.
    /// `.wake` (from `didWakeNotification`) re-checks the actual screen-lock
    /// state via `CGSessionCopyCurrentDictionary` before resuming, per spec:
    /// a lone wake notification isn't trusted, since macOS can wake the
    /// display while the screen is still locked -- the later
    /// `screenIsUnlocked` notification is what clears suspension in that
    /// case.
    ///
    /// Internal for the same reason as `suspend(at:)`: a test drives a
    /// lock+unlock pair that both land inside one IPC window.
    func resume(source: SystemMonitor.ResumeSource) {
        suspensionEpoch += 1
        switch source {
        case .unlock:
            suspensionState.unlock()
            observations?.logState("unlock")
        case .wake:
            suspensionState.wake(screenStillLocked: screenLockedProvider?() ?? isScreenLocked())
            observations?.logState("wake")
        }
    }

    /// See `SystemMonitor.isScreenLocked`: locked, or another user's
    /// session has the console.
    private func isScreenLocked() -> Bool {
        SystemMonitor.isScreenLocked()
    }

    /// Upserts the still-open current span, but only at 30s cadence: before
    /// any row exists, the gate is measured from the span's own `start`
    /// (so the first insert lands at the first 30s heartbeat after it
    /// opened, not on the opening tick itself); once inserted, the gate is
    /// measured from the last successful write.
    private func heartbeat(now: Date) {
        guard let current = builder.current else { return }
        let reference = currentRowID == nil ? current.start : lastHeartbeat
        guard now.timeIntervalSince(reference) >= Self.heartbeatInterval else { return }
        write(current, at: now, final: false)
    }

    /// Final write for a span that just closed (activity change, idle
    /// backdate, suspend, or app quit).
    private func persist(_ closed: Span) {
        write(closed, at: Date(), final: true)
    }

    /// Inserts `span` if it has never been written and has lasted >= 1s;
    /// otherwise, if it was already inserted, always reconciles its `end`
    /// via `updateEnd` regardless of duration (no delete path exists, so an
    /// already-persisted row must be corrected, not abandoned). Write
    /// failures are logged, never thrown further.
    ///
    /// Captures taken before the row existed went in with no span; they are
    /// filed under it when it is inserted, and again when it closes (a
    /// capture whose OCR was still running at the insert lands later).
    private func write(_ span: Span, at now: Date, final: Bool) {
        defer {
            if final {
                if let rowID = currentRowID { rowsSinceInput.append(rowID) }
                currentRowID = nil
                lastHeartbeat = .distantPast
            }
        }
        if let rowID = currentRowID {
            do {
                try spanStore.updateEnd(id: rowID, end: span.end, keySeconds: span.keySeconds)
                lastHeartbeat = now
                lastWriteStart = span.start
                if final { attachCaptures(to: rowID, of: span) }
                onChange?()
            } catch {
                logger.error("updateEnd failed: \(String(describing: error))")
            }
        } else if span.duration >= Self.minWriteDuration {
            do {
                let inserted = try spanStore.insert(span)
                currentRowID = inserted.id
                lastHeartbeat = now
                lastWriteStart = span.start
                if let rowID = inserted.id { attachCaptures(to: rowID, of: span) }
                onChange?()
            } catch {
                logger.error("insert failed: \(String(describing: error))")
            }
        }
    }

    private func attachCaptures(to rowID: Int64, of span: Span) {
        do {
            try observations?.attachCaptures(toSpan: rowID, appBundleID: span.appBundleID,
                                             from: span.start, to: span.end)
        } catch {
            logger.error("capture backfill failed: \(String(describing: error))")
        }
    }
}
