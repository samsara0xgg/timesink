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

    // Fix report finding 1: pattern/scopeKey dedupe must be case-insensitive
    // (title matching itself is 大小写不敏感), or the ON CONFLICT silently
    // stops firing for patterns differing only in ASCII case.
    func testTitleRuleUpsertIsCaseInsensitive() throws {
        let db = try makeDB()
        let store = CategoryStore(db)
        try store.upsertUserTitleRule(pattern: "Lecture", scopeKey: "youtube.com", categoryID: "learning")
        try store.upsertUserTitleRule(pattern: "lecture", scopeKey: "youtube.com", categoryID: "writing")
        let rules = try store.titleRules().filter { $0.source == "user" }
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].categoryID, "writing")
    }

    // Fix report finding 2: a user upsert colliding with a builtin row must
    // be a silent no-op -- it must never flip the row to source='user'
    // (which would make it deletable) or change its categoryID.
    func testUpsertUserTitleRuleDoesNotStealBuiltinRow() throws {
        let db = try makeDB()
        let store = CategoryStore(db)
        let builtinPattern = "lecture|course|教程|课程|讲座"
        try store.upsertUserTitleRule(pattern: builtinPattern, scopeKey: "", categoryID: "writing")
        let rules = try store.titleRules().filter { $0.pattern == builtinPattern }
        XCTAssertEqual(rules.count, 1)                    // no new row was added
        XCTAssertEqual(rules[0].source, "builtin")
        XCTAssertEqual(rules[0].categoryID, "learning")   // unchanged
        XCTAssertTrue(rules[0].enabled)
    }

    // Fix report finding 2: a user upsert colliding with a disabled builtin
    // row must not silently re-enable it.
    func testUpsertUserTitleRuleLeavesDisabledBuiltinDisabled() throws {
        let db = try makeDB()
        let store = CategoryStore(db)
        let builtin = try store.titleRules().first { $0.source == "builtin" && $0.categoryID == "learning" }!
        try store.setTitleRuleEnabled(id: builtin.id!, enabled: false)
        try store.upsertUserTitleRule(pattern: builtin.pattern, scopeKey: builtin.scopeKey, categoryID: "writing")
        let after = try store.titleRules().first { $0.id == builtin.id }!
        XCTAssertFalse(after.enabled)
        XCTAssertEqual(after.source, "builtin")
        XCTAssertEqual(after.categoryID, "learning")
    }
}
