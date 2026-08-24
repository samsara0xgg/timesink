import SwiftUI

/// Dashboard replicating the Timing "overview" layout: a top row of six
/// stat/profile mini-cards plus a double-height stacked-category card, and a
/// bottom row of two donut+ranking cards.
struct StatsView: View {
    let model: AppModel

    @State private var stats = StatsModel()
    @State private var granularity: StatsModel.Granularity = .day

    private let spacing: CGFloat = 12
    private let miniCardHeight: CGFloat = 150

    var body: some View {
        ScrollView {
            VStack(spacing: spacing) {
                topRow
                bottomRow
            }
            .padding()
        }
        .onAppear { stats.recompute(model: model) }
        .onChange(of: model.dataVersion) { _, _ in stats.recompute(model: model) }
        .onChange(of: model.range) { _, _ in stats.recompute(model: model) }
    }

    private var topRow: some View {
        GeometryReader { geo in
            let leftWidth = (geo.size.width - spacing) * 0.65
            let rightWidth = (geo.size.width - spacing) * 0.35
            HStack(alignment: .top, spacing: spacing) {
                Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                    GridRow {
                        TotalTimeCard(total: stats.total, avgPerDay: stats.avgPerDay)
                            .frame(maxWidth: .infinity, minHeight: miniCardHeight, maxHeight: miniCardHeight)
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
                        ProductivityScoreCard(pulse: stats.pulse)
                            .frame(maxWidth: .infinity, minHeight: miniCardHeight, maxHeight: miniCardHeight)
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
