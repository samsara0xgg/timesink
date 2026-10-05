import Foundation
import Observation
import os

/// Top-level sidebar destination.
public enum SidebarItem: Hashable, CaseIterable {
    case today, activities, stats, focus, organization
}

/// Settings window tab destination -- driven by `AppModel.settingsTab`, read
/// by `SettingsView`'s `TabView(selection:)` and written by notification
/// routing (`.settingsBudget` → `.budget`).
public enum SettingsTab: Hashable {
    case general, recording, categories, rules, uncategorized, projects, llm, budget, focus, account, privacy, permissions, notifications, about
}

/// App-wide observable state: the shared stores/engine, the current date-range
/// selection, and the menu bar's live summary text. Views read `range`,
/// `sidebarSelection`, `activityFilter` directly (tracked by `@Observable`);
/// `dataVersion` is bumped on every engine write so views that cache derived
/// data (e.g. per-category totals) know to re-query via
/// `.onChange(of: model.dataVersion)`.
@MainActor
@Observable
public final class AppModel {
    public let categoryStore: CategoryStore
    public let spanStore: SpanStore
    public let settings: SettingsStore
    public let resolver: CategoryResolver
    public let engine: TrackerEngine

    public var range: DateRangeSelection = .today() {
        didSet {
            if range.firstWeekday != firstWeekday { range.firstWeekday = firstWeekday }
            if oldValue.interval != range.interval { clearActivityTimeFilter() }
        }
    }
    public var activityTimeInterval: DateInterval?
    public private(set) var heatmapReturnRange: DateRangeSelection?
    public var sidebarSelection: SidebarItem = .today
    /// Days back the Today page shows: 0 is today, -1 yesterday.
    public var todayDayOffset = 0
    public var activityFilter: String?

    /// Selected Settings window tab -- default `.general`; notification
    /// routing (`.settingsBudget`) jumps this to `.budget`.
    let popoverShortcut = PopoverShortcut()
    let returnShortcut = PopoverShortcut(id: 2)
    /// F3: the window 回到刚才 would bring back; set only when it changes.
    var returnOffer: ReturnTracker.Origin?
    /// F4: a stretch away just ended and is waiting for a name.
    var awayOffer: DateInterval?
    @ObservationIgnored var lastTickAt: Date?
    @ObservationIgnored var awayAsked: (day: Date, count: Int) = (.distantPast, 0)
    @ObservationIgnored var returnTracker = ReturnTracker()
    @ObservationIgnored var returnCategory: (start: Date, bundleID: String, categoryID: String)?
    public var popoverShortcutAvailable = false
    public var accessibilityGranted = true { didSet { engine.setPermissionGranted(accessibilityGranted) } }
    public var settingsTab: SettingsTab = .general
    public var organizationTab: SettingsTab = .uncategorized
    public var organizationSearch = ""
    /// Distinct apps and sites uncategorized over the last 30 days. Counted
    /// off the main actor after each user edit, and at most every ten
    /// minutes for the tracker's own writes -- see `refreshPendingCount()`.
    public private(set) var pendingClassificationCount = 0
    @ObservationIgnored private let pendingWorker = StatsWorker()
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCountedAt = Date.distantPast
    @ObservationIgnored private var pendingEditVersion = -1

    /// A route decoded from a tapped notification, buffered here by
    /// `TimeSinkApp`'s `appDelegate.onRoute` assignment until `MenuBarLabel`
    /// (the one persistently-alive observation point) consumes and clears it.
    public var pendingRoute: NotificationRoute?

    /// Live text from the Activities tab's `.searchable` field. A read-path
    /// filter only — `ActivitiesView` debounces its own recompute off this;
    /// setting it must never call `dataChanged()` or touch `dataVersion`.
    public var activitySearch: String = ""

    /// Bumped on every `dataChanged()`; views observe this to know when to
    /// re-run range/category queries.
    public var dataVersion: Int = 0

    /// Bumped only when the USER changed data -- a reassignment, a rule or
    /// category edit -- never for the engine's own span writes, which arrive
    /// roughly every 1.5s while tracking runs.
    ///
    /// `dataVersion` cannot distinguish the two, and a view with an
    /// aggregation too expensive to run on every engine write is stuck
    /// choosing between recomputing constantly and going stale after an edit.
    /// `StatsModel`'s 30-day trend and heatmap are exactly that: gated to
    /// once a calendar day, so without this signal they would keep showing
    /// pre-edit numbers until midnight.
    public private(set) var dataEditVersion: Int = 0

    /// Menu bar icon label: today's TOTAL tracked time, kept in sync by
    /// `refreshMenu()`. Deliberately the total and not `Aggregator.focusTime`:
    /// the label renders as a bare number with no caption, and focus time drops
    /// every category scoring below 1 -- including `uncategorized`, which on
    /// real data is the single largest bucket -- so it read as "time tracked
    /// today" while under-reporting it ~3x. The focus figure is still shown,
    /// captioned, in the popover (`MenuBarDashboard`). The "productive" display
    /// mode is the captioned variant ("投入 2h"), see `menuProductiveTitle`.
    public var menuTitle: String = "0m"
    /// Menu bar label for the "productive" mode: "投入 " + today's focus time,
    /// the same figure as the Today page's 投入 card. Stored, not computed in
    /// the label body, so the label stays a plain read of model properties.
    public var menuProductiveTitle: String = String(localized: "投入 \("0m")")
    public var currentCategoryTitle: String {
        _ = dataVersion
        guard let span = engine.currentActivity else { return trackingPaused ? String(localized: "已暂停") : String(localized: "空闲") }
        let category = resolver.categoryID(for: span)
        let total = rangedSpans(for: .today()).filter { $0.categoryID == category }.reduce(0) { $0 + $1.span.duration }
        return (resolver.categoriesByID[category]?.name ?? String(localized: "未分类")) + " " + Format.duration(total)
    }
    /// Today's total tracked duration, for the menu bar dropdown.
    public var todayTotalTitle: String = "0m"
    /// Today's productivity score (0-100), for the menu bar dropdown. "--" if no data yet.
    public var todayPulseTitle: String = "--"

    /// @Observable mirror of `settings.menuBarTextEnabled` -- the KV setting
    /// itself isn't observable, so the menu bar label reads this property
    /// instead; the General settings pane's toggle writes both in lockstep.
    public var menuTextEnabled: Bool
    public var menuDisplayMode = "productive"
    public func setMenuDisplayMode(_ value: String) {
        menuDisplayMode = value
        menuTextEnabled = value != "icon"
        settings.set("menuDisplayMode", value)
        settings.setMenuBarTextEnabled(menuTextEnabled)
    }
    public var showScore: Bool = true {
        didSet { settings.set("showScore", showScore ? "true" : "false") }
    }
    public var firstWeekday = 2 {
        didSet { settings.set("firstWeekday", String(firstWeekday)); range.firstWeekday = firstWeekday }
    }
    public var timeFormat = "system" {
        didSet { settings.set("timeFormat", timeFormat) }
    }
    /// 设置 › 记录 › 什么算打断.
    public var interruptionRule = InterruptionRule() {
        didSet {
            settings.set("interruptionDwell", String(Int(interruptionRule.dwell)))
            settings.set("interruptionTyping", interruptionRule.countsTyping ? "true" : "false")
            interruptionCache.removeAll()
        }
    }
    /// F1 会话: away this long, or a change lasting this long, starts a new
    /// session (设置 › 记录).
    public var sessionThreshold: TimeInterval = SessionSegmenter.defaultThreshold {
        didSet { settings.set("sessionThreshold", String(Int(sessionThreshold))); sessionCache.removeAll() }
    }
    /// Names worked out off the main actor, by `WorkSession.nameKey`.
    public var sessionLabels: [String: SessionLabel] = [:]
    /// Your names and projects, by `WorkSession.signature`.
    public var sessionOverrides: [String: SessionNameRow] = [:]
    /// Bumped when you split a session.
    public var sessionSplitsVersion = 0
    /// The projects you named (and accepted), in your order. Jev is asked about these.
    public internal(set) var projects: [UserProject] = []
    @ObservationIgnored var projectNames: [String: String] = [:]
    @ObservationIgnored var projectsVersion = 0
    @ObservationIgnored var projectSuggestionTask: Task<ProjectSuggester.Result, Never>?
    @ObservationIgnored var projectHoursCache: (key: ProjectHours.Key, at: Date, value: [String: TimeInterval])?
    @ObservationIgnored var projectHoursTask: (key: ProjectHours.Key, task: Task<[String: TimeInterval], Never>)?
    /// How many times the 14-day pass actually ran (tests).
    @ObservationIgnored var projectHoursComputations = 0
    @ObservationIgnored var projectSuggestionCache: (at: Date, value: ProjectSuggester.Result)?
    @ObservationIgnored var sessionCache: [DateInterval: (version: Int, threshold: TimeInterval, splits: Int, value: [WorkSession])] = [:]
    @ObservationIgnored var sessionTasks: [DateInterval: Task<[WorkSession], Never>] = [:]
    @ObservationIgnored var namingQueue: [WorkSession] = []
    @ObservationIgnored var namingTask: Task<Void, Never>?
    @ObservationIgnored var sessionOverridesLoaded = false
    @ObservationIgnored let sessionNamer = SessionNamer()

    /// Classified days, keyed by day, data version and rule. The pass runs
    /// off the main actor; see `interruptions(for:)`.
    @ObservationIgnored private var interruptionCache: [DateInterval: (version: Int, rule: InterruptionRule, value: DayInterruptions)] = [:]
    @ObservationIgnored private var interruptionTasks: [DateInterval: Task<DayInterruptions, Never>] = [:]

    /// A day's episodes: cached when nothing was written since, otherwise
    /// classified on a background task from the spans already in memory.
    public func interruptions(for day: DateInterval) async -> DayInterruptions {
        let version = dataVersion, rule = interruptionRule
        if let hit = interruptionCache[day], hit.version == version, hit.rule == rule { return hit.value }
        if let running = interruptionTasks[day] { return await running.value }
        let items = rangedSpans(for: day)
        let productivity = resolver.categoriesByID.mapValues(\.productivity)
        let distracting = resolver.distractingIDs
        let blocked = ((try? observationStore?.stateEvents(in: day)) ?? []).filter { $0.kind == "focus_block" }.map(\.at)
        let task = Task.detached(priority: .userInitiated) {
            DayInterruptions(episodes: InterruptionClassifier.episodes(items, productivity: productivity, distracting: distracting, rule: rule),
                             blocked: blocked)
        }
        interruptionTasks[day] = task
        let value = await task.value
        interruptionTasks[day] = nil
        if interruptionCache.count > 40 { interruptionCache.removeAll() }
        interruptionCache[day] = (version, rule, value)
        return value
    }
    public var displayCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = firstWeekday
        return calendar
    }
    /// The language the interface text is in: the person's choice in Settings
    /// (or the system's), for formatting dates in words to match it.
    public var textLocale: Locale { Locale(identifier: Locale.preferredLanguages.first ?? "en") }
    public var displayLocale: Locale {
        guard timeFormat != "system" else { return .current }
        return Locale(identifier: Locale.current.identifier + (Locale.current.identifier.contains("@") ? ";" : "@") + "hours=" + (timeFormat == "24" ? "h23" : "h12"))
    }
    /// Rows call this per render; building a `DateFormatter` costs ~45 µs.
    @ObservationIgnored private var timeFormatter: (key: String, formatter: DateFormatter)?
    public func time(_ date: Date) -> String {
        let key = timeFormat + "|" + Locale.current.identifier
        if timeFormatter?.key != key {
            let formatter = DateFormatter()
            formatter.locale = displayLocale
            if timeFormat == "system" { formatter.timeStyle = .short }
            else { formatter.dateFormat = timeFormat == "24" ? "HH:mm" : "h:mm a" }
            timeFormatter = (key, formatter)
        }
        return timeFormatter!.formatter.string(from: date)
    }

    /// @Observable mirror of `engine.chromeCaptureDegraded` -- `TrackerEngine`
    /// is a plain `@MainActor` class, not `@Observable`, so a SwiftUI body
    /// reading `engine.chromeCaptureDegraded` directly registers no
    /// dependency and never re-renders on its own. Refreshed at the end of
    /// `refreshMenu()`, which already runs on every relevant update path
    /// (engine writes via `dataChanged()`, and construction).
    public private(set) var chromeDegraded: Bool = false

    /// C3 calendar overlay -- **injection convention**: every new
    /// collaborator introduced this batch is a post-init optional property,
    /// never a new `init` parameter. `TimeSinkApp.init` assigns this after
    /// constructing `AppModel` (real `CalendarStore`, which eagerly holds an
    /// `EKEventStore`); every existing construction point (`TimeSinkApp`
    /// pre-Task-10, `AppModelCacheTests`, `ActivitiesModelTests`'s fixture)
    /// is unaffected. It's `nil` throughout `init()`/`refreshMenu()`'s
    /// bootstrap call, which doubles as a natural "not wired up yet" guard
    /// for any bootstrap-time code that might otherwise touch it.
    public var calendarStore: CalendarStore?

    /// `@Observable` mirror of `settings.calendarOverlayEnabled` -- same
    /// pattern as `menuTextEnabled`: the KV setting itself isn't observable,
    /// so views read this instead, and the writer (the Activities calendar
    /// band / Settings row) writes both in lockstep.
    public var calendarOverlayEnabled: Bool

    /// Mirrors `settings.screenCapturePaused`; the collector is told on toggle.
    public var screenCapturePaused: Bool

    public private(set) var trackingPaused = false
    public private(set) var trackingResumeAt: Date?
    @ObservationIgnored private var trackingResumeTask: Task<Void, Never>?

    public func pauseTracking(minutes: Int?) {
        trackingResumeTask?.cancel()
        trackingPaused = true
        settings.set("trackingPaused", "true")
        trackingResumeAt = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        settings.set("trackingResumeAt", trackingResumeAt.map { String($0.timeIntervalSince1970) } ?? "manual")
        engine.setUserPaused(true)
        // Closes the open span; classifications are untouched, so the 30-day
        // aggregates keyed on `dataEditVersion` need not rerun.
        invalidateAndBump()
        if let minutes {
            trackingResumeTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(Double(minutes) * 60)) } catch { return }
                self?.resumeTracking()
            }
        }
    }

    public func resumeTracking() {
        trackingResumeTask?.cancel()
        trackingResumeTask = nil
        trackingPaused = false
        settings.set("trackingPaused", "false")
        settings.set("trackingResumeAt", "")
        trackingResumeAt = nil
        engine.setUserPaused(false)
        invalidateAndBump()
    }
    public func extendTrackingPause(minutes: Int) {
        let remaining = max(0, trackingResumeAt?.timeIntervalSinceNow ?? 0)
        pauseTracking(minutes: Int(ceil(remaining / 60)) + minutes)
    }

    public var screenCollector: ScreenCollector?
    public var observationStore: ObservationStore?

    /// Today's meeting-tagged calendar events, refreshed by
    /// `refreshCalendarWindows()`. Not `@Observable`-tracked -- only
    /// `isNowInMeeting` (derived from it) needs to be, and that's read by
    /// `TrackerEngine.isInMeetingProvider`, not SwiftUI.
    @ObservationIgnored
    private(set) var todayMeetingEvents: [CalendarEvent] = []

    /// C4 budgets -- same post-init injection convention as `calendarStore`:
    /// `TimeSinkApp.init` assigns these after constructing `AppModel`. All
    /// three are `nil` throughout `init()`'s bootstrap `refreshMenu()` call,
    /// which doubles as the "not wired up yet" guard `BudgetMonitor` needs
    /// (spec §8) -- `budgetMonitor?.evaluate(...)` is a no-op until assigned.
    public var budgetStore: BudgetStore?
    public var notifier: (any Notifying)?
    public var budgetMonitor: BudgetMonitor?

    /// Cloud account and sync (design doc 2026-09-22) -- same post-init
    /// injection convention. nil in tests and until `TimeSinkApp.init`
    /// assigns them; the account pane treats nil as "not available".
    public var cloudAuth: CloudAuth?
    public var sync: SyncEngine?

    /// Sparkle -- same post-init injection convention; nil in tests and in a
    /// `swift run` build, and the 通用 pane hides its 更新 section then.
    public var updates: Updates?

    /// C4 focus sessions -- same post-init injection convention as
    /// `calendarStore`/`budgetStore`: `TimeSinkApp.init` assigns these after
    /// constructing `AppModel`. `focus` is `nil` throughout `init()`'s
    /// bootstrap `refreshMenu()` call and until assembly wires it up; every
    /// view that reads `model.focus?.running` treats `nil` as "no session in
    /// progress", which is also the correct steady state pre-assembly.
    public var focusStore: FocusSessionStore?
    public var focus: FocusSessionController?
    /// Jev: the cached category verdicts and the worker that keeps them current.
    public var jev: JevService?

    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "appModel")

    /// Memoizes categorized fetches between `dataChanged()` bumps. Three
    /// consumers (StatsModel, ActivitiesModel, refreshMenu) re-query on every
    /// dataVersion change with overlapping ranges; without this each bump
    /// costs up to 4 identical full fetch+classify passes on the main actor.
    /// `@ObservationIgnored`: a cache must never be observable -- without it,
    /// every read-then-write in `rangedSpans(for:)` would register through
    /// `@Observable`'s registrar and self-invalidate any SwiftUI body that
    /// reads it, costing an extra render on every cold-cache fetch.
    @ObservationIgnored
    private var rangeCache: [DateInterval: [CategorizedSpan]] = [:]

    /// LRU order for `rangeCache`'s keys, oldest first. Capped at
    /// `rangeCacheCap` entries -- once querying a *new* interval would push
    /// it over the cap, the least-recently-used entry is evicted. Bounds
    /// memory for callers that page through many distinct ranges (e.g. a
    /// heatmap or "environment comparison" view issuing several
    /// `rangedSpans(for:)` calls with different intervals per recompute)
    /// without ever hitting `dataChanged()` to clear the whole cache.
    @ObservationIgnored
    private var cacheOrder: [DateInterval] = []
    /// Earliest span start the tracker wrote since the last bump. Windows
    /// ending before it -- yesterday, last week -- read the same rows as
    /// before, so the engine path keeps them cached.
    @ObservationIgnored private var engineDirtyFrom: Date?
    /// The earliest span start each recent `dataVersion` bump could have
    /// changed, newest last: `.distantPast` unless it was a tracking write.
    /// Lets the Stats worker keep past windows across tracking writes.
    @ObservationIgnored private(set) var writeLog: [(version: Int, from: Date)] = []
    private static let rangeCacheCap = 8

    /// Trailing debounce for `scheduleEngineDataChanged()` -- see its doc
    /// comment.
    private static let engineChangeDebounce: Duration = .seconds(1.5)
    private var pendingEngineRefresh: Task<Void, Never>?

    public init(
        categoryStore: CategoryStore,
        spanStore: SpanStore,
        settings: SettingsStore,
        resolver: CategoryResolver,
        engine: TrackerEngine
    ) {
        self.categoryStore = categoryStore
        self.spanStore = spanStore
        self.settings = settings
        self.resolver = resolver
        self.engine = engine
        self.menuTextEnabled = settings.menuBarTextEnabled
        self.menuDisplayMode = settings.get("menuDisplayMode") ?? (settings.menuBarTextEnabled ? "productive" : "icon")
        self.showScore = settings.get("showScore") != "false"
        self.firstWeekday = settings.get("firstWeekday") == "1" ? 1 : 2
        self.timeFormat = settings.get("timeFormat") ?? "system"
        self.interruptionRule = InterruptionRule(
            dwell: settings.get("interruptionDwell").flatMap(TimeInterval.init).flatMap { InterruptionRule.dwellChoices.contains($0) ? $0 : nil } ?? 15,
            countsTyping: settings.get("interruptionTyping") != "false")
        self.sessionThreshold = settings.get("sessionThreshold").flatMap(TimeInterval.init)
            .flatMap { SessionSegmenter.thresholdChoices.contains($0) ? $0 : nil } ?? SessionSegmenter.defaultThreshold
        self.calendarOverlayEnabled = settings.calendarOverlayEnabled
        self.screenCapturePaused = settings.screenCapturePaused
        self.range.firstWeekday = firstWeekday
        if settings.get("trackingPaused") == "true" {
            if let raw = settings.get("trackingResumeAt"), let until = Double(raw), until > Date().timeIntervalSince1970 {
                pauseTracking(minutes: max(1, Int(ceil((until - Date().timeIntervalSince1970) / 60))))
            } else if settings.get("trackingResumeAt") == "manual" { pauseTracking(minutes: nil) }
            else { settings.set("trackingPaused", "false") }
        }
        refreshMenu()
        // refreshMenu() just seeded rangeCache with a "today" snapshot taken
        // before any caller-visible dataChanged() boundary; drop it so the
        // first real query after construction always re-reads the store
        // rather than serving that bootstrap-time snapshot indefinitely.
        rangeCache.removeAll()
        cacheOrder.removeAll()
        engine.onTick = { [weak self] span, now in self?.observeForReturn(span, now: now); self?.observeForAway(now: now) }
        engine.onChange = { [weak self] in
            guard let self else { return }
            let start = engine.lastWriteStart ?? .distantPast
            engineDirtyFrom = min(engineDirtyFrom ?? start, start)
            scheduleEngineDataChanged()
        }
        reloadProjects()
        refreshPendingCount()
    }

    /// Spans in the current `range`, clipped to it, and categorized.
    public func rangedSpans() -> [CategorizedSpan] {
        rangedSpans(for: range)
    }

    // MARK: - C1+ navigation intents

    public func openToday() {
        clearActivityTimeFilter()
        todayDayOffset = 0
        show(.today())
        sidebarSelection = .today
    }

    /// Navigation picks ranges such as "today" with a fresh anchor. Keeping
    /// the current value when it covers the same days spares every view keyed
    /// on the range a reload.
    private func show(_ newRange: DateRangeSelection) {
        var newRange = newRange
        newRange.firstWeekday = firstWeekday
        guard newRange.kind != range.kind || newRange.interval != range.interval else { return }
        range = newRange
    }

    /// Points the main window at Stats for `range` -- shared by the
    /// popover's drill-down click routes (C1+) and notification routing.
    /// Sets state only; the caller does `openWindow(id: "main")` (a SwiftUI
    /// environment action `AppModel` itself never touches).
    public func openStats(range: DateRangeSelection) {
        clearActivityTimeFilter()
        show(range)
        sidebarSelection = .stats
    }

    /// Points the main window at Activities for `range`, filtered to
    /// `category` (`nil` clears any existing filter). Same navigation-intent
    /// convention as `openStats(range:)`.
    public func openActivities(category: String?, range: DateRangeSelection) {
        clearActivityTimeFilter()
        show(range)
        sidebarSelection = .activities
        activityFilter = category
    }

    /// A heatmap cell aggregates several dates; navigation only happens after
    /// the user chooses one concrete calendar-hour interval.
    public func openHeatmapActivities(in interval: DateInterval) {
        let returnRange = range
        openActivities(category: nil, range: DateRangeSelection(kind: .day, anchor: interval.start))
        activitySearch = ""
        activityTimeInterval = interval
        heatmapReturnRange = returnRange
    }

    public func clearActivityTimeFilter() {
        activityTimeInterval = nil
        heatmapReturnRange = nil
    }

    public func returnToHeatmap() {
        guard let originalRange = heatmapReturnRange else { return }
        openStats(range: originalRange)
    }

    public func todayFocusText() -> String {
        let items = rangedSpans(for: .today())
        let byCategory = Aggregator.durationByCategory(items)
        let focus = Aggregator.focusTime(durationByCategory: byCategory, categories: resolver.categoriesByID)
        return Format.duration(focus)
    }

    public func refreshMenu() {
        let items = rangedSpans(for: .today())
        let byCategory = Aggregator.durationByCategory(items)
        todayTotalTitle = Format.duration(Aggregator.totalDuration(items.map(\.span)))
        menuTitle = todayTotalTitle
        menuProductiveTitle = String(localized: "投入 \(Format.duration(Aggregator.focusTime(durationByCategory: byCategory, categories: resolver.categoriesByID)))")
        if let pulse = Aggregator.pulse(durationByCategory: byCategory, categories: resolver.categoriesByID) {
            todayPulseTitle = "\(pulse)"
        } else {
            todayPulseTitle = "--"
        }
        chromeDegraded = engine.chromeCaptureDegraded

        // C4: budget/summary notifications, off the totals just computed
        // above -- no new span query. `budgetMonitor` is nil until
        // `TimeSinkApp.init` assigns it post-construction, so this is a
        // no-op during the bootstrap `refreshMenu()` call inside `init()`.
        budgetMonitor?.evaluate(byCategory: byCategory, categories: resolver.categoriesByID, now: Date())
        budgetMonitor?.evaluateSummary(now: Date()) { [weak self] in self?.makeDailySummary() }
    }

    /// The user changed data. Invalidates everything and signals both
    /// versions -- see `dataEditVersion`.
    public func dataChanged() {
        dataEditVersion += 1
        invalidateAndBump()
    }

    /// A setting changed that no span's category depends on (budgets, focus
    /// blocks, the popover shortcut, deleted captures). Views refresh from the
    /// caches; the cache and the 30-day aggregates keyed on
    /// `dataEditVersion` are left alone.
    public func settingsChanged() {
        bump()
    }

    /// The tracker wrote a span. Same invalidation, but deliberately does not
    /// touch `dataEditVersion`: this fires about every 1.5s while tracking
    /// and must not drag a once-a-day aggregation along with it.
    private func engineDataChanged() {
        let from = engineDirtyFrom ?? .distantPast
        engineDirtyFrom = nil
        cacheOrder.removeAll { interval in
            guard interval.end > from else { return false }
            rangeCache.removeValue(forKey: interval)
            return true
        }
        bump(from: from)
    }

    /// The engine path is private and only ever reached through a 1.5s
    /// debounce, so `testDataEditVersionSeparatesUserEditsFromEngineWrites`
    /// needs a way in that does not involve waiting on a timer.
    func engineDataChangedForTesting(writtenFrom start: Date? = nil) {
        engineDirtyFrom = start
        engineDataChanged()
    }

    private func invalidateAndBump() {
        rangeCache.removeAll()
        cacheOrder.removeAll()
        bump()
    }

    private func bump(from: Date = .distantPast) {
        refreshMenu()
        dataVersion += 1
        writeLog.append((dataVersion, from))
        if writeLog.count > 32 { writeLog.removeFirst() }
        refreshPendingCount()
    }

    /// A 30-day classify pass costs ~0.2-1 s, so it never runs on the main
    /// actor or on every tracker write.
    func refreshPendingCount() {
        guard dataEditVersion != pendingEditVersion || Date().timeIntervalSince(pendingCountedAt) > 600 else { return }
        pendingEditVersion = dataEditVersion
        pendingCountedAt = Date()
        pendingTask?.cancel()
        let (worker, store, classification) = (pendingWorker, spanStore, resolver.snapshot())
        let (edits, version) = (dataEditVersion, dataVersion)
        let interval = DateRangeSelection(kind: .last30, anchor: Date()).interval
        pendingTask = Task { [weak self] in
            guard let count = try? await worker.uncategorizedCount(store: store, classification: classification,
                                                                     editVersion: edits, dataVersion: version, interval: interval),
                  !Task.isCancelled else { return }
            self?.pendingClassificationCount = count
        }
    }

    /// `dataChanged()` for edits that change how a category is presented or
    /// scored but not which category any span resolves to -- a name, a color,
    /// a productivity level, a sort order.
    ///
    /// Keeps `rangeCache`: its entries are `CategorizedSpan`s, span plus
    /// categoryID, and this kind of edit changes neither. The menu bar still
    /// has to be recomputed, because focus time and the pulse score are
    /// weighted by productivity. Pair this with
    /// `CategoryResolver.refreshCategories()` rather than `refresh()`, so the
    /// classification memo survives too -- see that method for why the memo,
    /// not the table reload, is what makes the full path expensive.
    public func categoryMetadataChanged() {
        // Bumps `dataEditVersion` too: productivity is a category field, and
        // both the pulse score and the heatmap are weighted by it, so this
        // edit does change the 30-day numbers even though it changes no
        // span's category.
        dataEditVersion += 1
        refreshMenu()
        dataVersion += 1
    }

    /// Debounced entry point wired ONLY to `engine.onChange` -- every span
    /// insert/update while live tracking is running. Every live view
    /// responds to `dataVersion` with a full `rangedSpans()` + aggregation
    /// recompute on the main actor, so with months of data at a wide range,
    /// rapid app switching (many writes in quick succession) would visibly
    /// hitch the UI if each one ran `dataChanged()` immediately. This
    /// coalesces bursts behind a short trailing delay. Explicit user
    /// actions (reassignment, settings edits) call `dataChanged()` directly
    /// elsewhere and must stay immediate -- do not route them through here.
    private func scheduleEngineDataChanged() {
        pendingEngineRefresh?.cancel()
        pendingEngineRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.engineChangeDebounce)
            guard !Task.isCancelled else { return }
            self?.engineDataChanged()
        }
    }

    /// `range.interval`'s spans -- one-line delegate to the interval
    /// primitive below.
    public func rangedSpans(for range: DateRangeSelection) -> [CategorizedSpan] {
        rangedSpans(for: range.interval)
    }

    /// `spanStore.spans(overlapping:)`, each span clipped to the interval's
    /// intersection, then categorized. Result is memoized per interval in
    /// `rangeCache` (an LRU capped at `rangeCacheCap` entries -- see
    /// `cacheOrder`) until the next `dataChanged()`. DB errors are logged and
    /// yield [] (not cached, so a transient failure doesn't stick).
    public func rangedSpans(for interval: DateInterval) -> [CategorizedSpan] {
        let key = interval
        if let cached = rangeCache[key] {
            touchCacheKey(key)
            return cached
        }
        do {
            let spans = try spanStore.spans(overlapping: interval)
            let clipped = spans.map { span -> Span in
                var s = span
                s.start = max(s.start, interval.start)
                s.end = min(s.end, interval.end)
                return s
            }
            let result = resolver.categorized(clipped)
            remember(result, for: key)
            return result
        } catch {
            logger.error("rangedSpans failed: \(String(describing: error))")
            return []
        }
    }

    private func remember(_ result: [CategorizedSpan], for key: DateInterval) {
        rangeCache[key] = result
        cacheOrder.append(key)
        while cacheOrder.count > Self.rangeCacheCap {
            rangeCache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// `rangedSpans(for:)` with the read and the classification off the main
    /// actor: the same rows, clipped and classified the same way, and cached
    /// the same way. A month is ~56k rows, 0.5-2 s that a page would
    /// otherwise spend frozen.
    ///
    /// nil when the caller was cancelled, or when a write since the call began
    /// could have changed `interval` (the rows read may be older than the
    /// store, and the result is not cached): `dataVersion` has moved by then,
    /// so whoever watches it is already asking again.
    func rangedSpansOffMain(for interval: DateInterval) async -> [CategorizedSpan]? {
        if let cached = rangeCache[interval] {
            touchCacheKey(interval)
            return cached
        }
        let (store, version, seed) = (spanStore, dataVersion, resolver.snapshot())
        let job = Task.detached(priority: .userInitiated) { () throws -> (spans: [CategorizedSpan], classification: CategoryResolver.Snapshot) in
            var classification = seed
            try Task.checkCancellation()
            let spans = try store.spans(overlapping: interval)
            try Task.checkCancellation()
            var result: [CategorizedSpan] = []
            result.reserveCapacity(spans.count)
            for (index, span) in spans.enumerated() {
                if index.isMultiple(of: 2048) { try Task.checkCancellation() }
                var clipped = span
                clipped.start = max(clipped.start, interval.start)
                clipped.end = min(clipped.end, interval.end)
                result.append(CategorizedSpan(span: clipped, categoryID: classification.categoryID(for: clipped)))
            }
            return (result, classification)
        }
        do {
            let loaded = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled, spansUnchanged(since: version, in: interval) else { return nil }
            if let cached = rangeCache[interval] { return cached }
            resolver.adopt(loaded.classification)
            remember(loaded.spans, for: interval)
            return loaded.spans
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("rangedSpans failed: \(String(describing: error))")
            return Task.isCancelled ? nil : []
        }
    }

    /// Nothing written since `version` reaches `interval`: a tracking write
    /// only touches spans from where it started (see `engineDataChanged`),
    /// anything else, or a version missing from the log, could have.
    private func spansUnchanged(since version: Int, in interval: DateInterval) -> Bool {
        guard dataVersion != version else { return true }
        let seen = writeLog.filter { $0.version > version }
        return seen.count == dataVersion - version && seen.allSatisfy { $0.from >= interval.end }
    }

    /// Per-day pulse over the trailing `days` days (last element = the day
    /// containing `endingAt`), nil for days with no tracked time -- exactly
    /// `Aggregator.dailyPulses`'s contract, computed without materializing
    /// one `Span` per row.
    ///
    /// Replaces `rangedSpans(for: .last30)` + `Aggregator.dailyPulses` in the
    /// popover's streak lookback. That path fetched every span overlapping 30
    /// days, built a clipped `Span` for each, classified it, then
    /// day-split it one span at a time, all to produce 30 integers.
    /// `SpanStore.dailyTupleTotals` collapses the same window to one row per
    /// (day, classification tuple) inside SQLite instead, so what reaches
    /// Swift scales with days x distinct tuples, not with span count.
    ///
    /// Release-build medians on a 541k-row one-year fixture (built from the
    /// real db, 30-day window = 43,362 rows), memo warm:
    ///
    ///   before ... 43,362 rows: 126 ms fetch + 21 ms classify + 180 ms
    ///              `Aggregator.dailyPulses` = 327 ms
    ///   after .... 7,340 group rows + 12 boundary-crossing spans: 56 ms,
    ///              of which 52 ms is the SQL
    ///
    /// 5.9x. On the real db (31,849 rows in the window) the same measurement
    /// is 240 ms -> 41 ms. Cold (memo just cleared by `refresh()`) both paths
    /// pay the same ~720 ms to classify ~5.3k distinct tuples, so cold is
    /// 1026 ms -> 755 ms; that residue is `Classifier`'s per-tuple cost, the
    /// one term this lookback is *supposed* to scale with.
    ///
    /// Day buckets are built here with `Calendar.current`, never in SQL:
    /// SQLite's `date()`/`strftime()` bucket in UTC, and its `'localtime'`
    /// modifier is both DST-fragile and slower than the whole aggregation
    /// (measured via sqlite3 on the same fixture: 134 ms for one grouped scan
    /// using it, versus 38 ms for these 30 per-day queries).
    public func dailyPulses(days: Int, endingAt: Date, calendar: Calendar) -> [Int?] {
        do {
            return try DailyPulseSummary.compute(store: spanStore, days: days, endingAt: endingAt,
                calendar: calendar, categories: resolver.categoriesByID, classify: resolver.categoryID(for:))
        } catch {
            // Matches the old path's failure mode: `rangedSpans` logged and
            // returned [], which `Aggregator.dailyPulses` turned into `days`
            // nils -- an all-untracked lookback, not an empty array.
            logger.error("dailyPulses failed: \(String(describing: error))")
            return Array(repeating: nil, count: days)
        }
    }

    /// Moves `key` to the most-recently-used end of `cacheOrder` on a cache
    /// hit, so a repeatedly-read interval isn't the one evicted next.
    private func touchCacheKey(_ key: DateInterval) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
            cacheOrder.append(key)
        }
    }

    // MARK: - C3 calendar overlay

    /// Refreshes `todayMeetingEvents` from `calendarStore` -- only while the
    /// overlay setting is on AND calendar access is actually granted;
    /// otherwise clears the cache so a just-disabled/just-revoked state
    /// can't keep exempting idle detection off a stale meeting window.
    ///
    /// Re-checks `calendarOverlayEnabled` again AFTER the `await` -- both
    /// call sites into this function (the Settings toggle's binding and
    /// `enableCalendarOverlay()`) are independent `Task`s, so a rapid
    /// ON->OFF flip can otherwise interleave: the ON call passes the
    /// leading guard and suspends at `calendarStore.events(on:)`; the user
    /// flips OFF; the OFF call runs to completion and clears
    /// `todayMeetingEvents`; the ON call then resumes and would overwrite
    /// it right back with the (now-stale) fetched events -- leaving the
    /// idle exemption armed off a meeting window the user just turned off,
    /// with nothing to self-correct it (the 5-minute background loop skips
    /// its own refresh while disabled). The second guard closes that
    /// window for every caller at once, rather than needing each call site
    /// to duplicate the check.
    public func refreshCalendarWindows() async {
        guard calendarOverlayEnabled, let calendarStore else {
            todayMeetingEvents = []
            return
        }
        await refreshCalendarPermission()
        guard calendarPermission == .granted else {
            todayMeetingEvents = []
            return
        }
        let fetched = await calendarStore.events(on: Date())
        guard calendarOverlayEnabled else {
            todayMeetingEvents = []
            return
        }
        todayMeetingEvents = fetched
    }

    /// Whether the current moment falls inside any of today's meeting
    /// events -- read by `TrackerEngine.isInMeetingProvider` (idle
    /// exemption) via the `[weak self]` closure `TimeSinkApp.init` wires up.
    public var isNowInMeeting: Bool {
        MeetingTagger.inMeeting(at: Date(), events: todayMeetingEvents)
    }

    /// Handle for the loop `startCalendarRefreshLoop()` starts -- stored so
    /// the loop is a real, cancellable Task rather than a fire-and-forget
    /// one nothing can ever stop.
    private var calendarRefreshTask: Task<Void, Never>?

    /// Starts the 5-minute calendar-window refresh loop -- called once from
    /// `TimeSinkApp.init` after `calendarStore` is assigned. Refreshes
    /// immediately (covers "on launch"), then every 5 minutes; each
    /// iteration only actually touches EventKit while `calendarOverlayEnabled`
    /// is on, otherwise it just re-checks the flag and goes back to sleep.
    /// `[weak self]`: this detached loop must never keep `AppModel` alive by
    /// itself -- once `self` is deallocated, the next `guard let self`
    /// fails and the loop exits instead of re-arming another sleep. Also
    /// checks `Task.isCancelled` right after waking from the sleep -- without
    /// it, a cancelled-but-still-running loop (e.g. if this were ever called
    /// a second time, or cancelled directly) would keep busy-looping through
    /// `Task.sleep`'s immediate cancellation-error return instead of
    /// actually stopping. Never calls `dataChanged()`: a background calendar
    /// refresh updates only the meeting-window cache `isNowInMeeting` reads,
    /// not app data views re-query on.
    public func startCalendarRefreshLoop() {
        calendarRefreshTask?.cancel()
        calendarRefreshTask = Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                if self.calendarOverlayEnabled {
                    await self.refreshCalendarWindows()
                }
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// Registers for `.EKEventStoreChanged` via `CalendarStore.observeChanges`
    /// -- called once from `TimeSinkApp.init` after `calendarStore` is
    /// assigned. `[weak self]` so the registered closure (which lives for
    /// the process's lifetime in `NotificationCenter`) never keeps `AppModel`
    /// alive on its own.
    public func observeCalendarChanges() {
        CalendarStore.observeChanges { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.calendarStore?.invalidateCache()
                await self.refreshCalendarWindows()
                self.calendarVersion += 1
            }
        }
    }

    /// Bumped when the user's calendars change, so views showing events
    /// fetch them again.
    public private(set) var calendarVersion = 0

    /// The menu bar popover's numbers, kept between openings so an open
    /// shows the last ones at their final height while it refreshes.
    @ObservationIgnored let dashboard = TodayDashboardModel()

    /// Calendar access as last read by `refreshCalendarPermission()`, nil
    /// until the first read. Views read this instead of asking the calendar
    /// service on the main thread.
    public private(set) var calendarPermission: PermissionState?

    public func refreshCalendarPermission() async {
        let state = await Permissions.calendarStateInBackground()
        if state != calendarPermission { calendarPermission = state }
    }

    /// Budgets and the daily summary only ever notify; without asking here
    /// the first alert would be dropped silently. The system prompts once.
    public func requestNotificationPermission() {
        Task { _ = await notifier?.requestAuthorization() }
    }

    /// At midnight a window left on "today" would keep showing yesterday,
    /// and the menu total would wait for the next tracker write.
    public func observeDayChanges() {
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayChanged() }
        }
    }

    func dayChanged(now: Date = Date()) {
        let calendar = Calendar.current
        // Any range that ended on "today" rolls forward: the last 7 and 30
        // days, this week and this month as well as the day itself.
        if range.kind != .custom, let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(range.anchor, inSameDayAs: yesterday) {
            range = DateRangeSelection(kind: range.kind, anchor: now)
        }
        invalidateAndBump()
    }

    // MARK: - C4 daily summary

    /// Builds today's daily-summary notification body, or `nil` if nothing's
    /// been tracked yet today (per the brief: no items → no summary). Passed
    /// to `BudgetMonitor.evaluateSummary` as `makeBody`, so it only actually
    /// runs once that call's enabled/hour/not-already-sent gates pass.
    ///
    /// R-T11b: the pulse delta vs. yesterday uses the SAME unclipped
    /// whole-day comparison the popover's own `pulseDelta` uses
    /// (`MenuBarDashboard.swift` -- deliberately NOT
    /// `Aggregator.clippedToElapsed`), so the two surfaces agree on what
    /// "较昨日" means for the same day. When yesterday has no tracked time at
    /// all, the `（较昨日 ±D）` parenthetical is omitted entirely (parity with
    /// how the popover suppresses its own delta chip when there's no
    /// baseline) rather than fabricating a misleading "+0".
    private func makeDailySummary() -> (title: String, body: String)? {
        let calendar = Calendar.current
        let categories = resolver.categoriesByID

        let items = rangedSpans(for: .today())
        guard !items.isEmpty else { return nil }
        let byCategory = Aggregator.durationByCategory(items)
        let focus = Aggregator.focusTime(durationByCategory: byCategory, categories: categories)
        guard let pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories) else { return nil }

        let now = Date()
        let yesterdayAnchor = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let yesterdayItems = rangedSpans(for: DateRangeSelection(kind: .day, anchor: yesterdayAnchor))
        let yesterdayByCategory = Aggregator.durationByCategory(yesterdayItems)
        let yesterdayPulse = Aggregator.pulse(durationByCategory: yesterdayByCategory, categories: categories)

        let deltaClause: String
        if let yesterdayPulse {
            // Shared `Format.signedInt` (not a private copy): R-T11b made this
            // number deliberately identical to the popover's 较昨日 chip, and
            // the two must keep rendering it the same way.
            deltaClause = String(localized: "（较昨日 \(Format.signedInt(pulse - yesterdayPulse))）")
        } else {
            deltaClause = ""
        }

        let total = Aggregator.totalDuration(items.map(\.span))
        let sessionCount = ((try? focusStore?.sessions(overlapping: DateRangeSelection.today().interval)) ?? []).filter(\.completed).count
        let body = String(localized: "记录 \(Format.chineseDuration(total))，投入 \(Format.chineseDuration(focus))，完成 \(sessionCount) 次专注。评分 \(pulse)\(deltaClause)。")
        return (String(localized: "今日小结"), body)
    }

    public func setScreenCapturePaused(_ paused: Bool) {
        screenCapturePaused = paused
        settings.setScreenCapturePaused(paused)
        guard let screenCollector else { return }
        Task { await screenCollector.setPaused(paused) }
    }
}
