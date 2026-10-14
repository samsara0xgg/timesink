import XCTest
@testable import TimeSinkKit

final class TodayPlanTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }
    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: hour, minute: minute))!
    }
    private var day: DateInterval { calendar.dateInterval(of: .day, for: date(12))! }
    private let categories: [String: TimeSinkKit.Category] = [
        "dev": .init(id: "dev", name: "开发", colorHex: "#3478F6", productivity: 2, sortOrder: 0),
        "chat": .init(id: "chat", name: "沟通", colorHex: "#FF9F0A", productivity: 0, sortOrder: 1),
        "uncategorized": .init(id: "uncategorized", name: "未分类", colorHex: "#C7C7CC", productivity: 0, sortOrder: 2)
    ]

    private func session(_ from: Date, _ to: Date, category: String = "dev") -> WorkSession {
        WorkSession(start: from, end: to, recorded: to.timeIntervalSince(from), categoryID: category, project: nil,
                    projectLabel: nil, apps: [], titles: [], documents: [])
    }
    private func item(_ from: Date, _ to: Date, app: String = "editor", category: String = "dev") -> CategorizedSpan {
        .init(span: Span(start: from, end: to, appBundleID: app, appName: app, title: nil, url: nil, domain: nil), categoryID: category)
    }

    // MARK: Palette

    func testAProjectKeepsItsColourAndIgnoresCase() {
        XCTAssertEqual(ProjectPalette.preferredSlot("TimeSink"), ProjectPalette.preferredSlot("timesink"))
        XCTAssertEqual(ProjectPalette.preferredSlot("jarvis"), ProjectPalette.preferredSlot("jarvis"))
        XCTAssertTrue((0..<ProjectPalette.slots).contains(ProjectPalette.preferredSlot("求职申请")))
    }

    func testANewProjectTakesItsPreferredSlotIfFreeElseTheFirstFreeOne() {
        let preferred = ProjectPalette.preferredSlot("jarvis")
        XCTAssertEqual(ProjectPalette.slot(for: "jarvis", taken: []), preferred)
        let next = ProjectPalette.slot(for: "jarvis", taken: [preferred])
        XCTAssertNotEqual(next, preferred)
        XCTAssertEqual(next, (0..<ProjectPalette.slots).first { $0 != preferred })
        // All eight in use: the preferred one again.
        XCTAssertEqual(ProjectPalette.slot(for: "jarvis", taken: Set(0..<ProjectPalette.slots)), preferred)
    }

    func testTodayReadsTheStoredColourNotTheDaysOrder() {
        let items = [item(date(9), date(10)), item(date(14), date(15))]
        let overview = DayOverview(items: items, categories: categories, sessions: [], now: date(16), calendar: calendar)
        let sessions = [session(date(9), date(10)), session(date(14), date(15))]
        let plan = TodayPlan.build(overview: overview, sessions: sessions, explicit: ["TimeSink", "unknown"], episodes: [], notes: [],
                                   categories: categories, lastFocus: nil, hasFocusToday: false, isToday: true,
                                   colors: ["timesink": 5], calendar: calendar)
        XCTAssertEqual(plan.rows.map(\.slot), [5, ProjectPalette.preferredSlot("unknown")])
    }

    // MARK: Guess

    func testAnUnnamedSessionTakesTheProjectOfAnAdjacentOneAndIsMarkedGuessed() {
        let sessions = [session(date(9), date(10)), session(date(10, 5), date(11)), session(date(11, 10), date(12))]
        let resolved = ProjectGuess.resolve(sessions, explicit: ["timesink", nil, nil])
        XCTAssertEqual(resolved, [.init(project: "timesink", guessed: false), .init(project: "timesink", guessed: true),
                                  .init(project: "timesink", guessed: true)])
    }

    func testNothingIsGuessedAcrossADifferentKindOfWorkOrALongGap() {
        let sessions = [session(date(9), date(10)), session(date(10, 5), date(11), category: "chat"), session(date(14), date(15))]
        let resolved = ProjectGuess.resolve(sessions, explicit: ["timesink", nil, nil])
        XCTAssertEqual(resolved.map(\.project), ["timesink", nil, nil])
        XCTAssertFalse(resolved.contains { $0.guessed })
    }

    func testARunOfUnknownsTakesTheProjectFromTheEndThatHasOne() {
        let sessions = [session(date(9), date(10)), session(date(10, 5), date(11)), session(date(11, 5), date(12))]
        let resolved = ProjectGuess.resolve(sessions, explicit: [nil, nil, "jarvis"])
        XCTAssertEqual(resolved.map(\.project), ["jarvis", "jarvis", "jarvis"])
        XCTAssertEqual(resolved.map(\.guessed), [true, true, false])
    }

    // MARK: Gaps, axis, switches

    func testGapsBetweenSessionsAndTheStretchSinceTheLastOne() {
        let sessions = [session(date(9), date(10)), session(date(10, 3), date(11)), session(date(13), date(14))]
        let gaps = TodayPlan.gaps(sessions, now: date(16), isToday: true)
        // Three minutes is not a gap; two hours is; 14:00 to 16:00 is still going.
        XCTAssertEqual(gaps.map(\.interval), [DateInterval(start: date(11), end: date(13)), DateInterval(start: date(14), end: date(16))])
        XCTAssertEqual(gaps.map(\.ongoing), [false, true])
        XCTAssertEqual(TodayPlan.gaps(sessions, now: date(14, 2), isToday: true).count, 1)
        XCTAssertEqual(TodayPlan.gaps(sessions, now: date(23), isToday: false).count, 1)
    }

    func testTheAxisStartsAtEightOrTheHourOfAnEarlierSession() {
        XCTAssertEqual(TodayPlan.axis([session(date(9, 22), date(10))], day: day, calendar: calendar).start, date(8))
        XCTAssertEqual(TodayPlan.axis([session(date(6, 40), date(7, 30)), session(date(9), date(10))], day: day, calendar: calendar).start, date(6))
        XCTAssertEqual(TodayPlan.axis([session(date(9), date(10))], day: day, calendar: calendar).end, day.end)
        // A session carried over from last night does not drag the axis to midnight.
        XCTAssertEqual(TodayPlan.axis([session(day.start, date(1, 19)), session(date(9), date(10))], day: day, calendar: calendar).start, date(8))
    }

    func testSwitchesCountChangesOfWindowInsideTheSession() {
        let items = [item(date(9), date(9, 10), app: "a"), item(date(9, 10), date(9, 20), app: "b"), item(date(9, 20), date(9, 30), app: "a"),
                     item(date(9, 30), date(9, 40), app: "a"), item(date(11), date(11, 10), app: "c")]
        XCTAssertEqual(TodayPlan.switches(in: DateInterval(start: date(9), end: date(10)), items: items), 2)
        XCTAssertEqual(TodayPlan.switches(in: DateInterval(start: date(11), end: date(12)), items: items), 0)
    }

    // MARK: Build

    func testBuildGroupsProjectsAndListsWhatNeedsAnswering() {
        let items = [item(date(9), date(10)), item(date(10, 5), date(11)), item(date(14), date(15)),
                     item(date(15), date(15, 30), app: "browser", category: "uncategorized")]
        let overview = DayOverview(items: items, categories: categories, sessions: [], now: date(16), calendar: calendar)
        let sessions = [session(date(9), date(11)), session(date(14), date(15)), session(date(15), date(15, 30), category: "uncategorized")]
        let plan = TodayPlan.build(overview: overview, sessions: sessions, explicit: ["timesink", nil, nil], episodes: [], notes: [],
                                   categories: categories, lastFocus: nil, hasFocusToday: false, isToday: true, calendar: calendar)
        XCTAssertEqual(plan.projects.map(\.name), ["timesink", nil])
        XCTAssertEqual(plan.rows.map(\.guessed), [false, false, false])
        // 11:00 to 14:00 away, uncategorised time to classify, no focus today.
        XCTAssertEqual(plan.todos.map(\.id).count, 3)
        XCTAssertTrue(plan.todos.contains { if case .fill(let gap) = $0 { return gap == DateInterval(start: date(11), end: date(14)) } else { return false } })
        XCTAssertTrue(plan.todos.contains { if case .classify(let seconds, let names) = $0 { return seconds == 1800 && names == ["browser"] } else { return false } })
        XCTAssertEqual(plan.total, 3600 + 3300 + 3600 + 1800)
    }

    func testAnAwayNoteTakesTheGapOffTheList() {
        let items = [item(date(9), date(10)), item(date(13), date(14))]
        let overview = DayOverview(items: items, categories: categories, sessions: [], now: date(15), calendar: calendar)
        let sessions = [session(date(9), date(10)), session(date(13), date(14))]
        let note = AwayNote(start: date(10), end: date(12, 40), label: "午饭", symbol: "fork.knife")
        let plan = TodayPlan.build(overview: overview, sessions: sessions, explicit: [nil, nil], episodes: [], notes: [note],
                                   categories: categories, lastFocus: nil, hasFocusToday: true, isToday: true, calendar: calendar)
        XCTAssertTrue(plan.todos.isEmpty)
    }

    func testPastDaysNeverAskForFocus() {
        let overview = DayOverview(items: [item(date(9), date(10))], categories: categories, sessions: [], now: date(23, 59), calendar: calendar)
        let plan = TodayPlan.build(overview: overview, sessions: [session(date(9), date(10))], explicit: ["a"], episodes: [], notes: [],
                                   categories: categories, lastFocus: nil, hasFocusToday: false, isToday: false, calendar: calendar)
        XCTAssertFalse(plan.todos.contains { if case .focus = $0 { return true } else { return false } })
        XCTAssertFalse(plan.currentIsLive)
    }

    // MARK: Lanes

    private func row(_ name: String, _ seconds: TimeInterval) -> TodayPlan.CategoryRow {
        .init(id: name, name: name, colorHex: "#000000", seconds: seconds, engaged: false)
    }

    /// Each category its own lane, the biggest first; a run is cut where
    /// another category held the window, and a glance shorter than the bridge is not.
    func testLanesSplitARunWhereAnotherCategoryInterrupts() {
        let items = [
            item(date(9), date(9, 40)),
            item(date(9, 40), date(9, 47), category: "chat"),       // seven minutes of chat: a real interruption
            item(date(9, 47), date(10, 30)),
            item(date(10, 30), date(10, 30).addingTimeInterval(20), category: "chat"),  // a glance
            item(date(10, 30).addingTimeInterval(20), date(11)),
        ]
        let lanes = TodayPlan.lanes(items: items, categories: [row("chat", 7 * 60 + 20), row("dev", 113 * 60)])
        XCTAssertEqual(lanes.map(\.id), ["dev", "chat"])
        XCTAssertEqual(lanes[0].runs.map(\.start), [date(9), date(9, 47)])
        XCTAssertEqual(lanes[0].runs.last?.end, date(11))
        let devSeconds: TimeInterval = lanes[0].runs.map(\.seconds).reduce(0, +)
        let expected: TimeInterval = 112 * 60 + 40  // 40 + 43 + 29 minutes, and 40 seconds
        XCTAssertEqual(devSeconds, expected)
        XCTAssertEqual(lanes[1].runs.count, 2)
    }

    /// Past the limit, the smallest categories share one lane and keep their own colours.
    func testSmallCategoriesShareTheOtherLane() {
        let names = ["a", "b", "c", "d", "e", "f"]
        var items: [CategorizedSpan] = []
        var rows: [TodayPlan.CategoryRow] = []
        for (i, name) in names.enumerated() {
            let minutes = 55 - i * 5
            items.append(item(date(8 + i), date(8 + i, minutes), category: name))
            rows.append(row(name, TimeInterval(minutes * 60)))
        }
        let lanes = TodayPlan.lanes(items: items, categories: Array(rows.reversed()))
        XCTAssertEqual(lanes.map(\.id), ["a", "b", "c", "d", TodayPlan.Lane.otherID])
        let otherSeconds: TimeInterval = 65 * 60  // e 35 minutes, f 30
        XCTAssertEqual(lanes.last?.seconds, otherSeconds)
        XCTAssertEqual(lanes.last?.runs.map(\.categoryID), ["e", "f"])

        // One category more than the limit gets a lane of its own instead.
        let five = TodayPlan.lanes(items: Array(items.prefix(5)), categories: Array(rows.prefix(5)))
        XCTAssertEqual(five.map(\.id), ["a", "b", "c", "d", "e"])
    }

    /// At a timeline's scale, runs closer than a legible mark are drawn as one,
    /// in the colour of whichever category holds most of it.
    func testFoldJoinsRunsCloserThanAMark() {
        let runs = [
            TodayPlan.Lane.Run(start: date(9), end: date(9, 2), seconds: 120, categoryID: "e"),
            TodayPlan.Lane.Run(start: date(9, 3), end: date(9, 13), seconds: 600, categoryID: "f"),
            TodayPlan.Lane.Run(start: date(10), end: date(10, 1), seconds: 60, categoryID: "e"),
        ]
        let folded = TodayPlan.fold(runs, gap: 120)
        XCTAssertEqual(folded.count, 2)
        XCTAssertEqual(folded[0].end, date(9, 13))
        XCTAssertEqual(folded[0].seconds, 720)
        XCTAssertEqual(folded[0].categoryID, "f")
        XCTAssertEqual(folded[1].categoryID, "e")
    }

    /// By project: each project's sessions in its lane, then time with no project.
    func testProjectLanesPutUnassignedTimeLast() {
        let items = [item(date(9), date(10)), item(date(10, 30), date(11), category: "chat"), item(date(13), date(14))]
        let overview = DayOverview(items: items, categories: categories, sessions: [], now: date(15), calendar: calendar)
        let sessions = [session(date(9), date(10)), session(date(10, 30), date(11), category: "chat"), session(date(13), date(14))]
        let plan = TodayPlan.build(overview: overview, sessions: sessions, explicit: ["TimeSink", nil, "Jarvis"], episodes: [], notes: [],
                                   categories: categories, lastFocus: nil, hasFocusToday: true, isToday: true, calendar: calendar)
        let lanes = plan.projectLanes
        XCTAssertEqual(lanes.map(\.id), ["Jarvis", "TimeSink", TodayPlan.Lane.noProjectID])
        XCTAssertEqual(lanes.last?.runs.map(\.start), [date(10, 30)])
        XCTAssertEqual(plan.lanes.map(\.id), ["dev", "chat"])
    }
}
