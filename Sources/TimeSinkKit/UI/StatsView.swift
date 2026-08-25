import SwiftUI

/// Dashboard replicating the Timing "overview" layout, C2 revision: an
/// in-page range control, a summary row of three delta-bearing stat cards
/// (Total/Score/Focus), a trend row (30-day score trend + 7x24 heatmap), the
/// existing profile mini-cards (now 2x2, since Total/Score moved up to the
/// summary row) + stacked-category card, and the bottom donut+ranking row.
struct StatsView: View {
    let model: AppModel

    @State private var stats = StatsModel()
    @State private var granularity: StatsModel.Granularity = .day
    @State private var showingCustomRangePopover = false
    @State private var customRangeStart = Date()
    @State private var customRangeEnd = Date()

    private let spacing: CGFloat = 12
    private let miniCardHeight: CGFloat = 150
    private let summaryCardHeight: CGFloat = 110
    private let trendRowHeight: CGFloat = 220

    var body: some View {
        ScrollView {
            VStack(spacing: spacing) {
                rangeControlRow
                summaryRow
                trendRow
                profileRow
                bottomRow
            }
            .padding()
        }
        .onAppear { stats.recompute(model: model, forceHeavy: true) }
        .onChange(of: model.dataVersion) { _, _ in stats.recompute(model: model, forceHeavy: false) }
        .onChange(of: model.range) { _, _ in stats.recompute(model: model, forceHeavy: true) }
    }

    // MARK: - (1) In-page range control

    private var rangeControlRow: some View {
        HStack {
            Picker("", selection: pageRangeKind) {
                Text("今天").tag(DateRangeSelection.Kind.day)
                Text("本周").tag(DateRangeSelection.Kind.week)
                Text("本月").tag(DateRangeSelection.Kind.month)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button("自定义…") { showingCustomRangePopover = true }
                .popover(isPresented: $showingCustomRangePopover) {
                    customRangePopover
                }

            Spacer()
        }
    }

    /// Reads/writes `model.range` directly (same state the toolbar's range
    /// menu writes -- see `MainWindowView.rangeToolbar`), so the two controls
    /// stay in sync automatically: no separate local selection state to
    /// desync. Selecting a segment discards any custom start/end, matching
    /// the toolbar menu's plain-kind buttons.
    private var pageRangeKind: Binding<DateRangeSelection.Kind> {
        Binding(
            get: { model.range.kind },
            set: { model.range = DateRangeSelection(kind: $0, anchor: Date()) }
        )
    }

    /// Mirrors `MainWindowView.customRangePopover` (same cross-bounded,
    /// today-clamped DatePickers applying a `.custom` `DateRangeSelection`)
    /// so the in-page "自定义…" button behaves identically to the toolbar's.
    private var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
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

    // MARK: - (2) Summary row: Total/Score/Focus, with 环比 delta chips

    private var summaryRow: some View {
        HStack(spacing: spacing) {
            TotalTimeCard(total: stats.total, avgPerDay: stats.avgPerDay, delta: stats.totalDelta)
            ProductivityScoreCard(pulse: stats.pulse, delta: stats.pulseDelta)
            FocusTimeCard(focus: stats.focus, delta: stats.focusDelta)
        }
        .frame(height: summaryCardHeight)
    }

    // MARK: - (3) Trend row: 30-day score trend + 7x24 heatmap

    private var trendRow: some View {
        GeometryReader { geo in
            let leftWidth = (geo.size.width - spacing) * 0.6
            let rightWidth = (geo.size.width - spacing) * 0.4
            HStack(alignment: .top, spacing: spacing) {
                ScoreTrendCard(trend: stats.scoreTrend, streak: stats.trendStreak) { day in
                    model.range = DateRangeSelection(kind: .day, anchor: day)
                }
                .frame(width: leftWidth)

                HeatmapCard(cells: stats.heatmap)
                    .frame(width: rightWidth)
            }
        }
        .frame(height: trendRowHeight)
    }

    // MARK: - (4) Existing profile mini-cards (2x2, Total/Score moved out) +
    // stacked-category card, and the unchanged donut/ranking row.

    private var profileRow: some View {
        GeometryReader { geo in
            let leftWidth = (geo.size.width - spacing) * 0.65
            let rightWidth = (geo.size.width - spacing) * 0.35
            HStack(alignment: .top, spacing: spacing) {
                Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                    GridRow {
                        ProfileBarCard(
                            title: "最活跃的星期",
                            points: stats.weekdayProfile,
                            tickLabels: nil,
                            diverging: false
                        )
                        .frame(maxWidth: .infinity, minHeight: miniCardHeight, maxHeight: miniCardHeight)
                        ProfileBarCard(
                            title: "最活跃的时段",
                            points: stats.hourProfile,
                            tickLabels: ["0", "6", "12", "18"],
                            diverging: false
                        )
                        .frame(maxWidth: .infinity, minHeight: miniCardHeight, maxHeight: miniCardHeight)
                    }
                    GridRow {
                        ProfileBarCard(
                            title: "最高效的星期",
                            points: stats.prodWeekdayProfile,
                            tickLabels: nil,
                            diverging: true
                        )
                        .frame(maxWidth: .infinity, minHeight: miniCardHeight, maxHeight: miniCardHeight)
                        ProfileBarCard(
                            title: "最高效的时段",
                            points: stats.prodHourProfile,
                            tickLabels: ["0", "6", "12", "18"],
                            diverging: true
                        )
                        .frame(maxWidth: .infinity, minHeight: miniCardHeight, maxHeight: miniCardHeight)
                    }
                }
                .frame(width: leftWidth)

                StackedCategoryCard(
                    granularity: $granularity,
                    points: granularity == .day ? stats.stackedByDay : stats.stackedByWeek,
                    domainNames: stats.stackedDomainNames,
                    domainColors: stats.stackedDomainColorHex.map { Color(hex: $0) }
                )
                .frame(width: rightWidth)
            }
        }
        .frame(height: miniCardHeight * 2 + spacing)
    }

    private var bottomRow: some View {
        HStack(alignment: .top, spacing: spacing) {
            DonutRankingCard(title: "应用", rows: stats.appRows)
            DonutRankingCard(title: "分类", rows: stats.categoryRows)
        }
    }
}
