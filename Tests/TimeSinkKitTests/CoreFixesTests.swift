import GRDB
import os
import XCTest
@testable import TimeSinkKit

/// Seed resources, database safety, projects, budgets, the cloud device id and the CSV export.
@MainActor
final class CoreFixesTests: XCTestCase {
    /// A new empty folder; the caller removes it.
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CoreFixesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A stand-in `TimeSink.app`, with the resource bundle in Contents/Resources when `withResources`.
    private func fakeApp(in folder: URL, withResources: Bool) throws -> Bundle {
        let app = folder.appendingPathComponent("Fake.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.fake." + UUID().uuidString, "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        if withResources {
            let bundle = resources.appendingPathComponent(SeedImporter.resourceBundleName, isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("# version: 1\nexample.invalid,learning\n".utf8).write(to: bundle.appendingPathComponent("seed_domains.csv"))
        }
        return try XCTUnwrap(Bundle(url: app))
    }

    // MARK: - Seed resources (#1)

    func testResourceBundleFallsBackToTheModuleBundleInTests() throws {
        let bundle = try XCTUnwrap(SeedImporter.resourceBundle(main: Bundle(for: CoreFixesTests.self)))
        XCTAssertEqual(bundle.bundleURL.standardizedFileURL, Bundle.module.bundleURL.standardizedFileURL)
        XCTAssertNotNil(bundle.url(forResource: "seed_domains", withExtension: "csv"))
        XCTAssertNotNil(SeedImporter.resourceBundle()?.url(forResource: "seed_overlay", withExtension: "csv"))
    }

    func testPackagedAppReadsTheBundleFromContentsResources() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try fakeApp(in: folder, withResources: true)
        let url = try XCTUnwrap(SeedImporter.resourceBundle(main: app)?.url(forResource: "seed_domains", withExtension: "csv"))
        XCTAssertTrue(url.path.hasPrefix(folder.resolvingSymlinksInPath().path) || url.path.hasPrefix(folder.path))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("example.invalid"))
    }

    func testPackagedAppWithoutTheBundleGetsNoneInsteadOfATrap() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try fakeApp(in: folder, withResources: false)
        XCTAssertNil(SeedImporter.resourceBundle(main: app))
    }

    // MARK: - Seed import after a category is deleted (#28)

    func testSeedImportSkipsPairsForADeletedCategory() throws {
        let db = try AppDatabase.openInMemory()
        let store = CategoryStore(db)
        let settings = SettingsStore(db)
        try store.deleteCategory("news", reassignTo: "misc")

        try store.importSeedDomains([("a.example", "news"), ("b.example", "learning")])
        try store.importCuratedDomains([("c.example", "news"), ("d.example", "writing")])
        let map = try store.domainMap()
        XCTAssertNil(map["a.example"])
        XCTAssertEqual(map["b.example"], DomainEntry(categoryID: "learning", source: "seed"))
        XCTAssertNil(map["c.example"])
        XCTAssertEqual(map["d.example"], DomainEntry(categoryID: "writing", source: "curated"))

        // The bundled seed names `news` too: it still imports, and its version is stamped.
        SeedImporter.importIfNeeded(categoryStore: store, settings: settings)
        XCTAssertNotNil(settings.get("seedVersion"))
        XCTAssertNotNil(settings.get("curatedSeedVersion"))
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM domainCategory WHERE categoryID = 'news'") }, 0)
    }

    func testRemovingAUserMappingWhoseDefaultCategoryIsGone() throws {
        let db = try AppDatabase.openInMemory()
        let store = CategoryStore(db)
        XCTAssertEqual(SeedImporter.shippedDomain("01net.com")?.categoryID, "news")
        try store.setUserDomain("01net.com", categoryID: "learning")
        try store.deleteCategory("news", reassignTo: "misc")
        try store.removeUserMapping(key: "domain:01net.com")
        XCTAssertNil(try store.domainMap()["01net.com"])
    }

    // MARK: - Database (#23)

    func testOpeningAnOlderDatabaseBacksItUpOnce() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("timesink.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try AppDatabase.migrator.migrate(old, upTo: "v20")
        try old.write { try $0.execute(sql: "INSERT INTO setting (key, value) VALUES ('marker', 'before')") }
        try old.close()
        // Older copies than the two kept.
        for stamp in ["20200101-000000", "20200102-000000", "20200103-000000"] {
            try Data().write(to: folder.appendingPathComponent("timesink-backup-\(stamp).sqlite"))
        }

        let pool = try AppDatabase.open(at: url)
        var backups = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("timesink-backup-") && $0.hasSuffix(".sqlite") }.sorted()
        XCTAssertEqual(backups.count, AppDatabase.keptBackups)
        XCTAssertEqual(backups.first, "timesink-backup-20200103-000000.sqlite")
        let newest = try XCTUnwrap(backups.last)
        let copy = try DatabaseQueue(path: folder.appendingPathComponent(newest).path)
        try copy.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'marker'"), "before")
            XCTAssertFalse(try AppDatabase.migrator.appliedIdentifiers(db).contains("v21"), "taken before migrating")
        }
        try copy.close()
        XCTAssertTrue(try pool.read { try AppDatabase.migrator.hasCompletedMigrations($0) })
        try pool.close()

        // Up to date: no copy.
        try AppDatabase.open(at: url).close()
        backups = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("timesink-backup-") && $0.hasSuffix(".sqlite") }
        XCTAssertEqual(backups.count, AppDatabase.keptBackups)
    }

    func testANewDatabaseIsNotBackedUp() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try AppDatabase.open(at: folder.appendingPathComponent("timesink.sqlite")).close()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains { $0.contains("-backup-") })
    }

    // MARK: - Projects (#27)

    func testDeletingAProjectClearsItsAssignmentsAndVerdicts() throws {
        let db = try AppDatabase.openInMemory()
        let projects = CategoryStore(db).projects
        let sessions = ObservationStore(db)
        let a = try projects.add(name: "Alpha")
        let b = try projects.add(name: "Beta")
        try sessions.setSessionName(signature: "p:x", project: "alpha")
        try sessions.setSessionName(signature: "p:y", name: "Mine", project: "Alpha")
        try sessions.setSessionName(signature: "p:z", project: "Beta")
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO jevProjectVerdict (appBundleID, projectID, runnerUp, promptVersion, at) VALUES ('a', ?, ?, 'pv', ?), ('b', ?, ?, 'pv', ?)
                """, arguments: [a.id, b.id, Date(), b.id, a.id, Date()])
        }

        try projects.delete(a.id)
        XCTAssertEqual(try projects.list().map(\.name), ["Beta"])
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project") }, 1, "gone, not archived")
        let names = try sessions.sessionNames()
        XCTAssertNil(names["p:x"], "a row left with nothing goes")
        XCTAssertEqual(names["p:y"]?.name, "Mine")
        XCTAssertNil(names["p:y"]?.project)
        XCTAssertEqual(names["p:z"]?.project, "Beta")
        let verdicts = try db.read { try Row.fetchAll($0, sql: "SELECT appBundleID, projectID, runnerUp FROM jevProjectVerdict") }
        XCTAssertEqual(verdicts.count, 1)
        let kept = try XCTUnwrap(verdicts.first)
        XCTAssertEqual(kept["projectID"] as String, b.id)
        XCTAssertEqual(kept["runnerUp"] as String, "")
        XCTAssertThrowsError(try projects.delete(a.id)) { XCTAssertEqual($0 as? ProjectStore.ProjectError, .notFound) }

        // The name is free again, for a new project.
        XCTAssertNotEqual(try projects.add(name: "Alpha").id, a.id)
    }

    func testRestoringAnArchivedProjectRespectsTheLimit() throws {
        let projects = CategoryStore(try AppDatabase.openInMemory()).projects
        let old = try projects.add(name: "Old")
        try projects.archive(old.id)
        for i in 0..<ProjectStore.maxProjects { try projects.add(name: "p\(i)") }
        XCTAssertThrowsError(try projects.add(name: "old")) { XCTAssertEqual($0 as? ProjectStore.ProjectError, .limitReached) }
        XCTAssertEqual(try projects.list().count, ProjectStore.maxProjects)
    }

    func testAnArchivedProjectGivesUpItsNameToARename() throws {
        let db = try AppDatabase.openInMemory()
        let projects = CategoryStore(db).projects
        let old = try projects.add(name: "Alpha")
        try projects.archive(old.id)
        let beta = try projects.add(name: "Beta")
        try projects.update(id: beta.id, name: "alpha", description: "")
        XCTAssertEqual(try projects.list().map(\.name), ["alpha"])
        XCTAssertEqual(try projects.list().map(\.id), [beta.id])
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project") }, 1)
    }

    // MARK: - Budgets (#33)

    private func monitor() throws -> (DatabaseQueue, BudgetMonitor, BudgetStore, SpyNotifier) {
        let db = try AppDatabase.openInMemory()
        let store = BudgetStore(db)
        let spy = SpyNotifier()
        return (db, BudgetMonitor(budgetStore: store, settings: SettingsStore(db), notifier: spy), store, spy)
    }

    func testRaisingALimitReArmsTheDaysAlerts() throws {
        let (db, m, store, spy) = try monitor()
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        m.evaluate(byCategory: ["entertainment": 3700], categories: cats, now: ts(0))
        m.evaluate(byCategory: ["entertainment": 3700], categories: cats, now: ts(60))
        XCTAssertEqual(spy.posted.map { $0.id }, ["budget.limit.entertainment"])

        try store.setBudget(categoryID: "entertainment", dailySeconds: 7200)
        m.evaluate(byCategory: ["entertainment": 3700], categories: cats, now: ts(120))
        XCTAssertEqual(spy.posted.count, 1, "under the new warn line")
        m.evaluate(byCategory: ["entertainment": 6000], categories: cats, now: ts(180))
        XCTAssertEqual(spy.posted.last?.id, "budget.warn.entertainment")
        m.evaluate(byCategory: ["entertainment": 7300], categories: cats, now: ts(240))
        XCTAssertEqual(spy.posted.map { $0.id }, ["budget.limit.entertainment", "budget.warn.entertainment", "budget.limit.entertainment"])

        // Lowering it again does not repeat what already went out.
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        m.evaluate(byCategory: ["entertainment": 7300], categories: cats, now: ts(300))
        XCTAssertEqual(spy.posted.count, 3)

        // A relaunch reads the stamps, limits included, from the database.
        try store.setBudget(categoryID: "entertainment", dailySeconds: 7200)
        let relaunched = BudgetMonitor(budgetStore: store, settings: SettingsStore(db), notifier: spy)
        relaunched.evaluate(byCategory: ["entertainment": 7300], categories: cats, now: ts(360))
        XCTAssertEqual(spy.posted.count, 3)
    }

    func testUnreadableStampsSendNothing() throws {
        let (db, m, store, spy) = try monitor()
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        try db.write { try $0.execute(sql: "DROP TABLE budgetAlert") }
        m.evaluate(byCategory: ["entertainment": 3700], categories: cats, now: ts(0))
        m.evaluate(byCategory: ["entertainment": 3700], categories: cats, now: ts(60))
        XCTAssertTrue(spy.posted.isEmpty)
    }

    // MARK: - Cloud device id (#21)

    func testDeviceIDIsMintedOnceAndKeptOnTheSameMac() throws {
        let db = try AppDatabase.openInMemory()
        let first = SettingsStore(db, hardwareID: { "mac-a" })
        let second = SettingsStore(db, hardwareID: { "mac-a" })
        let id = first.cloudDeviceID
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(second.cloudDeviceID, id)
        XCTAssertEqual(first.cloudDeviceID, id)
    }

    func testAnIDFromBeforeTheHardwareWasNotedIsKept() throws {
        let db = try AppDatabase.openInMemory()
        SettingsStore(db, hardwareID: { nil }).set("cloud.deviceID", "legacy-id")
        XCTAssertEqual(SettingsStore(db, hardwareID: { "mac-a" }).cloudDeviceID, "legacy-id")
        XCTAssertEqual(SettingsStore(db, hardwareID: { "mac-a" }).get("cloud.hardwareID"), "mac-a")
    }

    func testDeviceIDIsMintedAgainOnAnotherMac() throws {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db)
        let hardware = OSAllocatedUnfairLock(initialState: "mac-a")
        let settings = SettingsStore(db, hardwareID: { hardware.withLock { (state: inout String) -> String in state } })
        let old = settings.cloudDeviceID
        let uploaded = try spans.insert(Span(start: ts(0), end: ts(60), appBundleID: "a", appName: "A", title: nil, url: nil, domain: nil))
        let pending = try spans.insert(Span(start: ts(60), end: ts(120), appBundleID: "a", appName: "A", title: nil, url: nil, domain: nil))
        try spans.markSynced([(id: try XCTUnwrap(uploaded.id), seq: "0001")])
        try spans.insertRemote([SpanStore.RemoteSpan(span: Span(start: ts(0), end: ts(30), appBundleID: "c", appName: "C", title: nil, url: nil, domain: nil),
                                                     deviceID: "mac-c-device", originID: 7, seq: "0002")])
        settings.setCloudPullCursor("0002")

        hardware.withLock { (state: inout String) in state = "mac-b" }
        let new = settings.cloudDeviceID
        XCTAssertNotEqual(new, old)
        XCTAssertEqual(settings.cloudDeviceID, new)
        XCTAssertEqual(SettingsStore(db, hardwareID: { "mac-b" }).cloudDeviceID, new)
        XCTAssertEqual(settings.cloudPullCursor, "0002")

        let rows = try db.read { try Row.fetchAll($0, sql: "SELECT id, deviceID, originID FROM span ORDER BY id") }
        // What the old Mac uploaded is that Mac's now, as the cloud has it; a pull of it is a no-op.
        XCTAssertEqual(rows[0]["deviceID"] as String?, old)
        XCTAssertEqual(rows[0]["originID"] as Int64?, uploaded.id)
        XCTAssertNil(rows[1]["deviceID"] as String?, "not uploaded yet: goes up under the new id")
        XCTAssertEqual(rows[2]["deviceID"] as String?, "mac-c-device")
        XCTAssertEqual(try spans.unsynced(excluding: nil, limit: 10).map(\.id), [pending.id])
        let again = try spans.insertRemote([SpanStore.RemoteSpan(span: Span(start: ts(0), end: ts(60), appBundleID: "a", appName: "A", title: nil, url: nil, domain: nil),
                                                                 deviceID: old, originID: try XCTUnwrap(uploaded.id), seq: "0001")])
        XCTAssertEqual(again, 0)
    }

    // MARK: - CSV export (#33)

    func testCSVHasLocalTimesAndTheCategory() throws {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db)
        let span = try spans.insert(Span(start: ts(0), end: ts(90), appBundleID: "com.apple.dt.Xcode", appName: "Xcode", title: "=x", url: nil, domain: nil))
        let resolver = CategoryResolver(categoryStore: CategoryStore(db))
        let category = resolver.categoryID(for: span)
        let csv = try spans.exportCSV(categories: resolver.snapshot(), names: [category: "Dev"])
        let local = ISO8601DateFormatter()
        local.timeZone = TimeZone.current
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0].components(separatedBy: ",").count, 8)
        XCTAssertTrue(lines[1].hasPrefix("\"\(local.string(from: ts(0)))\",\"\(local.string(from: ts(90)))\""))
        XCTAssertTrue(lines[1].hasSuffix(",\"'=x\",\"\",\"\",\"Dev\""))
        // Without a resolver: the seven columns as before, the same local times.
        let plain = try spans.exportCSV().components(separatedBy: "\r\n")
        XCTAssertEqual(plain[0].components(separatedBy: ",").count, 7)
        XCTAssertTrue(plain[1].hasPrefix("\"\(local.string(from: ts(0)))\""))
    }
}
