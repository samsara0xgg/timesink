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
/// this device's unsynced rows up, other devices' rows down. Spans never
/// change once closed, so there is nothing to merge -- see the design doc
/// §5. Runs a pass every `interval` while the account pane's switch is on.
///
/// `@Observable` so the account pane and the menu bar row follow a pass as
/// it runs (the first upload of a year of history is ~100 requests).
@MainActor
@Observable
public final class SyncEngine {
    public static let interval: Duration = .seconds(60)
    public static let pushBatch = 500

    @ObservationIgnored private let spanStore: SpanStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let cloud: any SpanCloud
    /// The engine's open row, whose `end` is still being extended.
    @ObservationIgnored private let openRowID: @MainActor () -> Int64?
    /// Fired after a pass that inserted rows, so views re-query.
    @ObservationIgnored private let onPulled: @MainActor () -> Void
    @ObservationIgnored private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "cloud.sync")
    @ObservationIgnored private var loop: Task<Void, Never>?

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
                if let self, self.settings.cloudSyncEnabled { await self.syncNow() }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func refreshPending() {
        pending = (try? spanStore.unsyncedCount()) ?? pending
    }

    /// One pass: push, then pull. nil when a pass was already running.
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
        do {
            let device = settings.cloudDeviceID
            let pushed = try await push(device: device)
            let pulled = try await pull(device: device)
            lastSyncAt = Date()
            settings.setCloudLastSyncAt(lastSyncAt)
            lastError = nil
            try? spanStore.recordSyncPass(at: Date(), pushed: pushed, pulled: pulled, error: nil)
            if pulled > 0 { onPulled() }
            return (pushed, pulled)
        } catch {
            lastError = error.localizedDescription
            // Batches acknowledged before the failure did go up.
            try? spanStore.recordSyncPass(at: Date(), pushed: passPushed, pulled: passPulled,
                                          error: lastError)
            logger.error("sync failed: \(String(describing: error), privacy: .public)")
            return nil
        }
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
        refreshPending()
    }

    private func push(device: String) async throws -> Int {
        while true {
            let batch = try spanStore.unsynced(excluding: openRowID(), limit: Self.pushBatch)
            if batch.isEmpty { return passPushed }
            let acks = try await cloud.push(deviceID: device, spans: batch)
            guard !acks.isEmpty else { throw SyncError.nothingAcked }
            try spanStore.markSynced(acks.map { (id: $0.originID, seq: $0.seq) })
            passPushed += acks.count
            pending = max(0, pending - acks.count)
        }
    }

    private func pull(device: String) async throws -> Int {
        var after: String?
        repeat {
            let page = try await cloud.pull(since: settings.cloudPullCursor, after: after, excludingDevice: device)
            passPulled += try spanStore.insertRemote(page.spans)
            if let cursor = page.cursor {
                settings.setCloudPullCursor(cursor)
                after = cursor
            }
            guard page.more, after != nil else { break }
        } while true
        return passPulled
    }
}
