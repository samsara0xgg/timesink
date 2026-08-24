import SwiftUI

struct MainWindowView: View {
    let model: AppModel

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
            Text("统计")
        case .activities:
            Text("活动")
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
                ForEach(DateRangeSelection.Kind.allCases, id: \.self) { kind in
                    Button(label(for: kind)) {
                        model.range = DateRangeSelection(kind: kind, anchor: Date())
                    }
                }
            }
        }
    }

    private func label(for kind: DateRangeSelection.Kind) -> String {
        switch kind {
        case .day: return "今天"
        case .last7: return "近 7 天"
        case .last30: return "近 30 天"
        }
    }
}
