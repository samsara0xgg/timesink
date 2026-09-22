import Foundation
import os

enum SyncError: Error {
    /// The server accepted a push but acknowledged none of it; stop rather
    /// than resend the same batch forever.
    case nothingAcked
}

/// Moves closed spans between this database and the account's cloud copy:
/// this device's unsynced rows up, other devices' rows down. Spans never
/// change once closed, so there is nothing to merge -- see the design doc
/// §5. Runs a pass every `interval` while the account pane's switch is on.
@MainActor
public final class SyncEngine {
    public static let interval: Duration = .seconds(60)
    public static let pushBatch = 500

    private let spanStore: SpanStore
    private let settings: SettingsStore
    private let cloud: any SpanCloud
    /// The engine's open row, whose `end` is still being extended.
    private let openRowID: @MainActor () -> Int64?
    /// Fired after a pass that inserted rows, so views re-query.
    private let onPulled: @MainActor () -> Void
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "cloud.sync")
    private var loop: Task<Void, Never>?

    public private(set) var isSyncing = false
    public private(set) var lastError: String?
    public private(set) var lastSyncAt: Date?

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

    /// One pass: push, then pull. nil when a pass was already running.
    @discardableResult
    public func syncNow() async -> (pushed: Int, pulled: Int)? {
        guard !isSyncing else { return nil }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let device = settings.cloudDeviceID
            let pushed = try await push(device: device)
            let pulled = try await pull(device: device)
            lastSyncAt = Date()
            settings.setCloudLastSyncAt(lastSyncAt)
            lastError = nil
            if pulled > 0 { onPulled() }
            return (pushed, pulled)
        } catch {
            lastError = String(describing: error)
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
    }

    /// Wipes the cloud copy and the account, then the local sync state.
    public func deleteAccount() async throws {
        try await cloud.deleteAccount()
        settings.setCloudSyncEnabled(false)
        try spanStore.clearSyncState()
        settings.setCloudPullCursor(nil)
        settings.setCloudUserSub(nil)
        settings.setCloudLastSyncAt(nil)
        lastSyncAt = nil
    }

    private func push(device: String) async throws -> Int {
        var total = 0
        while true {
            let batch = try spanStore.unsynced(excluding: openRowID(), limit: Self.pushBatch)
            if batch.isEmpty { return total }
            let acks = try await cloud.push(deviceID: device, spans: batch)
            guard !acks.isEmpty else { throw SyncError.nothingAcked }
            try spanStore.markSynced(acks.map { (id: $0.originID, seq: $0.seq) })
            total += acks.count
        }
    }

    private func pull(device: String) async throws -> Int {
        var total = 0
        var after: String?
        repeat {
            let page = try await cloud.pull(since: settings.cloudPullCursor, after: after, excludingDevice: device)
            total += try spanStore.insertRemote(page.spans)
            if let cursor = page.cursor {
                settings.setCloudPullCursor(cursor)
                after = cursor
            }
            guard page.more, after != nil else { break }
        } while true
        return total
    }
}
