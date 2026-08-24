import SwiftUI
import Charts

/// Shared card chrome: a filled rounded rect matching the reference
/// screenshot's dashboard tiles.
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}

extension View {
    fileprivate func statCardBackground() -> some View { modifier(CardBackground()) }
}

private struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// 总时长: big bold number + daily-average subtitle.
struct TotalTimeCard: View {
    let total: TimeInterval
    let avgPerDay: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: "总时长")
            Spacer(minLength: 0)
            Text(Format.duration(total))
                .font(.system(size: 34, weight: .bold))
            Text("每日均值 \(Format.duration(avgPerDay))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCardBackground()
    }
}

/// 生产力分: number colored by value, with a two-state subtitle.
struct ProductivityScoreCard: View {
    let pulse: Int?

    private var color: Color {
        guard let pulse else { return .secondary }
        if pulse >= 70 { return .green }
        if pulse >= 40 { return .orange }
        return .red
    }

    private var subtitle: String {
        guard let pulse else { return "暂无数据" }
        return pulse >= 70 ? "继续保持" : "有点分心"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: "生产力分")
            Spacer(minLength: 0)
            Text(pulse.map { "\($0)%" } ?? "--")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCardBackground()
    }
}

/// Reusable ~90pt bar chart card, used for the four activity/productivity
/// profile mini-cards. `diverging` colors bars green/red by sign (for the
/// productivity profiles); otherwise all bars are blue. `tickLabels` limits
/// which x-axis labels are drawn (nil shows all — used for the 7 weekday
/// labels; a sparse subset is used for the 24 hour labels).
struct ProfileBarCard: View {
    let title: String
    let points: [StatsModel.ProfilePoint]
    let tickLabels: Set<String>?
    let diverging: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: title)
            Chart(points) { point in
                BarMark(
                    x: .value("时间", point.label),
                    y: .value("时长", point.hours)
                )
                .foregroundStyle(diverging ? (point.hours >= 0 ? Color.green : Color.red) : Color.blue)
            }
            .frame(height: 90)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    if let label = value.as(String.self), tickLabels?.contains(label) ?? true {
                        AxisTick()
                        AxisValueLabel()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCardBackground()
    }
}

/// 分类时长卡: Picker(按天/按周) + stacked bar chart over the chosen bucketing.
struct StackedCategoryCard: View {
    @Binding var granularity: StatsModel.Granularity
    let points: [StatsModel.StackedPoint]
    let domainNames: [String]
    let domainColors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CardTitle(text: "分类时长")
                Spacer()
                Picker("", selection: $granularity) {
                    Text("按天").tag(StatsModel.Granularity.day)
                    Text("按周").tag(StatsModel.Granularity.week)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            Chart(points) { point in
                BarMark(
                    x: .value("日期", point.bucketStart, unit: granularity == .day ? .day : .weekOfYear),
                    y: .value("时长", point.hours)
                )
                .foregroundStyle(by: .value("分类", point.categoryName))
            }
            .chartForegroundStyleScale(domain: domainNames, range: domainColors)
            .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .statCardBackground()
    }
}

/// 应用卡/分类卡: donut chart + top-10 ranking list (color dot + name + duration).
struct DonutRankingCard: View {
    let title: String
    let rows: [StatsModel.RankingRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(text: title)
            HStack(alignment: .top, spacing: 16) {
                Chart(rows) { row in
                    SectorMark(
                        angle: .value("时长", row.seconds),
                        innerRadius: .ratio(0.62)
                    )
                    .foregroundStyle(Color(hex: row.colorHex))
                }
                .frame(width: 180, height: 180)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: row.colorHex))
                                .frame(width: 8, height: 8)
                            Text(row.name)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Format.duration(row.seconds))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .statCardBackground()
    }
}
