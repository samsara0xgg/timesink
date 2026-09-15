import SwiftUI

struct MainWindowView: View {
    let model: AppModel

    /// Owned here, not inside `StatsView`. `detailContent` below is a
    /// `switch`, so its two branches are different concrete View types and
    /// SwiftUI tears the inactive one down -- a `@State` model inside
    /// `StatsView` was rebuilt from scratch on every 统计/活动 switch, which
    /// reset `StatsModel.lastHeavyDay` and re-ran the full 30-day
    /// trend+heatmap lookback each time. `MainWindowView` itself is not torn
    /// down by a sidebar selection change, so the model (and its once-a-day
    /// gate) survives here.
    @State private var stats = StatsModel()

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
            StatsView(model: model, stats: stats)
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
                Button(label(for: .custom)) { showingCustomRangePopover = true }
            }
            .popover(isPresented: $showingCustomRangePopover) {
                customRangePopover
            }
        }
    }

    private var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Cross-bounded and clamped to today, matching every other
            // kind's future-clamp convention (R-T7b). The model-level
            // normalization in `DateRangeSelection.interval` remains the
            // real guarantee against a reversed range; this is UX only.
            DatePicker("开始", selection: $customRangeStart,
                       in: ...min(customRangeEnd, Date()), displayedComponents: .date)
            DatePicker("结束", selection: $customRangeEnd,
                       in: customRangeStart...Date(), displayedComponents: .date)
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
