import AppKit
import SwiftUI
import Observation

/// 活动 tab: a grouped category/domain/title breakdown (`ActivityListView`,
/// flexible width) plus, for single-day-ish ranges, a vertical day timeline
/// (`DayTimelineView`, fixed width) mapped from the same spans — plus (C3) a
/// calendar band above both that walks through enable/guide/quiet states
/// depending on the overlay setting and live calendar permission.
struct ActivitiesView: View {
    let model: AppModel

    @Bindable var activities: ActivitiesModel

    /// Debounces search-driven recomputes only — see `scheduleSearchRecompute()`.
    /// Every other trigger (`dataVersion`/`range`/`activityFilter`) recomputes
    /// immediately, unrelated to this.
    @State private var pendingSearch: Task<Void, Never>?
    @State private var showsInspector = true

    /// Tracks the in-flight `refreshCalendarOverlay()` Task spawned by the
    /// `didBecomeActive` handler below -- see that handler's doc comment for
    /// why this needs the same store/cancel discipline `pendingSearch` uses.
    @State private var pendingActivationRefresh: Task<Void, Never>?

    /// C3: the current range's calendar events, fetched by `.task` below and
    /// re-fed into every `recompute` call so `activities.calendarBlocks`/
    /// `meetingSpanIDs`/etc. stay in sync with what's on screen.
    @State private var calendarEvents: [CalendarEvent] = []
    @State private var calendarPermissionState: PermissionState = .notDetermined

    private var searchBinding: Binding<String> {
        Binding(get: { model.activitySearch }, set: { model.activitySearch = $0 })
    }

    /// `.task(id:)` key: re-fetches calendar events whenever the visible
    /// range changes OR the overlay setting flips (from this view's own
    /// band, or from the Settings pane) -- either alone would leave the
    /// other trigger's change unobserved.
    private struct CalendarTaskKey: Equatable {
        let range: DateRangeSelection
        let overlayEnabled: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            timeFilterBanner
            calendarBand

            HStack(alignment: .top, spacing: 0) {
                ActivityListView(model: model, activities: activities, groups: activities.groups,
                                  matchCount: activities.matchCount, matchSeconds: activities.matchSeconds,
                                  meetingSeconds: activities.meetingSeconds)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if ActivitiesModel.showsTimeline(model.range) {
                    Divider()
                    DayTimelineView(day: model.range.interval.start, blocks: activities.timelineBlocks,
                                    events: activities.calendarBlocks, allDay: activities.allDayTitles,
                                    focusBlocks: activities.focusBlocks,
                                    selectedActivity: activities.selectedActivity,
                                    selectedStart: activities.selectedStart,
                                    isFiltered: model.activityTimeInterval != nil || model.activityFilter != nil || ActivitiesModel.normalizedQuery(model.activitySearch) != nil,
                                    hourHeight: $activities.timelineHourHeight,
                                    onSelect: selectTimelineBlock)
                        .padding(10).frame(width: 230)
                }
            }
        }
        .background(WorkspaceBackground())
        .inspector(isPresented: $showsInspector) {
            ActivityInspector(model: model, activities: activities)
                .inspectorColumnWidth(min: 260, ideal: 272, max: 320)
        }
        .searchable(text: searchBinding, prompt: "搜索应用、网址、标题")
        .toolbar {
            ToolbarItem {
                Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help("显示活动检查器")
            }
            ToolbarItem {
                Menu {
                    Button("所有分类") { model.activityFilter = nil }
                    Divider()
                    ForEach(model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { category in
                        Button(category.name) { model.activityFilter = category.id }
                    }
                } label: {
                    Label(model.activityFilter.flatMap { model.resolver.categoriesByID[$0]?.name } ?? String(localized: "所有分类"), systemImage: "line.3.horizontal.decrease")
                }
                .help("按分类筛选活动")
            }
        }
        .task {
            await Task.yield()
            activities.recompute(model: model, events: calendarEvents)
        }
        .onChange(of: model.dataVersion) { _, _ in activities.recompute(model: model, events: calendarEvents) }
        .onChange(of: activities.selectedActivity) { _, value in if value != nil { showsInspector = true } }
        .onChange(of: model.range) { _, _ in activities.recompute(model: model, events: calendarEvents) }
        .onChange(of: model.activityTimeInterval) { _, _ in activities.recompute(model: model, events: calendarEvents) }
        .onChange(of: model.activityFilter) { _, _ in activities.recompute(model: model, events: calendarEvents) }
        .onChange(of: model.activitySearch) { _, _ in scheduleSearchRecompute() }
        .onDisappear {
            pendingSearch?.cancel()
            pendingActivationRefresh?.cancel()
        }
        .task(id: CalendarTaskKey(range: model.range, overlayEnabled: model.calendarOverlayEnabled)) {
            await refreshCalendarOverlay()
        }
        // Closes the "denied -> System Settings -> grant" round-trip: the
        // guide card's permission state is otherwise only re-read by the
        // `.task(id:)` above, which doesn't re-run just because the app
        // regained focus -- without this, granting access in System
        // Settings and switching back would leave the guide card showing
        // until the range happened to change. Re-reads state and refetches
        // on every reactivation (harmless when nothing actually changed).
        //
        // Stores/cancels the spawned Task the same way `pendingSearch` does
        // (rather than firing an untracked `Task { }` per notification):
        // `refreshCalendarOverlay()`'s `Task.isCancelled` guard after its
        // `await store.events(on:)` fetch only protects against a stale
        // write if something actually cancels the stale Task -- `.task(id:)`
        // gets that for free from SwiftUI when its id changes, but a plain
        // `Task { }` spawned from `.onReceive` never does. Without this, two
        // reactivations in quick succession (e.g. fast Cmd-Tabbing) could
        // let an earlier, slower fetch for a since-abandoned range land
        // after a newer one already wrote the correct state, clobbering it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pendingActivationRefresh?.cancel()
            pendingActivationRefresh = Task { @MainActor in
                await refreshCalendarOverlay()
            }
        }
    }

    @ViewBuilder private var timeFilterBanner: some View {
        if let interval = model.activityTimeInterval {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("热力图时段 · \(interval.start.formatted(.dateTime.month().day()))", systemImage: "square.grid.3x3")
                    Text("\(interval.start.formatted(date: .omitted, time: .shortened))–\(interval.end.formatted(date: .omitted, time: .shortened))")
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                HStack {
                    Text("列表仅统计此时段；全天时间轴高亮命中记录。")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("返回热力图") { model.returnToHeatmap() }
                    Button("显示全天") { model.clearActivityTimeFilter() }
                }
                .font(.caption)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func selectTimelineBlock(_ block: TimelineBlock) {
        guard let selection = block.activity else { return }
        if !block.matchesFilter {
            pendingSearch?.cancel()
            model.activitySearch = ""
            model.activityFilter = nil
            model.clearActivityTimeFilter()
            activities.recompute(model: model, events: calendarEvents)
        }
        activities.select(selection, start: block.start)
    }

    /// Three states (C3 interaction spec): overlay off or permission not yet
    /// decided -> enable card; overlay on but access denied/restricted ->
    /// guide-to-settings card; overlay on and granted -> nothing here (the
    /// events themselves surface via the timeline's event lane and the
    /// list's meeting badges/summary, not a persistent band).
    @ViewBuilder
    private var calendarBand: some View {
        if !model.calendarOverlayEnabled || calendarPermissionState == .notDetermined {
            CalendarBandCard(
                title: String(localized: "日历叠加"),
                message: String(localized: "在时间轴上叠加你的日历日程，自动标注会议时间；会议期间空闲不会触发挂起。"),
                actionTitle: String(localized: "启用"),
                action: enableCalendarOverlay
            )
        } else if calendarPermissionState != .granted {
            CalendarBandCard(
                title: String(localized: "日历访问被拒绝"),
                message: String(localized: "无法叠加日程或自动标注会议。前往系统设置重新授权日历访问后即可生效。"),
                actionTitle: String(localized: "打开系统设置"),
                action: openCalendarSystemSettings
            )
        }
    }

    /// Turns the overlay setting on and requests calendar access (a no-op
    /// prompt-wise if already decided). `model.calendarOverlayEnabled = true`
    /// alone already retriggers the `.task(id:)` above via `CalendarTaskKey`,
    /// but that task computes its own fresh permission read at its own
    /// start, which can race ahead of the system prompt this triggers --
    /// hence the explicit follow-up work once the request resolves: on a
    /// fresh grant, `invalidateCache()` (belt-and-braces alongside the
    /// `.EKEventStoreChanged` notification that usually fires on its own --
    /// see `CalendarStore.invalidateCache`'s doc comment), then
    /// `refreshCalendarWindows()` so the idle-exemption seam
    /// (`isNowInMeeting`) picks up today's meetings immediately rather than
    /// staying inert for up to 5 minutes until the next background refresh,
    /// then this view's own `refreshCalendarOverlay()` for the visible UI.
    private func enableCalendarOverlay() {
        model.calendarOverlayEnabled = true
        model.settings.setCalendarOverlayEnabled(true)
        // Explicit user action -> `dataChanged()` directly (not the debounced
        // engine-change path, which is only for `engine.onChange`). Harmless
        // even though no span/category data actually changed: it just bumps
        // `dataVersion`, causing this and every other range-scoped view to
        // re-query once.
        model.dataChanged()
        Task { @MainActor in
            let granted = await Permissions.requestCalendarAccess()
            if granted {
                await model.calendarStore?.invalidateCache()
            }
            await model.refreshCalendarWindows()
            await refreshCalendarOverlay()
        }
    }

    private func openCalendarSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Re-reads the live calendar permission state and, only while the
    /// overlay setting is on AND access is granted, fetches the current
    /// range's events and feeds them into `recompute` -- otherwise clears
    /// both so a disabled/revoked state doesn't keep showing stale events.
    /// Checks `Task.isCancelled` right after the fetch, before touching any
    /// `@State` -- this runs inside `.task(id:)` (cancelled/replaced the
    /// instant `model.range`/`calendarOverlayEnabled` changes again) as well
    /// as one-shot callers, so without the guard a slow fetch for a range
    /// the user has already navigated away from could land after a newer
    /// task already wrote the correct state, clobbering it with stale data.
    private func refreshCalendarOverlay() async {
        calendarPermissionState = Permissions.calendarState()
        guard model.calendarOverlayEnabled, calendarPermissionState == .granted,
              let store = model.calendarStore else {
            calendarEvents = []
            activities.recompute(model: model, events: calendarEvents)
            return
        }
        let fetched = await store.events(on: model.range.interval.start)
        guard !Task.isCancelled else { return }
        calendarEvents = fetched
        activities.recompute(model: model, events: calendarEvents)
    }

    /// Search is a read-path filter over already-cached spans — it must
    /// never call `model.dataChanged()` (that would bump `dataVersion` and
    /// re-trigger the engine debounce). Shaped like
    /// `AppModel.scheduleEngineDataChanged`: cancel any pending recompute,
    /// then schedule a fresh one. Single-day ranges recompute immediately
    /// (0ms) since their span count is small; every other range debounces
    /// 200ms so fast typing doesn't re-filter a potentially large range on
    /// every keystroke.
    private func scheduleSearchRecompute() {
        pendingSearch?.cancel()
        let delay: Duration = model.range.kind == .day ? .zero : .milliseconds(200)
        pendingSearch = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            activities.recompute(model: model, events: calendarEvents)
        }
    }
}

/// Enable-card / guide-card chrome for `ActivitiesView.calendarBand`. Mirrors
/// `PermissionRow(compact: false)`'s look, but deliberately isn't
/// `PermissionRow` itself: that component disables its action button once
/// `state == .granted`, which is wrong here -- this card's button flips
/// `calendarOverlayEnabled` (an app setting), a different axis from the
/// underlying `PermissionState` a user can already have granted access, then
/// turned the overlay off, and must still be able to click "启用" to turn it
/// back on.
private struct CalendarBandCard: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

/// Computes `ActivitiesView`'s category/domain/title breakdown and (for
/// single-day-ish ranges, see `showsTimeline`) the day's timeline blocks
/// from a single `rangedSpans()` call per recompute — mirrors
/// StatsView/StatsModel's established pattern.
@MainActor
@Observable
final class ActivitiesModel {
    struct TitleRow: Identifiable {
        var id: String { title }
        let title: String
        let seconds: TimeInterval
    }

    /// A domain (browser), app (native), or (display-only) entity row within
    /// a category, with its per-title breakdown. `isDomain` says which
    /// `CategoryStore` method a reassignment should use — derived from
    /// whether the underlying spans carried a `domain`, not from the string
    /// shape of `id`. `id` is the display grouping key (may be a finer-grained
    /// `EntityParser` key), while `reassignKey` is always the domain or
    /// bundleID a reassignment actually writes to `CategoryStore` — the two
    /// diverge exactly when `isEntity` is true.
    struct ActivityRow: Identifiable {
        let id: String
        let label: String
        let seconds: TimeInterval
        let isDomain: Bool
        let reassignKey: String
        let isEntity: Bool
        /// True when any span grouped into this row overlaps a meeting event
        /// by >= 50% of its own duration (C3 -- see `MeetingTagger.tagged`).
        let hasMeeting: Bool
        let titles: [TitleRow]
    }

    struct CategoryGroup: Identifiable {
        let id: String
        let name: String
        let colorHex: String
        let seconds: TimeInterval
        let rows: [ActivityRow]
    }

    var groups: [CategoryGroup] = []
    var displayedItems: [CategorizedSpan] = []
    var timelineBlocks: [TimelineBlock] = []
    /// C4 focus sessions overlapping the visible range (single-day-ish
    /// ranges only, same gate as `timelineBlocks`) -- `DayTimelineView`
    /// renders these as a dashed outline lane over the activity column.
    var focusBlocks: [TimelineBlock] = []

    /// C3 calendar overlay -- populated only for single-day-ish ranges (see
    /// `showsTimeline`), from the `events` the caller fetched via
    /// `CalendarStore.events(on:)` and passed into `recompute`.
    var calendarBlocks: [TimelineEventBlock] = []
    var allDayTitles: [String] = []
    /// Span ids overlapping a meeting by >= 50% -- badges `ActivityRow.hasMeeting`.
    var meetingSpanIDs: Set<Int64> = []
    /// Summed duration of `meetingSpanIDs`' spans -- the list's "会议时间" summary row.
    var meetingSeconds: TimeInterval = 0

    /// Non-nil only while `model.activitySearch` holds a normalized query —
    /// the match-count row above the list reads these; `nil` means "no
    /// active search" (distinct from "search matched zero items").
    var matchCount: Int?
    var matchSeconds: TimeInterval?

    var selectedActivity: ActivitySelection?
    var selectedStart: Date?
    var timelineHourHeight: CGFloat = 64
    var expandedRows: Set<ActivitySelection> = []
    var collapsedCategories: Set<String> = []
    @ObservationIgnored private var selectionRange: DateInterval?
    @ObservationIgnored private var selectionTimeInterval: DateInterval?

    func select(_ activity: ActivitySelection, start: Date? = nil) {
        selectedActivity = activity
        expandedRows.insert(activity.row)
        collapsedCategories.remove(activity.categoryID)
        let matching = timelineBlocks.filter { $0.matchesFilter && ($0.activity.map(activity.matches) ?? false) }
        selectedStart = start.flatMap { date in
            matching.first { $0.start <= date && date < $0.end }?.start
        } ?? matching.first?.start
    }

    nonisolated static func selection(for item: CategorizedSpan) -> ActivitySelection {
        let span = item.span
        let entity = span.domain.flatMap { domain in
            span.url.flatMap { EntityParser.entity(urlString: $0, domain: domain) }
        }
        let rowID = span.document.map { "\(span.appBundleID)/\($0)" }
            ?? entity?.key ?? span.domain ?? span.appBundleID
        return ActivitySelection(categoryID: item.categoryID, rowID: rowID,
                                 title: span.title?.isEmpty == false ? span.title! : String(localized: "(无标题)"))
    }

    /// `events` (C3): the current range's calendar events, fetched
    /// asynchronously by `ActivitiesView` via `CalendarStore.events(on:)`
    /// and handed in here -- `recompute` itself stays synchronous (existing
    /// `onChange` call sites are unaffected), so `events` defaults to `[]`
    /// for every call site that predates the calendar overlay.
    func recompute(model: AppModel, events: [CalendarEvent] = []) {
        if selectionRange != model.range.interval || selectionTimeInterval != model.activityTimeInterval {
            selectedActivity = nil
            selectedStart = nil
            selectionRange = model.range.interval
            selectionTimeInterval = model.activityTimeInterval
            expandedRows.removeAll()
            collapsedCategories.removeAll()
        }
        let all = model.rangedSpans()
        let categories = model.resolver.categoriesByID

        let query = Self.normalizedQuery(model.activitySearch)
        let scoped = model.activityTimeInterval.map {
            Aggregator.clippedToElapsed(all, windowStart: $0.start, elapsed: $0.duration)
        } ?? all
        let items = Self.filter(scoped, query: query)

        // R-T9a: the match-count row must agree with what `ActivityListView`
        // actually displays. `ActivityListView` narrows `groups` to one
        // category when `model.activityFilter` is set, so the count/seconds
        // above the list have to be scoped the same way — otherwise the
        // header can show hits from every category while the (single-category)
        // list below it is empty. `groups` itself stays built from the
        // category-unfiltered `items` below, so `ActivityListView` can still
        // tell "no matches anywhere" apart from "matches exist, just not in
        // this category" for its empty-state text.
        let matchedItems: [CategorizedSpan]
        if let filterCategoryID = model.activityFilter {
            matchedItems = items.filter { $0.categoryID == filterCategoryID }
        } else {
            matchedItems = items
        }
        displayedItems = matchedItems
        let hasFilter = query != nil || model.activityTimeInterval != nil
        matchCount = hasFilter ? matchedItems.count : nil
        matchSeconds = hasFilter ? Aggregator.totalDuration(matchedItems.map(\.span)) : nil

        // R-T10a: `meetingSpanIDs` badges live on `groups`' rows, and `groups`
        // (like `matchCount`'s underlying `items`) stays category-UNFILTERED
        // -- the category chip only narrows `displayedGroups` in the view
        // layer, so narrowing the badge set to `matchedItems` would silently
        // un-badge a meeting span in a category the chip has filtered out of
        // view while its row is still shown elsewhere. `meetingSeconds`, by
        // contrast, IS a single summary number shown above the (possibly
        // category-narrowed) list -- exactly `matchSeconds`' situation above
        // -- so it must share `matchedItems`' scoping (search AND category),
        // not `meetingSpanIDs`'s. Two separate `tagged()` calls rather than
        // reusing one result for both, since the two axes genuinely differ.
        // R-T10b: both are gated off entirely outside single-day-ish ranges
        // -- `events` was fetched for one specific day
        // (`model.range.interval.start`), so tagging it against a multi-day
        // range's spans (e.g. `last30`, whose spans span 29 other days) would
        // silently score every span against the wrong day's calendar.
        let showsTimeline = Self.showsTimeline(model.range)
        if showsTimeline {
            meetingSpanIDs = MeetingTagger.tagged(items: items, events: events).spanIDs
            meetingSeconds = MeetingTagger.tagged(items: matchedItems, events: events).seconds
        } else {
            meetingSpanIDs = []
            meetingSeconds = 0
        }

        var byCategory: [String: [CategorizedSpan]] = [:]
        for item in items {
            byCategory[item.categoryID, default: []].append(item)
        }

        groups = byCategory
            .compactMap { categoryID, spans -> CategoryGroup? in
                guard let category = categories[categoryID] else { return nil }
                return CategoryGroup(
                    id: categoryID,
                    name: category.name,
                    colorHex: category.colorHex,
                    seconds: spans.reduce(0) { $0 + $1.span.duration },
                    rows: Self.rows(for: spans, meetingSpanIDs: meetingSpanIDs)
                )
            }
            .sorted { $0.seconds > $1.seconds }

        // Timeline keeps the unfiltered `all` so a narrowed list still shows
        // the full day's context (spec §7) rather than collapsing around
        // just the search hits.
        let visibleSelections = Set(matchedItems.map(Self.selection))
        let filterCategory = model.activityFilter
        let timeInterval = model.activityTimeInterval
        let timelineItems = Self.splitAtTimeFilter(all, interval: timeInterval)
        timelineBlocks = showsTimeline ? Self.timelineBlocks(timelineItems, categories: categories) { item in
            (filterCategory == nil || item.categoryID == filterCategory)
                && (query.map { Self.matches(item, query: $0) } ?? true)
                && (timeInterval.map { item.span.start < $0.end && item.span.end > $0.start } ?? true)
        } : []
        if let selectedActivity {
            if !visibleSelections.contains(where: selectedActivity.matches) {
                self.selectedActivity = nil
                selectedStart = nil
            } else if !timelineBlocks.contains(where: { $0.matchesFilter && $0.start == selectedStart && ($0.activity.map(selectedActivity.matches) ?? false) }) {
                selectedStart = timelineBlocks.first { $0.matchesFilter && ($0.activity.map(selectedActivity.matches) ?? false) }?.start
            }
        }
        if selectedActivity == nil, timeInterval != nil,
           let first = timelineBlocks.first(where: \.matchesFilter), let activity = first.activity {
            select(activity, start: first.start)
        }
        calendarBlocks = showsTimeline ? Self.eventBlocks(events, dayInterval: model.range.interval) : []
        allDayTitles = showsTimeline ? events.filter { $0.isAllDay && !$0.isDeclined }.map(\.title) : []

        if showsTimeline, let focusStore = model.focusStore {
            let sessions = (try? focusStore.sessions(overlapping: model.range.interval)) ?? []
            focusBlocks = Self.focusTimelineBlocks(sessions, items: all, categories: categories,
                                                   dayInterval: model.range.interval)
        } else {
            focusBlocks = []
        }
    }

    /// Split at the filter's exact edges so the timeline never highlights
    /// the out-of-range part of an activity that crosses an hour boundary.
    nonisolated static func splitAtTimeFilter(_ items: [CategorizedSpan], interval: DateInterval?) -> [CategorizedSpan] {
        guard let interval else { return items }
        return items.flatMap { item in
            let edges = [item.span.start]
                + [interval.start, interval.end].filter { $0 > item.span.start && $0 < item.span.end }
                + [item.span.end]
            return zip(edges, edges.dropFirst()).map { start, end in
                var piece = item
                piece.span.start = start
                piece.span.end = end
                return piece
            }
        }
    }

    /// Whether the current range is single-day-ish enough to show the day
    /// timeline (relaxed from `range.kind == .day` to also cover a custom
    /// range that happens to span one day — a UI gap carried over from the
    /// interaction spec). Shared by `recompute` (gates `timelineBlocks`/
    /// `calendarBlocks`/`allDayTitles`) and `ActivitiesView` (gates whether
    /// `DayTimelineView` is shown at all), so the two can never disagree.
    nonisolated static func showsTimeline(_ range: DateRangeSelection) -> Bool {
        abs(range.interval.duration - 86400) < 7200
    }

    // MARK: - Search

    /// Trims whitespace/newlines; an all-whitespace (or empty) query becomes
    /// `nil`, meaning "no active search" (as opposed to a query nothing
    /// matches).
    nonisolated static func normalizedQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Case-insensitive substring match against `domain` / `appName` /
    /// `title` / `url`, in that order, short-circuiting on first hit.
    nonisolated static func matches(_ item: CategorizedSpan, query: String) -> Bool {
        let span = item.span
        if let domain = span.domain, domain.localizedCaseInsensitiveContains(query) { return true }
        if span.appName.localizedCaseInsensitiveContains(query) { return true }
        if let title = span.title, title.localizedCaseInsensitiveContains(query) { return true }
        if let url = span.url, url.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    /// `items` unchanged when `query` is `nil`; otherwise only the items
    /// `matches` accepts.
    nonisolated static func filter(_ items: [CategorizedSpan], query: String?) -> [CategorizedSpan] {
        guard let query else { return items }
        return items.filter { matches($0, query: query) }
    }

    // MARK: - List grouping

    /// Not `private`, and `nonisolated`: pure function, exercised directly by
    /// `ActivitiesModelTests` via `@testable import` (which sees `internal`,
    /// not `private`, members) without needing a `@MainActor` hop — same
    /// convention as `timelineBlocks` below.
    ///
    /// Groups by `span.document ?? EntityParser.entity(...)?.key ??
    /// span.domain ?? span.appBundleID` — a finer display-level key than
    /// plain domain-or-app whenever the span carries one: a working
    /// directory, an open file, an AI chat conversation (migration v7), or a
    /// URL entity (github/gitlab owner-repo, youtube channel). The document
    /// outranks the URL entity because the two never coexist — a document
    /// comes from a native window, a URL entity from a browser tab — and
    /// because it is the more specific of the two where they could.
    /// `reassignKey` always stays at the domain/bundleID level regardless,
    /// since that's the only granularity `CategoryStore` understands.
    nonisolated static func rows(for items: [CategorizedSpan], meetingSpanIDs: Set<Int64> = []) -> [ActivityRow] {
        struct Accum {
            var seconds: TimeInterval = 0
            var label: String?
            var reassignKey: String = ""
            var isDomain = false
            var isEntity = false
            var hasMeeting = false
            var titles: [String: TimeInterval] = [:]
        }

        var byKey: [String: Accum] = [:]
        for item in items {
            let span = item.span
            let entity = span.domain.flatMap { domain in
                span.url.flatMap { EntityParser.entity(urlString: $0, domain: domain) }
            }
            // Namespaced by bundle ID: two apps can legitimately be on the
            // same document (an editor and a terminal in one repo) and must
            // not merge into a row that claims to be one activity.
            let documentKey = span.document.map { "\(span.appBundleID)/\($0)" }
            let key = documentKey ?? entity?.key ?? span.domain ?? span.appBundleID

            var accum = byKey[key] ?? Accum()
            accum.seconds += span.duration
            if accum.label == nil {
                accum.label = span.document.map { "\(span.appName) / \(DocumentIdentity.label(for: $0))" }
                    ?? entity?.label ?? span.domain ?? span.appName
                accum.reassignKey = span.domain ?? span.appBundleID
                accum.isDomain = span.domain != nil
                // Both kinds of row are finer than what they reassign at, and
                // the context menu says so.
                accum.isEntity = entity != nil || span.document != nil
            }
            if let id = span.id, meetingSpanIDs.contains(id) {
                accum.hasMeeting = true
            }
            let title = (span.title?.isEmpty == false) ? span.title! : String(localized: "(无标题)")
            accum.titles[title, default: 0] += span.duration
            byKey[key] = accum
        }

        return byKey.map { key, accum in
            let titles = accum.titles
                .map { TitleRow(title: $0.key, seconds: $0.value) }
                .sorted { lhs, rhs in
                    lhs.seconds != rhs.seconds ? lhs.seconds > rhs.seconds : lhs.title < rhs.title
                }
            return ActivityRow(
                id: key,
                label: accum.label ?? key,
                seconds: accum.seconds,
                isDomain: accum.isDomain,
                reassignKey: accum.reassignKey,
                isEntity: accum.isEntity,
                hasMeeting: accum.hasMeeting,
                titles: Array(titles)
            )
        }
        .sorted { lhs, rhs in
            lhs.seconds != rhs.seconds ? lhs.seconds > rhs.seconds : lhs.id < rhs.id
        }
    }

    // MARK: - Timeline blocks

    /// Keep app/title identity and short activities intact so a selected
    /// interval always maps back to the row it describes. Only truly adjoining
    /// intervals of the same activity can share a visual block.
    nonisolated static func timelineBlocks(_ items: [CategorizedSpan], categories: [String: Category],
                                          matching: (CategorizedSpan) -> Bool = { _ in true }) -> [TimelineBlock] {
        var merged: [(item: CategorizedSpan, end: Date)] = []
        for item in items.sorted(by: { $0.span.start < $1.span.start }) where item.span.duration > 0 {
            if let last = merged.last,
               selection(for: last.item) == selection(for: item),
               matching(last.item) == matching(item),
               item.span.start == last.end {
                merged[merged.count - 1].end = item.span.end
            } else {
                merged.append((item, item.span.end))
            }
        }
        return merged.map { item, end in
            TimelineBlock(start: item.span.start, end: end,
                          color: Color(hex: categories[item.categoryID]?.colorHex ?? "#98989D"),
                          label: item.span.domain ?? item.span.appName,
                          tooltip: tooltip(repSpan: item.span, start: item.span.start, end: end),
                          activity: selection(for: item), matchesFilter: matching(item))
        }
    }

    /// Zero-padded 24-hour "HH:mm", built from raw calendar components
    /// rather than `DateFormatter` — `DateFormatter` isn't `Sendable`, and a
    /// stored instance of it can't be `nonisolated` under strict
    /// concurrency; components sidestep that while staying locale-independent.
    private nonisolated static func hhmm(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    private nonisolated static func tooltip(repSpan: Span, start: Date, end: Date) -> String {
        var lines: [String] = []
        if let title = repSpan.title, !title.isEmpty {
            lines.append("\(repSpan.appName) — \(title)")
        } else {
            lines.append(repSpan.appName)
        }
        if let url = repSpan.url, !url.isEmpty {
            lines.append(url)
        }
        lines.append("\(hhmm(start))–\(hhmm(end)) (\(Format.duration(end.timeIntervalSince(start))))")
        return lines.joined(separator: "\n")
    }

    // MARK: - C4 focus session blocks

    /// Not `private`, and `nonisolated`: pure function, exercised directly by
    /// tests via `@testable import` without needing a `@MainActor` hop --
    /// same convention as `timelineBlocks` above. `items` is the day's
    /// UNFILTERED spans (`all`, not search/category-narrowed) -- the
    /// tooltip's productivity number describes what actually happened during
    /// the session, not what a search happens to match.
    ///
    /// Each block's rendered `start`/`end` are clipped to `dayInterval` for
    /// the same reason `eventBlocks` clips calendar events: `sessions(
    /// overlapping:)` returns a midnight-crossing session on BOTH days, and
    /// `DayTimelineView` positions purely off minutes-from-midnight. Without
    /// the clip, a 23:50 -> 00:15 session draws a phantom 23:50 block on the
    /// END day (while its real 00:00–00:15 slice goes missing) and overruns
    /// the bottom of the START day's 24h grid. The tooltip keeps reading the
    /// ORIGINAL session, so 专注 时长 and 拦下 次数 stay the session's true
    /// totals on both days no matter how much is clipped away.
    nonisolated static func focusTimelineBlocks(
        _ sessions: [FocusSession], items: [CategorizedSpan], categories: [String: Category],
        dayInterval: DateInterval
    ) -> [TimelineBlock] {
        sessions.compactMap { session -> TimelineBlock? in
            guard let clip = clipToDay(start: session.start, end: session.end, dayInterval: dayInterval) else {
                return nil
            }
            let elapsed = session.end.timeIntervalSince(session.start)
            let clipped = Aggregator.clippedToElapsed(items, windowStart: session.start, elapsed: elapsed)
            let byCategory = Aggregator.durationByCategory(clipped)
            let pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories)
            let distractions = session.appBlocks + session.siteBlocks
            let tooltip = String(localized: "专注 \(Format.duration(elapsed)) · 拦下 \(distractions) 次分心 · 期间分 \(pulse.map(String.init) ?? "--")")
            return TimelineBlock(start: clip.start, end: clip.end, color: .accentColor,
                                  label: String(localized: "专注"), tooltip: tooltip)
        }
    }

    /// Clips `[start, end)` to the displayed day, or `nil` when nothing of it
    /// lands inside. Every block handed to `DayTimelineView` must already be
    /// inside the displayed day -- it positions off minutes-from-midnight of
    /// the BLOCK's own date, so an unclipped cross-midnight block lands at
    /// the wrong y on the wrong day. Shared by both lanes (calendar events
    /// and focus sessions) so the two can never drift apart; `nonisolated
    /// static` so it's unit-testable on its own.
    nonisolated static func clipToDay(
        start: Date, end: Date, dayInterval: DateInterval
    ) -> (start: Date, end: Date)? {
        let clippedStart = max(start, dayInterval.start)
        let clippedEnd = min(end, dayInterval.end)
        guard clippedEnd > clippedStart else { return nil }
        return (clippedStart, clippedEnd)
    }

    // MARK: - Calendar event lane (C3)

    /// Non-all-day, non-declined calendar events -> `TimelineEventBlock`,
    /// for the day timeline's event lane. All-day events go through
    /// `allDayTitles` instead (no meaningful y-position); declined events
    /// are dropped entirely, same as they're excluded from `isMeeting`.
    ///
    /// Each block's `start`/`end` are clipped to `dayInterval` (the
    /// displayed range) before being handed to `DayTimelineView`, which
    /// positions purely off minutes-from-midnight -- without clipping, a
    /// cross-midnight event (23:00-01:00) would draw at y=23h with a 2h
    /// height on today's 24h grid, and a 3-day timed event would draw 72h
    /// tall. `eventTooltip` still reads the ORIGINAL (unclipped) event, so
    /// the tooltip keeps showing the event's true start/end regardless of
    /// how much of it is visually clipped into this day's column. An event
    /// clipped down to <= 0 duration (entirely outside `dayInterval`) is
    /// dropped.
    private nonisolated static func eventBlocks(
        _ events: [CalendarEvent], dayInterval: DateInterval
    ) -> [TimelineEventBlock] {
        events
            .filter { !$0.isAllDay && !$0.isDeclined }
            .compactMap { event -> TimelineEventBlock? in
                guard let clip = clipToDay(start: event.start, end: event.end, dayInterval: dayInterval) else {
                    return nil
                }
                return TimelineEventBlock(
                    id: event.id,
                    title: event.title,
                    start: clip.start,
                    end: clip.end,
                    color: Color(hex: event.colorHex),
                    tooltip: eventTooltip(event)
                )
            }
    }

    private nonisolated static func eventTooltip(_ event: CalendarEvent) -> String {
        "\(event.title)\n\(hhmm(event.start))–\(hhmm(event.end)) · \(event.calendarTitle)"
    }
}
