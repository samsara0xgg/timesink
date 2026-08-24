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

    /// Collapses consecutive same-category entries into single blocks.
    private static func mergeAdjacentSameCategory(_ input: [MergedBlock]) -> [MergedBlock] {
        var result: [MergedBlock] = []
        for block in input {
            if var last = result.last, last.categoryID == block.categoryID {
                last.end = max(last.end, block.end)
                result[result.count - 1] = last
            } else {
                result.append(block)
            }
        }
        return result
    }

    private static func timelineBlocks(_ items: [CategorizedSpan], categories: [String: Category]) -> [TimelineBlock] {
        let sorted = items.sorted { $0.span.start < $1.span.start }
        let initial = sorted.map {
            MergedBlock(start: $0.span.start, end: $0.span.end, categoryID: $0.categoryID, repSpan: $0.span)
        }
        let merged = mergeAdjacentSameCategory(initial)

        // Absorb sub-30s blocks into the previous block (dropped if there's
        // no previous one to absorb into), then re-coalesce: absorbing a
        // sliver can newly juxtapose two same-category blocks.
        var absorbed: [MergedBlock] = []
        for block in merged {
            if block.end.timeIntervalSince(block.start) < 30 {
                if var prev = absorbed.last {
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

    private static let tooltipTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func tooltip(repSpan: Span, start: Date, end: Date) -> String {
        var lines: [String] = []
        if let title = repSpan.title, !title.isEmpty {
            lines.append("\(repSpan.appName) — \(title)")
        } else {
            lines.append(repSpan.appName)
        }
        if let url = repSpan.url, !url.isEmpty {
            lines.append(url)
        }
        let startStr = tooltipTimeFormatter.string(from: start)
        let endStr = tooltipTimeFormatter.string(from: end)
        lines.append("\(startStr)–\(endStr) (\(Format.duration(end.timeIntervalSince(start))))")
        return lines.joined(separator: "\n")
    }
}
