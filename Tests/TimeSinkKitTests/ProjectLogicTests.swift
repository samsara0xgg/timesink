import GRDB
import XCTest
@testable import TimeSinkKit

/// Which project a session has, what is recommended, and when Today offers one.
final class ProjectLogicTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }
    private func at(day: Int, _ hour: Double) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!.addingTimeInterval(hour * 3600)
    }
    private func span(day: Int = 1, _ hour: Double = 9, minutes: Double = 10, app: String = "com.test.app", name: String = "Test",
                      title: String? = nil, url: String? = nil, domain: String? = nil, document: String? = nil) -> Span {
        Span(start: at(day: day, hour), end: at(day: day, hour).addingTimeInterval(minutes * 60), appBundleID: app, appName: name,
             title: title, url: url, domain: domain, document: document)
    }
    private func item(_ span: Span) -> CategorizedSpan { CategorizedSpan(span: span, categoryID: "misc") }
    private var home: String { DocumentIdentity.homePath }

    // MARK: Session project

    func testJevProjectNeedsHalfTheTimeAndAGoodMeanProbability() {
        let a = span(minutes: 10, title: "a"), b = span(minutes: 10, title: "b")
        let verdicts: [VerdictKey: ProjectVerdict] = [VerdictKey(a): .init(projectID: "p1", prob: 0.9)]
        func pick(_ items: [Span], _ v: [VerdictKey: ProjectVerdict]) -> String? {
            SessionProjectResolver.jevProjectID(of: items.map(item)) { v[VerdictKey($0)] }
        }
        XCTAssertEqual(pick([a], verdicts), "p1")
        // Exactly half the time is enough; less is not.
        XCTAssertEqual(pick([a, b], verdicts), "p1")
        // Windows nobody judged yet do not count against it, as long as it holds a quarter of the session.
        XCTAssertEqual(pick([a, b, span(minutes: 5, title: "c")], verdicts), "p1")
        XCTAssertNil(pick([a, span(minutes: 40, title: "x")], verdicts), "10 of 50 minutes is under a quarter")
        // 'none' and unasked windows are not a project.
        XCTAssertNil(pick([a, b], [VerdictKey(a): .init(projectID: "none", prob: 0.9)]))
        // The mean probability is time-weighted: 0.9 for 10 min and 0.3 for 10 min is 0.6, exactly enough.
        let c = span(minutes: 10, title: "c")
        XCTAssertEqual(pick([a, c], [VerdictKey(a): .init(projectID: "p1", prob: 0.9), VerdictKey(c): .init(projectID: "p1", prob: 0.3)]), "p1")
        XCTAssertNil(pick([a, c], [VerdictKey(a): .init(projectID: "p1", prob: 0.8), VerdictKey(c): .init(projectID: "p1", prob: 0.3)]))
        XCTAssertNil(pick([a], [VerdictKey(a): .init(projectID: "p1", prob: 0.59)]))
        XCTAssertEqual(pick([a], [VerdictKey(a): .init(projectID: "p1", prob: 0.6)]), "p1")
    }

    /// A realistic stretch: `project` minutes on windows judged to be in one project, `none` on windows judged to be in none
    /// (untitled assistant windows, a chat), `unjudged` on windows with no answer yet.
    private func mix(_ parts: [(String?, Double)], prob: Double = 0.9) -> (items: [CategorizedSpan], verdicts: [VerdictKey: ProjectVerdict]) {
        var verdicts: [VerdictKey: ProjectVerdict] = [:]
        var items: [CategorizedSpan] = []
        for (index, part) in parts.enumerated() {
            let s = span(day: 1, 9 + Double(index), minutes: part.1, title: "w\(index)")
            if let id = part.0, id != "?" { verdicts[VerdictKey(s)] = .init(projectID: id, prob: prob) }
            items.append(item(s))
        }
        return (items, verdicts)
    }
    private func pick(_ m: (items: [CategorizedSpan], verdicts: [VerdictKey: ProjectVerdict])) -> String? {
        SessionProjectResolver.jevProjectID(of: m.items) { m.verdicts[VerdictKey($0)] }
    }

    func testNoneWindowsDoNotDiluteAProjectButAThinSliceStillFails() {
        // 20 of 60 minutes in the project, 30 judged none, 10 unjudged.
        XCTAssertEqual(pick(mix([("p1", 20), ("none", 30), ("?", 10)])), "p1")
        // Only 6 of 60 minutes: under a quarter of the session.
        XCTAssertNil(pick(mix([("p1", 6), ("none", 44), ("?", 10)])))
        // Everything judged none: no project.
        XCTAssertNil(pick(mix([("none", 30), ("none", 30)])))
        // Two projects: the larger needs half of the project time, and a quarter of the session.
        XCTAssertEqual(pick(mix([("p1", 18), ("p2", 10), ("none", 32)])), "p1")
        XCTAssertNil(pick(mix([("p1", 12), ("p2", 12), ("none", 36)])), "a tie that is also under a quarter")
        XCTAssertNil(pick(mix([("p1", 14), ("p2", 14), ("p3", 14), ("none", 18)])), "14 of 42 project minutes is a third")
        // Low confidence is unsure however large.
        XCTAssertNil(pick(mix([("p1", 40), ("none", 20)], prob: 0.5)))
    }

    func testASessionWaitsForJevWhenHalfOfItIsUnjudged() {
        func pending(_ m: (items: [CategorizedSpan], verdicts: [VerdictKey: ProjectVerdict])) -> Bool {
            SessionProjectResolver.isPending(m.items) { m.verdicts[VerdictKey($0)] }
        }
        XCTAssertTrue(pending(mix([("?", 30), ("none", 30)])))
        XCTAssertFalse(pending(mix([("?", 29), ("none", 31)])))
        XCTAssertFalse(pending(mix([("none", 60)])), "judged none is an answer")
        // Only sessions cut while projects are being judged know it; otherwise nothing waits.
        let a = span(minutes: 30, title: "a")
        XCTAssertFalse(SessionSegmenter.sessions([item(a)]).first!.projectPending)
        XCTAssertTrue(SessionSegmenter.sessions([item(a)], projectVerdicts: [:]).first!.projectPending)
        XCTAssertFalse(SessionSegmenter.sessions([item(a)], projectVerdicts: [VerdictKey(a): .init(projectID: "none", prob: 1)]).first!.projectPending)
    }

    func testTheMajorityProjectWinsAndIsWeightedByTime() {
        let a = span(minutes: 20, title: "a"), b = span(minutes: 5, title: "b"), c = span(minutes: 5, title: "c")
        let v: [VerdictKey: ProjectVerdict] = [VerdictKey(a): .init(projectID: "p1", prob: 0.8), VerdictKey(b): .init(projectID: "p2", prob: 0.99),
                                               VerdictKey(c): .init(projectID: "p2", prob: 0.99)]
        XCTAssertEqual(SessionProjectResolver.jevProjectID(of: [a, b, c].map(item)) { v[VerdictKey($0)] }, "p1")
    }

    func testPriorityOverrideThenJevThenRule() {
        let mine = ["Alpha", "Time Sink"]
        XCTAssertEqual(SessionProjectResolver.resolve(override: "Mine", jev: "Alpha", ruleLabel: "repo", userNames: mine), "Mine")
        XCTAssertEqual(SessionProjectResolver.resolve(override: nil, jev: "Alpha", ruleLabel: "repo", userNames: mine), "Alpha")
        XCTAssertEqual(SessionProjectResolver.resolve(override: nil, jev: nil, ruleLabel: "repo", userNames: mine), "repo")
        XCTAssertNil(SessionProjectResolver.resolve(override: nil, jev: nil, ruleLabel: nil, userNames: mine))
        XCTAssertEqual(SessionProjectResolver.resolve(override: "", jev: nil, ruleLabel: nil, userNames: mine), nil)
    }

    func testARepoLabelShowsAsTheUsersProjectOfTheSameName() {
        XCTAssertEqual(SessionProjectResolver.resolve(override: nil, jev: nil, ruleLabel: "alpha", userNames: ["Alpha"]), "Alpha")
        XCTAssertEqual(SessionProjectResolver.resolve(override: nil, jev: nil, ruleLabel: "time-sink", userNames: ["Time Sink"]), "Time Sink")
        XCTAssertEqual(SessionProjectResolver.resolve(override: nil, jev: nil, ruleLabel: "other", userNames: ["Alpha"]), "other")
    }

    func testTheSegmenterFillsInTheJevProjectButNeverCutsOnIt() {
        let a = span(minutes: 30, app: "a", title: "a"), b = span(day: 1, 9.5, minutes: 30, app: "b", title: "b")
        let v: [VerdictKey: ProjectVerdict] = [VerdictKey(a): .init(projectID: "p1", prob: 0.9), VerdictKey(b): .init(projectID: "p2", prob: 0.9)]
        let withVerdicts = SessionSegmenter.sessions([a, b].map(item), projectVerdicts: v)
        let without = SessionSegmenter.sessions([a, b].map(item))
        XCTAssertEqual(withVerdicts.map(\.start), without.map(\.start))
        XCTAssertEqual(withVerdicts.map(\.end), without.map(\.end))
        XCTAssertEqual(withVerdicts.map(\.signature), without.map(\.signature))
        XCTAssertEqual(without.map(\.jevProjectID), [nil])
        XCTAssertEqual(withVerdicts.count, 1)
        // 30 of 60 minutes each, with p1 holding exactly half.
        XCTAssertEqual(withVerdicts.first?.jevProjectID, "p1")
    }

    // MARK: Recommendations

    /// A Claude Code window for `name`, on each of `days`, `minutes` long.
    private func claude(_ name: String, days: [Int], minutes: Double = 40) -> [Span] {
        days.map { span(day: $0, minutes: minutes, app: "com.test.term", name: "Terminal", title: "\(name) - Claude Code") }
    }
    private func filler(days: [Int], minutes: Double = 120) -> [Span] {
        days.map { span(day: $0, 13, minutes: minutes, app: "com.test.mail", name: "Mail", title: "Inbox") }
    }

    func testGateNeedsThreeDaysAndEightHours() {
        let two = filler(days: [1, 2], minutes: 300)
        XCTAssertEqual(ProjectSuggester.suggest(two, calendar: calendar).gate, .init(days: 2, recorded: 600 * 60))
        XCTAssertFalse(ProjectSuggester.suggest(two, calendar: calendar).gate.isOpen)
        let thin = filler(days: [1, 2, 3], minutes: 60)
        XCTAssertFalse(ProjectSuggester.suggest(thin, calendar: calendar).gate.isOpen, "3 days but 3 hours")
        let enough = filler(days: [1, 2, 3], minutes: 160)
        XCTAssertTrue(ProjectSuggester.suggest(enough, calendar: calendar).gate.isOpen)
        // A few minutes is not a day with data.
        XCTAssertEqual(ProjectSuggester.suggest(filler(days: [1, 2, 3, 4], minutes: 10) + filler(days: [5], minutes: 600), calendar: calendar).gate.days, 1)
    }

    func testNothingIsRecommendedBeforeTheGate() {
        let spans = claude("alpha", days: [1, 2]) + filler(days: [1, 2], minutes: 100)
        XCTAssertEqual(ProjectSuggester.suggest(spans, calendar: calendar).candidates, [])
    }

    func testAClaudeCodeTitleGivesACandidate() throws {
        let spans = claude("alpha", days: [1, 2, 3, 4]) + filler(days: [1, 2, 3, 4])
        let result = ProjectSuggester.suggest(spans, calendar: calendar)
        XCTAssertTrue(result.gate.isOpen)
        let alpha = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(alpha.name, "alpha")
        XCTAssertEqual(alpha.days, 4)
        XCTAssertEqual(alpha.seconds, 4 * 40 * 60)
        XCTAssertEqual(alpha.sources, [.claudeCode])
        XCTAssertFalse(alpha.summary.isEmpty)
        XCTAssertEqual(result.todoCandidate?.name, "alpha")
    }

    func testFoldersRepoNamesAndVariantsMergeIntoOne() throws {
        let folder = (1...3).map { span(day: $0, 10, minutes: 25, app: "com.test.term", name: "Terminal", document: "file://\(home)/Projects/Alpha/") }
        let editor = (1...3).map { span(day: $0, 11, minutes: 25, app: "com.test.editor", name: "Editor", title: "x.swift", document: "file://\(home)/Projects/alpha/Sources/x.swift") }
        let repo = (1...3).map { span(day: $0, 12, minutes: 25, app: "com.test.browser", name: "Browser", title: "PR", url: "https://github.com/someone/alpha/pull/1", domain: "github.com") }
        let result = ProjectSuggester.suggest(folder + editor + repo + filler(days: [1, 2, 3]), calendar: calendar)
        XCTAssertEqual(result.candidates.count, 1)
        let alpha = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(alpha.seconds, 9 * 25 * 60)
        XCTAssertEqual(alpha.sources, [.terminal, .github])
    }

    func testGenericWordsAndAppNamesAreDropped() {
        let junk = ["Claude", "ChatGPT", "Ghostty", "Terminal", "Electron", "Google Chrome", "Safari", "New Tab"]
        let spans = junk.flatMap { claude($0, days: [1, 2, 3], minutes: 60) }
            + claude("Mail", days: [1, 2, 3], minutes: 60)   // the name of an app in these records
            + filler(days: [1, 2, 3])
        XCTAssertEqual(ProjectSuggester.suggest(spans, calendar: calendar).candidates, [])
    }

    func testNeedsAnHourOnTwoDays() {
        let short = claude("shortlived", days: [1, 2], minutes: 20)           // 40 min
        let oneDay = claude("oneday", days: [1], minutes: 90)                  // 90 min, one day
        let ok = claude("steady", days: [1, 2], minutes: 35)                   // 70 min, two days
        let result = ProjectSuggester.suggest(short + oneDay + ok + filler(days: [1, 2, 3]), calendar: calendar)
        XCTAssertEqual(result.candidates.map(\.name), ["steady"])
        XCTAssertEqual(result.todoCandidate, nil, "two days is not enough for Today to speak up")
    }

    func testAtMostEightAndExistingProjectsAreLeftOut() {
        let many = (0..<10).flatMap { claude("proj\($0)", days: [1, 2, 3], minutes: Double(30 + $0)) }
        let all = ProjectSuggester.suggest(many + filler(days: [1, 2, 3]), calendar: calendar).candidates
        XCTAssertEqual(all.count, 8)
        XCTAssertEqual(all.first?.name, "proj9", "longest first")
        let without = ProjectSuggester.suggest(many + filler(days: [1, 2, 3]), existing: ["Proj9"], calendar: calendar).candidates
        XCTAssertFalse(without.contains { $0.name == "proj9" })
    }

    // MARK: Today

    func testTheTodoComesFromTheNewProjectAndOnlyToday() throws {
        let overview = DayOverview(items: [], categories: [:], sessions: [], now: at(day: 1, 12), calendar: calendar)
        func build(isToday: Bool, newProject: String?) -> [TodayPlan.Todo] {
            TodayPlan.build(overview: overview, sessions: [], explicit: [], episodes: [], notes: [], categories: [:], lastFocus: nil,
                            hasFocusToday: true, isToday: isToday, newProject: newProject, calendar: calendar).todos
        }
        XCTAssertEqual(build(isToday: true, newProject: "alpha").map(\.id), ["project|alpha"])
        XCTAssertTrue(build(isToday: false, newProject: "alpha").isEmpty)
        XCTAssertTrue(build(isToday: true, newProject: nil).isEmpty)
    }

    // MARK: Hours per project, off the main actor

    @MainActor private func hoursModel() throws -> (AppModel, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db), categories = CategoryStore(db), settings = SettingsStore(db)
        let model = AppModel(categoryStore: categories, spanStore: spans, settings: settings,
                             resolver: CategoryResolver(categoryStore: categories), engine: TrackerEngine(spanStore: spans, settings: settings))
        model.observationStore = ObservationStore(db)
        return (model, spans)
    }

    @MainActor func testHoursPerProjectAreWorkedOutOnceAndReusedUntilSomethingChanges() async throws {
        let (model, spans) = try hoursModel()
        let alpha = try model.categoryStore.projects.add(name: "Alpha")
        model.reloadProjects()
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86400)).addingTimeInterval(10 * 3600)
        let home = DocumentIdentity.homePath
        _ = try spans.insert(Span(start: start, end: start.addingTimeInterval(1800), appBundleID: "com.test.term", appName: "Terminal",
                                  title: nil, url: nil, domain: nil, document: "file://\(home)/Projects/alpha/"))
        let first = await model.projectHours()
        XCTAssertEqual(first["alpha"] ?? 0, 1800, accuracy: 1, "the repo label shows as the project named Alpha")
        let again = await model.projectHours()
        XCTAssertEqual(again, first)
        XCTAssertEqual(model.projectHoursComputations, 1, "the second ask came from the cache")
        // An engine write alone does not drop it; a project change does.
        model.dataVersion += 1
        _ = await model.projectHours()
        XCTAssertEqual(model.projectHoursComputations, 1)
        try model.categoryStore.projects.update(id: alpha.id, name: "Alpha", description: "now described")
        model.projectsChanged()
        _ = await model.projectHours()
        XCTAssertEqual(model.projectHoursComputations, 2)
        // So does one of your edits.
        model.dataChanged()
        _ = await model.projectHours()
        XCTAssertEqual(model.projectHoursComputations, 3)
    }

    @MainActor func testTwoAsksAtOnceShareOnePass() async throws {
        let (model, _) = try hoursModel()
        async let a = model.projectHours()
        async let b = model.projectHours()
        _ = await (a, b)
        XCTAssertEqual(model.projectHoursComputations, 1)
    }

    @MainActor func testTheNewProjectTodoArrivesWithoutRebuildingThePlan() {
        var plan = TodayPlan.build(overview: DayOverview(items: [], categories: [:], sessions: [], now: at(day: 1, 12), calendar: calendar),
                                   sessions: [], explicit: [], episodes: [], notes: [], categories: [:], lastFocus: nil,
                                   hasFocusToday: false, isToday: true, calendar: calendar)
        XCTAssertEqual(plan.todos.map(\.id), ["focus"])
        plan.setNewProject("alpha")
        XCTAssertEqual(plan.todos.map(\.id), ["project|alpha", "focus"])
        plan.setNewProject("beta")
        XCTAssertEqual(plan.todos.map(\.id), ["project|beta", "focus"])
        plan.setNewProject(nil)
        XCTAssertEqual(plan.todos.map(\.id), ["focus"])
    }

    // MARK: Today and the judgements arriving

    func testABlockWaitsForJevOnlyWithoutAProject() {
        func plan(explicit: String?, pending: Bool) -> TodayPlan.Row {
            let s = WorkSession(start: at(day: 1, 9), end: at(day: 1, 10), recorded: 3600, categoryID: "dev", project: nil, projectLabel: nil,
                                projectPending: pending, apps: [], titles: [], documents: [])
            let overview = DayOverview(items: [], categories: [:], sessions: [], now: at(day: 1, 12), calendar: calendar)
            return TodayPlan.build(overview: overview, sessions: [s], explicit: [explicit], episodes: [], notes: [], categories: [:], lastFocus: nil,
                                   hasFocusToday: true, isToday: false, calendar: calendar).rows[0]
        }
        XCTAssertTrue(plan(explicit: nil, pending: true).projectPending)
        XCTAssertFalse(plan(explicit: "Alpha", pending: true).projectPending)
        XCTAssertFalse(plan(explicit: nil, pending: false).projectPending)
    }

    @MainActor func testVerdictsArrivingFromTheWorkerRedrawTheSessions() async throws {
        let (model, spans) = try hoursModel()
        let alpha = try model.categoryStore.projects.add(name: "Alpha")
        model.reloadProjects()
        let day = Calendar.current.dateInterval(of: .day, for: Date().addingTimeInterval(-86400))!
        let start = day.start.addingTimeInterval(10 * 3600)
        _ = try spans.insert(Span(start: start, end: start.addingTimeInterval(1200), appBundleID: "com.test.app", appName: "App",
                                  title: "work", url: nil, domain: "work.example"))
        let settings = model.settings
        settings.setJevEnabled(true)
        model.resolver.jevEnabled = true
        model.resolver.refreshProjectVerdicts()
        let before = await model.sessions(for: day)
        XCTAssertEqual(before.map(\.projectPending), [true], "nothing judged yet")
        XCTAssertEqual(model.sessionProject(before[0]), nil)

        let transport = ProjectStubTransport { _, _ in (alpha.id, [alpha.id: 0.9]) }
        let jev = JevService(categoryStore: model.categoryStore, settings: settings, resolver: model.resolver, transport: transport, apiKey: { "k" })
        jev.onChange = { [weak model] in model?.dataChanged() }
        let edits = model.dataEditVersion
        jev.start()
        jev.nudge()
        for _ in 0..<200 where model.dataEditVersion == edits { try await Task.sleep(for: .milliseconds(50)) }
        jev.stop()
        XCTAssertGreaterThan(model.dataEditVersion, edits, "the worker's verdicts bump the version the caches are keyed on")
        let after = await model.sessions(for: day)
        XCTAssertEqual(after.map(\.projectPending), [false])
        XCTAssertEqual(model.sessionProject(after[0]), "Alpha")
    }
}

/// A project's colour is stored (v20): the migration, creation, and what the pages read.
final class ProjectColorTests: XCTestCase {
    private func store(_ db: DatabaseQueue) -> ProjectStore { ProjectStore(db) }

    func testMigrationGivesExistingProjectsDistinctColoursAndIsRepeatable() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db, upTo: "v19")
        // Eight live projects whose names propose colours that collide, plus an archived one.
        let names = (0..<8).map { "project \($0)" } + ["archived one"]
        try db.write { db in
            for (index, name) in names.enumerated() {
                try db.execute(sql: "INSERT INTO project (id, name, description, sortOrder, source, archived, createdAt) VALUES (?, ?, '', ?, 'user', ?, ?)",
                               arguments: ["p-\(index)", name, index, index == 8, Date()])
            }
        }
        try AppDatabase.migrator.migrate(db)
        let live = try db.read { try Int.fetchAll($0, sql: "SELECT colorIndex FROM project WHERE archived = 0 ORDER BY sortOrder") }
        XCTAssertEqual(Set(live).count, 8)
        XCTAssertEqual(Set(live), Set(0..<8))
        XCTAssertEqual(live[0], ProjectPalette.preferredSlot("project 0"))
        let archived = try db.read { try Int.fetchOne($0, sql: "SELECT colorIndex FROM project WHERE archived = 1") }
        XCTAssertNotNil(archived)
        // A second run changes nothing.
        try AppDatabase.migrator.migrate(db)
        let again = try db.read { try Int.fetchAll($0, sql: "SELECT colorIndex FROM project WHERE archived = 0 ORDER BY sortOrder") }
        XCTAssertEqual(live, again)
    }

    func testANewProjectTakesAFreeColourUntilAllEightAreUsed() throws {
        let projects = store(try AppDatabase.openInMemory())
        var colours: [Int] = []
        for index in 0..<8 { colours.append(try projects.add(name: "p\(index)").colorIndex!) }
        XCTAssertEqual(Set(colours), Set(0..<8))
        // The ninth shares: its own proposal.
        XCTAssertEqual(try projects.add(name: "ninth").colorIndex, ProjectPalette.preferredSlot("ninth"))
    }

    func testRenameKeepsTheColourAndMergeKeepsTheSurvivors() throws {
        let projects = store(try AppDatabase.openInMemory())
        let a = try projects.add(name: "Alpha"), b = try projects.add(name: "Beta")
        try projects.setColor(id: a.id, index: 6)
        try projects.update(id: a.id, name: "Alpha 2", description: "")
        XCTAssertEqual(try projects.list().first { $0.id == a.id }?.colorIndex, 6)
        try projects.merge(a.id, into: b.id)
        XCTAssertEqual(try projects.list().map(\.colorIndex), [b.colorIndex])
    }

    func testRestoringAnArchivedProjectKeepsItsColourUnlessTaken() throws {
        let projects = store(try AppDatabase.openInMemory())
        let a = try projects.add(name: "Alpha")
        try projects.archive(a.id)
        XCTAssertEqual(try projects.add(name: "Alpha").colorIndex, a.colorIndex)
        try projects.archive(a.id)
        let other = try projects.add(name: "Other")
        try projects.setColor(id: other.id, index: a.colorIndex!)
        XCTAssertNotEqual(try projects.add(name: "Alpha").colorIndex, a.colorIndex)
    }

    func testProjectsPageAndTodayAgree() throws {
        let projects = store(try AppDatabase.openInMemory())
        let a = try projects.add(name: "TimeSink"), b = try projects.add(name: "Drum Machine Pro")
        XCTAssertNotEqual(a.colorIndex, b.colorIndex)
        try projects.setColor(id: b.id, index: 2)
        let lookup = ProjectPalette.lookup(try projects.list())
        XCTAssertEqual(lookup["timesink"], a.colorIndex)
        XCTAssertEqual(lookup[SessionProjectResolver.normalized("Drum Machine Pro")], 2)
    }
}
