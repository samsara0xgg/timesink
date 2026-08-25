import SwiftUI
import Observation

/// 活动 tab: a grouped category/domain/title breakdown (`ActivityListView`,
/// flexible width) plus, for single-day ranges, a vertical day timeline
/// (`DayTimelineView`, fixed width) mapped from the same spans.
struct ActivitiesView: View {
    let model: AppModel

    @State private var activities = ActivitiesModel()

    /// Debounces search-driven recomputes only — see `scheduleSearchRecompute()`.
    /// Every other trigger (`dataVersion`/`range`/`activityFilter`) recomputes
    /// immediately, unrelated to this.
    @State private var pendingSearch: Task<Void, Never>?

    private var searchBinding: Binding<String> {
        Binding(get: { model.activitySearch }, set: { model.activitySearch = $0 })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivityListView(model: model, groups: activities.groups,
                              matchCount: activities.matchCount, matchSeconds: activities.matchSeconds)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.range.kind == .day {
                DayTimelineView(blocks: activities.timelineBlocks)
                    .frame(width: 180)
            }
        }
        .padding()
        .searchable(text: searchBinding, prompt: "搜索应用、网址、标题")
        .onAppear { activities.recompute(model: model) }
        .onChange(of: model.dataVersion) { _, _ in activities.recompute(model: model) }
        .onChange(of: model.range) { _, _ in activities.recompute(model: model) }
        .onChange(of: model.activityFilter) { _, _ in activities.recompute(model: model) }
        .onChange(of: model.activitySearch) { _, _ in scheduleSearchRecompute() }
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
            activities.recompute(model: model)
        }
    }
}

/// Computes `ActivitiesView`'s category/domain/title breakdown and (for
/// single-day ranges) the day's timeline blocks from a single
/// `rangedSpans()` call per recompute — mirrors StatsView/StatsModel's
/// established pattern.
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

    /// Non-nil only while `model.activitySearch` holds a normalized query —
    /// the match-count row above the list reads these; `nil` means "no
    /// active search" (distinct from "search matched zero items").
    var matchCount: Int?
    var matchSeconds: TimeInterval?

    private nonisolated static let titleTopCount = 20

    func recompute(model: AppModel) {
        let all = model.rangedSpans()
        let categories = model.resolver.categoriesByID

        let query = Self.normalizedQuery(model.activitySearch)
        let items = Self.filter(all, query: query)
        matchCount = query == nil ? nil : items.count
        matchSeconds = query == nil ? nil : Aggregator.totalDuration(items.map(\.span))

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
                    rows: Self.rows(for: spans)
                )
            }
            .sorted { $0.seconds > $1.seconds }

        // Timeline keeps the unfiltered `all` so a narrowed list still shows
        // the full day's context (spec §7) rather than collapsing around
        // just the search hits.
        timelineBlocks = model.range.kind == .day ? Self.timelineBlocks(all, categories: categories) : []
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
    nonisolated static func rows(for items: [CategorizedSpan]) -> [ActivityRow] {
        struct Accum {
            var seconds: TimeInterval = 0
            var label: String?
            var reassignKey: String = ""
            var isDomain = false
            var isEntity = false
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
}
