import Foundation

/// Pure threshold logic for category daily budgets, plus the `BudgetMonitor`
/// that drives notifications off `AppModel.refreshMenu()`.
public enum BudgetEngine {
    /// Which threshold `spent` has crossed relative to `limit`. Raw value
    /// doubles as severity ordering -- Swift doesn't auto-synthesize
    /// `Comparable` for a raw-valued enum, so `<` is implemented explicitly.
    public enum Level: Int, Comparable, Sendable {
        case none = 0, warn = 1, limit = 2

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// `warnPercent` = 剩余百分比阈值 (e.g. 20 means "warn once 20% of the
    /// budget remains", i.e. `spent >= 0.8 * limit`). `limit <= 0` is an
    /// invalid/unset budget -- always `.none` rather than dividing by zero.
    public static func level(spent: TimeInterval, limit: TimeInterval, warnPercent: Int) -> Level {
        guard limit > 0 else { return .none }
        if spent >= limit { return .limit }
        let warnThreshold = limit * (1.0 - Double(warnPercent) / 100.0)
        if spent >= warnThreshold { return .warn }
        return .none
    }

    /// Local-calendar "YYYY-MM-DD", built from `DateComponents` rather than
    /// `DateFormatter` -- `DateFormatter` is a mutable reference type, so a
    /// shared instance isn't `Sendable`-safe across call sites; this stays a
    /// pure value-in/value-out function.
    public static func dayStamp(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Evaluates category budgets and the daily summary against `AppModel`'s
/// already-computed today totals, on every `refreshMenu()`. Each of
/// warn/limit fires at most once per category per local day (stamped via
/// `BudgetStore.noteAlert` after a successful `post`, mirroring
/// `SeedImporter`'s do-then-stamp convention); a single evaluation that jumps
/// straight past both thresholds only fires the higher one, since `level(...)`
/// itself only ever reports the single highest tier reached.
///
/// Neither `evaluate` nor `evaluateSummary` checks notification authorization
/// -- both are synchronous (can't `await`), so an unauthorized state just
/// silently drops the system notification without re-sending; the alert/day
/// stamp is still recorded to avoid ever re-evaluating the same crossing.
/// Settings' permission-denied guidance is the only user-visible recovery
/// path for that case (spec §8).
@MainActor
public final class BudgetMonitor {
    private let budgetStore: BudgetStore
    private let settings: SettingsStore
    private let notifier: any Notifying

    public init(budgetStore: BudgetStore, settings: SettingsStore, notifier: any Notifying) {
        self.budgetStore = budgetStore
        self.settings = settings
        self.notifier = notifier
    }

    /// Called from `AppModel.refreshMenu()`'s tail with the day's
    /// already-aggregated `byCategory` totals -- no new DB query here beyond
    /// the budget rows themselves and the per-category alert-kind lookup.
    public func evaluate(byCategory: [String: TimeInterval], categories: [String: Category], now: Date) {
        guard let budgets = try? budgetStore.budgets() else { return }
        let calendar = Calendar.current
        let day = BudgetEngine.dayStamp(now, calendar: calendar)

        for budget in budgets where budget.enabled {
            let spent = byCategory[budget.categoryID] ?? 0
            let limit = TimeInterval(budget.dailySeconds)
            let level = BudgetEngine.level(spent: spent, limit: limit, warnPercent: settings.budgetWarnPercent)
            guard level != .none else { continue }

            let kind = level == .limit ? "limit" : "warn"
            let alreadyFired = (try? budgetStore.alertKinds(categoryID: budget.categoryID, day: day)) ?? []
            guard !alreadyFired.contains(kind) else { continue }

            let name = categories[budget.categoryID]?.name ?? budget.categoryID
            let id: String
            let title: String
            let body: String
            switch level {
            case .warn:
                id = "budget.warn.\(budget.categoryID)"
                title = "\(name)还剩 \(Format.duration(limit - spent))"
                body = "今天已用 \(Format.duration(spent)) / \(Format.duration(limit))。到达上限前会再提醒一次。"
            case .limit:
                id = "budget.limit.\(budget.categoryID)"
                title = "\(name)已到今日上限"
                body = "已用 \(Format.duration(limit)) / \(Format.duration(limit))。今天不会再提醒；上限可在设置中调整。"
            case .none:
                continue
            }

            notifier.post(id: id, title: title, body: body, route: .settingsBudget)
            try? budgetStore.noteAlert(categoryID: budget.categoryID, day: day, kind: kind)
        }
    }

    /// Same-channel daily summary: fires once per local day, no earlier than
    /// the configured hour. `makeBody` is only invoked once the gates pass,
    /// so a disabled/not-yet-due/already-sent evaluation never runs the
    /// caller's aggregation work. A `nil` body (nothing tracked yet) skips
    /// the post AND the day stamp, so a screen-locked machine that misses its
    /// hour gets a summary on the next `refreshMenu()` evaluation that
    /// actually has data, still the same day.
    public func evaluateSummary(now: Date, makeBody: () -> (title: String, body: String)?) {
        guard settings.dailySummaryEnabled else { return }
        let calendar = Calendar.current
        guard calendar.component(.hour, from: now) >= settings.dailySummaryHour else { return }
        let day = BudgetEngine.dayStamp(now, calendar: calendar)
        guard settings.lastSummaryDay != day else { return }
        guard let (title, body) = makeBody() else { return }

        notifier.post(id: "summary.\(day)", title: title, body: body, route: .statsToday)
        settings.setLastSummaryDay(day)
    }
}
