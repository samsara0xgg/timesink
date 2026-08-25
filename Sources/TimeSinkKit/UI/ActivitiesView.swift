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

    @State private var activities = ActivitiesModel()

    /// Debounces search-driven recomputes only — see `scheduleSearchRecompute()`.
    /// Every other trigger (`dataVersion`/`range`/`activityFilter`) recomputes
    /// immediately, unrelated to this.
    @State private var pendingSearch: Task<Void, Never>?

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
            calendarBand

            HStack(alignment: .top, spacing: 12) {
                ActivityListView(model: model, groups: activities.groups,
                                  matchCount: activities.matchCount, matchSeconds: activities.matchSeconds,
                                  meetingSeconds: activities.meetingSeconds)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if ActivitiesModel.showsTimeline(model.range) {
                    DayTimelineView(blocks: activities.timelineBlocks,
                                     events: activities.calendarBlocks,
                                     allDay: activities.allDayTitles)
                        .frame(width: 260)
                }
            }
        }
        .padding()
        .searchable(text: searchBinding, prompt: "搜索应用、网址、标题")
        .onAppear { activities.recompute(model: model, events: calendarEvents) }
        .onChange(of: model.dataVersion) { _, _ in activities.recompute(model: model, events: calendarEvents) }
        .onChange(of: model.range) { _, _ in activities.recompute(model: model, events: calendarEvents) }
        .onChange(of: model.activityFilter) { _, _ in activities.recompute(model: model, events: calendarEvents) }
        .onChange(of: model.activitySearch) { _, _ in scheduleSearchRecompute() }
        .onDisappear { pendingSearch?.cancel() }
        .task(id: CalendarTaskKey(range: model.range, overlayEnabled: model.calendarOverlayEnabled)) {
            await refreshCalendarOverlay()
        }
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
                title: "日历叠加",
                message: "在时间轴上叠加你的日历日程，自动标注会议时间；会议期间空闲不会触发挂起。",
                actionTitle: "启用",
                action: enableCalendarOverlay
            )
        } else if calendarPermissionState != .granted {
            CalendarBandCard(
                title: "日历访问被拒绝",
                message: "无法叠加日程或自动标注会议。前往系统设置重新授权日历访问后即可生效。",
                actionTitle: "打开系统设置",
                action: openCalendarSystemSettings
            )
        }
    }

    /// Turns the overlay setting on and requests calendar access (a no-op
    /// prompt-wise if already decided). `model.calendarOverlayEnabled = true`
    /// alone already retriggers the `.task(id:)` above via `CalendarTaskKey`,
    /// but that task computes its own fresh permission read at its own
    /// start, which can race ahead of the system prompt this triggers --
    /// hence the explicit follow-up refresh once the request resolves.
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
            _ = await Permissions.requestCalendarAccess()
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
    private func refreshCalendarOverlay() async {
        calendarPermissionState = Permissions.calendarState()
        guard model.calendarOverlayEnabled, calendarPermissionState == .granted,
              let store = model.calendarStore else {
            calendarEvents = []
            activities.recompute(model: model, events: calendarEvents)
            return
        }
        calendarEvents = await store.events(on: model.range.interval.start)
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
    var timelineBlocks: [TimelineBlock] = []

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

    private nonisolated static let titleTopCount = 20

    /// `events` (C3): the current range's calendar events, fetched
    /// asynchronously by `ActivitiesView` via `CalendarStore.events(on:)`
    /// and handed in here -- `recompute` itself stays synchronous (existing
    /// `onChange` call sites are unaffected), so `events` defaults to `[]`
    /// for every call site that predates the calendar overlay.
    func recompute(model: AppModel, events: [CalendarEvent] = []) {
        let all = model.rangedSpans()
        let categories = model.resolver.categoriesByID

        let query = Self.normalizedQuery(model.activitySearch)
        let items = Self.filter(all, query: query)

        // Tagged against the search-filtered `items` (not `all`) so the
        // per-row badges and the "会议时间" summary stay consistent with
        // whatever the list is actually showing -- same scoping choice as
        // `matchCount`/`matchSeconds` below. Must run on the flat,
        // pre-merge span list -- see `MeetingTagger.tagged`'s doc comment.
        let tagged = MeetingTagger.tagged(items: items, events: events)
        meetingSpanIDs = tagged.spanIDs
        meetingSeconds = tagged.seconds

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
        matchCount = query == nil ? nil : matchedItems.count
        matchSeconds = query == nil ? nil : Aggregator.totalDuration(matchedItems.map(\.span))

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
        let showsTimeline = Self.showsTimeline(model.range)
        timelineBlocks = showsTimeline ? Self.timelineBlocks(all, categories: categories) : []
        calendarBlocks = showsTimeline ? Self.eventBlocks(events) : []
        allDayTitles = showsTimeline ? events.filter { $0.isAllDay && !$0.isDeclined }.map(\.title) : []
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
    /// Groups by `EntityParser.entity(...)?.key ?? span.domain ??
    /// span.appBundleID` — a finer display-level key than plain
    /// domain-or-app when the span's URL resolves to a recognized entity
    /// (github/gitlab owner-repo, youtube channel). `reassignKey` always
    /// stays at the domain/bundleID level regardless, since that's the only
    /// granularity `CategoryStore` understands.
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
            let key = entity?.key ?? span.domain ?? span.appBundleID

            var accum = byKey[key] ?? Accum()
            accum.seconds += span.duration
            if accum.label == nil {
                accum.label = entity?.label ?? span.domain ?? span.appName
                accum.reassignKey = span.domain ?? span.appBundleID
                accum.isDomain = span.domain != nil
                accum.isEntity = entity != nil
            }
            if let id = span.id, meetingSpanIDs.contains(id) {
                accum.hasMeeting = true
            }
            let title = (span.title?.isEmpty == false) ? span.title! : "(无标题)"
            accum.titles[title, default: 0] += span.duration
            byKey[key] = accum
        }

        return byKey.map { key, accum in
            let titles = accum.titles
                .map { TitleRow(title: $0.key, seconds: $0.value) }
                .sorted { lhs, rhs in
                    lhs.seconds != rhs.seconds ? lhs.seconds > rhs.seconds : lhs.title < rhs.title
                }
                .prefix(titleTopCount)
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

    /// Intermediate merge unit before conversion to `TimelineBlock`. `repSpan`
    /// is the block's leading span (the one that started it), used for the
    /// tooltip's app/title/url — a merged block only shows one activity's
    /// detail, so we show whichever one opened it.
    private struct MergedBlock {
        var start: Date
        var end: Date
        var categoryID: String
        var repSpan: Span
    }

    /// Max gap between a block's end and the next same-category block's start
    /// for the two to still count as "adjacent". Without this guard, a
    /// same-category span hours later (across an idle stretch, sleep,
    /// overnight) would merge across the gap and paint it as active time.
    private nonisolated static let mergeGapTolerance: TimeInterval = 30

    /// Collapses consecutive same-category entries into single blocks, but
    /// only when they're contiguous (gap <= `mergeGapTolerance`). Pure
    /// (no actor-isolated state touched), so it's `nonisolated` — lets
    /// `ActivitiesModelTests` call it synchronously without hopping to
    /// `@MainActor`.
    private nonisolated static func mergeAdjacentSameCategory(_ input: [MergedBlock]) -> [MergedBlock] {
        var result: [MergedBlock] = []
        for block in input {
            if var last = result.last,
               last.categoryID == block.categoryID,
               block.start.timeIntervalSince(last.end) <= mergeGapTolerance {
                last.end = max(last.end, block.end)
                result[result.count - 1] = last
            } else {
                result.append(block)
            }
        }
        return result
    }

    /// Not `private`, and `nonisolated`: pure function, exercised directly by
    /// `ActivitiesModelTests` via `@testable import` (which sees `internal`,
    /// not `private`, members) without needing a `@MainActor` hop.
    nonisolated static func timelineBlocks(_ items: [CategorizedSpan], categories: [String: Category]) -> [TimelineBlock] {
        let sorted = items.sorted { $0.span.start < $1.span.start }
        let initial = sorted.map {
            MergedBlock(start: $0.span.start, end: $0.span.end, categoryID: $0.categoryID, repSpan: $0.span)
        }
        let merged = mergeAdjacentSameCategory(initial)

        // Absorb sub-30s blocks into the previous block only when contiguous
        // with it (gap <= mergeGapTolerance) — a short block glued to a real
        // activity is invisible noise, but the same short block hours later
        // (after an idle gap) is dropped rather than teleporting the
        // previous block's end forward to swallow it. Then re-coalesce:
        // absorbing (or dropping) a sliver can newly juxtapose two
        // same-category blocks that weren't touching before.
        var absorbed: [MergedBlock] = []
        for block in merged {
            if block.end.timeIntervalSince(block.start) < 30 {
                if var prev = absorbed.last, block.start.timeIntervalSince(prev.end) <= mergeGapTolerance {
                    prev.end = max(prev.end, block.end)
                    absorbed[absorbed.count - 1] = prev
                }
                continue
            }
            absorbed.append(block)
        }
        let coalesced = mergeAdjacentSameCategory(absorbed)

        return coalesced.map { block in
            let category = categories[block.categoryID]
            return TimelineBlock(
                start: block.start,
                end: block.end,
                color: Color(hex: category?.colorHex ?? "#98989D"),
                label: category?.name ?? block.categoryID,
                tooltip: tooltip(repSpan: block.repSpan, start: block.start, end: block.end)
            )
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

    // MARK: - Calendar event lane (C3)

    /// Non-all-day, non-declined calendar events -> `TimelineEventBlock`,
    /// for the day timeline's event lane. All-day events go through
    /// `allDayTitles` instead (no meaningful y-position); declined events
    /// are dropped entirely, same as they're excluded from `isMeeting`.
    private nonisolated static func eventBlocks(_ events: [CalendarEvent]) -> [TimelineEventBlock] {
        events
            .filter { !$0.isAllDay && !$0.isDeclined }
            .map { event in
                TimelineEventBlock(
                    id: event.id,
                    title: event.title,
                    start: event.start,
                    end: event.end,
                    color: Color(hex: event.colorHex),
                    tooltip: eventTooltip(event)
                )
            }
    }

    private nonisolated static func eventTooltip(_ event: CalendarEvent) -> String {
        "\(event.title)\n\(hhmm(event.start))–\(hhmm(event.end)) · \(event.calendarTitle)"
    }
}
