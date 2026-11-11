import XCTest
import GRDB
import ServiceManagement
import os
@testable import TimeSinkKit

final class StorageGuardTests: XCTestCase {
    // MARK: Login item

    func testLoginItemWarnsOnlyWhenWantedAndOff() {
        for status in [SMAppService.Status.notRegistered, .requiresApproval] {
            XCTAssertTrue(LoginItemGuard.decide(stored: "true", status: status).warn)
            XCTAssertFalse(LoginItemGuard.decide(stored: "false", status: status).warn)
            XCTAssertFalse(LoginItemGuard.decide(stored: nil, status: status).warn)
        }
        XCTAssertFalse(LoginItemGuard.decide(stored: "true", status: .enabled).warn)
        XCTAssertFalse(LoginItemGuard.decide(stored: "true", status: .notFound).warn)
    }

    func testLoginItemExistingInstallWithItemOnBecomesWanted() {
        let on = LoginItemGuard.decide(stored: nil, status: .enabled)
        XCTAssertEqual(on.store, true)
        XCTAssertFalse(on.warn)
        XCTAssertNil(LoginItemGuard.decide(stored: nil, status: .notRegistered).store)
        XCTAssertNil(LoginItemGuard.decide(stored: "false", status: .enabled).store)
    }

    // MARK: Classification

    func testClassifiesByResultCodeNotMessage() {
        let cases: [(ResultCode, StorageFailure)] = [
            (.SQLITE_FULL, .full), (.SQLITE_CORRUPT, .corrupt), (.SQLITE_NOTADB, .notADatabase),
            (.SQLITE_READONLY, .readOnly), (.SQLITE_CANTOPEN, .cantOpen), (.SQLITE_IOERR, .ioError),
            (.SQLITE_BUSY, .other),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(StorageFailure.classify(DatabaseError(resultCode: code, message: "unrelated")), expected)
        }
        // Extended codes fold into their primary code.
        XCTAssertEqual(StorageFailure.classify(DatabaseError(resultCode: .SQLITE_IOERR_WRITE)), .ioError)
        XCTAssertEqual(StorageFailure.classify(DatabaseError(resultCode: .SQLITE_READONLY_DBMOVED)), .readOnly)
        // A message that sounds like a full disk does not make it one.
        XCTAssertEqual(StorageFailure.classify(DatabaseError(resultCode: .SQLITE_ERROR, message: "database or disk is full")), .other)
        XCTAssertEqual(StorageFailure.classify(CocoaError(.fileWriteOutOfSpace)), .other)
    }

    func testOpenFailureMessageNamesTheClass() {
        let message = DatabaseOpenFailure.message(for: DatabaseError(resultCode: .SQLITE_NOTADB))
        XCTAssertTrue(message.detail.contains(StorageFailure.notADatabase.openReason))
        XCTAssertFalse(message.title.isEmpty)
    }

    // MARK: Degraded state

    func testDegradedAfterConsecutiveFailuresAndClearedBySuccess() {
        let health = WriteHealth(threshold: 2)
        let count = OSAllocatedUnfairLock(initialState: 0)
        health.observe { count.withLock { $0 += 1 } }
        var notified: Int { count.withLock { $0 } }
        let full = DatabaseError(resultCode: .SQLITE_FULL)

        health.succeeded(at: ts(10))
        health.failed(full)
        XCTAssertNil(health.degraded)
        XCTAssertEqual(health.consecutiveFailures, 1)

        health.failed(full)
        XCTAssertEqual(health.degraded, WriteHealth.Degraded(failure: .full, lastSuccess: ts(10)))
        XCTAssertEqual(notified, 1)

        health.failed(full)
        XCTAssertEqual(notified, 1, "no repeat notification while nothing changed")

        health.succeeded(at: ts(20))
        XCTAssertNil(health.degraded)
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertEqual(notified, 2)
    }

    func testSuccessBetweenFailuresResetsTheCount() {
        let health = WriteHealth(threshold: 2)
        let error = DatabaseError(resultCode: .SQLITE_BUSY)
        health.failed(error); health.succeeded(); health.failed(error)
        XCTAssertNil(health.degraded)
    }

    func testObservationStoreCountsFailedWrites() throws {
        let queue = try DatabaseQueue()    // no migrations: the stateEvent table is missing, so every write fails
        let health = WriteHealth(threshold: 2)
        let store = ObservationStore(queue, health: health)
        store.logState("a"); store.logState("b")
        XCTAssertEqual(health.degraded?.failure, .other)
        let good = ObservationStore(try AppDatabase.openInMemory(), health: health)
        good.logState("c")
        XCTAssertNil(health.degraded)
    }

    // MARK: Pre-migration backup

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A database file left behind by an older build: migrated up to `last` only.
    private func oldDatabase(at url: URL, upTo last: String) throws {
        let pool = try DatabasePool(path: url.path)
        try AppDatabase.migrator.migrate(pool, upTo: last)
        try pool.write { try $0.execute(sql: "INSERT INTO setting (key, value) VALUES ('marker', 'kept')") }
    }

    /// The installed 0.3.2 line shipped its own "v21" (callSpan); the public 0.3.1 line's "v21"
    /// is the Jev ledger. A database from either line ends up with both.
    func testADatabaseFromTheInstalledLineGetsThePublicLinesTables() throws {
        let url = try tempDir().appendingPathComponent("installed.sqlite")
        try oldDatabase(at: url, upTo: "v20")
        let pool = try DatabasePool(path: url.path)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE callSpan (id INTEGER PRIMARY KEY AUTOINCREMENT, start DATETIME NOT NULL,
                    "end" DATETIME NOT NULL, appBundleID TEXT NOT NULL, appName TEXT NOT NULL)
                """)
            try db.execute(sql: "CREATE INDEX callSpan_on_start ON callSpan(start)")
            try db.execute(sql: "INSERT INTO callSpan (start, \"end\", appBundleID, appName) VALUES ('2026-11-01 10:00:00.000', '2026-11-01 11:00:00.000', 'us.zoom.xos', 'zoom.us')")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v21')")
        }
        try pool.close()

        let opened = try AppDatabase.open(at: url)
        try opened.read { db in
            XCTAssertTrue(try db.tableExists("jevAttempt"))
            XCTAssertTrue(try db.columns(in: "budgetAlert").contains { $0.name == "limitSeconds" })
            XCTAssertTrue(try db.columns(in: "captureHealth").contains { $0.name == "axReads" })
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM callSpan"), 1)
            XCTAssertTrue(try AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }

    func testADatabaseFromThePublicLineGetsTheCallLane() throws {
        let url = try tempDir().appendingPathComponent("public.sqlite")
        try oldDatabase(at: url, upTo: "v22")
        let opened = try AppDatabase.open(at: url)
        try opened.read { db in
            XCTAssertTrue(try db.tableExists("callSpan"))
            XCTAssertTrue(try db.tableExists("jevAttempt"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'marker'"), "kept")
            XCTAssertTrue(try AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }
}
