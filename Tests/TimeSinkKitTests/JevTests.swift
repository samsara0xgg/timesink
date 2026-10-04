import GRDB
import XCTest
@testable import TimeSinkKit

/// Replies from a closure, records every request, never touches the network.
final class StubJevTransport: JevTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let reply: @Sendable (_ state: [String: String]) -> (choice: String, probabilities: [String: Double], cost: Double)
    /// When set, a request whose state title it accepts gets HTTP 429 with this Retry-After.
    var limit: (@Sendable (_ state: [String: String]) -> Bool)?
    var retryAfter: String?

    init(reply: @escaping @Sendable (_ state: [String: String]) -> (choice: String, probabilities: [String: Double], cost: Double)) {
        self.reply = reply
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func post(_ request: URLRequest) async throws -> (data: Data, status: Int, retryAfter: String?) {
        lock.withLock { recorded.append(request) }
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let raw = (body?["state"] as? [String: Any]) ?? [:]
        var state = raw.compactMapValues { $0 as? String }
        if let list = raw["用户以前确认过的例子"] as? [Any] { state["examples"] = String(list.count) }
        if limit?(state) == true { return (Data(), 429, retryAfter) }
        let r = reply(state)
        let json: [String: Any] = [
            "answers": ["category": ["choice": r.choice, "probabilities": r.probabilities, "confidence": 0.5]],
            "usage": ["input_tokens": 700, "cost": r.cost],
        ]
        return (try JSONSerialization.data(withJSONObject: json), 200, nil)
    }
}

@MainActor
final class JevTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: CategoryStore!
    private var settings: SettingsStore!

    override func setUpWithError() throws {
        db = try AppDatabase.openInMemory()
        store = CategoryStore(db)
        settings = SettingsStore(db)
    }

    private func span(_ app: String = "com.google.Chrome", domain: String? = nil, title: String? = nil, document: String? = nil,
                      url: String? = nil, at start: Date = Date().addingTimeInterval(-3600), seconds: Double = 600, name: String = "App") -> Span {
        Span(start: start, end: start.addingTimeInterval(seconds), appBundleID: app, appName: name, title: title, url: url,
             domain: domain, document: document)
    }

    private func ghosttyJob() -> JevRules.Hit? {
        JevRules.match(appBundleID: "com.mitchellh.ghostty", domain: nil, url: nil, title: "resume the session", document: nil)
    }

    // MARK: - Migration

    func testMigrationKeepsUserDataAndMergesShopping() throws {
        let old = try DatabaseQueue()
        try AppDatabase.migrator.migrate(old, upTo: "v14")
        let spanID = try old.write { db -> Int64 in
            try db.execute(sql: "UPDATE category SET name = '我的开发' WHERE id = 'softwareDev'")
            try db.execute(sql: "UPDATE category SET productivity = 1 WHERE id = 'learning'")
            try db.execute(sql: "INSERT INTO span (start, \"end\", appBundleID, appName, keySeconds) VALUES (?, ?, 'a', 'A', 0)",
                           arguments: [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 60)])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO spanCategoryOverride (spanID, categoryID) VALUES (?, 'shopping')", arguments: [id])
            try db.execute(sql: "INSERT INTO domainCategory (domain, categoryID, source, updatedAt) VALUES ('shop.example', 'shopping', 'user', ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO appCategory (bundleID, categoryID, source) VALUES ('app.shop', 'shopping', 'user')")
            try db.execute(sql: "INSERT INTO urlRule (pattern, categoryID, priority, source) VALUES ('shop.example/cart', 'shopping', 300, 'user')")
            try db.execute(sql: "INSERT INTO titleRule (pattern, scopeKey, categoryID, priority, source, enabled, createdAt) VALUES ('cart', '', 'shopping', 100, 'user', 1, ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO budget (categoryID, dailySeconds, enabled) VALUES ('shopping', 600, 1), ('business', 900, 1)")
            try db.execute(sql: "INSERT INTO budgetAlert (categoryID, day, kind) VALUES ('shopping', '2026-10-01', 'warn')")
            try db.execute(sql: "INSERT INTO classificationSuggestion (key, kind, categoryID, source, createdAt) VALUES ('s.example', 'domain', 'shopping', 'model', ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('focusBlockedCategories', 'shopping,entertainment'), ('llmEnabled', 'true'), ('llmEndpoint', 'https://api.openai.com/v1')")
            return id
        }
        try AppDatabase.migrator.migrate(old)

        try old.read { db in
            XCTAssertNil(try Category.fetchOne(db, key: "shopping"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT categoryID FROM spanCategoryOverride WHERE spanID = ?", arguments: [spanID]), "business")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT categoryID FROM domainCategory WHERE domain = 'shop.example'"), "business")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT source FROM domainCategory WHERE domain = 'shop.example'"), "user")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT categoryID FROM appCategory WHERE bundleID = 'app.shop'"), "business")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT categoryID FROM urlRule WHERE pattern = 'shop.example/cart'"), "business")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT categoryID FROM titleRule WHERE pattern = 'cart'"), "business")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dailySeconds FROM budget WHERE categoryID = 'business'"), 900)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM budget WHERE categoryID = 'shopping'"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT categoryID FROM budgetAlert"), "business")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT categoryID FROM classificationSuggestion"), "business")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'focusBlockedCategories'"), "business,entertainment")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM setting WHERE key LIKE 'llm%'"), 0)
        }
        let cats = Dictionary(uniqueKeysWithValues: try CategoryStore(old).rawCategories().map { ($0.id, $0) })
        XCTAssertEqual(cats.count, 13)
        XCTAssertEqual(cats["softwareDev"]?.name, "我的开发", "a name the user changed stays")
        XCTAssertEqual(cats["learning"]?.name, "学习")
        XCTAssertEqual(cats["learning"]?.productivity, 1, "a productivity the user changed stays")
        XCTAssertEqual(cats["business"]?.productivity, 0)
        XCTAssertEqual(cats["entertainment"]?.name, "视频娱乐")
        XCTAssertEqual(cats["jobSearch"]?.productivity, 2)
        XCTAssertEqual(cats["research"]?.productivity, 1)
        XCTAssertEqual(cats.values.filter(\.distracting).map(\.id).sorted(), ["communication", "entertainment", "news", "socialMedia"])
        XCTAssertTrue(cats.values.allSatisfy(\.isBuiltin))
        XCTAssertTrue(cats.values.filter { $0.id != "uncategorized" }.allSatisfy { !$0.description.isEmpty })
        XCTAssertFalse(cats["softwareDev"]!.description.contains("动画"))
    }

    func testFreshDatabaseHasTheSameCategories() throws {
        let cats = try store.rawCategories()
        XCTAssertEqual(cats.map(\.id), ["softwareDev", "jobSearch", "learning", "writing", "research", "business",
                                        "communication", "entertainment", "socialMedia", "news", "utilities", "misc", "uncategorized"])
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM jevVerdict") }, 0)
    }

    // MARK: - Category editing

    func testCategoryLimitMergeAndDelete() throws {
        let extra = try store.addCategory(name: "Mine", colorHex: "#123456", description: "x")
        XCTAssertFalse(extra.isBuiltin)
        for i in 0..<(CategoryStore.maxCategories - 13 + 1 - 1) { try store.addCategory(name: "c\(i)", colorHex: "#000000") }
        XCTAssertThrowsError(try store.addCategory(name: "one too many", colorHex: "#000000")) {
            XCTAssertEqual($0 as? CategoryStore.CategoryError, .limitReached)
        }
        try store.setUserDomain("mine.example", categoryID: extra.id)
        try store.setUserVerdict(VerdictKey(appBundleID: "a", domain: nil, title: "t", document: nil), categoryID: extra.id)
        settings.setFocusBlockedCategories([extra.id, "news"])
        try store.deleteCategory(extra.id, reassignTo: "research", settings: settings)
        XCTAssertEqual(try store.domainMap()["mine.example"]?.categoryID, "research")
        XCTAssertEqual(try store.verdicts().first?.categoryID, "research")
        XCTAssertEqual(settings.focusBlockedCategories, ["research", "news"])
        XCTAssertNil(try store.rawCategories().first { $0.id == extra.id })
        XCTAssertThrowsError(try store.mergeCategory("uncategorized", into: "misc"))
        XCTAssertThrowsError(try store.mergeCategory("news", into: "news"))
    }

    // MARK: - Hard rules

    func testResumeInATerminalMeansContinue() throws {
        XCTAssertNil(ghosttyJob())
        XCTAssertNil(JevRules.match(appBundleID: "com.google.Chrome", domain: nil, url: nil, title: "Claude Code - resume", document: nil))
        XCTAssertEqual(JevRules.match(appBundleID: "com.google.Chrome", domain: "docs.google.com", url: nil, title: "My Resume", document: nil)?.categoryID, "jobSearch")
        XCTAssertEqual(JevRules.match(appBundleID: "com.mitchellh.ghostty", domain: nil, url: nil, title: "cover letter draft", document: nil)?.categoryID, "jobSearch")
    }

    func testHardRuleSet() {
        func hit(_ app: String, domain: String? = nil, title: String? = nil, document: String? = nil) -> String? {
            JevRules.match(appBundleID: app, domain: domain, url: nil, title: title, document: document)?.categoryID
        }
        XCTAssertEqual(hit("x", title: "CL v3 final"), "jobSearch")
        XCTAssertNil(hit("x", title: "clean"))
        XCTAssertEqual(hit("x", domain: "linkedin.com"), "jobSearch")
        XCTAssertEqual(hit("x", domain: "boards.greenhouse.io"), "jobSearch")
        XCTAssertEqual(hit("x", title: "Internship offer"), "jobSearch")
        XCTAssertNil(hit("x", title: "RBC Interview"), "no company names in the rule")
        XCTAssertNil(JevRules.match(appBundleID: "x", domain: "linkedin.com", url: nil, title: nil, document: nil, job: false))
        XCTAssertEqual(hit("com.alllllenshi.TimeSink"), "softwareDev")
        XCTAssertEqual(hit("com.nousresearch.hermes"), "softwareDev")
        XCTAssertEqual(hit("x", title: "Malibu Workshop"), "softwareDev")
        XCTAssertEqual(hit("com.openai.codex", title: "Codex"), "softwareDev")
        XCTAssertNil(hit("com.openai.codex", title: "Refactor the parser"))
        XCTAssertNil(hit("com.openai.chat", title: "ChatGPT", document: "Some conversation"))
        XCTAssertEqual(hit("com.google.Chrome", title: "New Tab"), "utilities")
        XCTAssertNil(hit("com.google.Chrome", domain: "example.com", title: ""))
        XCTAssertEqual(hit("com.bjango.istatmenus"), "utilities")
        XCTAssertEqual(hit("com.google.Chrome", domain: "console.aws.amazon.com", title: "EC2"), "softwareDev")
        XCTAssertEqual(hit("com.google.Chrome", domain: "signin.aws.amazon.com", title: "Sign in"), "softwareDev")
    }

    // MARK: - Resolution order

    private func makeResolver(jev: Bool = true) -> CategoryResolver {
        let r = CategoryResolver(categoryStore: store)
        r.jevEnabled = jev
        return r
    }

    private func verdict(_ s: Span, _ category: String, prob: Double = 0.9, version: String = "v") throws {
        try store.saveVerdict(JevVerdict(appBundleID: s.appBundleID, domain: s.domain ?? "", title: s.title ?? "", document: s.document ?? "",
                                         categoryID: category, prob: prob, runnerUp: "misc", runnerUpProb: 0.05,
                                         promptVersion: version, at: Date(), source: "jev"))
    }

    func testJobRuleIsJevsAlone() throws {
        let item = try SpanStore(db).insert(span(domain: "linkedin.com", title: "My Resume", url: "https://linkedin.com/in/x"))
        XCTAssertEqual(makeResolver(jev: true).categoryID(for: item), "jobSearch")
        let off = makeResolver(jev: false)
        XCTAssertNotEqual(off.categoryID(for: item), "jobSearch")
        XCTAssertFalse(off.explanation(for: item).contains("求职"))
    }

    func testEachTierBeatsTheNext() throws {
        var item = span(domain: "github.com", title: "cover letter draft", url: "https://github.com/x")
        item = try SpanStore(db).insert(item)
        try verdict(item, "news")
        let resolver = makeResolver()

        // hard rule beats the verdict and the shipped github.com rule
        XCTAssertEqual(resolver.categoryID(for: item), "jobSearch")
        XCTAssertEqual(resolver.explanation(for: item), "内置求职规则 · cover letter")
        XCTAssertNil(resolver.matchingRuleKey(for: item))

        // a user rule beats the hard rule
        try store.setUserDomain("github.com", categoryID: "learning")
        resolver.refresh()
        XCTAssertEqual(resolver.categoryID(for: item), "learning")
        XCTAssertEqual(resolver.matchingRuleKey(for: item), "domain:github.com")

        // a user verdict beats a user rule
        try store.setUserVerdict(VerdictKey(item), categoryID: "writing")
        resolver.refresh()
        XCTAssertEqual(resolver.categoryID(for: item), "writing")

        // a segment override beats everything
        _ = try store.reclassify(span: item, scope: .segment, categoryID: "misc")
        resolver.refresh()
        XCTAssertEqual(resolver.categoryID(for: item), "misc")
    }

    func testVerdictBeatsShippedRulesAndFallbackWhenOff() throws {
        let page = try SpanStore(db).insert(span(domain: "github.com", title: "Docs", url: "https://github.com/x"))
        try verdict(page, "research", prob: 0.87)
        let on = makeResolver()
        XCTAssertEqual(on.categoryID(for: page), "research")
        XCTAssertEqual(on.explanation(for: page), "Jev 判断 · 概率 0.87")
        XCTAssertNil(on.matchingRuleKey(for: page))

        let off = makeResolver(jev: false)
        XCTAssertEqual(off.categoryID(for: page), "softwareDev", "the shipped rule is the fallback")
        XCTAssertNotEqual(off.matchingRuleKey(for: page), nil)

        let unknown = span(domain: "nowhere.example", title: "Hi", url: "https://nowhere.example")
        XCTAssertEqual(on.categoryID(for: unknown), "uncategorized")
    }

    func testResumeInGhosttyStaysSoftwareDev() throws {
        let item = span("com.mitchellh.ghostty", title: "resume the session", name: "Ghostty")
        XCTAssertEqual(makeResolver().categoryID(for: item), "softwareDev")
        let doc = span("com.google.Chrome", domain: "docs.google.com", title: "Resume 2026", url: "https://docs.google.com/d/1")
        XCTAssertEqual(makeResolver().categoryID(for: doc), "jobSearch")
    }

    func testAHardRuleForAMergedAwayCategoryFallsThrough() throws {
        let item = span("com.google.Chrome", domain: "nowhere.example", title: "Cover letter", url: "https://nowhere.example")
        let resolver = makeResolver()
        XCTAssertEqual(resolver.categoryID(for: item), "jobSearch")
        try store.mergeCategory("jobSearch", into: "misc", settings: settings)
        resolver.refresh()
        XCTAssertEqual(resolver.categoryID(for: item), "uncategorized")
    }

    // MARK: - Request

    func testRequestBodyShape() throws {
        let long = String(repeating: "a", count: 500)
        let state = JevState(app: "Chrome", bundleID: "com.google.Chrome", domain: "example.com", url: long, title: long, document: long)
        let criteria = JevPrompt.criteria(try store.rawCategories())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JevClient.body(state: state, criteria: criteria)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "typesafe/jev-1.13")
        let sent = try XCTUnwrap(json["state"] as? [String: String])
        XCTAssertEqual(Set(sent.keys), ["app", "bundle_id", "domain", "url", "window_title", "document"])
        XCTAssertEqual(sent["url"]?.count, 300)
        XCTAssertEqual(sent["window_title"]?.count, 300)
        XCTAssertEqual(sent["document"]?.count, 300)
        let q = try XCTUnwrap((json["questions"] as? [String: Any])?["category"] as? [String: Any])
        XCTAssertEqual(q["type"] as? String, "choice")
        XCTAssertEqual(q["instructions"] as? String, "这段电脑使用时间属于哪个活动类别？根据应用、网址、窗口标题判断。")
        let sentCriteria = try XCTUnwrap(q["criteria"] as? [String: String])
        XCTAssertEqual(sentCriteria.count, 12)
        XCTAssertNil(sentCriteria["uncategorized"])
        XCTAssertEqual(sentCriteria["jobSearch"], "求职 Coop：找 coop/实习/工作：浏览职位、投递、写简历和求职信、测评、面试准备")
        XCTAssertEqual(sentCriteria["misc"], "其他：以上都不像的；拿不准时也放这里")
        // keys keep the category order in the raw text
        let raw = String(decoding: JevClient.body(state: state, criteria: criteria), as: UTF8.self)
        XCTAssertLessThan(try XCTUnwrap(raw.range(of: "\"softwareDev\":")).lowerBound, try XCTUnwrap(raw.range(of: "\"misc\":")).lowerBound)
    }

    func testRequestHeadersAndParse() async throws {
        let transport = StubJevTransport { _ in ("misc", ["misc": 0.7, "news": 0.2], 0.0003) }
        let client = JevClient(endpoint: URL(string: "https://example.test/decisions")!, apiKey: "test-key", transport: transport)
        let answer = try await client.decide(JevState(app: "A", bundleID: "b", domain: "", url: "", title: "t", document: ""),
                                             criteria: JevPrompt.criteria(try store.rawCategories()))
        XCTAssertEqual(answer.choice, "misc")
        XCTAssertEqual(answer.inputTokens, 700)
        XCTAssertEqual(answer.cost, 0.0003, accuracy: 1e-9)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/decisions")
    }

    // MARK: - Worker

    private func worker(_ transport: StubJevTransport) -> JevWorker {
        settings.setJevEnabled(true)
        return JevWorker(categoryStore: store, settings: settings, transport: transport, apiKey: { "test-key" })
    }

    private func seedSpans(_ titles: [String]) throws {
        for (i, title) in titles.enumerated() {
            _ = try SpanStore(db).insert(span(domain: "site\(i).example", title: title, url: "https://site\(i).example/", seconds: Double(600 - i)))
        }
    }

    private var longAgo: Date { Date().addingTimeInterval(-86_400 * 30) }

    func testWorkerCachesVerdictsAndRequeuesWhenThePromptChanges() async throws {
        try seedSpans(["alpha", "beta"])
        let transport = StubJevTransport { _ in ("research", ["research": 0.8, "news": 0.1], 0.0002) }
        let w = worker(transport)
        let first = await w.run(since: longAgo)
        XCTAssertEqual(first.calls, 2)
        XCTAssertEqual(first.saved, 2)
        XCTAssertEqual(first.inputTokens, 1400)
        XCTAssertEqual(try store.verdicts().count, 2)
        XCTAssertEqual(try store.verdicts().first?.runnerUp, "news")
        XCTAssertEqual(settings.jevSpend(), 0.0004, accuracy: 1e-9)

        let second = await w.run(since: longAgo)
        XCTAssertEqual(second.calls, 0, "current verdicts are not asked again")

        // the category list changes: verdicts of the old prompt stay in use until replaced
        let before = try store.verdicts().map(\.promptVersion)
        var research = try XCTUnwrap(try store.rawCategories().first { $0.id == "research" })
        research.description = "新的描述"
        try store.updateCategory(research)
        let resolver = makeResolver()
        let probe = span(domain: "site0.example", title: "alpha", url: "https://site0.example/")
        XCTAssertEqual(resolver.categoryID(for: probe), "research")

        let third = await w.run(since: longAgo)
        XCTAssertEqual(third.calls, 2)
        XCTAssertNotEqual(try store.verdicts().map(\.promptVersion), before)
        XCTAssertEqual(Set(try store.verdicts().map(\.promptVersion)).count, 1)
    }

    func testPromptVersionIsStableAndSensitive() throws {
        let cats = try store.rawCategories()
        XCTAssertEqual(JevPrompt.version(cats), JevPrompt.version(cats))
        var changed = cats
        changed[0].name += "!"
        XCTAssertNotEqual(JevPrompt.version(cats), JevPrompt.version(changed))
        var onlyColor = cats
        onlyColor[0].colorHex = "#000000"
        XCTAssertEqual(JevPrompt.version(cats), JevPrompt.version(onlyColor))
    }

    func testMonthlyCapStopsTheWorker() async throws {
        try seedSpans(["a", "b", "c", "d", "e"])
        settings.setJevMonthlyCap(0.001)
        let transport = StubJevTransport { _ in ("misc", ["misc": 0.9], 0.0004) }
        let w = worker(transport)
        let run = await w.run(since: longAgo, maxConcurrent: 1)
        XCTAssertEqual(run.calls, 3)
        XCTAssertTrue(run.stoppedByCap)
        XCTAssertEqual(transport.requests.count, 3)

        let again = await w.run(since: longAgo, maxConcurrent: 1)
        XCTAssertEqual(again.calls, 0)
        XCTAssertTrue(again.stoppedByCap)
    }

    func testRateLimitHaltsLaunchesKeepsComboQueuedAndHalvesConcurrency() async throws {
        try seedSpans(["a", "b", "c", "d", "e", "f"])
        let transport = StubJevTransport { _ in ("misc", ["misc": 0.9], 0.0004) }
        transport.limit = { $0["window_title"] == "c" }
        transport.retryAfter = "45"
        let w = worker(transport)
        let first = await w.run(since: longAgo, maxConcurrent: 1)
        XCTAssertEqual(first.retryAfter, 45)
        XCTAssertEqual(first.calls, 3, "no new launches after the 429")
        XCTAssertEqual(first.saved, 2)
        XCTAssertEqual(first.failed, 0)
        XCTAssertEqual(try store.verdicts().count, 2)
        XCTAssertEqual(settings.jevSpend(), 0.0008, accuracy: 1e-9, "no spend for the limited request")
        XCTAssertEqual(try store.pendingCombos(since: longAgo, staleSince: nil, promptVersion: JevPrompt.version(try store.rawCategories())).count, 4)

        // concurrency: 10 -> 5 after a 429, and back to 10 after a clean pass
        let second = await w.run(since: longAgo, maxConcurrent: 10)
        XCTAssertEqual(second.concurrency, 5)
        XCTAssertEqual(second.retryAfter, 45, "still limited")
        transport.limit = nil
        let third = await w.run(since: longAgo, maxConcurrent: 10)
        XCTAssertEqual(third.concurrency, 5)
        XCTAssertNil(third.retryAfter)
        XCTAssertEqual(third.saved, 1, "only the limited combo was left; the others finished in flight last time")
        let fourth = await w.run(since: longAgo, maxConcurrent: 10)
        XCTAssertEqual(fourth.concurrency, 10)
        let small = await w.run(since: longAgo, maxConcurrent: 3)
        XCTAssertEqual(small.concurrency, 3)
    }

    func testRetryAfterDefaultsAndCaps() async throws {
        for (header, want) in [(nil, 30), ("abc", 30), ("Wed, 21 Oct 2026 07:28:00 GMT", 30), ("9999", 300), ("0", 1), (" 12 ", 12)] as [(String?, Int)] {
            let transport = StubJevTransport { _ in ("misc", ["misc": 0.9], 0) }
            transport.limit = { _ in true }
            transport.retryAfter = header
            let client = JevClient(endpoint: URL(string: "https://x.test")!, apiKey: "k", transport: transport)
            let state = JevState(app: "a", bundleID: "b", domain: "", url: "", title: "t", document: "")
            do { _ = try await client.decide(state, criteria: [("misc", "m")]); XCTFail() } catch {
                XCTAssertEqual(error as? JevError, .rateLimited(retryAfter: want), "header \(header ?? "nil")")
            }
        }
    }

    func testWorkerSkipsWhatHardRulesDecideAndUserVerdicts() async throws {
        try seedSpans(["alpha"])
        _ = try SpanStore(db).insert(span("com.alllllenshi.TimeSink", title: "TimeSink"))
        let mine = try SpanStore(db).insert(span(domain: "mine.example", title: "mine"))
        try store.setUserVerdict(VerdictKey(mine), categoryID: "writing")
        let transport = StubJevTransport { _ in ("misc", ["misc": 0.9], 0) }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.calls, 1)
        XCTAssertEqual(try store.verdicts().first { $0.title == "mine" }?.source, "user")
    }

    func testWorkerOffOrKeylessDoesNothing() async throws {
        try seedSpans(["alpha"])
        let transport = StubJevTransport { _ in ("misc", ["misc": 0.9], 0) }
        let off = JevWorker(categoryStore: store, settings: settings, transport: transport, apiKey: { "k" })
        let r1 = await off.run(since: longAgo)
        XCTAssertEqual(r1.calls, 0)
        settings.setJevEnabled(true)
        let keyless = JevWorker(categoryStore: store, settings: settings, transport: transport, apiKey: { nil })
        let r2 = await keyless.run(since: longAgo)
        XCTAssertEqual(r2.calls, 0)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAnUnofferedChoiceIsNotStored() async throws {
        try seedSpans(["alpha"])
        let transport = StubJevTransport { _ in ("uncategorized", ["uncategorized": 0.9], 0) }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.failed, 1)
        XCTAssertTrue(try store.verdicts().isEmpty)
    }

    // MARK: - Review

    func testLowConfidenceListAndUserVerdictWins() throws {
        let a = try SpanStore(db).insert(span(domain: "a.example", title: "A", seconds: 1800))
        let b = try SpanStore(db).insert(span(domain: "b.example", title: "B", seconds: 600))
        let c = try SpanStore(db).insert(span(domain: "c.example", title: "C", seconds: 600))
        try verdict(a, "news", prob: 0.4)
        try verdict(b, "news", prob: 0.55)
        try verdict(c, "news", prob: 0.95)
        let range = DateInterval(start: Date().addingTimeInterval(-86_400), end: Date())
        let low = try store.lowConfidenceVerdicts(in: range)
        XCTAssertEqual(low.map(\.key.title), ["A", "B"])
        XCTAssertEqual(low[0].seconds, 1800, accuracy: 1)
        XCTAssertEqual(low[0].runnerUp, "misc")

        let resolver = makeResolver()
        XCTAssertEqual(resolver.categoryID(for: a), "news")
        try store.setUserVerdict(VerdictKey(a), categoryID: "learning")
        resolver.refresh()
        XCTAssertEqual(resolver.categoryID(for: a), "learning")
        XCTAssertEqual(try store.lowConfidenceVerdicts(in: range).map(\.key.title), ["B"])
        // Jev does not overwrite it
        try verdict(a, "news", prob: 0.99)
        XCTAssertEqual(try store.verdicts().first { $0.title == "A" }?.categoryID, "learning")
    }

    func testServiceSetVerdictCanSaveARule() throws {
        let resolver = makeResolver()
        let service = JevService(categoryStore: store, settings: settings, resolver: resolver, apiKey: { nil })
        let key = VerdictKey(appBundleID: "com.google.Chrome", domain: "x.example", title: "T", document: nil)
        try service.setVerdict(key, categoryID: "learning", rule: .domain)
        XCTAssertEqual(try store.domainMap()["x.example"], DomainEntry(categoryID: "learning", source: "user"))
        XCTAssertEqual(try store.verdicts().first?.source, "user")
    }

    func testStatusCountsThisMonthsVerdictsAndUnsureOnes() throws {
        let service = JevService(categoryStore: store, settings: settings, resolver: makeResolver(), apiKey: { nil })
        let sure = try SpanStore(db).insert(span(title: "a")), unsure = try SpanStore(db).insert(span(title: "b"))
        try verdict(sure, "learning", prob: 0.9)
        try verdict(unsure, "learning", prob: 0.3)
        let status = try service.status()
        XCTAssertEqual(status.verdictsThisMonth, 2)
        XCTAssertEqual(status.toConfirm, 1)
        XCTAssertNil(status.lastRunAt)
    }

    func testJevIsOffByDefaultAndSendsOnlyTheListedFields() {
        XCTAssertFalse(settings.jevEnabled)
        XCTAssertEqual(settings.jevEndpoint, "https://openrouter.ai/api/alpha/decisions")
        XCTAssertEqual(JevService.sentFields.count, 7)
    }
}
