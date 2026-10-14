import Foundation
import Observation
import os

enum SyncError: LocalizedError {
    /// The server accepted a push but acknowledged none of it; stop rather
    /// than resend the same batch forever.
    case nothingAcked
    /// An account-level action was asked for while a pass was running.
    case busy

    var errorDescription: String? {
        switch self {
        case .nothingAcked: String(localized: "服务器没有确认任何记录")
        case .busy: String(localized: "正在同步，请稍后再试")
        }
    }
}

/// Moves closed spans between this database and the account's cloud copy:
/// this device's unsynced rows up, other devices' rows down. Each row has
/// one writer, the device that recorded it, so there is nothing to merge --
/// see the design doc §5. A closed row can still change there (an idle
/// tail trimmed after the fact): that clears its `remoteSeq`, the next push
/// overwrites the same cloud key under a new `seq`, and other devices'
/// `insertRemote` replaces their copy when they pull it. Runs a pass every
/// `interval` while the account pane's switch is on.
///
/// `@Observable` so the account pane and the menu bar row follow a pass as
/// it runs (the first upload of a year of history is ~100 requests).
@MainActor
@Observable
public final class SyncEngine {
    public static let interval: Duration = .seconds(60)
    public static let pushBatch = 500
    /// After a 429 the loop holds off for the server's Retry-After or this,
    /// doubled for each 429 in a row, whichever is longer, up to the cap.
    static let backoffBase: TimeInterval = 15
    static let backoffCap: TimeInterval = 3600

    @ObservationIgnored private let spanStore: SpanStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let cloud: any SpanCloud
    /// The engine's open row, whose `end` is still being extended.
    @ObservationIgnored private let openRowID: @MainActor () -> Int64?
    /// Fired after a pass that inserted rows, so views re-query.
    @ObservationIgnored private let onPulled: @MainActor () -> Void
    @ObservationIgnored private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "cloud.sync")
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 429s in a row, for the backoff; reset by a pass that is not one.
    @ObservationIgnored private var rateLimitStreak = 0
    /// While set and in the future, the loop skips its passes.
    @ObservationIgnored private(set) var retryAt: Date?

    public private(set) var isSyncing = false
    /// User-readable; nil after a clean pass.
    public private(set) var lastError: String?
    public private(set) var lastSyncAt: Date?
    /// Progress of the pass in flight (kept after it ends, until the next).
    public private(set) var passPushed = 0
    public private(set) var passPulled = 0
    /// This device's rows still to go up, as of the last `refreshPending()`.
    public private(set) var pending = 0

    public init(spanStore: SpanStore, settings: SettingsStore, cloud: any SpanCloud,
                openRowID: @escaping @MainActor () -> Int64?,
                onPulled: @escaping @MainActor () -> Void) {
        self.spanStore = spanStore
        self.settings = settings
        self.cloud = cloud
        self.openRowID = openRowID
        self.onPulled = onPulled
        self.lastSyncAt = settings.cloudLastSyncAt
    }

    public func start() {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                var wait: Duration = Self.interval
                if let self {
                    if self.settings.cloudSyncEnabled, !self.isBackingOff { await self.syncNow() }
                    wait = self.loopWait()
                }
                try? await Task.sleep(for: wait)
            }
        }
    }

    private var isBackingOff: Bool {
        guard let retryAt else { return false }
        return retryAt > Date()
    }

    /// The usual interval, or less when a backoff ends sooner, so a long
    /// first upload resumes as soon as the server allows.
    private func loopWait() -> Duration {
        guard let retryAt, retryAt > Date() else { return Self.interval }
        let until: Duration = .seconds(max(retryAt.timeIntervalSinceNow, 1))
        return min(until, Self.interval)
    }

    /// How long to hold off after the `streak`-th 429 in a row: what the
    /// server asked for or the doubling step, whichever is longer, plus up
    /// to 20% (`jitter` in 0...1) so devices refused together come back
    /// apart.
    static func backoff(retryAfter: Int, streak: Int, jitter: Double) -> TimeInterval {
        let doublings: Int = min(max(streak - 1, 0), 16)
        let step: TimeInterval = min(backoffBase * Double(1 << doublings), backoffCap)
        let asked: TimeInterval = min(Double(max(retryAfter, 0)), backoffCap)
        return max(step, asked) * (1 + 0.2 * min(max(jitter, 0), 1))
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func refreshPending() {
        pending = (try? spanStore.unsyncedCount()) ?? pending
    }

    /// One pass: push, then pull. nil when a pass was already running or
    /// failed. A failed push does not stop the pull -- other devices' rows
    /// still come down -- unless it was a 429, which the pull would get too.
    @discardableResult
    public func syncNow() async -> (pushed: Int, pulled: Int)? {
        guard !isSyncing else { return nil }
        isSyncing = true
        passPushed = 0
        passPulled = 0
        refreshPending()
        defer {
            isSyncing = false
            refreshPending()
        }
        let device = settings.cloudDeviceID
        var failure: (any Error)?
        do {
            try await push(device: device)
        } catch {
            failure = error
        }
        if Self.rateLimit(failure) == nil {
            do {
                try await pull(device: device)
            } catch {
                // A 429 outranks the push's error: it is what sets the backoff.
                if failure == nil || Self.rateLimit(error) != nil { failure = error }
            }
        }
        if passPulled > 0 { onPulled() }
        if let failure {
            fail(failure)
            return nil
        }
        rateLimitStreak = 0
        retryAt = nil
        lastSyncAt = Date()
        settings.setCloudLastSyncAt(lastSyncAt)
        lastError = nil
        return (passPushed, passPulled)
    }

    private static func rateLimit(_ error: (any Error)?) -> Int? {
        guard let cloudError = error as? CloudError, case .rateLimited(let seconds) = cloudError else { return nil }
        return seconds
    }

    private func fail(_ error: any Error) {
        logger.error("sync failed: \(String(describing: error), privacy: .public)")
        guard let retryAfter = Self.rateLimit(error) else {
            rateLimitStreak = 0
            retryAt = nil
            lastError = error.localizedDescription
            return
        }
        rateLimitStreak += 1
        let delay: TimeInterval = Self.backoff(retryAfter: retryAfter, streak: rateLimitStreak,
                                               jitter: Double.random(in: 0...1))
        retryAt = Date().addingTimeInterval(delay)
        let seconds = Int(delay.rounded(.up))
        lastError = String(localized: "请求太频繁（HTTP 429），\(seconds) 秒后重试。")
    }

    /// Signing into a different account than last time: rows marked as
    /// uploaded belong to the old account and must go up again, and the
    /// old account's cursor means nothing.
    public func accountChanged(to sub: String) throws {
        guard settings.cloudUserSub != sub else { return }
        try spanStore.clearSyncState()
        settings.setCloudPullCursor(nil)
        settings.setCloudUserSub(sub)
        refreshPending()
    }

    /// Wipes the cloud copy and the account, then the local sync state.
    /// The server accepts (202) once every device is signed out and turned
    /// away and empties the account in the background; the caller then
    /// signs out here (`CloudAuth.signOut`).
    public func deleteAccount() async throws {
        guard !isSyncing else { throw SyncError.busy }
        try await cloud.deleteAccount()
        settings.setCloudSyncEnabled(false)
        try spanStore.clearSyncState()
        settings.setCloudPullCursor(nil)
        settings.setCloudUserSub(nil)
        settings.setCloudLastSyncAt(nil)
        lastSyncAt = nil
        lastError = nil
        rateLimitStreak = 0
        retryAt = nil
        refreshPending()
    }

    private func push(device: String) async throws {
        while true {
            let batch = try spanStore.unsynced(excluding: openRowID(), limit: Self.pushBatch)
            if batch.isEmpty { return }
            let acks = try await cloud.push(deviceID: device, spans: batch)
            guard !acks.isEmpty else { throw SyncError.nothingAcked }
            try spanStore.markSynced(acks.map { (id: $0.originID, seq: $0.seq) })
            passPushed += acks.count
            pending = max(0, pending - acks.count)
        }
    }

    private func pull(device: String) async throws {
        var after: String?
        repeat {
            let page = try await cloud.pull(since: settings.cloudPullCursor, after: after, excludingDevice: device)
            passPulled += try spanStore.insertRemote(page.spans)
            if page.skipped > 0 {
                logger.error("pull skipped \(page.skipped, privacy: .public) unreadable rows")
            }
            // The server's cursor is the last row it read, this device's
            // own included, so it moves even when every row was ours.
            if let cursor = page.cursor {
                settings.setCloudPullCursor(cursor)
                after = cursor
            }
            guard page.more, after != nil else { break }
        } while true
    }
}
