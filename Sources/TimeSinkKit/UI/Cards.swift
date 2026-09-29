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

/// Pulse -> color mapping shared by the stats dashboard's score card and the
/// menu-bar mini dashboard's gauge, so the two stay visually consistent.
func scoreColor(_ pulse: Int?) -> Color {
    guard let pulse else { return .secondary }
    if pulse >= 70 { return .green }
    if pulse >= 40 { return .orange }
    return .red
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
    @Environment(\.locale) private var locale
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
                    Text("更新于 \(updatedAt.formatted(.dateTime.hour().minute().locale(locale)))")
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
