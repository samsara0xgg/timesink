import Foundation
import os

private let budgetEngineLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "budgetEngine")

/// Pure threshold logic for category daily budgets, plus the `BudgetMonitor`
/// that drives notifications off `AppModel.refreshMenu()`.
public enum BudgetEngine {
    /// Which threshold `spent` has crossed relative to `limit`. Raw value
    /// doubles as severity ordering -- Swift doesn't auto-synthesize
    /// `Comparable` for a raw-valued enum, so `<` is implemented explicitly.
    public enum Level: Int, Comparable, Sendable {
        case none = 0, warn = 1, limit = 2

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The `budgetAlert.kind` string this level stamps. Deriving it here
        /// (rather than a free `"warn"`/`"limit"` string literal at each call
        /// site) means the two can never drift apart. `.none` never reaches a
        /// call site that stamps -- its value is unused but the property
        /// stays total rather than partial/force-unwrapped.
        var stampKind: String {
            switch self {
            case .none: return "none"
            case .warn: return "warn"
            case .limit: return "limit"
            }
        }
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

    /// The two-consecutive-hour window (out of 24 hourly buckets, indices
    /// 0...23) with the highest combined total -- used for the daily
    /// summary's "最高峰在 H1 – H2 时". Pure/`nonisolated static`, matching the
    /// codebase's convention for lifted pure logic (e.g.
    /// `TodayDashboardModel`'s forwards to `Aggregator`).
    ///
    /// Deliberately does NOT wrap across midnight -- `(23, 0)` is never a
    /// candidate window, only consecutive pairs `(0,1)` through `(22,23)`.
    /// `hourTotals` is always a same-day hourly profile (from
    /// `Aggregator.profileByHourOfDay`), so there's no "hour 24" continuation
    /// into the next day to wrap into; pinned by
    /// `testPeakTwoHourWindowDoesNotWrapMidnight`. Ties resolve toward the
    /// earliest hour (first-seen wins, since a later equal sum doesn't
    /// exceed `peakSum`). Returns `(0, 2)` for a too-short/all-zero input.
    nonisolated static func peakTwoHourWindow(_ hourTotals: [Double]) -> (start: Int, end: Int) {
        guard hourTotals.count >= 24 else { return (0, 2) }
        var peakStart = 0
        var peakSum = -1.0
        for h in 0..<23 {
            let sum = hourTotals[h] + hourTotals[h + 1]
            if sum > peakSum {
                peakSum = sum
                peakStart = h
            }
        }
        return (peakStart, peakStart + 2)
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
    /// already-aggregated `byCategory` totals -- no new span query here, but
    /// `budgets()` and the per-category alert-kind lookup below still run
    /// against the DB each evaluation.
    public func evaluate(byCategory: [String: TimeInterval], categories: [String: Category], now: Date) {
        guard settings.budgetNotificationsEnabled, let budgets = try? budgetStore.budgets() else { return }
        let calendar = Calendar.current
        let day = BudgetEngine.dayStamp(now, calendar: calendar)
        let warnPercent = settings.budgetWarnPercent   // one read per evaluation, not per budget

        for budget in budgets where budget.enabled {
            let spent = byCategory[budget.categoryID] ?? 0
            let limit = TimeInterval(budget.dailySeconds)
            let level = BudgetEngine.level(spent: spent, limit: limit, warnPercent: warnPercent)
            guard level != .none else { continue }

            let alreadyFired = (try? budgetStore.alertKinds(categoryID: budget.categoryID, day: day)) ?? []
            guard !alreadyFired.contains(level.stampKind) else { continue }

            let name = categories[budget.categoryID]?.name ?? budget.categoryID
            let id: String
            let title: String
            let body: String
            switch level {
            case .warn:
                id = "budget.warn.\(budget.categoryID)"
                title = String(localized: "\(name)还剩 \(Format.chineseDuration(limit - spent))")
                body = String(localized: "今天已用 \(Format.chineseDuration(spent)) / \(Format.chineseDuration(limit))。到达上限时会再提醒一次。")
            case .limit:
                id = "budget.limit.\(budget.categoryID)"
                title = String(localized: "\(name)已到今日上限")
                body = String(localized: "已用 \(Format.chineseDuration(limit)) / \(Format.chineseDuration(limit))。今天不会再提醒；可在「专注与限额」中调整。")
            case .none:
                continue
            }

            // `notifier.post` is fire-and-forget through `Notifying`
            // (`SystemNotifier.post`'s `UNUserNotificationCenter.add`
            // completion handler only logs a failure -- it never propagates
            // one back to this call), so a `post` that silently fails to
            // actually deliver still stamps below. Accepted per the brief's
            // authorization ruling: neither this call nor the stamp can
            // distinguish "delivered" from "queued", and re-evaluating the
            // same crossing forever every `refreshMenu()` isn't a better
            // alternative.
            notifier.post(id: id, title: title, body: body, route: .settingsBudget)

            // R-T11a: firing `limit` ALSO stamps `warn`. Idle backdating
            // (`TrackerEngine`'s backdated close) can shrink a category's
            // persisted today-total by up to `idleThreshold` seconds between
            // evaluations, so `spent` can regress from over-limit back into
            // the warn band on a LATER same-day evaluation. Without this,
            // that regression would fire a warn notification AFTER limit
            // already fired, falsifying both mandated copy strings ("今天不会
            // 再提醒" vs. "到达上限前会再提醒一次").
            do {
                try budgetStore.noteAlert(categoryID: budget.categoryID, day: day, kind: level.stampKind)
                if level == .limit {
                    try budgetStore.noteAlert(categoryID: budget.categoryID, day: day, kind: BudgetEngine.Level.warn.stampKind)
                }
            } catch {
                budgetEngineLogger.error("noteAlert failed for \(budget.categoryID, privacy: .public)/\(day, privacy: .public): \(String(describing: error), privacy: .public)")
            }
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

        // R-T11d: day-less id -- tomorrow's summary replaces today's stale
        // one in Notification Center rather than accumulating a distinct
        // entry per day, matching the deliberate day-less convention already
        // used for the (per-category, not per-day) budget ids.
        notifier.post(id: "summary.daily", title: title, body: body, route: .today)
        settings.setLastSummaryDay(day)
    }
}
