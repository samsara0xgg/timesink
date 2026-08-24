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

/// Drives the 1s sampling loop: samples the frontmost window, throttles Chrome
/// tab lookups, tracks idle/lock/sleep suspension, and persists spans to
/// `SpanStore`.
///
/// Write policy for the current in-progress span: nothing is inserted until
/// it has lasted >= 1s (first qualifying heartbeat or close) to avoid DB
/// churn for sub-second activity flicker. Once a row exists (rowID known),
/// every subsequent write -- 30s heartbeat or final close -- always
/// reconciles that row via `updateEnd`, even if a later idle-backdated close
/// makes the final duration look short; there is no delete path, so a
/// written row must always be corrected rather than abandoned.
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
    private var cachedURL: String?
    private var cachedTabTitle: String?

    private var timer: Timer?

    public var onChange: (() -> Void)?
    public private(set) var isSuspended = false
    public private(set) var latestSample: Sample?

    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "tracker")

    public init(spanStore: SpanStore, settings: SettingsStore) {
        self.spanStore = spanStore
        self.settings = settings
    }

    public func start() {
        systemMonitor.onSuspend = { [weak self] date in self?.suspend(at: date) }
        systemMonitor.onResume = { [weak self] _ in self?.resume() }
        systemMonitor.start()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Closes the current span (if any) and writes it, then stops ticking.
    public func stop() {
        timer?.invalidate()
        timer = nil
        if let closed = builder.close(at: Date()) {
            persist(closed)
        }
    }

    private func tick() {
        let now = Date()
        let idleSeconds = idleMonitor.idleSeconds()

        if idleSeconds >= settings.idleThreshold {
            if !isSuspended {
                if let closed = builder.close(at: now.addingTimeInterval(-idleSeconds)) {
                    persist(closed)
                }
                isSuspended = true
            }
            return
        } else if isSuspended {
            isSuspended = false
        }

        guard var sample = windowSampler.sample(at: now) else { return }

        if sample.appBundleID == Self.chromeBundleID {
            if throttle.shouldFetch(title: sample.windowTitle, at: now) {
                if let tab = chromeSampler.activeTab() {
                    throttle.noteFetched(title: sample.windowTitle, at: now)
                    cachedURL = tab.isIncognito ? nil : tab.url
                    cachedTabTitle = tab.isIncognito ? nil : tab.title
                }
            }
            sample.url = cachedURL
            sample.windowTitle = cachedTabTitle
        }

        latestSample = sample

        if let closed = builder.ingest(sample) {
            persist(closed)
        }
        heartbeat(now: now)
    }

    private func suspend(at date: Date) {
        guard !isSuspended else { return }
        if let closed = builder.close(at: date) {
            persist(closed)
        }
        isSuspended = true
    }

    private func resume() {
        isSuspended = false
    }

    /// Upserts the still-open current span: writes it once it has lasted
    /// >= 1s (remembering its rowID via `write`), then re-writes it every
    /// 30s thereafter.
    private func heartbeat(now: Date) {
        guard let current = builder.current else { return }
        if currentRowID != nil {
            guard now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval else { return }
        }
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
            } catch {
                logger.error("updateEnd failed: \(String(describing: error))")
            }
        } else if span.duration >= Self.minWriteDuration {
            do {
                let inserted = try spanStore.insert(span)
                currentRowID = inserted.id
                lastHeartbeat = now
                onChange?()
            } catch {
                logger.error("insert failed: \(String(describing: error))")
            }
        }
    }
}
