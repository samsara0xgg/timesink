import GRDB
import XCTest
@testable import TimeSinkKit

@MainActor
final class JevExamplesTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: CategoryStore!
    private var settings: SettingsStore!
    private var longAgo: Date { Date().addingTimeInterval(-86_400 * 30) }

    override func setUpWithError() throws {
        db = try AppDatabase.openInMemory()
        store = CategoryStore(db)
        settings = SettingsStore(db)
    }

    private func insert(_ app: String = "com.google.Chrome", domain: String? = nil, title: String? = nil, ago: Double = 3600) throws -> Span {
        let start = Date().addingTimeInterval(-ago)
        return try SpanStore(db).insert(Span(start: start, end: start.addingTimeInterval(600), appBundleID: app, appName: "App",
                                             title: title, url: nil, domain: domain, document: nil))
    }

    private func worker(_ transport: StubJevTransport, screenText: Bool = false) -> JevWorker {
        settings.setJevEnabled(true)
        settings.setJevScreenText(screenText)
        return JevWorker(categoryStore: store, settings: settings, transport: transport, apiKey: { "k" })
    }

    private func bodies(_ t: StubJevTransport) throws -> [[String: Any]] {
        try t.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any]) }
    }

    private func seed(_ app: String, title: String, category: String, at: String = "2026-01-01 00:00:00.000") throws {
        try db.write { try $0.execute(sql: """
            INSERT INTO jevVerdict (appBundleID, domain, title, document, categoryID, prob, runnerUp, runnerUpProb, promptVersion, at, source, screenText)
            VALUES (?, '', ?, '', ?, 1, '', 0, '', ?, 'seed', 0)
            """, arguments: [app, title, category, at]) }
    }

    private func example(_ i: Int, bundle: String, domain: String = "") -> JevExample {
        JevExample(bundleID: bundle, app: bundle, domain: domain, title: "t\(i)", document: "", category: "c")
    }

    func testSelectionPutsSameAppFirstUpToEightThenFillsToTwenty() {
        let all = (0..<10).map { example($0, bundle: "a") } + (10..<40).map { example($0, bundle: "b") }
        let picked = JevExample.select(from: all, bundleID: "a", domain: "")
        XCTAssertEqual(picked.count, 20)
        XCTAssertEqual(picked.prefix(8).map(\.title), (0..<8).map { "t\($0)" })
        XCTAssertEqual(picked.dropFirst(8).map(\.title), ["t8", "t9"] + (10..<20).map { "t\($0)" }, "the rest keep the given order")

        let withDomain = [example(1, bundle: "a", domain: "x.com"), example(2, bundle: "a", domain: "y.com")]
        XCTAssertEqual(JevExample.select(from: withDomain + [example(3, bundle: "b")], bundleID: "a", domain: "y.com").map(\.title), ["t2", "t1", "t3"])
        XCTAssertEqual(JevExample.select(from: [], bundleID: "a", domain: "").count, 0)
    }

    func testExamplesComeFromUserVerdictsSeedRowsAndUserRules() throws {
        let research = try XCTUnwrap(try store.rawCategories().first { $0.id == "research" }).name
        try store.setUserVerdict(VerdictKey(appBundleID: "app.u", domain: nil, title: "mine", document: nil), categoryID: "research")
        try seed("app.s", title: "seeded", category: "research")
        try store.setUserDomain("rule.example", categoryID: "research")
        try store.setUserApp("app.rule", categoryID: "research")
        let all = try store.jevExamples()
        XCTAssertEqual(all.map(\.title).prefix(2), ["mine", "seeded"], "verdicts first, most recent first")
        XCTAssertTrue(all.contains { $0.domain == "rule.example" && $0.category == research })
        XCTAssertTrue(all.contains { $0.bundleID == "app.rule" && $0.category == research })
    }

    func testSeedRowsAreNeverVerdicts() async throws {
        let s = try insert("app.s", title: "seeded")
        try seed("app.s", title: "seeded", category: "research")
        let r = CategoryResolver(categoryStore: store)
        r.jevEnabled = true
        XCTAssertNotEqual(r.categoryID(for: s), "research")

        let transport = StubJevTransport { _ in ("news", ["news": 0.2], 0.0001) }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.calls, 0, "a seed row settles the combo: nothing to ask, nothing overwritten")
        XCTAssertEqual(try store.verdicts().map(\.source), ["seed"])
        XCTAssertEqual(try store.verdicts().first?.categoryID, "research")
        let range = DateInterval(start: longAgo, end: Date())
        XCTAssertTrue(try store.lowConfidenceVerdicts(in: range).isEmpty)
        try store.saveVerdict(JevVerdict(appBundleID: "app.s", domain: "", title: "seeded", document: "", categoryID: "news", prob: 0.1,
                                         runnerUp: "", runnerUpProb: 0, promptVersion: "x", at: Date(), source: "jev"))
        XCTAssertEqual(try store.verdicts().first?.categoryID, "research")
    }

    func testReaskCarriesExamplesEvenWithTheSwitchOff() async throws {
        let research = try XCTUnwrap(try store.rawCategories().first { $0.id == "research" }).name
        try seed("app.s", title: "seeded", category: "research")
        _ = try insert("app.low", title: "unsure")
        let transport = StubJevTransport { state in
            state["window_title"] == "unsure" && state["examples"] == nil ? ("news", ["news": 0.4], 0.0001) : ("news", ["news": 0.8], 0.0001)
        }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.calls, 2, "first ask, then the re-ask")
        let sent = try bodies(transport)
        let first = try XCTUnwrap(sent[0]["state"] as? [String: Any])
        XCTAssertNil(first["用户以前确认过的例子"], "first asks are plain")
        let second = try XCTUnwrap(sent[1]["state"] as? [String: Any])
        XCTAssertNil(second["screen_text"])
        let list = try XCTUnwrap(second["用户以前确认过的例子"] as? [[String: String]])
        XCTAssertEqual(list, [["app": "app.s", "domain": "", "title": "seeded", "document": "", "用户定的分类": research]])
        let q = try XCTUnwrap((sent[1]["questions"] as? [String: Any])?["category"] as? [String: Any])
        XCTAssertEqual(q["instructions"] as? String, JevPrompt.instructions + "用户以前确认过的例子代表他的分类习惯，类似的内容按同样方式分。")
        XCTAssertEqual(try store.verdicts().first { $0.title == "unsure" }?.prob ?? 0, 0.8, accuracy: 1e-9, "the higher re-ask is kept")
        let again = await worker(transport).run(since: longAgo)
        XCTAssertEqual(again.calls, 0)
    }

    func testNoExamplesMeansNoFieldAndNoPointlessReask() async throws {
        _ = try insert("app.low", title: "unsure")
        let transport = StubJevTransport { _ in ("news", ["news": 0.4], 0.0001) }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.calls, 1)
        XCTAssertFalse(String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self).contains("用户以前确认过的例子"))
    }

    func testBodyHasScreenTextAndExamplesTogether() throws {
        let criteria = JevPrompt.criteria(try store.rawCategories())
        let ex = JevExample(bundleID: "b", app: "A", domain: "d.com", title: String(repeating: "t", count: 100), document: String(repeating: "d", count: 100), category: "研究")
        let state = JevState(app: "A", bundleID: "b", domain: "", url: "", title: "t", document: "", screenText: "hello", examples: [ex])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JevClient.body(state: state, criteria: criteria)) as? [String: Any])
        let st = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertEqual(st["screen_text"] as? String, "hello")
        let item = try XCTUnwrap((st["用户以前确认过的例子"] as? [[String: String]])?.first)
        XCTAssertEqual(item["title"]?.count, 80)
        XCTAssertEqual(item["document"]?.count, 60)
        XCTAssertEqual(item["用户定的分类"], "研究")
        let q = try XCTUnwrap((json["questions"] as? [String: Any])?["category"] as? [String: Any])
        XCTAssertEqual(q["instructions"] as? String, JevPrompt.instructionsWithScreenText + JevPrompt.examplesNote)
    }
}
