import SwiftUI
import Charts

/// The label on a dashed average line: one per chart, in the quiet ink on
/// the card's own colour so a bar behind it does not cut the text.
struct AverageTag: View {
    let text: String
    var body: some View {
        Text(text).font(.note).monospacedDigit().foregroundStyle(Design.ink2)
            .padding(.horizontal, Design.Space.xs)
            .background(Design.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous))
    }
}

/// 最近 4 周: the last 28 days whatever range the page shows. One sentence
/// on the last two weeks against the two before, then each leading
/// category as four weekly bars (oldest first) and what the latest week
/// changed.
struct FourWeekCard: View {
    let data: FourWeekComparison

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            CardHeading(title: "最近 4 周", caption: Text("每周，左边最早"))
            headline.fixedSize(horizontal: false, vertical: true)
            if data.rows.isEmpty {
                Text("这段时间还没有记录。").foregroundStyle(Design.ink2)
            } else {
                let nameWidth = RefinedStyle.nameColumn(data.rows.map(\.name), font: .systemFont(ofSize: NSFont.systemFontSize), cap: 140)
                VStack(spacing: 0) {
                    HStack(spacing: Design.Space.sm) {
                        Spacer()
                        Text("最近一周").fixedSize().frame(width: Design.durationWidth, alignment: .trailing)
                        Text("与前一周差").fixedSize().frame(width: Design.durationWidth, alignment: .trailing)
                    }
                    .font(.note).foregroundStyle(Design.ink2)
                    ForEach(data.rows) { row in
                        HStack(spacing: Design.Space.sm) {
                            Circle().fill(RefinedStyle.category(row.id, hex: row.colorHex)).frame(width: 8, height: 8)
                            Text(row.name).frame(width: nameWidth, alignment: .leading).lineLimit(1)
                            Spacer(minLength: Design.Space.sm)
                            WeekBars(row: row)
                            Text(Format.duration(row.weeks[3])).monospacedDigit()
                                .frame(width: Design.durationWidth, alignment: .trailing)
                            Text(Format.durationDelta(row.delta)).monospacedDigit().foregroundStyle(Design.ink2)
                                .frame(width: Design.durationWidth, alignment: .trailing)
                        }
                        .frame(height: Design.rowHeight)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .cardBox()
    }

    @ViewBuilder private var headline: some View {
        switch data.headline {
        case nil:
            Text("前两周还没有记录，没法比较。").foregroundStyle(Design.ink2)
        case .same:
            Text("最近两周和前两周差不多。")
        case let .changed(delta, category):
            let amount = Format.duration(abs(delta))
            switch (delta > 0, category) {
            case (true, let name?): Text("最近两周比前两周多记录了 \(amount)，主要是\(name)。")
            case (true, nil): Text("最近两周比前两周多记录了 \(amount)。")
            case (false, let name?): Text("最近两周比前两周少记录了 \(amount)，主要是\(name)。")
            case (false, nil): Text("最近两周比前两周少记录了 \(amount)。")
            }
        }
    }

    /// Four bars on the row's own scale, one indigo ramp from the oldest to the newest.
    private struct WeekBars: View {
        let row: FourWeekComparison.Row
        private static let height: CGFloat = 20
        var body: some View {
            let peak = max(1, row.weeks.max() ?? 1)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(ColorSystem.isOriginal ? RefinedStyle.category(row.id, hex: row.colorHex).opacity(index == 3 ? 1 : 0.4) : ColorSystem.ramp([0.2, 0.4, 0.62, 1][index]))
                        .frame(width: 10, height: row.weeks[index] > 0 ? max(2, Self.height * row.weeks[index] / peak) : 1)
                }
            }
            .frame(height: Self.height, alignment: .bottom)
            .padding(.trailing, Design.Space.md)
            .accessibilityHidden(true)
        }
    }
}

/// 每天的打断: interruptions on each of the last 14 days, today last, with
/// the dashed average. The count shows under the pointer.
struct InterruptionTrendCard: View {
    let days: [StatsModel.InterruptionDay]?
    @State private var hovered: Date?
    #if DEBUG
    @MainActor static var previewHover: Date?
    #endif

    private var average: Double? {
        guard let days, days.count >= 3 else { return nil }
        return Double(days.reduce(0) { $0 + $1.count }) / Double(days.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            CardHeading(title: "每天的打断", caption: Text("近 14 天"))
            if let days {
                chart(days).frame(minHeight: 140, maxHeight: .infinity)
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Design.track)
                    .frame(minHeight: 140, maxHeight: .infinity)
            }
        }
        .cardBox()
        #if DEBUG
        .onAppear { hovered = Self.previewHover }
        #endif
    }

    private func chart(_ days: [StatsModel.InterruptionDay]) -> some View {
        let calendar = Calendar.current
        let peak = days.map(\.count).max() ?? 0
        return Chart {
            ForEach(days) { day in
                BarMark(x: .value("日期", day.day, unit: .day), y: .value("次数", day.count))
                    .foregroundStyle(hovered == day.day ? Design.interruptionActive : Design.interruption.opacity(hovered == nil ? 1 : 0.45))
                    .accessibilityLabel(day.day.formatted(.dateTime.month().day()))
                    .accessibilityValue("\(day.count)")
            }
            if let average {
                RuleMark(y: .value("日均", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Design.ink2)
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        AverageTag(text: String(localized: "均 \(average.formatted(.number.precision(.fractionLength(0...1))))"))
                    }
            }
            if let hovered, let day = days.first(where: { $0.day == hovered }) {
                RuleMark(x: .value("日期", hovered, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("\(hovered.formatted(.dateTime.month().day())) · \(day.count) 次打断")
                            .font(.note).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .floatingCard()
                    }
            }
        }
        .chartYScale(domain: 0...Double(max(peak, 1)) * 1.25)
        .chartXScale(domain: (days.first?.day ?? .now)...(days.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0.day) } ?? .now))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Design.line2)
                AxisValueLabel().font(.note).foregroundStyle(Design.ink2)
            }
        }
        .chartXAxis {
            AxisMarks(values: days.enumerated().filter { $0.offset % 2 == 1 || $0.offset == days.count - 1 }
                .map { calendar.date(byAdding: .hour, value: 12, to: $0.element.day) ?? $0.element.day }) { value in
                AxisValueLabel(collisionResolution: .disabled) {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.month(.defaultDigits).day()).font(.note).foregroundStyle(Design.ink2)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovered = proxy.plotFrame.flatMap { frame in
                                proxy.value(atX: location.x - geometry[frame].origin.x, as: Date.self)
                            }.map { calendar.startOfDay(for: $0) }.flatMap { day in days.contains { $0.day == day } ? day : nil }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }
}
