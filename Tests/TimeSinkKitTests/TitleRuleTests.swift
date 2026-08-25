import XCTest
import GRDB
@testable import TimeSinkKit

final class TitleRuleTests: XCTestCase {
    func makeDB() throws -> DatabaseQueue { try AppDatabase.openInMemory() }

    func testTitleRuleUpsertIsIdempotent() throws {
        let db = try makeDB()
        let store = CategoryStore(db)
        try store.upsertUserTitleRule(pattern: "lecture", scopeKey: "youtube.com", categoryID: "learning")
        try store.upsertUserTitleRule(pattern: "lecture", scopeKey: "youtube.com", categoryID: "writing")
        let rules = try store.titleRules().filter { $0.source == "user" }
        XCTAssertEqual(rules.count, 1)                    // 不复制 addUserURLRule 的裸 INSERT 缺陷
        XCTAssertEqual(rules[0].categoryID, "writing")    // upsert 更新分类
    }
}
