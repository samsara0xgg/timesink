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
}
