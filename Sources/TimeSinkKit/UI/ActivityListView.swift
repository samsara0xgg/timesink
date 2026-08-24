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

    private var displayedGroups: [ActivitiesModel.CategoryGroup] {
        guard let filter = model.activityFilter else { return groups }
        return groups.filter { $0.id == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                        CategoryGroupRow(model: model, group: group)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(model.activityFilter == nil ? "当前范围内没有活动记录" : "该分类在当前范围内没有活动记录")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.rows) { row in
                ActivityRowView(model: model, row: row)
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

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        DisclosureGroup {
            ForEach(row.titles) { title in
                HStack {
                    Text(title.title)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.duration(title.seconds))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Button(category.name) {
                    reassign(to: category.id)
                }
            }
        }
    }

    private func reassign(to categoryID: String) {
        do {
            if row.isDomain {
                try model.categoryStore.setUserDomain(row.id, categoryID: categoryID)
            } else {
                try model.categoryStore.setUserApp(row.id, categoryID: categoryID)
            }
            model.resolver.refresh()
            model.dataChanged()
        } catch {
            activityListLogger.error("reassign failed for \(row.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
