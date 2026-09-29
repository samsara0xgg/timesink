import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    private var navigation: Binding<SidebarItem> {
        Binding(get: { model.sidebarSelection }, set: { destination in
            switch destination {
            case .today: model.openToday()
            case .stats: model.openStats(range: DateRangeSelection(kind: .last7, anchor: Date()))
            default: model.sidebarSelection = destination
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: navigation) {
                Section {
                    navigationLabel(String(localized: "今天"), symbol: "sun.max").tag(SidebarItem.today)
                    navigationLabel(String(localized: "活动"), symbol: "list.bullet.rectangle").tag(SidebarItem.activities)
                    navigationLabel(String(localized: "趋势"), symbol: "chart.bar.xaxis").tag(SidebarItem.stats)
                }
                Section("安排时间") {
                    navigationLabel(String(localized: "专注与限额"), symbol: "scope").tag(SidebarItem.focus)
                    navigationLabel(String(localized: "分类与规则"), symbol: "tag")
                        .badge(model.pendingClassificationCount).tag(SidebarItem.organization)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 9) {
                    Image(systemName: "hourglass.bottomhalf.filled").foregroundStyle(.tint)
                    Text("TimeSink").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 12) {
                RecordingStatusView(model: model)
                SettingsLink { Label("设置", systemImage: "gearshape") }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func navigationLabel(_ title: String, symbol: String) -> some View {
        Label { Text(title) } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
    }
}
