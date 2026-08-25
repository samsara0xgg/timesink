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
    let groups: [ActivitiesModel.CategoryGroup]
    /// Non-nil only while a search query is active — see
    /// `ActivitiesModel.matchCount`/`matchSeconds`.
    let matchCount: Int?
    let matchSeconds: TimeInterval?

    /// Sheet is hosted here (not inside the transient `contextMenu`) because
    /// the menu tears itself down as soon as its action runs.
    @State private var pendingTitleRule: PendingTitleRule?

    private var displayedGroups: [ActivitiesModel.CategoryGroup] {
        guard let filter = model.activityFilter else { return groups }
        return groups.filter { $0.id == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let matchCount {
                Text("命中 \(matchCount) 项 · 合计 \(Format.duration(matchSeconds ?? 0))")
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
                List {
                    ForEach(displayedGroups) { group in
                        CategoryGroupRow(model: model, group: group, pendingTitleRule: $pendingTitleRule)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $pendingTitleRule) { pending in
            TitleRuleEditor(model: model, pending: pending)
        }
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
            return model.activityFilter == nil ? "当前范围内没有活动记录" : "该分类在当前范围内没有活动记录"
        }
        if model.activityFilter != nil && !groups.isEmpty {
            return "该分类下没有命中的活动（其他分类还有命中，可清除分类筛选查看）"
        }
        return "没有命中的活动（隐身窗口与未授权时段无记录）"
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
    let group: ActivitiesModel.CategoryGroup
    @Binding var pendingTitleRule: PendingTitleRule?

    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.rows) { row in
                ActivityRowView(model: model, row: row, pendingTitleRule: $pendingTitleRule)
            }
        } label: {
            HStack {
                Circle()
                    .fill(Color(hex: group.colorHex))
                    .frame(width: 8, height: 8)
                Text(group.name)
                Spacer()
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
    let row: ActivitiesModel.ActivityRow
    @Binding var pendingTitleRule: PendingTitleRule?

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        DisclosureGroup {
            ForEach(row.titles) { title in
                TitleRowView(model: model, parent: row, title: title, pendingTitleRule: $pendingTitleRule)
            }
        } label: {
            HStack {
                Text(row.label)
                Spacer()
                Text(Format.duration(row.seconds))
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            ForEach(sortedCategories, id: \.id) { category in
                Button(row.isEntity ? "\(category.name)（整站）" : category.name) {
                    reassign(to: category.id)
                }
            }
        }
    }

    /// Always writes at `row.reassignKey` (domain or bundleID) — an entity
    /// row's finer-grained `row.id` (e.g. a specific github repo) is
    /// display-only; `CategoryStore` only understands domain/app-level
    /// overrides, hence the「（整站）」menu hint on entity rows.
    private func reassign(to categoryID: String) {
        do {
            if row.isDomain {
                try model.categoryStore.setUserDomain(row.reassignKey, categoryID: categoryID)
            } else {
                try model.categoryStore.setUserApp(row.reassignKey, categoryID: categoryID)
            }
            model.resolver.refresh()
            model.dataChanged()
        } catch {
            activityListLogger.error("reassign failed for \(row.reassignKey, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

/// Level 3: a single title within a domain/app row. Right-click opens the
/// title-rule editor sheet (hosted on `ActivityListView`'s List, since this
/// menu is transient) prefilled with this title and scoped to the parent
/// domain/app — "始终把此标题归为…".
private struct TitleRowView: View {
    let model: AppModel
    let parent: ActivitiesModel.ActivityRow
    let title: ActivitiesModel.TitleRow
    @Binding var pendingTitleRule: PendingTitleRule?

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        HStack {
            Text(title.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Format.duration(title.seconds))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
                    prefill: title.title == "(无标题)" ? "" : title.title,
                    scopeKey: parent.reassignKey,
                    scopeLabel: parent.isEntity ? parent.reassignKey : parent.label,
                    categoryID: sortedCategories.first?.id ?? ""
                )
            }
        }
    }
}
