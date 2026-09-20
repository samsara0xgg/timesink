import Foundation
import Observation
import os

/// Top-level sidebar destination.
public enum SidebarItem: Hashable {
    case stats, activities
}

/// Settings window tab destination -- driven by `AppModel.settingsTab`, read
/// by `SettingsView`'s `TabView(selection:)` and written by notification
/// routing (`.settingsBudget` → `.budget`).
public enum SettingsTab: Hashable {
    case general, categories, rules, uncategorized, llm, budget
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

    public var range: DateRangeSelection = .today()
    public var sidebarSelection: SidebarItem = .stats
    public var activityFilter: String?

    /// Selected Settings window tab -- default `.general`; notification
    /// routing (`.settingsBudget`) jumps this to `.budget`.
    public var settingsTab: SettingsTab = .general

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

    /// Menu bar icon label: today's focus time, kept in sync by `refreshMenu()`.
    public var menuTitle: String = "0m"
    /// Today's total tracked duration, for the menu bar dropdown.
    public var todayTotalTitle: String = "0m"
    /// Today's productivity score (0-100), for the menu bar dropdown. "--" if no data yet.
    public var todayPulseTitle: String = "--"

    /// @Observable mirror of `settings.menuBarTextEnabled` -- the KV setting
    /// itself isn't observable, so the menu bar label reads this property
    /// instead; the General settings pane's toggle writes both in lockstep.
    public var menuTextEnabled: Bool

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

    public var screenCollector: ScreenCollector?
    public var observationStore: ObservationStore?

    /// Today's meeting-tagged calendar events, refreshed by
    /// `refreshCalendarWindows()`. Not `@Observable`-tracked -- only
    /// `isNowInMeeting` (derived from it) needs to be, and that's read by
    /// `TrackerEngine.isInMeetingProvider`, not SwiftUI.
    @ObservationIgnored
    private var todayMeetingEvents: [CalendarEvent] = []

    /// C4 budgets -- same post-init injection convention as `calendarStore`:
    /// `TimeSinkApp.init` assigns these after constructing `AppModel`. All
    /// three are `nil` throughout `init()`'s bootstrap `refreshMenu()` call,
    /// which doubles as the "not wired up yet" guard `BudgetMonitor` needs
    /// (spec §8) -- `budgetMonitor?.evaluate(...)` is a no-op until assigned.
    public var budgetStore: BudgetStore?
    public var notifier: (any Notifying)?
    public var budgetMonitor: BudgetMonitor?

    /// C4 focus sessions -- same post-init injection convention as
    /// `calendarStore`/`budgetStore`: `TimeSinkApp.init` assigns these after
    /// constructing `AppModel`. `focus` is `nil` throughout `init()`'s
    /// bootstrap `refreshMenu()` call and until assembly wires it up; every
    /// view that reads `model.focus?.running` treats `nil` as "no session in
    /// progress", which is also the correct steady state pre-assembly.
    public var focusStore: FocusSessionStore?
    public var focus: FocusSessionController?

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
    private var rangeCache: [String: [CategorizedSpan]] = [:]

    /// LRU order for `rangeCache`'s keys, oldest first. Capped at
    /// `rangeCacheCap` entries -- once querying a *new* interval would push
    /// it over the cap, the least-recently-used entry is evicted. Bounds
    /// memory for callers that page through many distinct ranges (e.g. a
    /// heatmap or "environment comparison" view issuing several
    /// `rangedSpans(for:)` calls with different intervals per recompute)
    /// without ever hitting `dataChanged()` to clear the whole cache.
    @ObservationIgnored
    private var cacheOrder: [String] = []
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
        self.calendarOverlayEnabled = settings.calendarOverlayEnabled
        self.screenCapturePaused = settings.screenCapturePaused
        refreshMenu()
        // refreshMenu() just seeded rangeCache with a "today" snapshot taken
        // before any caller-visible dataChanged() boundary; drop it so the
        // first real query after construction always re-reads the store
        // rather than serving that bootstrap-time snapshot indefinitely.
        rangeCache.removeAll()
        cacheOrder.removeAll()
        engine.onChange = { [weak self] in self?.scheduleEngineDataChanged() }
    }

    /// Spans in the current `range`, clipped to it, and categorized.
    public func rangedSpans() -> [CategorizedSpan] {
        rangedSpans(for: range)
    }

    // MARK: - C1+ navigation intents

    /// Points the main window at Stats for `range` -- shared by the
    /// popover's drill-down click routes (C1+) and notification routing.
    /// Sets state only; the caller does `openWindow(id: "main")` (a SwiftUI
    /// environment action `AppModel` itself never touches).
    public func openStats(range: DateRangeSelection) {
        self.range = range
        sidebarSelection = .stats
    }

    /// Points the main window at Activities for `range`, filtered to
    /// `category` (`nil` clears any existing filter). Same navigation-intent
    /// convention as `openStats(range:)`.
    public func openActivities(category: String?, range: DateRangeSelection) {
        self.range = range
        sidebarSelection = .activities
        activityFilter = category
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
        let focus = Aggregator.focusTime(durationByCategory: byCategory, categories: resolver.categoriesByID)
        menuTitle = Format.duration(focus)
        todayTotalTitle = Format.duration(Aggregator.totalDuration(items.map(\.span)))
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

    /// The tracker wrote a span. Same invalidation, but deliberately does not
    /// touch `dataEditVersion`: this fires about every 1.5s while tracking
    /// and must not drag a once-a-day aggregation along with it.
    private func engineDataChanged() {
        invalidateAndBump()
    }

    /// The engine path is private and only ever reached through a 1.5s
    /// debounce, so `testDataEditVersionSeparatesUserEditsFromEngineWrites`
    /// needs a way in that does not involve waiting on a timer.
    func engineDataChangedForTesting() {
        engineDataChanged()
    }

    private func invalidateAndBump() {
        rangeCache.removeAll()
        cacheOrder.removeAll()
        refreshMenu()
        dataVersion += 1
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
        let key = "\(interval.start.timeIntervalSinceReferenceDate)-\(interval.end.timeIntervalSinceReferenceDate)"
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
            rangeCache[key] = result
            cacheOrder.append(key)
            while cacheOrder.count > Self.rangeCacheCap {
                rangeCache.removeValue(forKey: cacheOrder.removeFirst())
            }
            return result
        } catch {
            logger.error("rangedSpans failed: \(String(describing: error))")
            return []
        }
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
        // days + 1 ascending boundaries, built with the same
        // `date(byAdding: .day)` walk `Aggregator.dailyPulses` uses for its
        // per-day lookup keys, so bucket i is the same calendar day it would
        // have looked up -- including DST days, which are 23 or 25 hours long
        // here and in `Aggregator.split` alike.
        let todayStart = calendar.startOfDay(for: endingAt)
        let boundaries = ((-1)...(days - 1)).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: todayStart)
        }
        guard boundaries.count == days + 1 else { return Array(repeating: nil, count: days) }

        do {
            let (totals, straddlers) = try spanStore.dailyTupleTotals(dayBoundaries: boundaries)
            var byDay = Array(repeating: [String: TimeInterval](), count: days)
            for total in totals {
                // `CategoryResolver.categoryID(for:)` reads only these four
                // fields (they are its memo key), so a probe span with
                // placeholder timestamps classifies identically to the rows
                // it stands for -- and the resolver's memo means each tuple
                // costs a dictionary hit after its first day.
                let probe = Span(start: todayStart, end: todayStart, appBundleID: total.appBundleID,
                                 appName: "", title: total.title, url: total.url, domain: total.domain)
                byDay[total.dayIndex][resolver.categoryID(for: probe), default: 0] += total.seconds
            }
            // Boundary-crossing spans, split across the buckets they touch.
            // Clipping is implicit: a part outside [first, last] boundary
            // never matches, which is what `rangedSpans`' clip-to-interval
            // did at both ends of the window.
            for span in straddlers {
                let categoryID = resolver.categoryID(for: span)
                for index in 0..<days {
                    let start = max(span.start, boundaries[index])
                    let end = min(span.end, boundaries[index + 1])
                    guard end > start else { continue }
                    byDay[index][categoryID, default: 0] += end.timeIntervalSince(start)
                }
            }
            return byDay.map { Aggregator.pulse(durationByCategory: $0, categories: resolver.categoriesByID) }
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
    private func touchCacheKey(_ key: String) {
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
        guard calendarOverlayEnabled, let calendarStore, Permissions.calendarState() == .granted else {
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
            }
        }
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
            deltaClause = "（较昨日 \(Format.signedInt(pulse - yesterdayPulse))）"
        } else {
            deltaClause = ""
        }

        // Peak = the highest-total consecutive 2-hour window, per the brief.
        var hourTotals = Array(repeating: 0.0, count: 24)
        for (hour, seconds) in Aggregator.profileByHourOfDay(items, calendar: calendar) {
            hourTotals[hour] = seconds
        }
        let peak = BudgetEngine.peakTwoHourWindow(hourTotals)

        let body = "专注 \(Format.duration(focus))，生产力分 \(pulse)\(deltaClause)。"
            + "最高峰在 \(peak.start) – \(peak.end) 时。"
        return ("今日小结", body)
    }

    public func setScreenCapturePaused(_ paused: Bool) {
        screenCapturePaused = paused
        settings.setScreenCapturePaused(paused)
        guard let screenCollector else { return }
        Task { await screenCollector.setPaused(paused) }
    }
}
