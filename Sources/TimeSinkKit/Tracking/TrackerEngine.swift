import CoreGraphics
import Foundation
import os

/// Throttles Chrome active-tab fetches: only re-fetch when the window title
/// changed since the last fetch, or when `interval` seconds have elapsed.
public struct ChromeThrottle {
    let interval: TimeInterval
    private var lastTitle: String??
    private var lastFetch = Date.distantPast
    public init(interval: TimeInterval = 5) { self.interval = interval }
    public mutating func shouldFetch(title: String?, at date: Date) -> Bool {
        title != lastTitle || date.timeIntervalSince(lastFetch) >= interval
    }
    public mutating func noteFetched(title: String?, at date: Date) {
        lastTitle = title; lastFetch = date
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
/// must always be corrected rather than abandoned.
@MainActor
public final class TrackerEngine {
    private static let chromeBundleID = "com.google.Chrome"
    private static let minWriteDuration: TimeInterval = 1
    private static let heartbeatInterval: TimeInterval = 30

    private let spanStore: SpanStore
    private let settings: SettingsStore

    private let builder = SpanBuilder()
    private let windowSampler = WindowSampler()
    private let chromeSampler = ChromeSampler()
    private let idleMonitor = IdleMonitor()
    private let systemMonitor = SystemMonitor()
    private var throttle = ChromeThrottle()

    private var currentRowID: Int64?
    private var lastHeartbeat = Date.distantPast

    /// Chrome tab capture state. `.none` (fetch failed / never fetched) never
    /// carries a URL -- the pre-fix code kept applying the last successful
    /// URL forever, misattributing days of browsing to one stale domain once
    /// fetches started failing. It keeps the AX window title only while
    /// Chrome Automation is authorized (see `chromeAutomationAuthorized`);
    /// unauthorized, we can't confirm the window isn't incognito, so both
    /// are suppressed. A failure never overwrites a prior `.incognito` --
    /// that suppression is sticky until the next successful, non-incognito
    /// fetch.
    private enum ChromeTabState {
        case none
        case tab(url: String?, title: String?)
        case incognito
    }
    private var chromeTabState: ChromeTabState = .none
    private var chromeBackoff = ChromeFetchBackoff()

    /// Chrome Automation authorization, refreshed at most once per fetch
    /// attempt -- inside the same `chromeBackoff.shouldAttempt` gate that
    /// spaces out attempts -- rather than on every tick.
    /// `AEDeterminePermissionToAutomateTarget` is a slow IPC round-trip to
    /// tccd; the `.none` tab-state arm and `chromeCaptureDegraded` used to
    /// call it fresh every second, forever, for anyone who declined the
    /// permission (`.none` is the permanent steady state in that case). Both
    /// now only ever read this cached value.
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
    var chromeAutomationAuthorizedProvider: (() -> Bool)?
    var idleSecondsProvider: (() -> TimeInterval)?
    /// True while the user is currently in a calendar meeting -- when set,
    /// `tick` forces `idleSeconds` to 0 regardless of the real idle reading,
    /// so hands-off-keyboard time during a video call never triggers
    /// `becameIdle` (C3 idle exemption). Lock/sleep suspension is untouched
    /// by this -- it only ever affects the idle branch of
    /// `SuspensionState.tick`.
    var isInMeetingProvider: (() -> Bool)?

    /// C4 focus session seam: consulted once per tick, after the sample
    /// guard and Chrome tab-URL enrichment, right before the sample is
    /// handed to `builder.ingest`. Returning `true` skips this tick's sample
    /// entirely (the focus block page's own synthetic Chrome tab -- see
    /// `FocusSessionController.intercept`'s decision 2); every other
    /// intercept outcome (app hidden, site redirected) returns `false` and
    /// the sample is recorded normally. Deliberately placed AFTER Chrome
    /// enrichment rather than immediately after the sample guard: Chrome
    /// site-category blocking needs `sample.url`, which `WindowSampler`
    /// always leaves `nil` -- only the Chrome branch above ever populates it
    /// from `chromeTabState`. Placed here it still never touches the
    /// calendar idle-exemption logic above the sample guard.
    var focusInterceptor: ((Sample, Date) -> Bool)?

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
    /// `builder.current`, `chromeTabState`, `throttle`, `chromeBackoff`,
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
    public var llmCoordinator: LLMCoordinator?
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

    /// Previous tick's `isInMeetingProvider` reading -- used only to detect
    /// the true->false transition below.
    private var wasInMeeting = false
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

    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "tracker")

    public init(spanStore: SpanStore, settings: SettingsStore) {
        self.spanStore = spanStore
        self.settings = settings
    }

    public func start() {
        systemMonitor.onSuspend = { [weak self] date in self?.suspend(at: date) }
        systemMonitor.onResume = { [weak self] _, source in self?.resume(source: source) }
        systemMonitor.start()

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
    }

    /// The one state-machine entry point -- production and tests both drive
    /// this, so there is no second copy of the phase ordering to drift.
    /// Everything that touches engine state stays on the main actor,
    /// including the `NSWorkspace` frontmost-app read; only the AX Mach IPC
    /// and the Chrome Apple Event leave it.
    ///
    /// Two hops rather than one because the Chrome fetch gate
    /// (`shouldFetchChromeTab`) depends on the AX window title AND on
    /// `throttle`/`chromeBackoff`, which live here. Keeping the decision on
    /// the actor avoids shipping copies of that state across the boundary,
    /// and the second hop only happens when Chrome is frontmost and the 5s
    /// throttle allows -- at most once per 5s, not once per tick.
    func tickAsync(now: Date = Date()) async {
        guard !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        guard beginTick(now: now) else { return }

        // AppKit on the actor (see `WindowSampler.frontmostApp`). Skipped
        // entirely when a seam is installed, so tests never depend on whichever
        // app happens to be frontmost on the machine running them.
        let frontmost = windowSampleProvider == nil ? windowSampler.frontmostApp() : nil
        let epochBeforeSample = suspensionEpoch
        guard var sample = await offActorWindowSample(
            now: now, provider: windowSampleProvider, app: frontmost
        ) else { return }
        guard suspensionEpoch == epochBeforeSample else { return }

        if sample.appBundleID == Self.chromeBundleID {
            if shouldFetchChromeTab(title: sample.windowTitle, at: now) {
                // Refresh the cached authorization answer once per attempt,
                // regardless of whether the fetch itself succeeds -- this is
                // the only place that ever calls the real TCC check.
                cachedChromeAutomationAuthorized = chromeAutomationAuthorized()
                let epochBeforeChrome = suspensionEpoch
                let fetched = await offActorChromeTab(provider: chromeTabProvider)
                guard suspensionEpoch == epochBeforeChrome else { return }
                noteChromeFetch(fetched, title: sample.windowTitle, at: now)
            }
            applyChromeTabState(to: &sample)
        }

        finishTick(sample, now: now)
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

    /// Off-actor counterpart for the Chrome Apple Event -- likewise bounded to
    /// one cooperative-pool thread by `tickInFlight`. See
    /// `offActorWindowSample`.
    nonisolated private func offActorChromeTab(
        provider: (@Sendable () -> ChromeSampler.TabInfo?)?
    ) async -> ChromeSampler.TabInfo? {
        provider.map { $0() } ?? chromeSampler.activeTab()
    }

    /// Tick phase 1 (main actor, no IPC): meeting idle-exemption and the
    /// idle/lock/sleep suspension state machine. Returns `true` when the
    /// caller should go on to sample.
    private func beginTick(now: Date) -> Bool {
        let rawIdle = idleSecondsProvider?() ?? idleMonitor.idleSeconds()
        let isInMeetingNow = isInMeetingProvider?() == true
        if wasInMeeting, !isInMeetingNow {
            exemptionEndedAt = now
        }
        wasInMeeting = isInMeetingNow
        let idleSeconds = isInMeetingNow ? 0 : rawIdle

        switch suspensionState.tick(idleSeconds: idleSeconds, threshold: settings.idleThreshold) {
        case .systemSuspended, .stillIdle:
            return false
        case .becameIdle:
            let backdated = now.addingTimeInterval(-idleSeconds)
            let closeAt = exemptionEndedAt.map { max(backdated, $0) } ?? backdated
            exemptionEndedAt = nil
            if let closed = builder.close(at: closeAt) {
                persist(closed)
            }
            return false
        case .active:
            return true
        }
    }

    /// Chrome tab-fetch gate: the 5s/title-change throttle AND the failure
    /// backoff must both allow it. Pure read -- neither call mutates.
    private func shouldFetchChromeTab(title: String?, at now: Date) -> Bool {
        throttle.shouldFetch(title: title, at: now) && chromeBackoff.shouldAttempt(at: now)
    }

    /// Folds one Chrome tab fetch result into `throttle`, `chromeBackoff`,
    /// `chromeTabState` and `chromeCaptureDegraded`. `title` is the AX window
    /// title of the sample that triggered the fetch (what the throttle keys
    /// on).
    private func noteChromeFetch(_ fetched: ChromeSampler.TabInfo?, title: String?, at now: Date) {
        if let tab = fetched {
            throttle.noteFetched(title: title, at: now)
            chromeBackoff.noteSuccess()
            chromeTabState = tab.isIncognito
                ? .incognito
                : .tab(url: tab.url, title: tab.title)
        } else {
            chromeBackoff.noteFailure(at: now)
            // A failed re-fetch must not un-suppress a window we
            // already confirmed is incognito -- only .tab/.none
            // collapse to .none; .incognito is sticky until the next
            // successful (non-incognito) fetch.
            if case .incognito = chromeTabState {} else { chromeTabState = .none }
            if chromeBackoff.isDegraded, !cachedChromeAutomationAuthorized {
                logger.error("Chrome capture degraded: automation likely revoked")
            }
        }
        // 5+ failures while window-less (Chrome frontmost, zero
        // windows) is not a permissions problem -- only surface the
        // warning when authorization is actually the cause.
        chromeCaptureDegraded = chromeBackoff.isDegraded && !cachedChromeAutomationAuthorized
    }

    /// Overlays the cached Chrome tab state onto a Chrome sample. Runs on
    /// every Chrome tick, whether or not this tick fetched.
    private func applyChromeTabState(to sample: inout Sample) {
        // R-T12a: the AX title read fresh THIS tick, captured before
        // anything below can overwrite `sample.windowTitle` with a
        // ScriptingBridge title that can be stale (the throttle only
        // re-fetches every 5s, and backoff can skip fetches for up to
        // 60s without resetting `chromeTabState`). Used just below to
        // keep the focus block page's marker title from being silently
        // replaced by a stale SB title -- decision 2's block-page
        // detection would otherwise lose its title signal.
        let axTitle = sample.windowTitle
        switch chromeTabState {
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
            // No confirmed tab state. Automation still authorized: keep
            // the AX window title (classification degrades to app-level,
            // but nothing private leaks -- Chrome's AX title for a
            // non-incognito window is just the page title). Automation
            // NOT authorized: we cannot tell whether this window is
            // incognito, so suppress both, matching pre-change behavior.
            if !cachedChromeAutomationAuthorized {
                sample.url = nil
                sample.windowTitle = nil
            }
        }
    }

    /// Tick phase 3 (main actor, no IPC): focus intercept, span ingest,
    /// heartbeat.
    private func finishTick(_ sample: Sample, now: Date) {
        // Heartbeat runs regardless of whether this tick's sample is
        // intercepted (fold-in fix): the interceptor only ever skips
        // INGESTING the current sample, but the span already open in
        // `builder` from BEFORE the interception (e.g. real activity right
        // up to the moment a redirect landed on the block page) still needs
        // its 30s checkpoint written while the user dwells there -- a naive
        // early-return here left that open span's row un-checkpointed for
        // the entire dwell (observed: 120 intercepted ticks, 0 heartbeat
        // writes).
        guard focusInterceptor?(sample, now) != true else {
            heartbeat(now: now)
            return
        }

        latestSample = sample

        if let closed = builder.ingest(sample) {
            persist(closed)
        }
        heartbeat(now: now)
    }

    /// True when Chrome Automation is currently authorized. Backed by the
    /// real `Permissions` check (no prompt: `ask: false`); when a test seam
    /// is present it answers instead and the real check is never invoked.
    /// Only called from the cached-refresh site inside the
    /// `shouldFetchChromeTab` gate in `tickAsync(now:)` -- never call this
    /// directly elsewhere, or the whole point of caching is lost. Stays on the
    /// main actor because `Permissions.chromeAutomationStatus` is
    /// `@MainActor`; the gate already keeps it to at most once per 5s.
    private func chromeAutomationAuthorized() -> Bool {
        chromeAutomationAuthorizedProvider?() ?? (Permissions.chromeAutomationStatus(ask: false) == 0)
    }

    /// Internal rather than private so a test can simulate the screen
    /// locking mid-tick, which is what `SystemMonitor.onSuspend` does in
    /// production (see `testSampleArrivingAfterLockIsDropped`).
    func suspend(at date: Date) {
        // Bumped before the idempotence guard: the epoch only has to be a
        // superset of "the suspension context moved", and a redundant signal
        // costs at most one dropped 1s sample.
        suspensionEpoch += 1
        guard suspensionState.suspendSystem() else { return }
        if let closed = builder.close(at: date) {
            persist(closed)
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
        case .wake:
            suspensionState.wake(screenStillLocked: isScreenLocked())
        }
    }

    /// Reads `CGSSessionScreenIsLocked` from the current window-server
    /// session dictionary. That key isn't in the public `CGSession.h`
    /// header, but reading it via `CGSessionCopyCurrentDictionary` is the
    /// long-standing, widely-used way to answer "is the screen locked right
    /// now" without extra permissions.
    private func isScreenLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
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
    /// failures are logged, never thrown further. On a successful `final`
    /// write (span close, not a 30s heartbeat), also notifies
    /// `llmCoordinator` so it can consider LLM fallback classification.
    private func write(_ span: Span, at now: Date, final: Bool) {
        defer {
            if final {
                currentRowID = nil
                lastHeartbeat = .distantPast
            }
        }
        if let rowID = currentRowID {
            do {
                try spanStore.updateEnd(id: rowID, end: span.end)
                lastHeartbeat = now
                onChange?()
                if final { llmCoordinator?.noteSpanClosed(span) }
            } catch {
                logger.error("updateEnd failed: \(String(describing: error))")
            }
        } else if span.duration >= Self.minWriteDuration {
            do {
                let inserted = try spanStore.insert(span)
                currentRowID = inserted.id
                lastHeartbeat = now
                onChange?()
                if final { llmCoordinator?.noteSpanClosed(span) }
            } catch {
                logger.error("insert failed: \(String(describing: error))")
            }
        }
    }
}
