import XCTest
@testable import TimeSinkKit

@MainActor
final class BudgetTests: XCTestCase {
    func testLevelThresholds() {
        XCTAssertEqual(BudgetEngine.level(spent: 0, limit: 3600, warnPercent: 20), .none)
        XCTAssertEqual(BudgetEngine.level(spent: 2879, limit: 3600, warnPercent: 20), .none)
        XCTAssertEqual(BudgetEngine.level(spent: 2880, limit: 3600, warnPercent: 20), .warn)   // 80%
        XCTAssertEqual(BudgetEngine.level(spent: 3600, limit: 3600, warnPercent: 20), .limit)
        XCTAssertEqual(BudgetEngine.level(spent: 100, limit: 0, warnPercent: 20), .none)       // 无效预算不炸
    }
    func testDayStampIsLocalCalendar() {
        let cal = Calendar.current
        let d = cal.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 0, minute: 5))!
        XCTAssertEqual(BudgetEngine.dayStamp(d, calendar: cal), "2026-08-24")  // 本地 0:05 不回滚昨天
    }
    func makeMonitor() throws -> (BudgetMonitor, BudgetStore, SpyNotifier, SettingsStore) {
        let db = try AppDatabase.openInMemory()
        let store = BudgetStore(db)
        let settings = SettingsStore(db)
        let spy = SpyNotifier()
        return (BudgetMonitor(budgetStore: store, settings: settings, notifier: spy), store, spy, settings)
    }
    func testWarnFiresOnceThenLimitOnce() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        m.evaluate(byCategory: ["entertainment": 3000], categories: cats, now: ts(0))
        m.evaluate(byCategory: ["entertainment": 3100], categories: cats, now: ts(60))   // 不重发
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertTrue(spy.posted[0].id.hasPrefix("budget.warn"))
        m.evaluate(byCategory: ["entertainment": 3700], categories: cats, now: ts(120))
        XCTAssertEqual(spy.posted.count, 2)
        XCTAssertTrue(spy.posted[1].id.hasPrefix("budget.limit"))
    }
    func testJumpingBothThresholdsFiresOnlyLimit() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        m.evaluate(byCategory: ["entertainment": 4000], categories: cats, now: ts(0))
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertTrue(spy.posted[0].id.hasPrefix("budget.limit"))
    }
    func testDisabledBudgetSilent() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        try store.setEnabled(categoryID: "entertainment", enabled: false)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        m.evaluate(byCategory: ["entertainment": 9999], categories: cats, now: ts(0))
        XCTAssertTrue(spy.posted.isEmpty)
    }
    func testSummaryFiresOnceAfterHourAndStamps() throws {
        let (m, _, spy, settings) = try makeMonitor()
        settings.setDailySummaryEnabled(true)
        settings.setDailySummaryHour(19)
        let cal = Calendar.current
        let before = cal.date(bySettingHour: 18, minute: 59, second: 0, of: Date())!
        let after = cal.date(bySettingHour: 19, minute: 1, second: 0, of: Date())!
        m.evaluateSummary(now: before) { ("今日小结", "x") }
        XCTAssertTrue(spy.posted.isEmpty)
        m.evaluateSummary(now: after) { ("今日小结", "x") }
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertEqual(settings.lastSummaryDay, BudgetEngine.dayStamp(after, calendar: cal))
        m.evaluateSummary(now: after.addingTimeInterval(600)) { ("今日小结", "x") }
        XCTAssertEqual(spy.posted.count, 1)     // 当天不重发
    }
    func testNilSummaryBodySkipsWithoutStamping() throws {
        let (m, _, spy, settings) = try makeMonitor()
        settings.setDailySummaryEnabled(true)
        let now = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        m.evaluateSummary(now: now) { nil }     // 当天无数据 → 不发不盖戳
        XCTAssertTrue(spy.posted.isEmpty)
        XCTAssertNil(settings.lastSummaryDay)
    }
}
