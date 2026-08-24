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

    /// Test seams: when set, replace the real AX / ScriptingBridge samplers.
    var windowSampleProvider: (() -> Sample?)?
    var chromeTabProvider: (() -> ChromeSampler.TabInfo?)?
    var chromeAutomationAuthorizedProvider: (() -> Bool)?

    /// True after 5 consecutive Chrome tab fetch failures while Chrome is
    /// frontmost; cleared by the next success. Read by the menu bar dashboard.
    public private(set) var chromeCaptureDegraded = false

    private var timer: Timer?

    public var onChange: (() -> Void)?
    public var llmCoordinator: LLMCoordinator?
    private var suspensionState = SuspensionState()
    public var isSuspended: Bool { suspensionState.isSuspended }
    public private(set) var latestSample: Sample?

    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "tracker")

    public init(spanStore: SpanStore, settings: SettingsStore) {
        self.spanStore = spanStore
        self.settings = settings
    }

    public func start() {
        systemMonitor.onSuspend = { [weak self] date in self?.suspend(at: date) }
        systemMonitor.onResume = { [weak self] _, source in self?.resume(source: source) }
        systemMonitor.start()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Closes the current span (if any) and writes it, then stops ticking.
    public func stop() {
        timer?.invalidate()
        timer = nil
        if let closed = builder.close(at: Date()) {
            persist(closed)
        }
    }

    func tick(now: Date = Date()) {
        let idleSeconds = idleMonitor.idleSeconds()

        switch suspensionState.tick(idleSeconds: idleSeconds, threshold: settings.idleThreshold) {
        case .systemSuspended, .stillIdle:
            return
        case .becameIdle:
            if let closed = builder.close(at: now.addingTimeInterval(-idleSeconds)) {
                persist(closed)
            }
            return
        case .active:
            break
        }

        guard var sample = (windowSampleProvider.map { $0() } ?? windowSampler.sample(at: now)) else { return }

        if sample.appBundleID == Self.chromeBundleID {
            if throttle.shouldFetch(title: sample.windowTitle, at: now),
               chromeBackoff.shouldAttempt(at: now) {
                let fetched = chromeTabProvider.map { $0() } ?? chromeSampler.activeTab()
                if let tab = fetched {
                    throttle.noteFetched(title: sample.windowTitle, at: now)
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
                    if chromeBackoff.isDegraded, !chromeAutomationAuthorized() {
                        logger.error("Chrome capture degraded: automation likely revoked")
                    }
                }
                chromeCaptureDegraded = chromeBackoff.isDegraded
            }
            switch chromeTabState {
            case .tab(let url, let title):
                sample.url = url
                sample.windowTitle = title
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
                if !chromeAutomationAuthorized() {
                    sample.url = nil
                    sample.windowTitle = nil
                }
            }
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
    private func chromeAutomationAuthorized() -> Bool {
        chromeAutomationAuthorizedProvider?() ?? (Permissions.chromeAutomationStatus(ask: false) == 0)
    }

    private func suspend(at date: Date) {
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
    private func resume(source: SystemMonitor.ResumeSource) {
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
