import SwiftUI

struct MainWindowView: View {
    let model: AppModel
    @State private var showingCustomRangePopover = false
    @State private var customRangeStart = Date()
    @State private var customRangeEnd = Date()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { rangeToolbar }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.sidebarSelection {
        case .stats:
            StatsView(model: model)
        case .activities:
            ActivitiesView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var rangeToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.range.shift(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            Button {
                model.range.shift(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            Menu(model.range.label) {
                ForEach(DateRangeSelection.Kind.allCases.filter { $0 != .custom }, id: \.self) { kind in
                    Button(label(for: kind)) {
                        model.range = DateRangeSelection(kind: kind, anchor: Date())
                    }
                }
                Button("自定义…") { showingCustomRangePopover = true }
            }
            .popover(isPresented: $showingCustomRangePopover) {
                customRangePopover
            }
        }
    }

    private var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("开始", selection: $customRangeStart, displayedComponents: .date)
            DatePicker("结束", selection: $customRangeEnd, displayedComponents: .date)
            Button("应用") {
                model.range = DateRangeSelection(
                    kind: .custom, anchor: customRangeEnd,
                    customStart: customRangeStart, customEnd: customRangeEnd)
                showingCustomRangePopover = false
            }
        }
        .padding()
        .frame(width: 240)
    }

    private func label(for kind: DateRangeSelection.Kind) -> String {
        switch kind {
        case .day: return "今天"
        case .week: return "本周"
        case .month: return "本月"
        case .last7: return "近 7 天"
        case .last30: return "近 30 天"
        case .custom: return "自定义…"
        }
    }
}
