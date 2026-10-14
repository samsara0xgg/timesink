import GRDB
import XCTest
@testable import TimeSinkKit

/// Replies from a closure over the raw request: any status and body, or a thrown error. Counts requests.
final class JevFixesTransport: JevTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let reply: @Sendable (URLRequest) throws -> (data: Data, status: Int)

    init(_ reply: @escaping @Sendable (URLRequest) throws -> (data: Data, status: Int)) {
        self.reply = reply
    }

    var calls: Int { lock.withLock { count } }

    func post(_ request: URLRequest) async throws -> (data: Data, status: Int, retryAfter: String?) {
        lock.withLock { () -> Void in count += 1 }
        let r = try reply(request)
        return (r.data, r.status, nil)
    }

    /// A category answer as the service sends it.
    static func answer(_ choice: String, cost: Double = 0.0002) -> Data {
        let json: [String: Any] = [
            "answers": ["category": ["choice": choice, "probabilities": [choice: 0.9], "confidence": 0.9]],
            "usage": ["input_tokens": 10, "cost": cost],
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
}

@MainActor
final class JevFixesTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: CategoryStore!
    private var settings: SettingsStore!
    private var longAgo: Date { Date().addingTimeInterval(-86_400 * 30) }

    override func setUpWithError() throws {
        db = try AppDatabase.openInMemory()
        store = CategoryStore(db)
        settings = SettingsStore(db)
    }

    @discardableResult
    private func span(_ app: String = "com.google.Chrome", domain: String? = nil, title: String, url: String? = nil,
                      ago: Double = 3600, seconds: Double = 600) throws -> Span {
        let start = Date().addingTimeInterval(-ago)
        return try SpanStore(db).insert(Span(start: start, end: start.addingTimeInterval(seconds), appBundleID: app, appName: "App",
                                             title: title, url: url, domain: domain, document: nil))
    }

    private func capture(_ span: Span, _ text: String, ago: Double = 1800) throws {
        try db.write { d in
            var c = Capture(at: Date().addingTimeInterval(-ago), lastSeenAt: Date().addingTimeInterval(-ago), appBundleID: span.appBundleID,
                            appName: "App", windowID: 1, title: span.title, spanID: span.id, text: text, imagePath: nil)
            try c.insert(d)
        }
    }

    private func worker(_ transport: any JevTransport) -> JevWorker {
        settings.setJevEnabled(true)
        return JevWorker(categoryStore: store, settings: settings, transport: transport, apiKey: { "k" })
    }

    private func key(_ domain: String, _ title: String) -> VerdictKey {
        VerdictKey(appBundleID: "com.google.Chrome", domain: domain, title: title, document: nil)
    }

    // MARK: - Built-in job rule

    private func job(_ domain: String?, url: String? = nil, title: String? = nil, app: String = "com.google.Chrome") -> String? {
        JevRules.job(appBundleID: app, domain: domain, url: url, title: title, document: nil)?.categoryID
    }

    func testJobRuleNoLongerMatchesOrdinarySites() {
        XCTAssertNil(job("jd.com", url: "https://www.jd.com/", title: "京东(JD.COM)-正品低价"), "a shop")
        XCTAssertNil(job("example.com", title: "JD Sports sale"))
        XCTAssertNil(job("clever.com", url: "https://clever.com/oauth/sis/login", title: "Clever | Log in"))
        XCTAssertNil(job("example.com", title: "The Scoop: daily news"))
        XCTAssertNil(job("example.com", title: "Co-op grocery hours"))
        XCTAssertNil(job("youtube.com", url: "https://www.youtube.com/watch?v=x&resume=1", title: "Video"), "the query string is never read")
        XCTAssertNil(job("example.com", url: "https://example.com/search?q=internship+resume", title: "Search"))
        XCTAssertNil(job("linkedin.com", url: "https://www.linkedin.com/feed/", title: "Feed | LinkedIn"), "the feed is not job hunting")
        XCTAssertNil(job("hire.lever.co", url: "https://hire.lever.co/candidates", title: "Candidates"), "the recruiter's console")
        XCTAssertNil(job("acme.bamboohr.com", url: "https://acme.bamboohr.com/home", title: "Home"), "an employee's own HR pages")
        XCTAssertNil(job(nil, title: "Resumed upload"), "resume only as a word")
    }

    func testJobRuleStillFindsJobHunting() {
        XCTAssertEqual(job("jobs.lever.co", url: "https://jobs.lever.co/acme/123"), "jobSearch")
        XCTAssertEqual(job("linkedin.com", url: "https://www.linkedin.com/jobs/view/123/"), "jobSearch")
        XCTAssertEqual(job("acme.wd5.myworkdayjobs.com"), "jobSearch")
        XCTAssertEqual(job("acme.bamboohr.com", url: "https://acme.bamboohr.com/careers/12"), "jobSearch")
        XCTAssertEqual(job(nil, title: "My R\u{E9}sum\u{E9}.pdf"), "jobSearch")
        XCTAssertEqual(job(nil, title: "Resume - Google Docs"), "jobSearch")
        XCTAssertEqual(job(nil, title: "简历 v3"), "jobSearch")
        XCTAssertNil(job(nil, title: "resume the session", app: "com.mitchellh.ghostty"), "in a terminal it means continue")
    }

    func testTheUsersOwnRulesOutrankTheJobRule() {
        let mine = ClassificationContext(domainMap: [:], appMap: ["com.apple.TextEdit": DomainEntry(categoryID: "writing", source: "user")],
                                         urlRules: [], jevEnabled: true)
        let shipped = ClassificationContext(domainMap: [:], appMap: ["com.apple.TextEdit": DomainEntry(categoryID: "writing", source: "builtin")],
                                            urlRules: [], jevEnabled: true)
        func category(_ context: ClassificationContext) -> String {
            Classifier.categoryID(appBundleID: "com.apple.TextEdit", url: nil, domain: nil, title: "Cover letter draft", context: context)
        }
        XCTAssertEqual(category(mine), "writing")
        XCTAssertEqual(category(shipped), "jobSearch", "a shipped app mapping does not")
        XCTAssertEqual(Classifier.userRuleCategory(appBundleID: "com.apple.TextEdit", url: nil, domain: nil, title: "x", context: mine), "writing")
        XCTAssertNil(Classifier.userRuleCategory(appBundleID: "com.apple.TextEdit", url: nil, domain: nil, title: "x", context: shipped))
    }

    // MARK: - What is sent

    func testRedactionCatchesTokensPhonesAndCards() {
        let cases: [(String, String)] = [
            ("key sk-or-v1-0123456789abcdef0123456789abcdef end", "key  end"),
            ("tok ghp_ABCDEFGHIJKLMNOPQRSTuvwxyz0123 end", "tok  end"),
            ("tok gho_ABCDEFGHIJKLMNOPQRSTuvwxyz0123 end", "tok  end"),
            ("pat github_pat_11ABCDEFG0123456789_abcdefXYZ end", "pat  end"),
            ("aws AKIAIOSFODNN7EXAMPLE end", "aws  end"),
            ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c end", "jwt  end"),
            ("sha 3f786850e387550fdab836ed7e6dc881de23001b end", "sha  end"),
            ("blob aGVsbG8gd29ybGQgdGhpcyBpcyBhIHRlc3Q0MjQy end", "blob  end"),
            ("call +1 415.555.0132 now", "call  now"),
            ("call +1 (415) 555-0132 now", "call  now"),
            ("card 4111.1111.1111.1111 ok", "card  ok"),
        ]
        for (input, want) in cases { XCTAssertEqual(JevPrompt.redact(input), want, input) }
        for kept in ["Q3-2026-Board-Meeting-Notes-Final-v2.docx", "file:///Users/Allen/Projects/TimeSink2026/Sources/Main.swift",
                     "Xcode 16.0.1", "Episode 12 of 20", "decaffeinated"] {
            XCTAssertEqual(JevPrompt.redact(kept), kept, "not a secret: \(kept)")
        }
    }

    func testURLsLoseQueryAndFragmentAndEveryFieldIsRedacted() throws {
        XCTAssertEqual(JevPrompt.strippedURL("https://example.com/reset/confirm?token=abc123&code=9#top"), "https://example.com/reset/confirm")
        XCTAssertEqual(JevPrompt.strippedURL("https://me:secret@example.com:8443/a/b?x=1"), "https://example.com:8443/a/b")
        XCTAssertEqual(JevPrompt.strippedURL("chrome://newtab/"), "chrome://newtab/")
        XCTAssertEqual(JevPrompt.strippedURL("not a url?with=query"), "not a url")

        let state = JevState(app: "Chrome", bundleID: "com.google.Chrome", domain: "mail.example.com",
                             url: "https://mail.example.com/inbox?auth=secret#msg", title: "Inbox – me@example.com",
                             document: "notes sk-or-v1-0123456789abcdef0123")
        let criteria: [(id: String, text: String)] = [("misc", "其他")]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JevClient.body(state: state, criteria: criteria)) as? [String: Any])
        let sent = try XCTUnwrap(json["state"] as? [String: String])
        XCTAssertEqual(sent["url"], "https://mail.example.com/inbox")
        XCTAssertEqual(sent["window_title"], "Inbox – ")
        XCTAssertEqual(sent["document"], "notes ")
    }

    func testOnlyThisMacsRowsAreAsked() throws {
        try span(domain: "local.example", title: "here")
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO span (start, "end", appBundleID, appName, title, domain, keySeconds, deviceID, originID)
                VALUES (?, ?, 'com.google.Chrome', 'Chrome', 'there', 'remote.example', 0, 'other-mac', 1)
                """, arguments: [Date().addingTimeInterval(-3600), Date().addingTimeInterval(-3000)])
        }
        let version = JevPrompt.version(try store.rawCategories())
        XCTAssertEqual(try store.pendingCombos(since: longAgo, promptVersion: version).map(\.key.title), ["here"])
        XCTAssertEqual(try store.pendingProjectCombos(since: longAgo, version: "pv").ask.map(\.key.title), ["here"])
    }

    // MARK: - Unusable answers and spend

    func testAttemptBackoff() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(JevAttempt.nextTry(attempts: 0, lastTried: t), t.addingTimeInterval(180))
        XCTAssertEqual(JevAttempt.nextTry(attempts: 1, lastTried: t), t.addingTimeInterval(360))
        XCTAssertEqual(JevAttempt.nextTry(attempts: 5, lastTried: t), t.addingTimeInterval(180 * 32))
        XCTAssertNil(JevAttempt.nextTry(attempts: JevAttempt.maxAttempts, lastTried: t), "given up")
        XCTAssertTrue(JevAttempt.isDue(nil, now: t))
        XCTAssertFalse(JevAttempt.isDue(JevAttempt(attempts: 1, lastTried: t), now: t.addingTimeInterval(359)))
        XCTAssertTrue(JevAttempt.isDue(JevAttempt(attempts: 1, lastTried: t), now: t.addingTimeInterval(360)))
        XCTAssertFalse(JevAttempt.isDue(JevAttempt(attempts: 6, lastTried: t), now: t.addingTimeInterval(86_400 * 365)))
        XCTAssertEqual(JevAttemptKey.category(VerdictKey(appBundleID: "a", domain: nil, title: "t", document: nil)).key, "a\u{1F}\u{1F}t\u{1F}")
        XCTAssertNotEqual(JevAttemptKey.category(key("d", "t")), JevAttemptKey.project(key("d", "t")))
    }

    func testAnUnusableAnswerWaitsAndASavedVerdictClearsIt() async throws {
        try span(domain: "a.example", title: "A")
        let transport = StubJevTransport { _ in ("uncategorized", ["uncategorized": 0.9], 0.0001) }
        let w = worker(transport)
        let first = await w.run(since: longAgo)
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(first.failed, 1)
        XCTAssertEqual(try store.jevAttempts()[JevAttemptKey.category(key("a.example", "A"))]?.attempts, 1)
        XCTAssertEqual(settings.jevSpend(), 0.0001, accuracy: 1e-9, "paid for, so counted")

        let second = await w.run(since: longAgo)
        XCTAssertEqual(second.calls, 0, "not asked again on the next run")

        try store.saveVerdict(JevVerdict(appBundleID: "com.google.Chrome", domain: "a.example", title: "A", document: "", categoryID: "news",
                                         prob: 0.9, runnerUp: "", runnerUpProb: 0, promptVersion: "v", at: Date(), source: "jev"))
        XCTAssertTrue(try store.jevAttempts().isEmpty)
    }

    func testAReplyThatDoesNotParseIsStillCharged() async throws {
        for i in 0..<3 { try span(domain: "s\(i).example", title: "t\(i)") }
        let transport = JevFixesTransport { _ in (Data(#"{"answers":{},"usage":{"cost":0.002}}"#.utf8), 200) }
        let run = await worker(transport).run(since: longAgo, maxConcurrent: 1)
        XCTAssertEqual(run.calls, 3)
        XCTAssertEqual(run.failed, 3)
        XCTAssertNil(run.problem, "a bad answer says nothing about the service")
        XCTAssertEqual(run.costUSD, 0.006, accuracy: 1e-9)
        XCTAssertEqual(settings.jevSpend(), 0.006, accuracy: 1e-9)
        XCTAssertEqual(try store.jevAttempts().count, 3)
    }

    func testTimeoutsAreChargedAnEstimateAndThreeInARowStopTheRun() async throws {
        for i in 0..<5 { try span(domain: "s\(i).example", title: "t\(i)") }
        let transport = JevFixesTransport { _ in throw URLError(.timedOut) }
        let run = await worker(transport).run(since: longAgo, maxConcurrent: 1)
        XCTAssertEqual(run.calls, 3, "three service failures in a row stop launching")
        XCTAssertEqual(run.problem, .unavailable)
        XCTAssertEqual(run.estimatedCostUSD, 3 * JevWorker.timeoutCostEstimate, accuracy: 1e-9)
        XCTAssertEqual(settings.jevSpend(), 3 * JevWorker.timeoutCostEstimate, accuracy: 1e-9)
        XCTAssertEqual(try store.jevAttempts().count, 3)
    }

    func testRefusalsStopTheRunAndAreToldApart() async throws {
        for i in 0..<3 { try span(domain: "s\(i).example", title: "t\(i)") }
        let cases: [(Int, JevProblem)] = [(404, .badModelOrEndpoint), (400, .badModelOrEndpoint), (401, .invalidKey), (403, .invalidKey), (402, .noCredits)]
        for (status, problem) in cases {
            let transport = JevFixesTransport { _ in (Data(), status) }
            let run = await worker(transport).run(since: longAgo, maxConcurrent: 1)
            XCTAssertEqual(run.calls, 1, "HTTP \(status) stops the run")
            XCTAssertEqual(run.problem, problem)
        }
        XCTAssertTrue(try store.jevAttempts().isEmpty, "a refusal says nothing about the question")
        let down = JevFixesTransport { _ in (Data(), 503) }
        let run = await worker(down).run(since: longAgo, maxConcurrent: 1)
        XCTAssertEqual(run.calls, 3)
        XCTAssertEqual(run.problem, .unavailable)
        XCTAssertNil(JevProblem(JevError.badAnswer(cost: 0)))
        XCTAssertNotEqual(JevProblem.invalidKey.message, JevProblem.noCredits.message)
    }

    func testTheServiceWaitsLongerAfterTroubledRuns() {
        XCTAssertEqual(JevService.delay(retryAfter: 45, troubledRuns: 3), 45)
        XCTAssertEqual(JevService.delay(retryAfter: nil, troubledRuns: 0), 180)
        XCTAssertEqual(JevService.delay(retryAfter: nil, troubledRuns: 1), 360)
        XCTAssertEqual(JevService.delay(retryAfter: nil, troubledRuns: 10), 3_600)
    }

    // MARK: - Switched off mid-run

    func testTurningJevOffStopsWhatIsQueued() async throws {
        for i in 0..<4 { try span(domain: "s\(i).example", title: "t\(i)") }
        let settings = self.settings!
        let transport = JevFixesTransport { _ in
            settings.setJevEnabled(false)
            return (JevFixesTransport.answer("misc"), 200)
        }
        let run = await worker(transport).run(since: longAgo, maxConcurrent: 1)
        XCTAssertEqual(run.calls, 1, "nothing more is launched once the switch is off")
        XCTAssertEqual(transport.calls, 1)
    }

    func testTurningScreenTextOffStopsQueuedScreens() async throws {
        for i in 0..<2 {
            let s = try span("com.openai.codex", title: "Codex", ago: 3600 - Double(i) * 600)
            try capture(s, String(repeating: "screen \(i) ", count: 10))
        }
        settings.setJevScreenText(true)
        let settings = self.settings!
        let transport = JevFixesTransport { _ in
            settings.setJevScreenText(false)
            return (JevFixesTransport.answer("research"), 200)
        }
        let run = await worker(transport).run(since: longAgo, maxConcurrent: 1)
        XCTAssertEqual(run.calls, 1)
        XCTAssertEqual(transport.calls, 1)
    }

    // MARK: - What is asked, in what order

    func testStaleCombosComeAfterNeverAskedOnesAndUserRulesAreLeftAlone() throws {
        try span(domain: "old.example", title: "old", ago: 7200, seconds: 3000)
        try span(domain: "recent.example", title: "recent", ago: 1800, seconds: 600)
        try span(domain: "new.example", title: "new", seconds: 60)
        try span(domain: "mine.example", title: "mine")
        for (domain, title) in [("old.example", "old"), ("recent.example", "recent")] {
            try store.saveVerdict(JevVerdict(appBundleID: "com.google.Chrome", domain: domain, title: title, document: "", categoryID: "research",
                                             prob: 0.9, runnerUp: "", runnerUpProb: 0, promptVersion: "old", at: Date(), source: "jev"))
        }
        try store.setUserDomain("mine.example", categoryID: "writing")
        let resolver = CategoryResolver(categoryStore: store)
        resolver.jevEnabled = true
        let version = JevPrompt.version(try store.rawCategories())
        let asked = try store.pendingCombos(since: longAgo, promptVersion: version, userRules: resolver.classificationContext).map(\.key.title)
        XCTAssertEqual(asked, ["new", "recent", "old"], "never asked first; then the stale ones, most recently seen first")
        XCTAssertEqual(try store.pendingCombos(since: longAgo, promptVersion: version).map(\.key.title).sorted(), ["mine", "new", "old", "recent"])
    }

    func testCaptureVerdictsAreReadForTheLookbackOnly() throws {
        let old = try span("com.openai.codex", title: "Codex", ago: 86_400 * 100)
        let recent = try span("com.openai.codex", title: "Codex")
        let oldText = String(repeating: "old screen ", count: 10), newText = String(repeating: "new screen ", count: 10)
        try capture(old, oldText, ago: 86_400 * 100)
        try capture(recent, newText)
        for text in [oldText, newText] {
            try store.saveCaptureVerdict(key: captureKey(text), categoryID: "research", prob: 0.9, runnerUp: "", runnerUpProb: 0, promptVersion: "v")
        }
        let found = try store.captureVerdictsBySpan(since: Date().addingTimeInterval(-86_400 * 90))
        XCTAssertEqual(Array(found.keys), [try XCTUnwrap(recent.id)])
    }

    func testForgottenScreensTakeTheirVerdictsAndAttemptsAlong() async throws {
        let s = try span("com.openai.codex", title: "Codex")
        let keptText = String(repeating: "kept screen ", count: 10), goneText = String(repeating: "gone screen ", count: 10)
        try capture(s, keptText)
        try capture(s, goneText, ago: 86_400 * 40)
        for text in [keptText, goneText] {
            try store.saveCaptureVerdict(key: captureKey(text), categoryID: "research", prob: 0.9, runnerUp: "", runnerUpProb: 0, promptVersion: "v")
        }
        try store.recordJevAttempt(.capture(captureKey(goneText)))
        try store.recordJevAttempt(.category(key("a.com", "t")))
        XCTAssertEqual(try store.forgetOrphanedCaptureVerdicts(), 0, "every screen is still saved")

        // Screen review forgets the old capture (as `ObservationStore.forgetCaptures` does).
        try await db.write { try $0.execute(sql: "DELETE FROM capture WHERE lastSeenAt < ?", arguments: [Date().addingTimeInterval(-86_400 * 30)]) }
        XCTAssertEqual(try store.forgetOrphanedCaptureVerdicts(), 2, "its verdict and its attempt")
        let keys = try await db.read { try String.fetchAll($0, sql: "SELECT textKey FROM jevCaptureVerdict") }
        XCTAssertEqual(keys, [captureKey(keptText)])
        XCTAssertEqual(Set(try store.jevAttempts().keys), Set([JevAttemptKey.category(key("a.com", "t"))]), "other attempts stay")

        // A Jev run does the same on its own.
        try store.saveCaptureVerdict(key: captureKey(goneText), categoryID: "research", prob: 0.9, runnerUp: "", runnerUpProb: 0, promptVersion: "v")
        _ = await worker(JevFixesTransport { _ in (JevFixesTransport.answer("research"), 200) }).run(since: longAgo)
        let goneKey = captureKey(goneText)
        let left = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM jevCaptureVerdict WHERE textKey = ?", arguments: [goneKey]) }
        XCTAssertEqual(left, 0)
    }

    // MARK: - Key check

    func testKeyCheckReportsUsageAndTellsABadKeyApart() async throws {
        XCTAssertEqual(JevClient.keyURL(endpoint: JevClient.defaultEndpoint)?.absoluteString, "https://openrouter.ai/api/v1/key")
        let good = JevFixesTransport { request in
            guard request.httpMethod == "GET", request.url?.path == "/api/v1/key" else { return (Data(), 404) }
            return (Data(#"{"data":{"label":"x","limit":5,"usage":1.25,"limit_remaining":3.75,"is_free_tier":false}}"#.utf8), 200)
        }
        let info = try await JevClient.checkKey(endpoint: JevClient.defaultEndpoint, apiKey: "sk-or-test", transport: good)
        XCTAssertEqual(info, JevKeyInfo(usage: 1.25, limit: 5, limitRemaining: 3.75, isFreeTier: false))
        XCTAssertEqual(JevSettingsPane.keyLine(info), "密钥有效 · 已用 $1.25，额度还剩 $3.75")

        let bad = JevFixesTransport { _ in (Data(), 401) }
        do {
            _ = try await JevClient.checkKey(endpoint: JevClient.defaultEndpoint, apiKey: "sk-or-wrong", transport: bad)
            XCTFail("a 401 is an invalid key")
        } catch {
            XCTAssertEqual(JevProblem(error), .invalidKey)
            XCTAssertEqual(JevSettingsPane.keyErrorLine(error), JevProblem.invalidKey.message)
        }
    }
}
