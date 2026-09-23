import XCTest
import GRDB
@testable import TimeSinkKit

/// An account's cloud copy in memory: keyed like the real table so a
/// retried push overwrites, paged like the real API so the engine's cursor
/// handling is what is under test.
actor FakeCloud: SpanCloud {
    struct Item { let span: Span; let deviceID: String; let originID: Int64; let seq: String }
    private(set) var items: [String: Item] = [:]
    private var counter = 0
    var pushes = 0
    var pageSize = 500
    var deleted = false

    func push(deviceID: String, spans: [Span]) async throws -> [SpanAck] {
        pushes += 1
        return spans.map { span in
            counter += 1
            let seq = String(format: "%020d", counter)
            let id = span.id!
            items["\(deviceID)#\(id)"] = Item(span: span, deviceID: deviceID, originID: id, seq: seq)
            return SpanAck(originID: id, seq: seq)
        }
    }

    func pull(since: String?, after: String?, excludingDevice: String) async throws -> PullPage {
        let lower = after ?? since ?? ""
        let sorted = items.values.filter { $0.seq > lower }.sorted { $0.seq < $1.seq }
        let page = Array(sorted.prefix(pageSize))
        let rows = page.filter { $0.deviceID != excludingDevice }
            .map { SpanStore.RemoteSpan(span: $0.span, deviceID: $0.deviceID, originID: $0.originID, seq: $0.seq) }
        return PullPage(spans: rows, cursor: page.last?.seq ?? lower.nilIfEmpty, more: sorted.count > page.count)
    }

    func deleteAccount() async throws {
        items.removeAll()
        deleted = true
    }

    func setPageSize(_ n: Int) { pageSize = n }
    var count: Int { items.count }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
final class SyncEngineTests: XCTestCase {
    private func span(_ minute: Int, app: String = "com.test") -> Span {
        let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60)
        return Span(start: start, end: start.addingTimeInterval(50), appBundleID: app, appName: "T",
                    title: "t\(minute)", url: nil, domain: nil, document: nil)
    }

    private func count(_ db: DatabaseQueue, _ sql: String) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    func testMigrationLeavesOwnRowsUnmarked() throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let inserted = try store.insert(span(0))
        let row = try db.read { try Row.fetchOne($0, sql: "SELECT deviceID, originID, remoteSeq FROM span WHERE id = ?", arguments: [inserted.id]) }!
        XCTAssertNil(row["deviceID"] as String?)
        XCTAssertNil(row["originID"] as Int64?)
        XCTAssertNil(row["remoteSeq"] as String?)
        XCTAssertEqual(try store.unsynced(excluding: nil, limit: 10).map(\.id), [inserted.id])
        XCTAssertEqual(try store.unsyncedCount(), 1)
    }

    /// The first live upload stalled on a 4.7k-character ad URL: the server
    /// caps every field at 4096 scalars and rejected the whole batch, and
    /// every retry hit the same row.
    func testWireCutsFieldsToTheServerLimit() {
        var long = span(0)
        long.id = 7
        long.url = String(repeating: "u", count: 5000)
        long.title = "短"
        let wire = HTTPCloud.wire(long)!
        XCTAssertEqual(wire.url?.unicodeScalars.count, HTTPCloud.maxFieldLength)
        XCTAssertEqual(wire.title, "短")
        XCTAssertEqual(wire.originId, 7)
        XCTAssertNil(HTTPCloud.wire(span(1)))  // never inserted: no id, nothing to push
    }

    func testPushSkipsOpenRowAndDoesNotResend() async throws {
        let cloud = FakeCloud()
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db)
        let settings = SettingsStore(db)
        let closed = try spans.insert(span(0))
        let open = try spans.insert(span(1))
        let engine = SyncEngine(spanStore: spans, settings: settings, cloud: cloud,
                                openRowID: { open.id }, onPulled: {})

        let first = await engine.syncNow()
        XCTAssertEqual(first?.pushed, 1)
        let synced = try await db.read { try String.fetchOne($0, sql: "SELECT remoteSeq FROM span WHERE id = ?", arguments: [closed.id]) }
        XCTAssertNotNil(synced)
        XCTAssertEqual(try spans.unsynced(excluding: open.id, limit: 10).count, 0)
        XCTAssertEqual(try spans.unsyncedCount(), 1)  // the open row, still waiting

        let second = await engine.syncNow()
        XCTAssertEqual(second?.pushed, 0)
        let pushes = await cloud.pushes
        XCTAssertEqual(pushes, 1)
        XCTAssertNil(engine.lastError)
        XCTAssertNotNil(engine.lastSyncAt)
        XCTAssertNotNil(settings.cloudLastSyncAt)
    }

    func testTwoDevicesMeetInTheCloudWithoutDuplicates() async throws {
        let cloud = FakeCloud()
        await cloud.setPageSize(2)  // force paging through `after`
        let dbA = try AppDatabase.openInMemory(), dbB = try AppDatabase.openInMemory()
        let spansA = SpanStore(dbA), spansB = SpanStore(dbB)
        let settingsA = SettingsStore(dbA), settingsB = SettingsStore(dbB)
        var pulledB = 0
        let engineA = SyncEngine(spanStore: spansA, settings: settingsA, cloud: cloud, openRowID: { nil }, onPulled: {})
        let engineB = SyncEngine(spanStore: spansB, settings: settingsB, cloud: cloud, openRowID: { nil },
                                 onPulled: { pulledB += 1 })
        for m in 0..<5 { try spansA.insert(span(m, app: "com.a")) }
        try spansB.insert(span(9, app: "com.b"))

        let a = await engineA.syncNow()
        XCTAssertEqual(a?.pushed, 5)
        let b = await engineB.syncNow()
        XCTAssertEqual(b?.pushed, 1)
        XCTAssertEqual(b?.pulled, 5)
        XCTAssertEqual(pulledB, 1)
        XCTAssertEqual(try count(dbB, "SELECT COUNT(*) FROM span"), 6)
        XCTAssertEqual(try count(dbB, "SELECT COUNT(*) FROM span WHERE deviceID = '\(settingsA.cloudDeviceID)'"), 5)
        XCTAssertNotNil(settingsB.cloudPullCursor)

        // A pulls B's one row and not its own five back.
        let a2 = await engineA.syncNow()
        XCTAssertEqual(a2?.pulled, 1)
        XCTAssertEqual(try count(dbA, "SELECT COUNT(*) FROM span"), 6)

        // A repeat pass (the server re-reads a 60 s overlap in production;
        // here the fake replays from the cursor) inserts nothing twice.
        settingsB.setCloudPullCursor(nil)
        let b2 = await engineB.syncNow()
        XCTAssertEqual(b2?.pulled, 0)
        XCTAssertEqual(try count(dbB, "SELECT COUNT(*) FROM span"), 6)
        XCTAssertEqual(pulledB, 1)

        // Pulled rows are never pushed back up as this device's own.
        XCTAssertEqual(try spansB.unsynced(excluding: nil, limit: 100).count, 0)
    }

    func testAccountChangeAndDeleteResetSyncState() async throws {
        let cloud = FakeCloud()
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db)
        let settings = SettingsStore(db)
        try spans.insert(span(0))
        let engine = SyncEngine(spanStore: spans, settings: settings, cloud: cloud, openRowID: { nil }, onPulled: {})
        try engine.accountChanged(to: "sub-1")
        _ = await engine.syncNow()
        XCTAssertEqual(try spans.unsyncedCount(), 0)

        // Same account again: nothing changes.
        try engine.accountChanged(to: "sub-1")
        XCTAssertEqual(try spans.unsyncedCount(), 0)

        // A different account: every own row is due again.
        try engine.accountChanged(to: "sub-2")
        XCTAssertEqual(try spans.unsyncedCount(), 1)
        XCTAssertNil(settings.cloudPullCursor)
        _ = await engine.syncNow()

        settings.setCloudSyncEnabled(true)
        try await engine.deleteAccount()
        let deleted = await cloud.deleted
        XCTAssertTrue(deleted)
        XCTAssertFalse(settings.cloudSyncEnabled)
        XCTAssertEqual(try spans.unsyncedCount(), 1)
        XCTAssertNil(settings.cloudUserSub)
        XCTAssertNil(engine.lastSyncAt)
    }
}
