import SwiftUI

/// One row in the sidebar's "分类" section: a category's total duration
/// within the model's current date range.
private struct CategoryRow: Identifiable {
    let id: String
    let name: String
    let colorHex: String
    let seconds: TimeInterval
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var categoryRows: [CategoryRow] = []

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section {
                Label("统计", systemImage: "chart.pie")
                    .tag(SidebarItem.stats)
                Label("活动", systemImage: "waveform.path.ecg")
                    .tag(SidebarItem.activities)
            }
            Section("分类") {
                ForEach(categoryRows) { row in
                    Button {
                        model.activityFilter = row.id
                        model.sidebarSelection = .activities
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color(hex: row.colorHex))
                                .frame(width: 8, height: 8)
                            Text(row.name)
                            Spacer()
                            Text(Format.duration(row.seconds))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { refreshCategoryRows() }
        .onChange(of: model.range) { _, _ in refreshCategoryRows() }
        .onChange(of: model.dataVersion) { _, _ in refreshCategoryRows() }
    }

    private func refreshCategoryRows() {
        let byCategory = Aggregator.durationByCategory(model.rangedSpans())
        let categories = model.resolver.categoriesByID
        categoryRows = byCategory
            .compactMap { categoryID, seconds -> CategoryRow? in
                guard let category: TimeSinkKit.Category = categories[categoryID] else { return nil }
                return CategoryRow(id: category.id, name: category.name, colorHex: category.colorHex, seconds: seconds)
            }
            .sorted { $0.seconds > $1.seconds }
    }
}
