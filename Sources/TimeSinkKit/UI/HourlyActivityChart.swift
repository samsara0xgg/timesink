import SwiftUI
import Charts

/// Shared absolute minute scale for expanded hourly charts. Overview sparklines
/// can be compact; a detail chart must reveal both the time and the quantity.
struct HourlyActivityChart: View {
    let bars: [HourlyBigView.Bar]
    var minimumScale: Double = 60
    @State private var selectedHour: Int?

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

    private var ceiling: Double {
        max(minimumScale, ceil((totals.values.max() ?? 0) / 3600) * 60)
    }

    private func description(_ hour: Int) -> String {
        String(format: "%02d:00–%02d:00", hour, hour + 1) + " · " + Format.duration(totals[hour] ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("每小时活动时长 · 分钟")
                .font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(Self.segments(for: bars)) { segment in
                    let bar = segment.bar
                    RectangleMark(xStart: .value("小时", Double(bar.hour) + 0.08),
                                  xEnd: .value("小时", Double(bar.hour) + 0.92),
                                  yStart: .value("分钟", segment.startMinutes),
                                  yEnd: .value("分钟", segment.endMinutes))
                        .cornerRadius(2)
                        .foregroundStyle(RefinedStyle.category(bar.categoryID, hex: bar.colorHex))
                        .accessibilityLabel(String(format: "%02d:00–%02d:00", bar.hour, bar.hour + 1))
                        .accessibilityValue(Format.duration(bar.seconds))
                }
                if let selectedHour {
                    RuleMark(x: .value("小时", Double(selectedHour) + 0.5))
                        .foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: 0.0...24.0)
            .chartYScale(domain: 0...ceiling)
            .chartXAxis {
                AxisMarks(values: [0.0, 6.0, 12.0, 18.0, 24.0]) { value in
                    let hour = Int(value.as(Double.self) ?? 0)
                    AxisTick()
                    AxisValueLabel(anchor: hour == 24 ? .topTrailing : (hour == 0 ? .topLeading : .top),
                                   collisionResolution: .disabled) {
                        Text(String(format: "%02d", hour)).monospacedDigit()
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, ceiling / 2, ceiling]) {
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
                                selectedHour = min(23, max(0, Int(hour)))
                            case .ended: selectedHour = nil
                            }
                        }
                }
            }
            .frame(height: 100)
            Text(selectedHour.map(description) ?? (bars.allSatisfy { $0.seconds == 0 } ? String(localized: "暂无活动记录") : String(localized: "指向柱形查看具体时段与时长")))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .focusable()
        .onKeyPress(.leftArrow) {
            selectedHour = max(0, (selectedHour ?? 1) - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selectedHour = min(23, (selectedHour ?? -1) + 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("24 小时活动分布，单位分钟")
        .accessibilityValue(selectedHour.map(description) ?? String(localized: "00:00 至 24:00"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1 : -1
            selectedHour = min(23, max(0, (selectedHour ?? 0) + step))
        }
    }
}
