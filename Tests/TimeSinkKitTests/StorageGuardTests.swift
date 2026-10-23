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

    func testBackupTakenOnlyWhenMigrationsArePending() throws {
        let dir = try tempDir()
        let db = dir.appendingPathComponent("timesink.sqlite")
        let backups = dir.appendingPathComponent("Backups")

        // New install: file did not exist, nothing to protect.
        _ = try AppDatabase.open(at: db, backupsDirectory: backups)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        // Up to date: reopening needs no backup.
        _ = try AppDatabase.open(at: db, backupsDirectory: backups)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))

        let old = dir.appendingPathComponent("old.sqlite")
        try oldDatabase(at: old, upTo: "v20")
        _ = try AppDatabase.open(at: old, backupsDirectory: backups)
        let backup = backups.appendingPathComponent("old.pre-v21.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        // The backup is the pre-migration state: marker kept, v21 not applied.
        let copy = try DatabaseQueue(path: backup.path)
        try copy.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'marker'"), "kept")
            XCTAssertFalse(try AppDatabase.migrator.appliedMigrations(db).contains("v21"))
        }
    }

    func testNoBackupWithoutDirectory() throws {
        let dir = try tempDir()
        let old = dir.appendingPathComponent("old.sqlite")
        try oldDatabase(at: old, upTo: "v20")
        _ = try AppDatabase.open(at: old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("pre-") }, [])
    }

    func testKeepsNewestThreeBackups() throws {
        let dir = try tempDir()
        let backups = dir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        // Four older backups plus an unrelated manual file that must stay.
        for (index, id) in ["v3", "v4", "v5", "v6"].enumerated() {
            let file = backups.appendingPathComponent("old.pre-\(id).sqlite")
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-1000 + index * 100))],
                                                  ofItemAtPath: file.path)
        }
        let manual = backups.appendingPathComponent("before-refined-keep.sqlite")
        try Data("x".utf8).write(to: manual)

        let old = dir.appendingPathComponent("old.sqlite")
        try oldDatabase(at: old, upTo: "v20")
        _ = try AppDatabase.open(at: old, backupsDirectory: backups)

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: backups.path))
        XCTAssertEqual(names, ["old.pre-v21.sqlite", "old.pre-v6.sqlite", "old.pre-v5.sqlite", "before-refined-keep.sqlite"])
    }
}
