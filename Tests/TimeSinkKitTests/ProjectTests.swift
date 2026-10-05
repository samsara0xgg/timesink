import GRDB
import XCTest
@testable import TimeSinkKit

/// Answers both questions from a closure and records every request body; never touches the network.
final class ProjectStubTransport: JevTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    /// Given the request's state title and the offered project ids, returns the project answer (nil: no project answer in the reply).
    private let project: @Sendable (String, [String]) -> (choice: String, probabilities: [String: Double])?
    var rawProject: String?

    init(project: @escaping @Sendable (String, [String]) -> (choice: String, probabilities: [String: Double])?) {
        self.project = project
    }

    var requests: [[String: Any]] { lock.withLock { bodies } }

    func post(_ request: URLRequest) async throws -> (data: Data, status: Int, retryAfter: String?) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        lock.withLock { bodies.append(body) }
        let title = ((body["state"] as? [String: Any])?["window_title"] as? String) ?? ""
        let questions = body["questions"] as? [String: Any] ?? [:]
        var answers: [String: Any] = [:]
        if questions["category"] != nil { answers["category"] = ["choice": "misc", "probabilities": ["misc": 0.9, "writing": 0.05], "confidence": 0.9] }
        if let asked = questions["project"] as? [String: Any], let criteria = asked["criteria"] as? [String: Any] {
            if let raw = rawProject { answers["project"] = raw }
            else if let p = project(title, Array(criteria.keys)) {
                answers["project"] = ["choice": p.choice, "probabilities": p.probabilities, "confidence": 0.8]
            }
        }
        return (try JSONSerialization.data(withJSONObject: ["answers": answers, "usage": ["input_tokens": 900, "cost": 0.0004]]), 200, nil)
    }
}

@MainActor
final class ProjectTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: CategoryStore!
    private var projects: ProjectStore!
    private var settings: SettingsStore!

    override func setUpWithError() throws {
        db = try AppDatabase.openInMemory()
        store = CategoryStore(db)
        projects = store.projects
        settings = SettingsStore(db)
    }

    private func span(domain: String, title: String, seconds: Double = 600, ago: Double = 3600) -> Span {
        let start = Date().addingTimeInterval(-ago)
        return Span(start: start, end: start.addingTimeInterval(seconds), appBundleID: "com.google.Chrome", appName: "Chrome",
                    title: title, url: "https://\(domain)/", domain: domain)
    }

    // MARK: - Store and migration

    func testMigrationAddsTheTablesAndMovesProjectAnswers() throws {
        let old = try DatabaseQueue()
        try AppDatabase.migrator.migrate(old, upTo: "v18")
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO jevVerdict (appBundleID, categoryID, prob, promptVersion, at, source, projectID, projectProb, projectRunnerUp, projectPromptVersion)
                VALUES ('a', 'misc', 0.9, 'v', ?, 'jev', 'p-1', 0.8, 'none', 'pv'), ('b', 'misc', 0.9, 'v', ?, 'jev', '', 0, '', ''),
                       ('c', 'misc', 0.9, 'v', ?, 'seed', 'p-1', 0.8, '', 'pv')
                """, arguments: [Date(), Date(), Date()])
        }
        try AppDatabase.migrator.migrate(old)
        try old.read { db in
            XCTAssertTrue(try db.tableExists("project"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jevVerdict"), 3, "category verdicts are kept")
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM jevProjectVerdict")
            XCTAssertEqual(rows.count, 1, "only judged, non-seed rows move")
            XCTAssertEqual(rows[0]["appBundleID"] as String, "a")
            XCTAssertEqual(rows[0]["projectID"] as String, "p-1")
            XCTAssertEqual(rows[0]["prob"] as Double, 0.8)
            XCTAssertEqual(rows[0]["runnerUp"] as String, "none")
            XCTAssertEqual(rows[0]["promptVersion"] as String, "pv")
        }
    }

    func testAddListDuplicateAndOrder() throws {
        let a = try projects.add(name: "  Alpha ", description: "the first")
        let b = try projects.add(name: "Beta")
        XCTAssertEqual(a.name, "Alpha")
        XCTAssertEqual(try projects.list().map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(b.source, "user")
        XCTAssertThrowsError(try projects.add(name: "alpha")) { XCTAssertEqual($0 as? ProjectStore.ProjectError, .duplicate) }
        XCTAssertThrowsError(try projects.add(name: "  ")) { XCTAssertEqual($0 as? ProjectStore.ProjectError, .emptyName) }
    }

    func testLimit() throws {
        for i in 0..<ProjectStore.maxProjects { try projects.add(name: "p\(i)") }
        XCTAssertThrowsError(try projects.add(name: "one too many")) { XCTAssertEqual($0 as? ProjectStore.ProjectError, .limitReached) }
    }

    func testArchiveHidesAndTheNameComesBack() throws {
        let a = try projects.add(name: "Alpha", description: "old")
        try projects.archive(a.id)
        XCTAssertTrue(try projects.list().isEmpty)
        let again = try projects.add(name: "ALPHA", description: "new")
        XCTAssertEqual(again.id, a.id)
        XCTAssertEqual(try projects.list().map(\.description), ["new"])
    }

    func testRenameFollowsYourAssignments() throws {
        let a = try projects.add(name: "Alpha")
        _ = try projects.add(name: "Beta")
        try ObservationStore(db).setSessionName(signature: "p:x", project: "alpha")
        try projects.update(id: a.id, name: "Alpha 2", description: "d")
        XCTAssertEqual(try ObservationStore(db).sessionNames()["p:x"]?.project, "Alpha 2")
        XCTAssertThrowsError(try projects.update(id: a.id, name: "beta", description: "")) { XCTAssertEqual($0 as? ProjectStore.ProjectError, .duplicate) }
    }

    func testMergeRelabelsAssignmentsAndVerdicts() throws {
        let a = try projects.add(name: "Alpha")
        let b = try projects.add(name: "Beta")
        try ObservationStore(db).setSessionName(signature: "p:x", project: "Alpha")
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO jevProjectVerdict (appBundleID, projectID, runnerUp, promptVersion, at) VALUES ('a', ?, ?, 'pv', ?), ('b', ?, '', 'pv', ?)
                """, arguments: [a.id, b.id, Date(), b.id, Date()])
        }
        try projects.merge(a.id, into: b.id)
        XCTAssertEqual(try projects.list().map(\.name), ["Beta"])
        XCTAssertEqual(try ObservationStore(db).sessionNames()["p:x"]?.project, "Beta")
        let verdicts = try store.projectVerdicts()
        XCTAssertEqual(verdicts.values.map(\.projectID), [b.id, b.id])
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT runnerUp FROM jevProjectVerdict WHERE appBundleID = 'a'") }, b.id)
        XCTAssertThrowsError(try projects.merge(b.id, into: b.id)) { XCTAssertEqual($0 as? ProjectStore.ProjectError, .sameProject) }
    }

    // MARK: - Request and answer

    private var state: JevState { JevState(app: "Chrome", bundleID: "b", domain: "d.example", url: "https://d.example/", title: "t", document: "") }
    private let categories: [(id: String, text: String)] = [("misc", "其他"), ("writing", "写作")]

    func testWithoutProjectsTheRequestIsWhatItWas() throws {
        let plain = JevClient.body(state: state, criteria: categories)
        XCTAssertEqual(plain, JevClient.body(state: state, criteria: categories, projects: []))
        let text = String(decoding: plain, as: UTF8.self)
        XCTAssertFalse(text.contains("\"project\""))
        XCTAssertTrue(text.hasSuffix("\"criteria\":{\"misc\":\"其他\",\"writing\":\"写作\"}}}}"))
    }

    func testProjectsAddASecondQuestion() throws {
        let a = try projects.add(name: "Alpha", description: "the first")
        let list = JevPrompt.projectCriteria(try projects.list())
        XCTAssertEqual(list.map(\.id), [a.id, "none"])
        XCTAssertEqual(list.map(\.text), ["Alpha：the first", "不属于以上任何项目"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JevClient.body(state: state, criteria: categories, projects: list)) as? [String: Any])
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual(Set(questions.keys), ["category", "project"])
        let project = try XCTUnwrap(questions["project"] as? [String: Any])
        XCTAssertEqual(project["type"] as? String, "choice")
        XCTAssertEqual(project["instructions"] as? String, "这段电脑使用时间属于哪个项目？不属于任何一个就选 none。")
        XCTAssertEqual((project["criteria"] as? [String: String])?["none"], "不属于以上任何项目")
        // The category question is untouched.
        XCTAssertEqual((questions["category"] as? [String: Any])?["instructions"] as? String, JevPrompt.instructions)
    }

    func testProjectVersionChangesWithTheListOnly() throws {
        let none = JevPrompt.projectVersion([])
        let a = try projects.add(name: "Alpha")
        let one = JevPrompt.projectVersion(try projects.list())
        XCTAssertNotEqual(none, one)
        XCTAssertEqual(one, JevPrompt.projectVersion(try projects.list()))
        try projects.update(id: a.id, name: "Alpha", description: "now described")
        XCTAssertNotEqual(one, JevPrompt.projectVersion(try projects.list()))
    }

    func testParseReadsTheProjectAnswerAndSurvivesABadOne() throws {
        let good = Data(#"{"answers":{"category":{"choice":"misc","probabilities":{"misc":0.9}},"project":{"choice":"p-1","probabilities":{"p-1":0.7,"none":0.3},"confidence":0.7}},"usage":{"input_tokens":5,"cost":0.1}}"#.utf8)
        let answer = try JevClient.parse(good)
        XCTAssertEqual(answer.choice, "misc")
        XCTAssertEqual(answer.projectChoice, "p-1")
        XCTAssertEqual(answer.projectProbabilities?["none"], 0.3)
        XCTAssertEqual(answer.projectConfidence, 0.7)
        let bad = Data(#"{"answers":{"category":{"choice":"misc"},"project":"nope"}}"#.utf8)
        let kept = try JevClient.parse(bad)
        XCTAssertEqual(kept.choice, "misc")
        XCTAssertNil(kept.projectChoice)
        let plain = try JevClient.parse(Data(#"{"answers":{"category":{"choice":"misc"}}}"#.utf8))
        XCTAssertNil(plain.projectChoice)
    }

    func testUnknownProjectIdIsNone() {
        func answer(_ choice: String?) -> JevAnswer {
            JevAnswer(choice: "misc", probabilities: [:], confidence: 0, inputTokens: 0, cost: 0, projectChoice: choice,
                      projectProbabilities: choice.map { ["p-1": 0.1].merging([$0: 0.8]) { _, new in new } }, projectConfidence: 0.8)
        }
        let known = JevWorker.projectFields(answer("p-1"), ids: ["p-1"], version: "v")
        XCTAssertEqual(known.id, "p-1")
        XCTAssertEqual(known.prob, 0.8, accuracy: 1e-9)
        XCTAssertEqual(known.runnerUp, "")
        XCTAssertEqual(JevWorker.projectFields(answer("p-9"), ids: ["p-1"], version: "v").id, "none")
        XCTAssertEqual(JevWorker.projectFields(answer("none"), ids: ["p-1"], version: "v").id, "none")
        let missing = JevWorker.projectFields(answer(nil), ids: ["p-1"], version: "v")
        XCTAssertEqual(missing.id, "none")
        XCTAssertEqual(missing.version, "v")
    }

    // MARK: - Worker

    private func worker(_ transport: ProjectStubTransport) -> JevWorker {
        settings.setJevEnabled(true)
        return JevWorker(categoryStore: store, settings: settings, transport: transport, apiKey: { "test-key" })
    }
    private var longAgo: Date { Date().addingTimeInterval(-86_400 * 30) }

    private func key(_ title: String) -> VerdictKey { VerdictKey(appBundleID: "com.google.Chrome", domain: nil, title: title, document: nil) }
    private func questions(_ request: [String: Any]) -> Set<String> {
        Set((request["questions"] as? [String: Any] ?? [:]).keys)
    }

    func testNoProjectsMeansNoSecondQuestionAndNoProjectRows() async throws {
        _ = try SpanStore(db).insert(span(domain: "one.example", title: "one"))
        let transport = ProjectStubTransport { _, _ in nil }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.saved, 1)
        XCTAssertEqual(questions(try XCTUnwrap(transport.requests.first)), ["category"])
        XCTAssertTrue(try store.projectVerdicts().isEmpty)
    }

    func testProjectAnswerIsSavedWithTheCategory() async throws {
        let alpha = try projects.add(name: "Alpha")
        _ = try SpanStore(db).insert(span(domain: "one.example", title: "one"))
        _ = try SpanStore(db).insert(span(domain: "two.example", title: "two", seconds: 300))
        let transport = ProjectStubTransport { title, ids in
            title == "one" ? (alpha.id, [alpha.id: 0.85, "none": 0.15]) : ("p-unknown", ["p-unknown": 0.9])
        }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.saved, 2)
        XCTAssertEqual(run.inputTokens, 1800)
        XCTAssertEqual(run.costUSD, 0.0008, accuracy: 1e-9)
        XCTAssertEqual(Set(transport.requests.map(questions)), [["category", "project"]], "both questions, one request")
        XCTAssertEqual(try store.verdicts().count, 2)
        let found = try store.projectVerdicts()
        XCTAssertEqual(found.count, 2)
        let one = try XCTUnwrap(found.first { $0.key.title == "one" }?.value), two = try XCTUnwrap(found.first { $0.key.title == "two" }?.value)
        XCTAssertEqual(one.projectID, alpha.id)
        XCTAssertEqual(one.prob, 0.85, accuracy: 1e-9)
        let extra = try await db.read { db -> [String] in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT runnerUp, promptVersion FROM jevProjectVerdict WHERE title = 'one'"))
            return [row["runnerUp"], row["promptVersion"]]
        }
        XCTAssertEqual(extra, ["none", JevPrompt.projectVersion(try projects.list())])
        XCTAssertEqual(two.projectID, "none")
    }

    func testAChangedProjectListAsksAgainButOnlyForRecentCombos() async throws {
        let alpha = try projects.add(name: "Alpha")
        _ = try SpanStore(db).insert(span(domain: "recent.example", title: "recent", ago: 86_400 * 2))
        _ = try SpanStore(db).insert(span(domain: "old.example", title: "old", ago: 86_400 * 20))
        let transport = ProjectStubTransport { _, _ in (alpha.id, [alpha.id: 0.9]) }
        let w = worker(transport)
        _ = await w.run(since: longAgo)
        XCTAssertEqual(transport.requests.count, 2)
        let quiet = await w.run(since: longAgo)
        XCTAssertEqual(quiet.calls, 0, "nothing changed: nothing is asked")
        // A new project changes the version: the combo seen in the last 14 days is asked again, the old one is not,
        // and its category is settled so only the project is asked.
        _ = try projects.add(name: "Beta")
        let again = await w.run(since: longAgo)
        XCTAssertEqual(again.calls, 1)
        XCTAssertEqual(questions(try XCTUnwrap(transport.requests.last)), ["project"])
        let versions = try await db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT title, promptVersion FROM jevProjectVerdict").map { ($0["title"] as String, $0["promptVersion"] as String) })
        }
        XCTAssertEqual(versions["recent"], JevPrompt.projectVersion(try projects.list()))
        XCTAssertNotEqual(versions["old"], JevPrompt.projectVersion(try projects.list()))
    }

    func testTheUsersCategoryStaysButItsProjectIsFilled() async throws {
        let alpha = try projects.add(name: "Alpha")
        let mine = try SpanStore(db).insert(span(domain: "mine.example", title: "mine"))
        try store.setUserVerdict(VerdictKey(mine), categoryID: "writing")
        let transport = ProjectStubTransport { _, _ in (alpha.id, [alpha.id: 0.9]) }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.calls, 1)
        XCTAssertEqual(questions(try XCTUnwrap(transport.requests.first)), ["project"])
        let verdict = try XCTUnwrap(store.verdicts().first)
        XCTAssertEqual(verdict.source, "user")
        XCTAssertEqual(verdict.categoryID, "writing")
        XCTAssertEqual(try store.projectVerdicts()[VerdictKey(mine)]?.projectID, alpha.id)
    }

    func testAWindowDecidedByARuleOrNeverAProjectIsStillJudged() async throws {
        let alpha = try projects.add(name: "Alpha")
        let store2 = SpanStore(db)
        // A hard rule decides the category (the owner's own app): no category request, but a project question.
        let own = try store2.insert(Span(start: Date().addingTimeInterval(-3600), end: Date().addingTimeInterval(-3000), appBundleID: "com.alllllenshi.timesink",
                                         appName: "TimeSink", title: "Today", url: nil, domain: nil))
        // A window the user filed under entertainment, a chat app, and a window with no rule at all.
        let video = try store2.insert(span(domain: "videos.example", title: "clip"))
        try store.setUserVerdict(VerdictKey(video), categoryID: "entertainment")
        let chat = try store2.insert(Span(start: Date().addingTimeInterval(-3600), end: Date().addingTimeInterval(-3000), appBundleID: "com.tencent.xinWeChat",
                                          appName: "WeChat", title: "Friends", url: nil, domain: nil))
        try store.setUserVerdict(VerdictKey(chat), categoryID: "communication")
        _ = try store2.insert(span(domain: "work.example", title: "work"))
        let transport = ProjectStubTransport { _, _ in (alpha.id, [alpha.id: 0.9]) }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.calls, 2, "the owner's app and the unruled window; the video and the chat are settled locally")
        XCTAssertEqual(Set(transport.requests.map(questions)), [["project"], ["category", "project"]])
        let found = try store.projectVerdicts()
        XCTAssertEqual(found[VerdictKey(own)]?.projectID, alpha.id)
        XCTAssertEqual(found[VerdictKey(video)]?.projectID, "none")
        XCTAssertEqual(found[VerdictKey(chat)]?.projectID, "none")
        XCTAssertEqual(found.count, 4)
        XCTAssertEqual(try store.verdicts().filter { $0.source == "jev" }.count, 1, "only the unruled window got a category from Jev")
        // Nothing left to ask.
        let again = await worker(transport).run(since: longAgo)
        XCTAssertEqual(again.calls, 0)
    }

    func testACurrentCategoryIsKeptWhenOnlyTheProjectIsAsked() async throws {
        _ = try SpanStore(db).insert(span(domain: "one.example", title: "one"))
        let transport = ProjectStubTransport { _, _ in nil }
        _ = await worker(transport).run(since: longAgo)
        let first = try XCTUnwrap(store.verdicts().first)
        let alpha = try projects.add(name: "Alpha")
        let second = ProjectStubTransport { _, _ in (alpha.id, [alpha.id: 0.7]) }
        _ = await worker(second).run(since: longAgo)
        let after = try XCTUnwrap(store.verdicts().first)
        XCTAssertEqual(after.at, first.at, "the category verdict was not rewritten")
        XCTAssertEqual(try store.projectVerdicts().values.map(\.projectID), [alpha.id])
    }

    func testTheCapStopsProjectRequestsToo() async throws {
        let alpha = try projects.add(name: "Alpha")
        _ = try SpanStore(db).insert(span(domain: "one.example", title: "one"))
        settings.addJevSpend(settings.jevMonthlyCap + 1)
        let transport = ProjectStubTransport { _, _ in (alpha.id, [alpha.id: 0.9]) }
        let run = await worker(transport).run(since: longAgo)
        XCTAssertEqual(run.calls, 0)
        XCTAssertTrue(run.stoppedByCap)
    }

    func testAnArchivedProjectIsNotAskedAndItsVerdictsAreIgnored() throws {
        let alpha = try projects.add(name: "Alpha")
        _ = try projects.add(name: "Beta")
        let id = alpha.id
        try db.write { db in
            try db.execute(sql: "INSERT INTO jevProjectVerdict (appBundleID, projectID, prob, promptVersion, at) VALUES ('a', ?, 0.9, 'pv', ?), ('b', 'none', 1, 'pv', ?)",
                           arguments: [id, Date(), Date()])
        }
        try projects.archive(alpha.id)
        XCTAssertEqual(JevPrompt.projectCriteria(try projects.list()).count, 2)
        let resolver = CategoryResolver(categoryStore: store)
        resolver.jevEnabled = true
        resolver.refreshProjectVerdicts()
        XCTAssertNil(resolver.projectVerdicts[VerdictKey(appBundleID: "a", domain: "", title: "", document: "")], "an archived project is as good as unjudged")
        XCTAssertEqual(resolver.projectVerdicts[VerdictKey(appBundleID: "b", domain: "", title: "", document: "")]?.projectID, "none")
        XCTAssertTrue(resolver.projectsJudged)
    }

    // MARK: - Seed file

    func testSeedLoadsOnceFromAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("project-seed.json")
        XCTAssertFalse(ProjectSeed.applyIfNeeded(store: projects, settings: settings, file: file), "no file: nothing")
        try Data(#"{"projects":[{"name":"Alpha","description":"first"},{"name":"Beta"}]}"#.utf8).write(to: file)
        XCTAssertTrue(ProjectSeed.applyIfNeeded(store: projects, settings: settings, file: file))
        let list = try projects.list()
        XCTAssertEqual(list.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(Set(list.map(\.source)), ["suggested"])
        XCTAssertEqual(list.first?.description, "first")
        // The user deletes them: the seed does not come back.
        for p in list { try projects.archive(p.id) }
        XCTAssertFalse(ProjectSeed.applyIfNeeded(store: projects, settings: settings, file: file))
        XCTAssertTrue(try projects.list().isEmpty)
    }

    func testSeedIgnoresBrokenFilesAndExistingProjects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("project-seed.json")
        try Data("not json".utf8).write(to: file)
        XCTAssertFalse(ProjectSeed.applyIfNeeded(store: projects, settings: settings, file: file))
        XCTAssertTrue(try projects.list().isEmpty)
        try Data(#"{"projects":[{"name":"Alpha"}]}"#.utf8).write(to: file)
        try projects.add(name: "Mine")
        XCTAssertFalse(ProjectSeed.applyIfNeeded(store: projects, settings: settings, file: file))
        XCTAssertEqual(try projects.list().map(\.name), ["Mine"])
    }
}
