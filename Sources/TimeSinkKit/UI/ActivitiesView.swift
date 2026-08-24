import SwiftUI
import Observation

/// 活动 tab: a grouped category/domain/title breakdown (`ActivityListView`,
/// flexible width) plus, for single-day ranges, a vertical day timeline
/// (`DayTimelineView`, fixed width) mapped from the same spans.
struct ActivitiesView: View {
    let model: AppModel

    @State private var activities = ActivitiesModel()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivityListView(model: model, groups: activities.groups)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.range.kind == .day {
                DayTimelineView(blocks: activities.timelineBlocks)
                    .frame(width: 180)
            }
        }
        .padding()
        .onAppear { activities.recompute(model: model) }
        .onChange(of: model.dataVersion) { _, _ in activities.recompute(model: model) }
        .onChange(of: model.range) { _, _ in activities.recompute(model: model) }
        .onChange(of: model.activityFilter) { _, _ in activities.recompute(model: model) }
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

    /// A domain (browser) or app (native) row within a category, with its
    /// per-title breakdown. `isDomain` says which `CategoryStore` method a
    /// reassignment of `id` should use — derived from whether the underlying
    /// spans carried a `domain`, not from the string shape of `id`.
    struct ActivityRow: Identifiable {
        let id: String
        let label: String
        let seconds: TimeInterval
        let isDomain: Bool
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

    private static let titleTopCount = 20

    func recompute(model: AppModel) {
        let items = model.rangedSpans()
        let categories = model.resolver.categoriesByID

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

        timelineBlocks = model.range.kind == .day ? Self.timelineBlocks(items, categories: categories) : []
    }

    // MARK: - List grouping

    private static func rows(for items: [CategorizedSpan]) -> [ActivityRow] {
        var isDomainByKey: [String: Bool] = [:]
        var titlesByKey: [String: [String: TimeInterval]] = [:]
        for item in items {
            let span = item.span
            let key = span.domain ?? span.appBundleID
            isDomainByKey[key] = span.domain != nil
            let title = (span.title?.isEmpty == false) ? span.title! : "(无标题)"
            titlesByKey[key, default: [:]][title, default: 0] += span.duration
        }

        return Aggregator.durationByDomainOrApp(items).map { entry in
            let titles = (titlesByKey[entry.key] ?? [:])
                .map { TitleRow(title: $0.key, seconds: $0.value) }
                .sorted { lhs, rhs in
                    lhs.seconds != rhs.seconds ? lhs.seconds > rhs.seconds : lhs.title < rhs.title
                }
                .prefix(titleTopCount)
            return ActivityRow(
                id: entry.key,
                label: entry.label,
                seconds: entry.seconds,
                isDomain: isDomainByKey[entry.key] ?? false,
                titles: Array(titles)
            )
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
