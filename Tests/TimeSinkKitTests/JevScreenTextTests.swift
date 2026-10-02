import GRDB
import XCTest
@testable import TimeSinkKit

@MainActor
final class JevScreenTextTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: CategoryStore!
    private var settings: SettingsStore!
    private var longAgo: Date { Date().addingTimeInterval(-86_400 * 30) }

    override func setUpWithError() throws {
        db = try AppDatabase.openInMemory()
        store = CategoryStore(db)
        settings = SettingsStore(db)
    }

    private func insert(_ app: String = "com.google.Chrome", domain: String? = nil, title: String? = nil, document: String? = nil,
                        ago: Double = 3600, seconds: Double = 600) throws -> Span {
        let start = Date().addingTimeInterval(-ago)
        return try SpanStore(db).insert(Span(start: start, end: start.addingTimeInterval(seconds), appBundleID: app, appName: "App",
                                             title: title, url: nil, domain: domain, document: document))
    }

    @discardableResult
    private func capture(_ span: Span, _ text: String, ago: Double = 1800) throws -> Capture {
        try db.write { d in
            var c = Capture(at: Date().addingTimeInterval(-ago), lastSeenAt: Date().addingTimeInterval(-ago), appBundleID: span.appBundleID,
                            appName: "App", windowID: 1, title: span.title, spanID: span.id, text: text, imagePath: nil)
            try c.insert(d)
            return c
        }
    }

    private func worker(_ transport: StubJevTransport, screenText: Bool) -> JevWorker {
        settings.setJevEnabled(true)
        settings.setJevScreenText(screenText)
        return JevWorker(categoryStore: store, settings: settings, transport: transport, apiKey: { "k" })
    }

    private func resolver(screenText: Bool = true) -> CategoryResolver {
        let r = CategoryResolver(categoryStore: store)
        r.jevEnabled = true
        r.jevScreenText = screenText
        return r
    }

    private func captureVerdictCount() throws -> Int? {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM jevCaptureVerdict") }
    }

    private func sentBodies(_ t: StubJevTransport) -> [String] { t.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }

    // MARK: - Redaction

    func testRedactionStripsEmailsAndLongDigitRunsAndTruncates() {
        XCTAssertEqual(JevPrompt.redact("mail me at a.b+c@mail.example.com now"), "mail me at  now")
        XCTAssertEqual(JevPrompt.redact("card 4111 1111 1111 1111 ok"), "card  ok")
        XCTAssertEqual(JevPrompt.redact("sin 123-456-789 and 12-34-56"), "sin  and ")
        XCTAssertEqual(JevPrompt.redact("code 12345 stays, 123456 goes"), "code 12345 stays,  goes")
        XCTAssertEqual(JevPrompt.redact(String(repeating: "a", count: 2000)).count, 1200)
        XCTAssertFalse(JevPrompt.redact(String(repeating: "x", count: 1190) + " 1234567 tail").contains("1234567"))
    }

    func testBodyCarriesRedactedScreenTextAndTheLongerInstruction() throws {
        let criteria = JevPrompt.criteria(try store.rawCategories())
        var state = JevState(app: "A", bundleID: "b", domain: "", url: "", title: "t", document: "")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JevClient.body(state: state, criteria: criteria)) as? [String: Any])
        XCTAssertNil((plain["state"] as? [String: String])?["screen_text"])

        state.screenText = "hello bob@example.com 99887766 world"
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JevClient.body(state: state, criteria: criteria)) as? [String: Any])
        XCTAssertEqual((json["state"] as? [String: String])?["screen_text"], "hello   world")
        let q = try XCTUnwrap((json["questions"] as? [String: Any])?["category"] as? [String: Any])
        XCTAssertEqual(q["instructions"] as? String, "这段电脑使用时间属于哪个活动类别？根据应用、网址、窗口标题和屏幕上的文字判断。")
    }

    // MARK: - Switch off

    func testSwitchOffSendsNoScreenText() async throws {
        let s = try insert(domain: "a.example", title: "A")
        try capture(s, String(repeating: "visible text ", count: 10))
        let bare = try insert("com.openai.codex", title: "Codex")
        try capture(bare, String(repeating: "chat screen ", count: 10))
        let transport = StubJevTransport { _ in ("misc", ["misc": 0.3, "news": 0.2], 0.0001) }
        let run = await worker(transport, screenText: false).run(since: longAgo)
        XCTAssertEqual(run.calls, 1)
        XCTAssertTrue(sentBodies(transport).allSatisfy { !$0.contains("screen_text") })
        XCTAssertEqual(try captureVerdictCount(), 0)
        XCTAssertEqual(resolver(screenText: false).categoryID(for: bare), "softwareDev")
    }

    // MARK: - Low-confidence re-ask

    func testReaskKeepsTheHigherProbabilityOnce() async throws {
        let a = try insert(domain: "a.example", title: "A")
        let b = try insert(domain: "b.example", title: "B")
        let short = try insert(domain: "c.example", title: "C")
        try capture(a, String(repeating: "alpha screen text ", count: 5))
        try capture(b, String(repeating: "beta screen text ", count: 5))
        try capture(short, "too short")
        let transport = StubJevTransport { state in
            let text = state["screen_text"] ?? ""
            if text.contains("alpha") { return ("research", ["research": 0.9, "news": 0.05], 0.0001) }
            if text.contains("beta") { return ("learning", ["learning": 0.3, "news": 0.25], 0.0001) }
            return ("news", ["news": 0.4, "misc": 0.3], 0.0001)
        }
        let w = worker(transport, screenText: true)
        let run = await w.run(since: longAgo)
        XCTAssertEqual(run.calls, 5, "3 first asks, then 2 re-asks (the short capture has no usable text)")
        let v = Dictionary(uniqueKeysWithValues: try store.verdicts().map { ($0.title, $0) })
        XCTAssertEqual(v["A"]?.categoryID, "research")
        XCTAssertEqual(v["A"]?.prob ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(v["A"]?.screenText, 1)
        XCTAssertEqual(v["B"]?.categoryID, "news", "first answer kept: the re-ask was lower")
        XCTAssertEqual(v["B"]?.screenText, 2)
        XCTAssertEqual(v["C"]?.screenText, 0)

        let again = await w.run(since: longAgo)
        XCTAssertEqual(again.calls, 0, "asked once")
        let r = resolver()
        XCTAssertEqual(r.categoryID(for: a), "research")
        XCTAssertEqual(r.explanation(for: a), "Jev 判断（含截图文字）· 概率 0.90")
        XCTAssertEqual(r.explanation(for: b), "Jev 判断 · 概率 0.40")
    }

    // MARK: - Per-capture verdicts

    func testBareAIAppScreensAreClassifiedPerCapture() async throws {
        let a1 = try insert("com.openai.codex", title: "Codex", ago: 7200)
        let a2 = try insert("com.openai.codex", title: "Codex", ago: 5400)
        let a3 = try insert("com.anthropic.claudefordesktop", title: "Claude", ago: 3600)
        let none = try insert("com.openai.chat", title: "ChatGPT", ago: 1800)
        let prefix = String(repeating: "p", count: 200)
        try capture(a1, prefix + " fix the swift build", ago: 7000)   // same first 200 chars as the next one
        try capture(a2, prefix + " different tail", ago: 5000)
        try capture(a3, "cover letter for the role at Acme, tailored to the posting", ago: 3500)
        let transport = StubJevTransport { state in
            (state["screen_text"] ?? "").contains("cover letter") ? ("jobSearch", ["jobSearch": 0.9, "writing": 0.05], 0.0001)
                                                                  : ("research", ["research": 0.8, "softwareDev": 0.1], 0.0001)
        }
        let w = worker(transport, screenText: true)
        let run = await w.run(since: longAgo)
        XCTAssertEqual(run.calls, 2, "two distinct 200-char keys")
        XCTAssertEqual(try captureVerdictCount(), 2)
        let again = await w.run(since: longAgo)
        XCTAssertEqual(again.calls, 0)

        let r = resolver()
        XCTAssertEqual(r.categoryID(for: a1), "research")
        XCTAssertEqual(r.categoryID(for: a2), "research")
        XCTAssertEqual(r.categoryID(for: a3), "jobSearch")
        XCTAssertEqual(r.categoryID(for: none), "softwareDev", "no capture: the hard rule")
        XCTAssertEqual(r.explanation(for: a3), "Jev 判断（含截图文字）· 概率 0.90")
        XCTAssertEqual(r.explanation(for: none), "内置规则 · 没有打开的对话")
        XCTAssertEqual(resolver(screenText: false).categoryID(for: a3), "softwareDev")
    }

    func testASpanWithSeveralCapturesTakesTheLatestVerdict() async throws {
        let s = try insert("com.openai.codex", title: "Codex")
        try capture(s, "old screen about swift and some more words to pass the floor", ago: 3000)
        try capture(s, "newer screen about cover letter with enough words to pass", ago: 2000)
        let transport = StubJevTransport { state in
            (state["screen_text"] ?? "").contains("cover letter") ? ("jobSearch", ["jobSearch": 0.9], 0) : ("research", ["research": 0.9], 0)
        }
        _ = await worker(transport, screenText: true).run(since: longAgo)
        XCTAssertEqual(resolver().categoryID(for: s), "jobSearch")
    }

    func testScreenVerdictBeatsAUserAppRuleAndShortTextIsNotAsked() async throws {
        try store.setUserApp("com.openai.codex", categoryID: "softwareDev")
        let s = try insert("com.openai.codex", title: "Codex")
        let short = try insert("com.openai.codex", title: "Codex")
        let bare = try insert("com.openai.codex", title: "Codex")
        try capture(s, "a long enough screen about the portfolio design mockup")
        try capture(short, "short text")
        let transport = StubJevTransport { _ in ("writing", ["writing": 0.9], 0) }
        _ = await worker(transport, screenText: true).run(since: longAgo)
        XCTAssertEqual(transport.requests.count, 1, "text of 40 characters or fewer is not sent")
        let r = resolver()
        XCTAssertEqual(r.categoryID(for: bare), "softwareDev")
        XCTAssertEqual(r.categoryID(for: short), "softwareDev")
        XCTAssertEqual(r.matchingRuleKey(for: short), "app:com.openai.codex")
        XCTAssertEqual(r.matchingRuleKey(for: s), nil)
        XCTAssertEqual(r.explanation(for: short), "你的应用分类 · App")
        XCTAssertTrue(r.explanation(for: s).hasPrefix("Jev 判断（含截图文字）"))
        XCTAssertEqual(r.categoryID(for: s), "writing")
        XCTAssertEqual(resolver(screenText: false).categoryID(for: s), "softwareDev")
    }

    // MARK: - Rule order

    func testJobKeywordsBeatAUserAppRuleButNotAUserDomainRule() throws {
        try store.setUserApp("com.openai.codex", categoryID: "softwareDev")
        let r0 = resolver()
        let plain = try insert("com.openai.codex", title: "Refactor the parser")
        XCTAssertEqual(r0.categoryID(for: plain), "softwareDev", "the user's app rule still decides ordinary windows")
        let job = try insert("com.openai.codex", title: "Cover letter for Acme", document: "resume v3")
        XCTAssertEqual(r0.categoryID(for: job), "jobSearch")
        XCTAssertEqual(r0.explanation(for: job), "内置求职规则 · Cover letter")
        XCTAssertNil(r0.matchingRuleKey(for: job))

        let site = try insert(domain: "linkedin.com", title: "Jobs")
        try store.setUserDomain("linkedin.com", categoryID: "learning")
        r0.refresh()
        XCTAssertEqual(r0.categoryID(for: site), "learning")
        try store.setUserVerdict(VerdictKey(job), categoryID: "writing")
        r0.refresh()
        XCTAssertEqual(r0.categoryID(for: job), "writing", "a per-content user verdict still wins")
    }

    func testLocalhostAndVercelAreSoftwareDev() throws {
        let r = resolver()
        for domain in ["localhost", "127.0.0.1", "myapp.vercel.app", "vercel.app"] {
            XCTAssertEqual(r.categoryID(for: try insert(domain: domain, title: "x")), "softwareDev", domain)
        }
        XCTAssertNotEqual(r.categoryID(for: try insert(domain: "vercel.app.evil.example", title: "x")), "softwareDev")
        XCTAssertEqual(r.categoryID(for: try insert(domain: "console.aws.amazon.com", title: "x")), "softwareDev")
    }
}
