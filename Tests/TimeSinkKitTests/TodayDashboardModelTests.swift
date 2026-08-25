import XCTest
@testable import TimeSinkKit

final class TodayDashboardModelTests: XCTestCase {
    func testStreakCountsTrailingDaysAtOrAboveThreshold() {
        // 数组末位是今天
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [60, 72, 75, 71], threshold: 70), 3)
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [72, 65], threshold: 70), 0)
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [], threshold: 70), 0)
        // 无数据的天（nil，例如没开机）终止连续
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [80, nil, 75, 80], threshold: 70), 2)
    }

    func testDailyPulsesSplitsAcrossDays() {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        // 昨天一段纯生产力（softwareDev, +2 -> 100 分），今天一段纯娱乐（-2 -> 0 分）
        let categories = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        let items = [
            CategorizedSpan(span: Span(start: todayStart.addingTimeInterval(-3600),
                                       end: todayStart.addingTimeInterval(-1800),
                                       appBundleID: "a", appName: "a", title: nil, url: nil, domain: nil),
                            categoryID: "softwareDev"),
            CategorizedSpan(span: Span(start: todayStart.addingTimeInterval(600),
                                       end: todayStart.addingTimeInterval(1200),
                                       appBundleID: "b", appName: "b", title: nil, url: nil, domain: nil),
                            categoryID: "entertainment"),
        ]
        let pulses = TodayDashboardModel.dailyPulses(
            items: items, categories: categories, days: 2, endingAt: now, calendar: calendar)
        XCTAssertEqual(pulses.count, 2)
        XCTAssertEqual(pulses[0], 100) // 昨天
        XCTAssertEqual(pulses[1], 0)   // 今天
    }

    /// CONTROLLER RULING 14: yesterday's spans must be clipped to the same
    /// elapsed time-of-day as today before comparing, not compared as a full
    /// day. A span straddling the clip boundary contributes only its inside
    /// portion; a span entirely after the boundary contributes nothing.
    func testClippedToElapsedKeepsOnlyThePortionInsideTheWindow() {
        let windowStart = ts(0)
        let straddling = CategorizedSpan(
            span: Span(start: ts(3000), end: ts(4200), appBundleID: "a", appName: "a",
                       title: nil, url: nil, domain: nil),
            categoryID: "softwareDev")
        let after = CategorizedSpan(
            span: Span(start: ts(4000), end: ts(4800), appBundleID: "b", appName: "b",
                       title: nil, url: nil, domain: nil),
            categoryID: "softwareDev")

        let result = TodayDashboardModel.clippedToElapsed(
            [straddling, after], windowStart: windowStart, elapsed: 3600)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].span.start, ts(3000))
        XCTAssertEqual(result[0].span.end, ts(3600)) // clipped at windowStart + elapsed
    }

    /// C1+ 分数环 hover 下钻子窗的数据源：每分类的贡献 (seconds * points)
    /// 降序，points 复用 pulse 公式的每分类换算（+2 → 100，-2 → 0），share 为
    /// 该分类占当日总时长的比例。
    func testScoreContributions() {
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        let rows = TodayDashboardModel.scoreContributions(
            byCategory: ["softwareDev": 3600, "entertainment": 1800], categories: cats)
        XCTAssertEqual(rows[0].id, "softwareDev")                 // 贡献降序
        XCTAssertEqual(rows[0].points, 100)                       // +2 → 100
        XCTAssertEqual(rows[0].share, 3600.0/5400.0, accuracy: 0.001)
        XCTAssertEqual(rows[1].points, 0)                         // -2 → 0
    }

    // MARK: - Fix round 1 (F5/F6): mutation-resistant coverage

    /// F5: kills a "sort by raw seconds" mutant AND a "sort by raw points"
    /// mutant -- both agree with `midPoints` for a plain-seconds OR
    /// plain-points sort here, but neither matches the correct
    /// `seconds * points` (contribution) order, which puts `midPoints`
    /// first.
    func testScoreContributionsSortsByWeightedContributionNotByRawDurationOrPoints() {
        let cats: [String: TimeSinkKit.Category] = [
            "highPoints": TimeSinkKit.Category(id: "highPoints", name: "High", colorHex: "#000000", productivity: 2, sortOrder: 0),
            "lowPoints": TimeSinkKit.Category(id: "lowPoints", name: "Low", colorHex: "#000000", productivity: -2, sortOrder: 1),
            "midPoints": TimeSinkKit.Category(id: "midPoints", name: "Mid", colorHex: "#000000", productivity: 0, sortOrder: 2),
        ]
        let byCategory: [String: TimeInterval] = [
            "highPoints": 100,      // points 100 -> contribution 10_000
            "lowPoints": 100_000,   // points 0   -> contribution 0
            "midPoints": 300,       // points 50  -> contribution 15_000
        ]
        let rows = TodayDashboardModel.scoreContributions(byCategory: byCategory, categories: cats)
        // A pure-seconds sort would put "lowPoints" first; a pure-points
        // sort would put "highPoints" first. Only seconds*points matches
        // this order.
        XCTAssertEqual(rows.map(\.id), ["midPoints", "highPoints", "lowPoints"])
    }

    /// F5/F6 (R-T13a): equal contributions tiebreak by `seconds` descending,
    /// THEN `id` ascending -- an id-only tiebreak (pre-fix behavior) would
    /// put "aaaLowerSeconds" first (alphabetically first); the more-duration
    /// row should win the tie instead.
    func testScoreContributionsTiebreaksBySecondsThenID() {
        let cats: [String: TimeSinkKit.Category] = [
            "aaaLowerSeconds": TimeSinkKit.Category(id: "aaaLowerSeconds", name: "A", colorHex: "#000000", productivity: 2, sortOrder: 0),
            "zzzHigherSeconds": TimeSinkKit.Category(id: "zzzHigherSeconds", name: "Z", colorHex: "#000000", productivity: 0, sortOrder: 1),
        ]
        let byCategory: [String: TimeInterval] = [
            "aaaLowerSeconds": 100,   // points 100 -> contribution 10_000
            "zzzHigherSeconds": 200,  // points 50  -> contribution 10_000
        ]
        let rows = TodayDashboardModel.scoreContributions(byCategory: byCategory, categories: cats)
        XCTAssertEqual(rows.map(\.id), ["zzzHigherSeconds", "aaaLowerSeconds"])
    }

    /// F5: zero total tracked time (empty dict, or a single all-zero entry)
    /// returns `[]` -- no division by zero, no spurious rows.
    func testScoreContributionsReturnsEmptyForZeroTotal() {
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        XCTAssertTrue(TodayDashboardModel.scoreContributions(byCategory: [:], categories: cats).isEmpty)
        XCTAssertTrue(TodayDashboardModel.scoreContributions(byCategory: ["softwareDev": 0], categories: cats).isEmpty)
    }

    /// F5: a `byCategory` key with no matching `Category` (e.g. a category
    /// deleted out from under stale data -- no such delete path exists
    /// today, but the `compactMap` silently drops it either way) is pinned
    /// as-is: the unknown row is dropped, but its seconds still count
    /// toward the denominator -- `share` for the surviving known category is
    /// NOT renormalized to 100%.
    func testScoreContributionsDropsUnknownCategoryWithoutRenormalizingShare() {
        let cats = ["known": TimeSinkKit.Category(id: "known", name: "Known", colorHex: "#000000", productivity: 2, sortOrder: 0)]
        let rows = TodayDashboardModel.scoreContributions(byCategory: ["known": 1000, "ghost": 4000], categories: cats)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "known")
        XCTAssertEqual(rows[0].share, 1000.0 / 5000.0, accuracy: 0.001)
    }

    /// F5: agreement test (same pattern as `TitleRuleTests
    /// .testCompiledTitleRuleAgreesWithTitleMatches`) -- `TodayDashboardModel`
    /// and `Aggregator` each carry their OWN private copy of the
    /// productivity->points formula (+2 -> 100, -2 -> 0, linear between,
    /// clamped). Neither is directly callable from here, so this compares
    /// them indirectly: with exactly one category making up the whole
    /// tracked total, `Aggregator.pulse`'s rounded result and
    /// `scoreContributions`'s raw `points` (rounded) must always agree.
    func testScoreContributionsPointsAgreesWithAggregatorPulseAcrossProductivityRange() {
        for productivity in -3...3 {
            let categories = ["x": TimeSinkKit.Category(id: "x", name: "X", colorHex: "#000000", productivity: productivity, sortOrder: 0)]
            let byCategory: [String: TimeInterval] = ["x": 100]

            let points = TodayDashboardModel.scoreContributions(byCategory: byCategory, categories: categories).first?.points
            let pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories)

            XCTAssertEqual(points.map { Int($0.rounded()) }, pulse,
                            "productivity \(productivity): scoreContributions points \(String(describing: points)) disagrees with Aggregator.pulse \(String(describing: pulse))")
        }
    }

    // MARK: - Fix round 1 (F5): `recompute()` integration coverage
    //
    // `AppModelCacheTests.makeModel()`'s in-memory-DB fixture pattern
    // (`AppDatabase.openInMemory()` already seeds `Taxonomy.categories` via
    // migration -- no `SeedImporter` call needed).

    @MainActor
    private func makeDashboardAppModel() throws -> (AppModel, SpanStore, BudgetStore) {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let settings = SettingsStore(db)
        let model = AppModel(categoryStore: categoryStore, spanStore: spanStore, settings: settings,
                              resolver: CategoryResolver(categoryStore: categoryStore),
                              engine: TrackerEngine(spanStore: spanStore, settings: settings))
        let budgetStore = BudgetStore(db)
        model.budgetStore = budgetStore
        return (model, spanStore, budgetStore)
    }

    /// F5: `budgetRows` (the popover's tightest-2) must always be exactly
    /// `Array(allBudgetRows.prefix(2))` (the drill-down's full list) -- both
    /// sliced from the SAME sorted list in `recompute`, guarding against a
    /// future refactor that decouples them.
    @MainActor
    func testRecomputeBudgetRowsIsPrefixOfAllBudgetRows() throws {
        let (model, _, budgetStore) = try makeDashboardAppModel()
        // Three enabled budgets so the tightest-2 is a STRICT prefix of the
        // full list (`setBudget` enables a brand-new row by default).
        try budgetStore.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        try budgetStore.setBudget(categoryID: "socialMedia", dailySeconds: 1800)
        try budgetStore.setBudget(categoryID: "news", dailySeconds: 2700)

        let dashboard = TodayDashboardModel()
        dashboard.recompute(model: model, forceStreak: true)

        XCTAssertEqual(dashboard.allBudgetRows.count, 3)
        XCTAssertEqual(dashboard.budgetRows.count, 2)
        XCTAssertEqual(dashboard.budgetRows.map(\.id), Array(dashboard.allBudgetRows.prefix(2)).map(\.id))
    }

    /// F5: `streakLookbackPulses`'s TAIL (index 29, "today") must equal
    /// `dashboard.pulse` for today, and `streak(dailyPulses:
    /// streakLookbackPulses, ...)` must equal `dashboard.streakDays` --
    /// both are derived from the same 30-day lookback in
    /// `refreshStreakIfDayChanged`, so this pins that they stay aligned
    /// (index-order and value) if that method is ever refactored.
    @MainActor
    func testRecomputeStreakLookbackPulsesTailMatchesTodayAndAgreesWithStreakDays() throws {
        let (model, spanStore, _) = try makeDashboardAppModel()
        let todayStart = Calendar.current.startOfDay(for: Date())
        // com.apple.dt.Xcode -> softwareDev (builtin app map), the sole
        // category tracked today: productivity +2 -> pulse 100.
        try spanStore.insert(Span(start: todayStart.addingTimeInterval(3600), end: todayStart.addingTimeInterval(4200),
                                   appBundleID: "com.apple.dt.Xcode", appName: "Xcode",
                                   title: nil, url: nil, domain: nil))

        let dashboard = TodayDashboardModel()
        dashboard.recompute(model: model, forceStreak: true)

        XCTAssertEqual(dashboard.pulse, 100)
        XCTAssertEqual(dashboard.streakLookbackPulses.count, 30)
        XCTAssertEqual(dashboard.streakLookbackPulses.last ?? nil, dashboard.pulse)
        XCTAssertEqual(
            TodayDashboardModel.streak(dailyPulses: dashboard.streakLookbackPulses, threshold: TodayDashboardModel.streakThreshold),
            dashboard.streakDays)
    }

    // Not added: a unit test for `CompareBaseView.yesterdayValue`
    // (`todayValue - delta`). It's a private computed property on a plain
    // SwiftUI view (no automated-test mandate for UI files, per this
    // codebase's convention), and the formula itself is a one-line
    // arithmetic identity with no branching to pin beyond what the type
    // checker already guarantees -- a test would either need to expose
    // internal view state purely for test access, or restate the exact
    // same expression the source uses (a tautology, not a check).
}
