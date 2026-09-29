import SwiftUI
import Charts

/// Shared card chrome: a filled rounded rect matching the reference
/// screenshot's dashboard tiles.
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .workspacePanel()
    }
}

extension View {
    func statCardBackground() -> some View { modifier(CardBackground()) }
}

private struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// Small colored 环比 chip shared by the three summary cards -- green when
/// non-negative, red when negative, matching the menu-bar dashboard's KPI
/// delta styling (`MenuBarDashboardView.kpiLine`/`scoreColumn`).
private struct DeltaChip: View {
    let text: String
    let isNegative: Bool
    var neutral = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(neutral ? Color.secondary : (isNegative ? Color.red : Color.green))
    }
}

/// 总时长: big bold number + daily-average subtitle. `delta` (环比, vs the
/// previous equal period -- see `StatsModel.recomputeDeltas`) defaults to nil
/// so existing call sites are unaffected.
struct TotalTimeCard: View {
    let total: TimeInterval
    let avgPerDay: TimeInterval
    var delta: TimeInterval? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: String(localized: "总时长"))
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.duration(total))
                    .font(.system(size: 28, weight: .medium)).monospacedDigit()
                if let delta {
                    DeltaChip(text: Format.durationDelta(delta), isNegative: delta < 0, neutral: true)
                }
            }
            Text("每日均值 \(Format.duration(avgPerDay))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCardBackground()
    }
}

/// 专注时长: mirrors `TotalTimeCard` (big bold number + delta chip) but for
/// focus time (productive-category duration), with no daily-average subtitle.
struct FocusTimeCard: View {
    let focus: TimeInterval
    var delta: TimeInterval? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: String(localized: "投入时长"))
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.duration(focus))
                    .font(.system(size: 28, weight: .medium)).monospacedDigit()
                if let delta {
                    DeltaChip(text: Format.durationDelta(delta), isNegative: delta < 0)
                }
            }
            Text("按高效分类统计，非专注会话时长")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCardBackground()
    }
}

/// Pulse -> color mapping shared by the stats dashboard's score card and the
/// menu-bar mini dashboard's gauge, so the two stay visually consistent.
func scoreColor(_ pulse: Int?) -> Color {
    guard let pulse else { return .secondary }
    if pulse >= 70 { return .green }
    if pulse >= 40 { return .orange }
    return .red
}

/// 生产力分: number colored by value, with a two-state subtitle. `delta`
/// (环比, in percentage points vs the previous equal period) defaults to nil
/// so existing call sites are unaffected.
struct ProductivityScoreCard: View {
    let pulse: Int?
    var delta: Int? = nil

    private var color: Color { scoreColor(pulse) }

    private var subtitle: String {
        guard let pulse else { return String(localized: "暂无数据") }
        return pulse >= 70 ? String(localized: "满分 100 分 · 继续保持") : String(localized: "满分 100 分 · 按分类估算")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: String(localized: "生产力分"))
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pulse.map { "\($0) 分" } ?? "--")
                    .font(.system(size: 28, weight: .medium)).monospacedDigit()
                    .foregroundStyle(color)
                if let delta {
                    DeltaChip(text: (delta >= 0 ? "+\(delta)" : "\(delta)") + String(localized: " 分"), isNegative: delta < 0)
                }
            }
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
                CardTitle(text: String(localized: "分类时长"))
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
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hours = value.as(Double.self) { Text("\(hours, specifier: "%.0f")h") }
                    }
                }
            }
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

/// Compact ranking with a complete distribution, including the remainder.
struct DonutRankingCard: View {
    let title: String
    let rows: [StatsModel.RankingRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardTitle(text: title)
                Spacer()
                Text("合计 \(Format.duration(rows.reduce(0) { $0 + $1.seconds }))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("当前范围内没有活动记录")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        distribution
                        ranking.frame(minWidth: 150)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        distribution.frame(maxWidth: .infinity)
                        ranking
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .statCardBackground()
    }

    private var distribution: some View {
        Chart(rows) { row in
            SectorMark(angle: .value("时长", row.seconds), innerRadius: .ratio(0.62))
                .foregroundStyle(Color(hex: row.colorHex))
                .accessibilityLabel(row.name)
                .accessibilityValue(Format.duration(row.seconds))
        }
        .frame(width: 160, height: 160)
    }

    private var ranking: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: row.colorHex)).frame(width: 8, height: 8)
                    Text(row.name).lineLimit(1).help(row.name)
                    Spacer(minLength: 8)
                    Text(Format.duration(row.seconds))
                        .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
                .font(.callout)
            }
        }
    }
}

/// 生产力趋势: 30-day daily-pulse line -- untracked days are gapped (each
/// contiguous run of tracked days is its own `LineMark` series, so the
/// polyline actually breaks across a nil run instead of bridging it; no mark
/// is drawn for an untracked day itself) -- a dashed 阈值 reference line, and
/// a hover crosshair (`chartOverlay` + `onContinuousHover`, mirroring the
/// plotFrame-relative hit-testing pattern used for Swift Charts hover
/// overlays) that annotates the nearest day's score. A `SpatialTapGesture` on
/// the same overlay reports the tapped day via `onSelectDay` so the caller
/// can jump the range to that single day.
struct ScoreTrendCard: View {
    let trend: [Int?]
    let streak: Int
    var updatedAt: Date? = nil
    let onSelectDay: (Date) -> Void

    @State private var hoverIndex: Int?

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    /// Index `i` in `trend` (a 30-entry, tail-is-today trailing window) is
    /// the day `today - (29 - i)` -- i.e. `today - 29 + i`, per spec.
    private func day(forIndex index: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: index - 29, to: today) ?? today
    }

    private func tooltipText(forIndex index: Int) -> String {
        guard trend.indices.contains(index), let pulse = trend[index] else { return String(localized: "无记录") }
        let d = day(forIndex: index)
        return String(localized: "\(d.formatted(.dateTime.month().day())) · \(pulse) 分")
    }

    /// Contiguous runs of tracked (non-nil) days, each `(index, pulse)`.
    /// Swift Charts connects every `LineMark` sharing an implicit series into
    /// one polyline regardless of gaps in the drawn marks -- `Optional` has
    /// no `Plottable` conformance to encode a nil-y directly, so each run is
    /// instead tagged with its own `series:` value (see `body`) to force a
    /// break between runs.
    private var runs: [[(index: Int, pulse: Int)]] {
        var result: [[(index: Int, pulse: Int)]] = []
        var current: [(index: Int, pulse: Int)] = []
        for (index, value) in trend.enumerated() {
            guard let value else {
                if !current.isEmpty { result.append(current); current = [] }
                continue
            }
            current.append((index, value))
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CardTitle(text: String(localized: "生产力趋势 · 近 30 天"))
                Spacer()
                if streak >= 2 {
                    Text("连续 \(streak) 天 ≥ \(StatsModel.streakThreshold) 分")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            Chart {
                ForEach(Array(runs.enumerated()), id: \.offset) { runIndex, run in
                    ForEach(run, id: \.index) { point in
                        LineMark(
                            x: .value("日", point.index),
                            y: .value("分数", point.pulse),
                            series: .value("段", runIndex)
                        )
                        .interpolationMethod(.monotone)
                        .accessibilityLabel(day(forIndex: point.index).formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(point.pulse) 分")
                        PointMark(x: .value("日", point.index), y: .value("分数", point.pulse))
                            .symbolSize(hoverIndex == point.index ? 60 : 18)
                    }
                }
                RuleMark(y: .value("阈值", StatsModel.streakThreshold))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                if let hoverIndex {
                    RuleMark(x: .value("日", hoverIndex))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .annotation(position: .top, alignment: .center) {
                            Text(tooltipText(forIndex: hoverIndex))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                }
            }
            .chartXScale(domain: 0...max(trend.count - 1, 0))
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: [0, 7, 14, 21, 29]) { value in
                    let index = value.as(Int.self) ?? 0
                    AxisTick()
                    AxisValueLabel(anchor: index == 29 ? .topTrailing : (index == 0 ? .topLeading : .top),
                                   collisionResolution: .disabled) {
                        Text(day(forIndex: index), format: .dateTime.month(.defaultDigits).day())
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoverIndex = nearestIndex(at: location, proxy: proxy, geo: geo)
                            case .ended:
                                hoverIndex = nil
                            }
                        }
                        .gesture(
                            SpatialTapGesture().onEnded { value in
                                // Empty trend (heavy lookback hasn't populated
                                // yet) -> `nearestIndex` still resolves to 0
                                // against the domain's 0...0 fallback; guard
                                // so a tap can't navigate to a fabricated day.
                                guard !trend.isEmpty,
                                      let idx = nearestIndex(at: value.location, proxy: proxy, geo: geo)
                                else { return }
                                onSelectDay(day(forIndex: idx))
                            }
                        )
                }
            }
            HStack {
                Text("\(day(forIndex: 0).formatted(.dateTime.month().day()))–\(today.formatted(.dateTime.month().day()))")
                Spacer()
                if let updatedAt {
                    Text("更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .statCardBackground()
    }

    private func nearestIndex(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Int? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geo[plotFrame].origin
        let xPos = location.x - origin.x
        guard let index: Int = proxy.value(atX: xPos) else { return nil }
        return min(max(index, 0), max(trend.count - 1, 0))
    }
}
