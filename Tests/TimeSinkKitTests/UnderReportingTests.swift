import XCTest
@testable import TimeSinkKit

/// 两处让界面上的时间显著少于实际记录的缺陷，各留一个钉子。
/// 都不是性能战役的回归，两处都是初版行为。
@MainActor
final class UnderReportingTests: XCTestCase {
    private func makeModel() throws -> (AppModel, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let resolver = CategoryResolver(categoryStore: categoryStore)
        let settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: spanStore, settings: settings)
        let model = AppModel(categoryStore: categoryStore, spanStore: spanStore,
                             settings: settings, resolver: resolver, engine: engine)
        return (model, spanStore)
    }

    /// 同 `AppModelCacheTests`：锚在"今天"正午，而不是 `Date()` 的偏移 ——
    /// `.today()` 的窗口是按日历日切的，午夜后几分钟跑会落到昨天。
    private func span(dayOffset: Int = 0, hour: Double = 12, seconds: TimeInterval = 7200) -> Span {
        let day = Calendar.current.date(byAdding: .day, value: dayOffset,
                                        to: Calendar.current.startOfDay(for: Date()))!
        let start = day.addingTimeInterval(hour * 3600)
        return Span(start: start, end: start.addingTimeInterval(seconds),
                    appBundleID: "com.test", appName: "Test", title: nil, url: nil, domain: nil)
    }

    /// 菜单栏那串数字没有任何标题文字，用户只会把它读成"今天记了多久"。
    /// 曾经它是 `Aggregator.focusTime`，而 focusTime 只累加生产力分 >= 1 的
    /// 分类 —— 未分类(0 分)被整个丢掉，真实数据上未分类是最大的一桶，实测
    /// 菜单栏 7 天累计只显示实录时长的 34%。专注时长仍然在弹出层里带标签显示。
    func testMenuBarLabelIsTodayTotalNotFocusTime() throws {
        let (model, store) = try makeModel()
        try store.insert(span())          // 无分类映射 -> 未分类 -> 生产力 0 -> 不进 focusTime
        model.dataChanged()

        model.refreshMenu()

        XCTAssertEqual(model.menuTitle, model.todayTotalTitle,
                       "菜单栏必须显示今日总时长")
        XCTAssertNotEqual(model.menuTitle, Format.duration(0),
                          "未分类时长被算成 0 就是旧的 focusTime 行为")
    }

    /// 已结束的周期：分母就是整个窗口，行为不变。
    func testAvgPerDayOverCompletedWeekDividesByFullWindow() async throws {
        let (model, store) = try makeModel()
        try store.insert(span(dayOffset: -30))
        model.dataChanged()
        model.range = DateRangeSelection(kind: .week,
                                         anchor: Calendar.current.date(byAdding: .day, value: -30, to: Date())!)
        let stats = StatsModel()
        await stats.recompute(model: model, forceHeavy: false)

        XCTAssertEqual(stats.total, 7200, accuracy: 1)
        XCTAssertEqual(stats.avgPerDay, 7200 / 7, accuracy: 1)
    }

    /// 跑到一半的周期：分母是已过去的天数，不是整个日历窗口。
    /// 旧代码在周一看"本周"是拿一天的数据除以 7。
    func testAvgPerDayOverRunningMonthDividesByElapsedDays() async throws {
        let (model, store) = try makeModel()
        try store.insert(span())
        model.dataChanged()

        let sel = DateRangeSelection(kind: .month, anchor: Date())
        let windowDays = (sel.interval.duration / 86400).rounded()
        let elapsedDays = max(1, (Date().timeIntervalSince(sel.interval.start) / 86400).rounded())
        try XCTSkipUnless(elapsedDays < windowDays, "月末最后一两天两个分母相同，无从区分")

        model.range = sel
        let stats = StatsModel()
        await stats.recompute(model: model, forceHeavy: false)

        XCTAssertEqual(stats.avgPerDay, stats.total / elapsedDays, accuracy: 1)
        XCTAssertGreaterThan(stats.avgPerDay, stats.total / windowDays,
                             "除以整月天数就是旧行为")
    }
}
