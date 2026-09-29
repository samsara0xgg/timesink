import XCTest
import UserNotifications
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
        // Deliberately late-evening, not early-morning: in a west-of-UTC
        // environment (UTC-7/UTC-8, this dev/CI machine's zone), local
        // 23:59:59 already rolls into the NEXT UTC calendar day, so a
        // UTC-based regression here would report "2026-08-25" instead of
        // the correct local "2026-08-24". The previous 00:05 fixture didn't
        // discriminate that regression in this timezone (local and UTC
        // agree on the date at 00:05 west-of-UTC).
        let d = cal.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 23, minute: 59, second: 59))!
        XCTAssertEqual(BudgetEngine.dayStamp(d, calendar: cal), "2026-08-24")
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
        XCTAssertEqual(spy.posted[0].id, "budget.warn.entertainment")
        m.evaluate(byCategory: ["entertainment": 3700], categories: cats, now: ts(120))
        XCTAssertEqual(spy.posted.count, 2)
        XCTAssertEqual(spy.posted[1].id, "budget.limit.entertainment")
    }
    func testJumpingBothThresholdsFiresOnlyLimit() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        m.evaluate(byCategory: ["entertainment": 4000], categories: cats, now: ts(0))
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertEqual(spy.posted[0].id, "budget.limit.entertainment")
    }
    func testDisabledBudgetSilent() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        try store.setEnabled(categoryID: "entertainment", enabled: false)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        m.evaluate(byCategory: ["entertainment": 9999], categories: cats, now: ts(0))
        XCTAssertTrue(spy.posted.isEmpty)
    }

    /// R-T11a / C1 regression: idle backdating (`TrackerEngine`'s backdated
    /// close) can shrink a category's persisted today-total by up to
    /// `idleThreshold` seconds between evaluations. Without stamping "warn"
    /// alongside "limit", a later same-day evaluation where `spent` has
    /// regressed back into the warn band would fire a SECOND post (a warn,
    /// after the limit already fired) -- falsifying both mandated copy
    /// strings ("今天不会再提醒" vs. "到达上限前会再提醒一次").
    func testLimitThenRegressToWarnBandFiresNoSecondPost() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        m.evaluate(byCategory: ["entertainment": 3700], categories: cats, now: ts(0))   // limit fires
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertEqual(spy.posted[0].id, "budget.limit.entertainment")

        m.evaluate(byCategory: ["entertainment": 3000], categories: cats, now: ts(60))  // regresses into warn band, same day
        XCTAssertEqual(spy.posted.count, 1)   // no second (warn) post
    }

    /// Fold-in 11: the notification copy is verbatim-binding per the brief
    /// -- pin the exact title/body/route for both levels once, so a copy
    /// regression fails loudly instead of only a `hasPrefix` id check.
    func testWarnAndLimitNotificationCopyIsVerbatim() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })

        m.evaluate(byCategory: ["entertainment": 3000], categories: cats, now: ts(0))   // 50m / 1h -> warn
        XCTAssertEqual(spy.posted[0].id, "budget.warn.entertainment")
        XCTAssertEqual(spy.posted[0].title, "娱乐还剩 10 分钟")
        XCTAssertEqual(spy.posted[0].body, "今天已用 50 分钟 / 1 小时。到达上限时会再提醒一次。")
        XCTAssertEqual(spy.posted[0].route, .settingsBudget)

        m.evaluate(byCategory: ["entertainment": 3600], categories: cats, now: ts(60))  // 1h / 1h -> limit
        XCTAssertEqual(spy.posted[1].id, "budget.limit.entertainment")
        XCTAssertEqual(spy.posted[1].title, "娱乐已到今日上限")
        XCTAssertEqual(spy.posted[1].body, "已用 1 小时 / 1 小时。今天不会再提醒；可在「专注与限额」中调整。")
        XCTAssertEqual(spy.posted[1].route, .settingsBudget)
    }

    /// I4: pins post-then-stamp ordering -- at the moment `post` runs, the
    /// alert must NOT be stamped yet (it's stamped only after `post`
    /// returns). A mutation that swapped the two statements' order would
    /// fail this.
    func testPostHappensBeforeAlertIsStamped() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        let day = BudgetEngine.dayStamp(ts(0), calendar: Calendar.current)

        var stampedAtPostTime: Set<String>?
        spy.onPost = {
            stampedAtPostTime = try? store.alertKinds(categoryID: "entertainment", day: day)
        }
        m.evaluate(byCategory: ["entertainment": 3000], categories: cats, now: ts(0))

        XCTAssertEqual(stampedAtPostTime, Set<String>())   // 断言 post 那一刻还没盖戳
        XCTAssertEqual(try store.alertKinds(categoryID: "entertainment", day: day), ["warn"])
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
        XCTAssertEqual(spy.posted[0].id, "summary.daily")   // R-T11d: day-less id
        XCTAssertEqual(spy.posted[0].route, .today)
        XCTAssertEqual(settings.lastSummaryDay, BudgetEngine.dayStamp(after, calendar: cal))
        m.evaluateSummary(now: after.addingTimeInterval(600)) { ("今日小结", "x") }
        XCTAssertEqual(spy.posted.count, 1)     // 当天不重发
    }

    func testSummaryDefaultAndExplicitActionsRouteToToday() {
        XCTAssertEqual(NotificationRoute.destination(action: UNNotificationDefaultActionIdentifier, notificationID: "summary.daily", storedRoute: "statsToday"), .today)
        XCTAssertEqual(NotificationRoute.destination(action: "today", notificationID: "summary.daily", storedRoute: "statsToday"), .today)
        XCTAssertNil(NotificationRoute.destination(action: UNNotificationDismissActionIdentifier, notificationID: "summary.daily", storedRoute: "today"))
        XCTAssertEqual(NotificationRoute.destination(action: UNNotificationDefaultActionIdentifier, notificationID: "custom.trends", storedRoute: "statsToday"), .statsToday)
    }
    func testNilSummaryBodySkipsWithoutStamping() throws {
        let (m, _, spy, settings) = try makeMonitor()
        settings.setDailySummaryEnabled(true)
        let now = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        m.evaluateSummary(now: now) { nil }     // 当天无数据 → 不发不盖戳
        XCTAssertTrue(spy.posted.isEmpty)
        XCTAssertNil(settings.lastSummaryDay)
    }

    // MARK: - Fold-in 6: BudgetEngine.peakTwoHourWindow

    func testPeakTwoHourWindowPicksHighestConsecutivePair() {
        var profile = Array(repeating: 0.0, count: 24)
        profile[9] = 1.5
        profile[10] = 2.0
        profile[14] = 1.0
        let result = BudgetEngine.peakTwoHourWindow(profile)
        XCTAssertEqual(result.start, 9)
        XCTAssertEqual(result.end, 11)
    }

    /// Fold-in 6: pins the judgment call that the scan does NOT wrap across
    /// midnight -- hour 23 and hour 0 are each other's biggest neighbor here,
    /// but `(23, 0)` is never a candidate window, so neither wins outright;
    /// the earliest-tied non-wrapping pair, `(0, 1)`, wins instead.
    func testPeakTwoHourWindowDoesNotWrapMidnight() {
        var profile = Array(repeating: 0.0, count: 24)
        profile[23] = 10
        profile[0] = 10
        let result = BudgetEngine.peakTwoHourWindow(profile)
        XCTAssertEqual(result.start, 0)
        XCTAssertEqual(result.end, 2)
        XCTAssertNotEqual(result.start, 23)
    }
}
