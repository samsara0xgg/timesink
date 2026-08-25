import XCTest
import GRDB
@testable import TimeSinkKit

final class DatabaseTests: XCTestCase {
    func makeDB() throws -> DatabaseQueue { try AppDatabase.openInMemory() }

    func testMigrationSeedsCategories() throws {
        let db = try makeDB()
        let store = CategoryStore(db)
        let cats = try store.allCategories()
        XCTAssertEqual(cats.count, 12)
        XCTAssertEqual(cats.first?.id, "softwareDev")   // sortOrder 排序
        XCTAssertEqual(cats.first?.productivity, 2)
    }
    func testSpanRoundtrip() throws {
        let db = try makeDB()
        let store = SpanStore(db)
        var span = Span(start: ts(0), end: ts(10), appBundleID: "a", appName: "A",
                        title: "t", url: nil, domain: nil)
        span = try store.insert(span)
        XCTAssertNotNil(span.id)
        try store.updateEnd(id: span.id!, end: ts(20))
        let hits = try store.spans(overlapping: DateInterval(start: ts(5), end: ts(15)))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].end, ts(20))
        let miss = try store.spans(overlapping: DateInterval(start: ts(100), end: ts(200)))
        XCTAssertTrue(miss.isEmpty)
    }
    func testSeedImportDoesNotOverwriteUser() throws {
        let db = try makeDB()
        let store = CategoryStore(db)
        try store.setUserDomain("github.com", categoryID: "learning")
        try store.importSeedDomains([("github.com", "softwareDev"), ("x.com", "socialMedia")])
        let map = try store.domainMap()
        XCTAssertEqual(map["github.com"], DomainEntry(categoryID: "learning", source: "user"))
        XCTAssertEqual(map["x.com"], DomainEntry(categoryID: "socialMedia", source: "seed"))
    }
    func testLLMInsertNeverOverwrites() throws {
        let db = try makeDB()
        let store = CategoryStore(db)
        try store.setUserDomain("a.com", categoryID: "news")
        try store.insertLLMDomain("a.com", categoryID: "shopping")
        XCTAssertEqual(try store.domainMap()["a.com"]?.categoryID, "news")
    }
    func testBuiltinRulesAndAppsSeeded() throws {
        let db = try makeDB()
        let store = CategoryStore(db)
        XCTAssertTrue(try store.urlRules().contains { $0.pattern == "youtube.com/watch" })
        XCTAssertEqual(try store.appMap()["com.apple.dt.Xcode"]?.categoryID, "softwareDev")
    }
    func testSettingsDefaultsAndPersistence() throws {
        let db = try makeDB()
        let s = SettingsStore(db)
        XCTAssertEqual(s.idleThreshold, 180)
        XCTAssertFalse(s.llmEnabled)
        s.setIdleThreshold(300)
        XCTAssertEqual(s.idleThreshold, 300)
    }
    func testV2SocialAndCommRulesSeeded() throws {
        let db = try makeDB()
        let store = CategoryStore(db)
        let rules = try store.urlRules()
        XCTAssertTrue(rules.contains { $0.pattern == "facebook.com" && $0.categoryID == "socialMedia" })
        XCTAssertTrue(rules.contains { $0.pattern == "outlook." && $0.categoryID == "communication" })
        XCTAssertTrue(rules.contains { $0.pattern == #"re:https?://(www\.)?x\.com"# && $0.categoryID == "socialMedia" })
    }
    func testDatabaseFileNameSplitsDevAndProd() {
        XCTAssertEqual(AppDatabase.databaseFileName(bundleIdentifier: "com.alllllenshi.TimeSink"),
                       "timesink.sqlite")
        XCTAssertEqual(AppDatabase.databaseFileName(bundleIdentifier: nil),
                       "timesink-dev.sqlite")
        XCTAssertEqual(AppDatabase.databaseFileName(bundleIdentifier: "com.example.other"),
                       "timesink-dev.sqlite")
    }
    func testV3IndexesEndAndDropsUnusedIndexes() throws {
        let db = try AppDatabase.openInMemory()
        let names = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'span'")
        }
        XCTAssertTrue(names.contains("span_on_end"))
        XCTAssertTrue(names.contains("span_on_start"))
        XCTAssertFalse(names.contains("span_on_appBundleID"))
        XCTAssertFalse(names.contains("span_on_domain"))
    }
    /// With `ORDER BY start ASC` present, SQLite prefers span_on_start (it
    /// both filters and supplies the ordering) over the more selective
    /// span_on_end -- so this must run the exact ORDER-BY-less SQL
    /// SpanStore.spans(overlapping:) actually issues (via the shared
    /// `SpanStore.overlapSQL` constant, not a hand-copied paraphrase that
    /// could silently drift from the real query and stop guarding anything).
    func testOverlapQueryPlanUsesEndIndex() throws {
        let db = try AppDatabase.openInMemory()
        let rows = try db.read { db in
            try Row.fetchAll(
                db,
                sql: "EXPLAIN QUERY PLAN " + SpanStore.overlapSQL,
                arguments: [Date(), Date()]
            )
        }
        let plan = rows.map(String.init(describing:)).joined(separator: " ")
        XCTAssertTrue(plan.contains("span_on_end"), "expected span_on_end in query plan, got: \(plan)")
    }
    func testV4CreatesTablesAndSeedsTitleRules() throws {
        let db = try makeDB()
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for t in ["titleRule", "budget", "budgetAlert", "focusSession"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
        let store = CategoryStore(db)
        let seeds = try store.titleRules()
        XCTAssertEqual(seeds.filter { $0.source == "builtin" }.count, 2)
        XCTAssertTrue(seeds.contains { $0.pattern == "lecture|course|教程|课程|讲座" && $0.categoryID == "learning" })
        XCTAssertTrue(seeds.contains { $0.pattern == "pull request|merge request|PR #" && $0.categoryID == "softwareDev" })
    }
    func testV4DoesNotTouchSpanIndexes() throws {
        // 与 testV3IndexesEndAndDropsUnusedIndexes 同一组断言，证明 v4 没动 span
        let db = try AppDatabase.openInMemory()
        let names = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'span'")
        }
        XCTAssertTrue(names.contains("span_on_end"))
        XCTAssertTrue(names.contains("span_on_start"))
    }
    func testUpgradeFromV3PreservesData() throws {
        // 现有测试全测全新库；这是唯一的升级路径测试
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db, upTo: "v3")
        let spanStore = SpanStore(db)
        let catStore = CategoryStore(db)
        _ = try spanStore.insert(Span(start: ts(0), end: ts(100), appBundleID: "a",
                                      appName: "A", title: "t", url: nil, domain: nil))
        try catStore.addUserURLRule(pattern: "mysite.com", categoryID: "news", priority: 1000)
        try AppDatabase.migrator.migrate(db)  // v3 → v4
        XCTAssertEqual(try spanStore.spans(overlapping: DateInterval(start: ts(0), end: ts(200))).count, 1)
        XCTAssertTrue(try catStore.urlRules().contains { $0.pattern == "mysite.com" })
        XCTAssertEqual(try catStore.titleRules().filter { $0.source == "builtin" }.count, 2)
    }
    func testBudgetAlertCompositePKAndPrune() throws {
        let db = try makeDB()
        let store = BudgetStore(db)
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        try store.noteAlert(categoryID: "entertainment", day: "2026-08-24", kind: "warn")
        try store.noteAlert(categoryID: "entertainment", day: "2026-08-24", kind: "warn")  // 重复无效
        XCTAssertEqual(try store.alertKinds(categoryID: "entertainment", day: "2026-08-24"), ["warn"])
        try store.noteAlert(categoryID: "entertainment", day: "2026-05-01", kind: "limit")
        try store.pruneAlerts(before: "2026-08-01")
        XCTAssertEqual(try store.alertKinds(categoryID: "entertainment", day: "2026-05-01"), [])
        XCTAssertEqual(try store.alertKinds(categoryID: "entertainment", day: "2026-08-24"), ["warn"])
    }
    func testFocusSessionLifecycle() throws {
        let db = try makeDB()
        let store = FocusSessionStore(db)
        let s = try store.start(at: ts(0), plannedSeconds: 1500)
        XCTAssertNotNil(s.id)
        XCTAssertEqual(s.end, ts(0))          // 开始即落盘，end = start
        try store.heartbeat(id: s.id!, end: ts(30))
        try store.finish(id: s.id!, end: ts(1500), appBlocks: 1, siteBlocks: 2, completed: true)
        let hits = try store.sessions(overlapping: DateInterval(start: ts(0), end: ts(2000)))
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].completed)
        XCTAssertEqual(hits[0].siteBlocks, 2)
    }
    func testNewSettingsAccessors() throws {
        let db = try makeDB()
        let s = SettingsStore(db)
        XCTAssertEqual(s.budgetWarnPercent, 20)
        XCTAssertFalse(s.dailySummaryEnabled)
        XCTAssertEqual(s.dailySummaryHour, 19)
        XCTAssertTrue(s.menuBarTextEnabled)
        XCTAssertEqual(s.focusDurationMinutes, 25)
        XCTAssertEqual(s.focusBlockedApps, [])
        s.setFocusBlockedApps(["com.tencent.xinWeChat", "com.hnc.Discord"])
        XCTAssertEqual(s.focusBlockedApps, ["com.tencent.xinWeChat", "com.hnc.Discord"])
    }
}
