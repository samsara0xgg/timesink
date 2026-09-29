import SwiftUI
import os

private let activityListLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "activityList")

/// Three-level grouped breakdown for the current range: category → domain/app
/// → title. `model.activityFilter` (a category ID set from the sidebar)
/// restricts the list to one category and shows a clearable chip; if that
/// category has no spans in range, the chip still shows with an empty state
/// rather than an empty screen.
struct ActivityListView: View {
    let model: AppModel
    let activities: ActivitiesModel
    let groups: [ActivitiesModel.CategoryGroup]
    /// Non-nil only while a search query is active — see
    /// `ActivitiesModel.matchCount`/`matchSeconds`.
    let matchCount: Int?
    let matchSeconds: TimeInterval?
    /// C3: summed duration of spans tagged as overlapping a meeting — see
    /// `ActivitiesModel.meetingSeconds`. The summary row below only shows
    /// while this is > 0, which is also true whenever the calendar overlay
    /// is off (no events feed `MeetingTagger`, so it settles at 0).
    let meetingSeconds: TimeInterval

    /// Sheet is hosted here (not inside the transient `contextMenu`) because
    /// the menu tears itself down as soon as its action runs.
    @State private var pendingTitleRule: PendingTitleRule?
    @State private var grouping = 0

    private var totalSeconds: TimeInterval { displayedGroups.reduce(0) { $0 + $1.seconds } }

    private var groupingControl: some View {
        Picker("分组方式", selection: $grouping) {
            Text("按分类").tag(0)
            Text("按应用").tag(1)
            Text("按时间").tag(2)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 186)
    }

    private var summary: some View {
        Text("\(Format.duration(totalSeconds)) · \(activities.displayedItems.count) 段 · \(displayedGroups.count) 个分类")
            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
    }

    private var displayedGroups: [ActivitiesModel.CategoryGroup] {
        guard let filter = model.activityFilter else { return groups }
        return groups.filter { $0.id == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { summary; Spacer(minLength: 10); groupingControl }
                VStack(alignment: .leading, spacing: 8) { summary; groupingControl }
            }.padding(.horizontal, 14).padding(.top, 10)
            if let matchCount {
                Text("命中 \(matchCount) 项 · 合计 \(Format.duration(matchSeconds ?? 0))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if meetingSeconds > 0 {
                Text("会议时间 \(Format.duration(meetingSeconds))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let filter = model.activityFilter {
                FilterChip(name: model.resolver.categoriesByID[filter]?.name ?? filter) {
                    model.activityFilter = nil
                }
            }

            if displayedGroups.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List {
                        if grouping == 0 {
                            ForEach(displayedGroups) { group in
                                CategoryGroupRow(model: model, activities: activities, group: group, totalSeconds: totalSeconds, pendingTitleRule: $pendingTitleRule)
                            }
                        } else if grouping == 1 {
                            ForEach(applicationGroups, id: \.key) { group in
                                Section {
                                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in segmentRow(item) }
                                } header: {
                                    HStack {
                                        AppIcon(bundleID: group.key, size: 18)
                                        Text(group.items.first?.span.appName ?? group.key)
                                        Spacer()
                                        Text(Format.duration(group.items.reduce(0) { $0 + $1.span.duration })).monospacedDigit()
                                    }
                                }
                            }
                        } else {
                            ForEach(Array(activities.displayedItems.sorted { $0.span.start > $1.span.start }.enumerated()), id: \.offset) { _, item in segmentRow(item) }
                        }
                    }
                    .listStyle(.inset)
                    .task(id: activities.selectedActivity) {
                        guard let selection = activities.selectedActivity else { return }
                        await Task.yield()
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
        }
        .sheet(item: $pendingTitleRule) { pending in
            TitleRuleEditor(model: model, pending: pending)
        }
    }

    private var applicationGroups: [(key: String, items: [CategorizedSpan])] {
        Dictionary(grouping: activities.displayedItems, by: { $0.span.appBundleID })
            .map { (key: $0.key, items: $0.value.sorted { $0.span.start > $1.span.start }) }
            .sorted { $0.items.reduce(0) { $0 + $1.span.duration } > $1.items.reduce(0) { $0 + $1.span.duration } }
    }

    private func segmentRow(_ item: CategorizedSpan) -> some View {
        let selection = ActivitiesModel.selection(for: item)
        return Button { activities.select(selection, start: item.span.start) } label: {
            HStack(spacing: 8) {
                AppIcon(bundleID: item.span.appBundleID, size: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.span.title ?? item.span.domain ?? item.span.appName).lineLimit(1)
                    Text("\(model.time(item.span.start))–\(model.time(item.span.end)) · \(model.resolver.categoriesByID[item.categoryID]?.name ?? String(localized: "未分类"))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(Format.duration(item.span.duration)).monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.vertical, 5).padding(.horizontal, 4)
                .background(activities.selectedActivity == selection && activities.selectedStart == item.span.start ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).id(selection)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(emptyStateText)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Composes search-active and category-filter-active independently
    /// (R-T9a) rather than short-circuiting on search alone: with a category
    /// chip active, `matchCount` (now scoped to that category — see
    /// `ActivitiesModel.recompute`) can be zero while the search still has
    /// hits in *other* categories (`groups`, unlike `displayedGroups`, is
    /// never narrowed by `activityFilter`) — that's a distinct state from
    /// "the search matched nothing at all" and must not claim the latter.
    private var emptyStateText: String {
        guard matchCount != nil else {
            return model.activityFilter == nil ? String(localized: "当前范围内没有活动记录") : String(localized: "该分类在当前范围内没有活动记录")
        }
        if model.activityFilter != nil && !groups.isEmpty {
            return String(localized: "该分类下没有命中的活动（其他分类还有命中，可清除分类筛选查看）")
        }
        return String(localized: "没有命中的活动（隐身窗口与未授权时段无记录）")
    }
}

private struct FilterChip: View {
    let name: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("筛选：\(name)")
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .foregroundStyle(Color.accentColor)
    }
}

/// Level 1: a category header (color dot + name + total) that discloses its
/// domain/app rows. Starts expanded per spec, tracked with per-row @State so
/// each category row's own instance defaults to open on first appearance.
private struct CategoryGroupRow: View {
    let model: AppModel
    let activities: ActivitiesModel
    let group: ActivitiesModel.CategoryGroup
    let totalSeconds: TimeInterval
    @Binding var pendingTitleRule: PendingTitleRule?

    private var isExpanded: Binding<Bool> {
        Binding(get: { !activities.collapsedCategories.contains(group.id) }, set: { expanded in
            if expanded { activities.collapsedCategories.remove(group.id) }
            else { activities.collapsedCategories.insert(group.id) }
        })
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(group.rows) { row in
                ActivityRowView(model: model, activities: activities, categoryID: group.id, row: row, pendingTitleRule: $pendingTitleRule)
                    .id(ActivitySelection(categoryID: group.id, rowID: row.id))
            }
        } label: {
            HStack {
                Circle()
                    .fill(RefinedStyle.category(group.id, hex: group.colorHex))
                    .frame(width: 8, height: 8)
                Text(group.name)
                Spacer()
                GeometryReader { geometry in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(RefinedStyle.category(group.id, hex: group.colorHex))
                                .frame(width: geometry.size.width * group.seconds / max(1, totalSeconds))
                        }
                }.frame(width: 70, height: 4)
                Text(Format.duration(group.seconds))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Level 2: a domain-or-app row that discloses its Level 3 title breakdown.
/// Right-click reassigns this domain/app to another category, routed to the
/// matching `CategoryStore` method based on `row.isDomain`.
private struct ActivityRowView: View {
    let model: AppModel
    let activities: ActivitiesModel
    let categoryID: String
    private var isExpanded: Binding<Bool> {
        let key = ActivitySelection(categoryID: categoryID, rowID: row.id)
        return Binding(get: { activities.expandedRows.contains(key) }, set: { expanded in
            if expanded { activities.expandedRows.insert(key) }
            else { activities.expandedRows.remove(key) }
        })
    }
    let row: ActivitiesModel.ActivityRow
    @Binding var pendingTitleRule: PendingTitleRule?

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(row.titles) { title in
                TitleRowView(model: model, activities: activities, categoryID: categoryID, parent: row, title: title, pendingTitleRule: $pendingTitleRule)
            }
        } label: {
            Button { activities.select(ActivitySelection(categoryID: categoryID, rowID: row.id)) } label: {
            HStack {
                AppIcon(bundleID: row.isDomain ? "com.google.Chrome" : row.reassignKey, size: 18)
                Text(row.label).lineLimit(1)
                Spacer()
                if row.hasMeeting {
                    Text("会议")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                        .help("由日历事件自动标注")
                }
                let count = activities.segmentCounts[ActivitySelection(categoryID: categoryID, rowID: row.id)] ?? 0
                if count > 1 { Text("\(count) 段").font(.system(size: 11)).foregroundStyle(.tertiary) }
                Text(Format.duration(row.seconds))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(activities.selectedActivity?.row == ActivitySelection(categoryID: categoryID, rowID: row.id)
                        ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在时间轴中定位这项活动")
        }
        .contextMenu {
            Button("检查并调整分类…") {
                activities.select(ActivitySelection(categoryID: categoryID, rowID: row.id), start: nil)
            }
        }
    }


}

/// Level 3: a single title within a domain/app row. Right-click opens the
/// title-rule editor sheet (hosted on `ActivityListView`'s List, since this
/// menu is transient) prefilled with this title and scoped to the parent
/// domain/app — "始终把此标题归为…".
private struct TitleRowView: View {
    let model: AppModel
    let activities: ActivitiesModel
    let categoryID: String
    let parent: ActivitiesModel.ActivityRow
    let title: ActivitiesModel.TitleRow
    @Binding var pendingTitleRule: PendingTitleRule?

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        let selection = ActivitySelection(categoryID: categoryID, rowID: parent.id, title: title.title)
        Button { activities.select(selection) } label: {
        HStack {
            Text(title.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Format.duration(title.seconds))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(activities.selectedActivity == selection ? Color.accentColor.opacity(0.2) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(selection)
        .help(title.title + String(localized: " · 在时间轴中定位"))
        .accessibilityAddTraits(activities.selectedActivity == selection ? .isSelected : [])
        .contextMenu {
            Button("始终把此标题归为…") {
                // `scopeKey` must be `parent.reassignKey` (domain/bundleID),
                // never `parent.id` -- `TitleRuleInput.affected` and
                // `Classifier.scopeMatches` both compare a rule's scopeKey
                // against `span.domain ?? span.appBundleID`, which an
                // entity row's finer-grained `id` (e.g. a specific repo)
                // never equals. A rule scoped to `id` would show a live "影响
                // 0 项" preview and never fire once saved. `scopeLabel`
                // mirrors that: an entity row shows `reassignKey`, not its
                // repo-level `label`, so the picker never promises a
                // repo-level scope it can't honor -- same honesty as the
                // 「（整站）」 reassignment-menu suffix.
                pendingTitleRule = PendingTitleRule(
                    prefill: title.title == String(localized: "(无标题)") ? "" : title.title,
                    scopeKey: parent.reassignKey,
                    scopeLabel: parent.isEntity ? parent.reassignKey : parent.label,
                    categoryID: sortedCategories.first?.id ?? ""
                )
            }
        }
    }
}
