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

extension TitleRuleTests {
    private func trCtx(titleRules: [TitleRule] = [], domains: [String: DomainEntry] = [:],
                       rules: [URLRule] = []) -> ClassificationContext {
        ClassificationContext(domainMap: domains, appMap: [:], urlRules: rules, titleRules: titleRules)
    }
    private func tr(_ pattern: String, _ cat: String, scope: String = "",
                    source: String = "user", id: Int64? = nil) -> TitleRule {
        TitleRule(id: id, pattern: pattern, scopeKey: scope, categoryID: cat, source: source)
    }

    func testUserTitleRuleBeatsUserDomainAndBuiltinURLRule() {
        // 经典场景：youtube.com 整体娱乐（user domain + builtin urlRule 双重压制下），讲座标题仍归学习
        let c = trCtx(
            titleRules: [tr("lecture", "learning", scope: "youtube.com")],
            domains: ["youtube.com": .init(categoryID: "entertainment", source: "user")],
            rules: [URLRule(id: nil, pattern: "youtube.com/watch", categoryID: "entertainment", priority: 200, source: "builtin")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.google.Chrome",
            url: "https://youtube.com/watch?v=1", domain: "youtube.com",
            title: "MIT Lecture 3 - YouTube", context: c), "learning")
    }
    func testScopedRuleDoesNotFireElsewhere() {
        let c = trCtx(titleRules: [tr("lecture", "learning", scope: "youtube.com")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://bilibili.com/v", domain: "bilibili.com",
            title: "lecture 42", context: c), "uncategorized")
    }
    func testGlobalRuleFiresOnNativeApp() {
        // 无 url/domain 的原生应用 span：scopeKey 落到 bundleID，全局规则也要命中
        let c = trCtx(titleRules: [tr("教程", "learning")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.apple.Preview",
            url: nil, domain: nil, title: "SwiftUI 教程.pdf", context: c), "learning")
    }
    func testNilTitleFallsThroughFree() {
        let c = trCtx(titleRules: [tr("lecture", "learning")],
                      domains: ["x.com": .init(categoryID: "socialMedia", source: "seed")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://x.com/", domain: "x.com", title: nil, context: c), "socialMedia")
    }
    func testUserURLRuleBeatsBuiltinTitleSeed() {
        let c = trCtx(
            titleRules: [tr("course", "learning", source: "builtin")],
            rules: [URLRule(id: nil, pattern: "udemy.com", categoryID: "entertainment", priority: 1000, source: "user")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://udemy.com/course/x", domain: "udemy.com",
            title: "My course", context: c), "entertainment")
    }
    func testBuiltinTitleSeedBeatsBuiltinURLRule() {
        let c = trCtx(
            titleRules: [tr("pull request", "softwareDev", source: "builtin")],
            rules: [URLRule(id: nil, pattern: "example.com", categoryID: "news", priority: 100, source: "builtin")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://example.com/pr/1", domain: "example.com",
            title: "Fix span clipping — Pull Request #42", context: c), "softwareDev")
    }
    func testPipeKeywordGroupAnyHit() {
        XCTAssertTrue(Classifier.titleMatches(pattern: "lecture|course|教程", title: "线性代数教程 第3讲"))
        XCTAssertTrue(Classifier.titleMatches(pattern: "lecture|course|教程", title: "CS540 Course Home"))
        XCTAssertFalse(Classifier.titleMatches(pattern: "lecture|course|教程", title: "Weekend Vlog"))
    }
    func testRegexTitlePattern() {
        XCTAssertTrue(Classifier.titleMatches(pattern: #"re:PR #\d+"#, title: "Fix bug PR #42"))
        XCTAssertFalse(Classifier.titleMatches(pattern: #"re:PR #\d+"#, title: "PR # pending"))
    }
    func testScopedRuleSortsBeforeUnscoped() {
        // 同为 user 层：scoped 的更具体，先命中
        let scoped = tr("news", "learning", scope: "ycombinator.com", id: 1)
        let global = tr("news", "news", id: 2)
        let c = trCtx(titleRules: [scoped, global])   // resolver 排序后的顺序
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://ycombinator.com/news", domain: "ycombinator.com",
            title: "Hacker news daily", context: c), "learning")
    }
}
