import SwiftUI
import Charts

/// Shared absolute minute scale for expanded hourly charts. Overview sparklines
/// can be compact; a detail chart must reveal both the time and the quantity.
struct HourlyActivityChart: View {
    let bars: [HourlyBigView.Bar]
    @State private var selectedHour: Int?
    @Environment(\.locale) private var locale

    struct Segment: Identifiable {
        let bar: HourlyBigView.Bar
        let startMinutes: Double
        let endMinutes: Double
        var id: String { bar.id }
    }

    /// Explicit bounds avoid an inferred band size on a continuous hour axis.
    static func segments(for bars: [HourlyBigView.Bar]) -> [Segment] {
        var offsets: [Int: Double] = [:]
        return bars.filter { $0.seconds > 0 }.sorted {
            $0.hour == $1.hour ? $0.categoryID < $1.categoryID : $0.hour < $1.hour
        }.map { bar in
            let start = offsets[bar.hour, default: 0]
            let end = start + bar.seconds / 60
            offsets[bar.hour] = end
            return Segment(bar: bar, startMinutes: start, endMinutes: end)
        }
    }

    private var totals: [Int: TimeInterval] {
        Dictionary(grouping: bars, by: \.hour).mapValues { $0.reduce(0) { $0 + $1.seconds } }
    }

    private var scale: (top: Double, step: Double) { ChartAxis.minuteScale(maxMinutes: (totals.values.max() ?? 0) / 60) }
    /// Only the hours that have data, e.g. 7:00–18:00 rather than 0–24.
    private var span: Range<Int> { ChartAxis.hourSpan(totals.filter { $0.value > 0 }.keys) ?? 0..<24 }


    private func description(_ hour: Int) -> String {
        HeatmapData.Key(weekday: 0, hour: hour).timeLabel(locale) + " · " + Format.duration(totals[hour] ?? 0)
    }

    var body: some View {
        let span = span, scale = scale
        VStack(alignment: .leading, spacing: 6) {
            Text("每小时活动时长 · 分钟")
                .font(.note).foregroundStyle(Design.ink2)
            Chart {
                ForEach(Self.segments(for: bars)) { segment in
                    let bar = segment.bar
                    RectangleMark(xStart: .value("小时", Double(bar.hour) + 0.08),
                                  xEnd: .value("小时", Double(bar.hour) + 0.92),
                                  yStart: .value("分钟", segment.startMinutes),
                                  yEnd: .value("分钟", segment.endMinutes))
                        .foregroundStyle(RefinedStyle.category(bar.categoryID, hex: bar.colorHex))
                        .accessibilityLabel(HeatmapData.Key(weekday: 0, hour: bar.hour).timeLabel(locale))
                        .accessibilityValue(Format.duration(bar.seconds))
                }
                if let selectedHour {
                    RuleMark(x: .value("小时", Double(selectedHour) + 0.5))
                        .foregroundStyle(Design.ink2)
                }
            }
            .chartXScale(domain: Double(span.lowerBound)...Double(span.upperBound))
            .chartYScale(domain: 0...scale.top)
            .chartXAxis {
                AxisMarks(values: Array(stride(from: Double(span.lowerBound), through: Double(span.upperBound), by: 3))) { value in
                    let hour = Int(value.as(Double.self) ?? 0)
                    AxisTick()
                    AxisValueLabel(anchor: hour == span.upperBound ? .topTrailing : (hour == span.lowerBound ? .topLeading : .top),
                                   collisionResolution: .disabled) {
                        Text("\(hour):00").monospacedDigit()
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: Array(stride(from: 0, through: scale.top, by: scale.step))) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                guard let frame = proxy.plotFrame else { return }
                                let plot = geometry[frame]
                                guard plot.contains(point),
                                      let hour: Double = proxy.value(atX: point.x - plot.minX) else {
                                    selectedHour = nil
                                    return
                                }
                                selectedHour = min(span.upperBound - 1, max(span.lowerBound, Int(hour)))
                            case .ended: selectedHour = nil
                            }
                        }
                }
            }
            .frame(height: 100)
            Text(selectedHour.map(description) ?? (bars.allSatisfy { $0.seconds == 0 } ? String(localized: "暂无活动记录") : String(localized: "指向柱形查看具体时段与时长")))
                .font(.note).monospacedDigit().foregroundStyle(Design.ink2)
        }
        .focusable()
        .onKeyPress(.leftArrow) {
            selectedHour = max(span.lowerBound, (selectedHour ?? span.lowerBound + 1) - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selectedHour = min(span.upperBound - 1, (selectedHour ?? span.lowerBound - 1) + 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("24 小时活动分布，单位分钟")
        .accessibilityValue(selectedHour.map(description) ?? String(localized: "全天 24 小时"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1 : -1
            selectedHour = min(span.upperBound - 1, max(span.lowerBound, (selectedHour ?? span.lowerBound) + step))
        }
    }
}
