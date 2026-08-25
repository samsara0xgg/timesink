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

/// Small colored 环比 chip shared by the three summary cards -- green when
/// non-negative, red when negative, matching the menu-bar dashboard's KPI
/// delta styling (`MenuBarDashboardView.kpiLine`/`scoreColumn`).
private struct DeltaChip: View {
    let text: String
    let isNegative: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(isNegative ? Color.red : Color.green)
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
            CardTitle(text: "总时长")
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.duration(total))
                    .font(.system(size: 34, weight: .bold))
                if let delta {
                    DeltaChip(text: Format.durationDelta(delta), isNegative: delta < 0)
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
            CardTitle(text: "专注时长")
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.duration(focus))
                    .font(.system(size: 34, weight: .bold))
                if let delta {
                    DeltaChip(text: Format.durationDelta(delta), isNegative: delta < 0)
                }
            }
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
        guard let pulse else { return "暂无数据" }
        return pulse >= 70 ? "继续保持" : "有点分心"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: "生产力分")
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pulse.map { "\($0)%" } ?? "--")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(color)
                if let delta {
                    DeltaChip(text: (delta >= 0 ? "+\(delta)" : "\(delta)") + "%", isNegative: delta < 0)
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
    let onSelectDay: (Date) -> Void

    @State private var hoverIndex: Int?

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    /// Index `i` in `trend` (a 30-entry, tail-is-today trailing window) is
    /// the day `today - (29 - i)` -- i.e. `today - 29 + i`, per spec.
    private func day(forIndex index: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: index - 29, to: today) ?? today
    }

    private func tooltipText(forIndex index: Int) -> String {
        guard trend.indices.contains(index), let pulse = trend[index] else { return "无记录" }
        let cal = Calendar.current
        let d = day(forIndex: index)
        return "\(cal.component(.month, from: d))月\(cal.component(.day, from: d))日 · \(pulse) 分"
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
                CardTitle(text: "生产力趋势")
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
            .chartXAxis(.hidden)
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

/// 生产力热力图: hand-drawn 7x24 `Grid` (168 cells), not a Swift Charts mark
/// grid -- `DayTimelineView` established that per-mark `.help()` tooltips are
/// unreliable on Charts marks, so this card places plain `RoundedRectangle`s
/// with `.help()` directly, same as `DayTimelineView`'s timeline blocks.
/// Cell color is `scoreColor(pulse)` at an opacity driven by the cell's
/// PER-OCCURRENCE average tracked seconds -- `cells[row][hour].seconds` is a
/// SUM across every occurrence of that weekday in the 30-day window (4 or 5,
/// per `occurrences`), so dividing the raw sum by one hour would saturate
/// any weekday with as little as ~12 min/day tracked (fix round 1, IMPORTANT
/// 1). The per-occurrence average is then clamped to 3600 -- a DST
/// fall-back day's last hour can exceed 3600 wall-clock seconds, and
/// intensity must never exceed 100%. The low-sample rule is unchanged from
/// the original brief: cells with under 15 minutes of AGGREGATE sample lose
/// most of their opacity and get a "样本不足" tooltip instead of a score.
/// Cell side is derived from the available width (fix round 1, IMPORTANT 4)
/// so the grid compresses rather than overflowing its column at narrower
/// window widths, capped at 12pt.
struct HeatmapCard: View {
    let cells: [[(pulse: Int?, seconds: TimeInterval)]]
    /// 7 entries, Monday=0...Sunday=6 -- see `StatsModel.heatmapOccurrences`.
    let occurrences: [Int]

    private static let weekdayLabels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private static let hourTickLabels: [Int: String] = [0: "0", 6: "6", 12: "12", 18: "18", 23: "23"]
    private static let lowSampleThreshold: TimeInterval = 900
    private static let secondsPerHour: TimeInterval = 3600
    private static let labelColumnWidth: CGFloat = 24
    private static let gridSpacing: CGFloat = 2
    private static let minCellSide: CGFloat = 6
    private static let maxCellSide: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CardTitle(text: "生产力热力图")
                Spacer()
                Text("近 30 天")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let cellSide = Self.cellSide(forAvailableWidth: geo.size.width)
                Grid(horizontalSpacing: Self.gridSpacing, verticalSpacing: Self.gridSpacing) {
                    ForEach(0..<7, id: \.self) { row in
                        GridRow {
                            Text(Self.weekdayLabels[row])
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: Self.labelColumnWidth, alignment: .trailing)
                            ForEach(0..<24, id: \.self) { hour in
                                cellView(row: row, hour: hour, side: cellSide)
                            }
                        }
                    }
                    GridRow {
                        Color.clear.frame(width: Self.labelColumnWidth, height: 10)
                        ForEach(0..<24, id: \.self) { hour in
                            Text(Self.hourTickLabels[hour] ?? "")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: cellSide)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .statCardBackground()
    }

    /// `(available width - label column - inter-column spacing) / 24`,
    /// clamped to `minCellSide...maxCellSide`. 25 columns (1 label + 24
    /// hours) means 24 gaps of `gridSpacing`.
    private static func cellSide(forAvailableWidth width: CGFloat) -> CGFloat {
        let totalSpacing = gridSpacing * 24
        let available = (width - labelColumnWidth - totalSpacing) / 24
        return max(minCellSide, min(maxCellSide, available))
    }

    private func entry(row: Int, hour: Int) -> (pulse: Int?, seconds: TimeInterval) {
        guard cells.indices.contains(row), cells[row].indices.contains(hour) else { return (nil, 0) }
        return cells[row][hour]
    }

    private func cellView(row: Int, hour: Int, side: CGFloat) -> some View {
        let e = entry(row: row, hour: hour)
        let occurrenceCount = max(1, row < occurrences.count ? occurrences[row] : 1)
        let perOccurrenceSeconds = e.seconds / Double(occurrenceCount)
        let clampedSeconds = min(perOccurrenceSeconds, Self.secondsPerHour)
        let intensity = e.pulse == nil ? 0.06 : 0.2 + 0.8 * (clampedSeconds / Self.secondsPerHour)
        let lowSample = e.seconds < Self.lowSampleThreshold
        let opacity = lowSample ? intensity * 0.35 : intensity
        let tooltip = lowSample
            ? "\(Self.weekdayLabels[row]) \(hour) 时 · 样本不足"
            : "\(Self.weekdayLabels[row]) \(hour) 时 · 平均分 \(e.pulse.map(String.init) ?? "--")"
        return RoundedRectangle(cornerRadius: 2)
            .fill(scoreColor(e.pulse).opacity(opacity))
            .frame(width: side, height: side)
            .help(tooltip)
    }
}
