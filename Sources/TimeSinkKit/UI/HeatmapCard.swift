import SwiftUI

struct HeatmapCard: View {
    let data: HeatmapData
    @Binding var interaction: HeatmapInteraction
    let onOpenDay: (DateInterval) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var gridFocused: Bool
    @State private var showsScore = false

    private var previewKey: HeatmapData.Key { interaction.preview(fallback: data.suggestedKey) }
    private var preview: HeatmapData.Cell { data[previewKey] }
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    private var hours: [Int] {
        let first = min(6, data.cells.filter { $0.seconds > 0 }.map { $0.key.hour }.min() ?? 6)
        return Array(first..<24)
    }
    private var weekdays: [Int] { calendar.firstWeekday == 1 ? [6, 0, 1, 2, 3, 4, 5] : Array(0..<7) }
    private var rowTotals: [Double] { (0..<7).map { day in (0..<24).reduce(0) { $0 + data[.init(weekday: day, hour: $1)].averageSeconds } } }
    private var columnTotals: [Double] { (0..<24).map { hour in (0..<7).reduce(0) { $0 + data[.init(weekday: $1, hour: hour)].averageSeconds } / 7 } }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            HStack(alignment: .center) {
                CardHeading(title: "什么时候在用电脑",
                            caption: Text("\(data.window.start.formatted(.dateTime.month().day().locale(AppLanguage.locale)))–\(data.window.end.addingTimeInterval(-1).formatted(.dateTime.month().day().locale(AppLanguage.locale))) · 每格是同一星期、同一小时的平均"))
                Spacer(minLength: Design.Space.sm)
                Segmented(options: [false, true], selection: $showsScore, height: 24) { score in
                    score ? Text("评分") : Text("时长")
                }
                .accessibilityLabel("热力图指标")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) { grid; legend }.frame(minWidth: 520)
                    previewSummary.padding(Design.Space.md).frame(width: 230).background(Design.floor, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 12) { grid; legend; Divider(); previewSummary }
            }
            if interaction.pinned != nil { dateDetails }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBox()
        .animation(Design.motion(Design.page, reduced: reduceMotion), value: interaction.pinned != nil)
    }

    private var grid: some View {
        GeometryReader { geometry in
        let cellWidth = max(4, (geometry.size.width - 34 - 96 - 12 - CGFloat(hours.count + 2) * 3) / CGFloat(hours.count))
        let rows = rowTotals, columns = columnTotals
        Grid(horizontalSpacing: 3, verticalSpacing: 4) {
            ForEach(weekdays, id: \.self) { weekday in
                GridRow {
                    Text(HeatmapData.Key(weekday: weekday, hour: 0).weekdayLabel)
                        .font(.note).foregroundStyle(previewKey.weekday == weekday ? .primary : .secondary)
                        .frame(width: 34, alignment: .leading)
                    ForEach(hours, id: \.self) { hour in
                        cell(data[.init(weekday: weekday, hour: hour)]).frame(width: cellWidth)
                    }
                    Color.clear.frame(width: 12, height: 1)
                    HStack(spacing: 6) {
                        GeometryReader { bar in
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule().fill(Color.secondary.opacity(0.55)).frame(width: bar.size.width * rows[weekday] / max(1, rows.max() ?? 1))
                        }.frame(height: 6)
                        Text(Format.duration(rows[weekday], compact: true)).font(.note).foregroundStyle(Design.ink2).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }.frame(width: 96).help("每个\(HeatmapData.Key(weekday: weekday, hour: 0).weekdayLabel)平均记录时长")
                }
            }
            GridRow {
                Color.clear.frame(width: 34, height: 36)
                ForEach(hours, id: \.self) { hour in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.55))
                            .frame(width: max(2, cellWidth - 6), height: max(2, 22 * columns[hour] / max(1, columns.max() ?? 1)))
                            .frame(height: 22, alignment: .bottom)
                        Text(hour % 3 == 0 ? HeatmapData.Key.hourLabel(hour, locale: locale) : " ")
                            .font(.note).monospacedDigit().foregroundStyle(Design.ink2)
                    }.frame(width: cellWidth).help("\(HeatmapData.Key(weekday: 0, hour: hour).timeLabel(locale)) 平均 \(Format.chineseDuration(columns[hour]))")
                }
                Color.clear.frame(width: 12, height: 1)
                Text("平均 / 日").font(.note).foregroundStyle(Design.ink2).frame(width: 96)
            }
        }
        }
        .frame(height: 208)
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(gridFocused ? Color.accentColor : .clear, lineWidth: 2)
                .padding(-4).allowsHitTesting(false)
        }
        .onKeyPress(.leftArrow) { move(horizontal: -1); return .handled }
        .onKeyPress(.rightArrow) { move(horizontal: 1); return .handled }
        .onKeyPress(.upArrow) { move(vertical: -1); return .handled }
        .onKeyPress(.downArrow) { move(vertical: 1); return .handled }
        .onKeyPress(.return) { interaction.select(interaction.cursor ?? previewKey); return .handled }
        .onKeyPress(.space) { interaction.select(interaction.cursor ?? previewKey); return .handled }
        .onKeyPress(.escape) { interaction.dismiss(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("按星期和小时汇总的生产力热力图")
        .accessibilityHint("方向键选择时段，回车查看具体日期，Escape 取消固定")
    }

    private func cell(_ cell: HeatmapData.Cell) -> some View {
        let key = previewKey
        return HeatmapCellView(cell: cell, locale: locale, showsScore: showsScore, highlighted: key == cell.key,
            aligned: key.weekday == cell.key.weekday || key.hour == cell.key.hour,
            pinned: interaction.pinned == cell.key,
            select: { interaction.select(cell.key); gridFocused = true },
            hover: { inside in
                guard interaction.pinned == nil else { return }
                if inside, interaction.hovered != cell.key { interaction.hovered = cell.key }
                else if !inside, interaction.hovered == cell.key { interaction.hovered = nil }
            })
            .equatable()
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(showsScore ? "评分" : "平均分钟")
                ForEach([0, 40, 70], id: \.self) { score in
                    RoundedRectangle(cornerRadius: 2).fill((showsScore ? scoreColor(score) : RefinedStyle.heat.opacity(0.08 + 0.8 * min(1, Double(score) / 70)))).frame(width: 12, height: 8)
                    Text(showsScore ? (score == 0 ? "0–39" : score == 40 ? "40–69" : "70–100") : (score == 0 ? "少" : score == 40 ? "30" : "60"))
                }
                Spacer(minLength: 0)
            }
            Text(showsScore ? "颜色表示评分；样本不足不显示分数。" : "颜色越深，平均活动时长越长。")
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(.secondary.opacity(0.5)).frame(width: 10, height: 10)
                Text("无记录")
                RoundedRectangle(cornerRadius: 2).strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 10, height: 10).padding(.leading, 8)
                Text("样本不足：累计不足 15 分钟")
            }
        }
        .font(.note).foregroundStyle(Design.ink2)
        .accessibilityElement(children: .combine)
    }

    private var previewSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(preview.key.label(locale)).font(.subheadline.weight(.semibold)).monospacedDigit()
                Spacer(minLength: 4)
                if interaction.pinned != nil {
                    Button { interaction.dismiss(); gridFocused = true } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless).accessibilityLabel("取消固定时段").help("取消固定时段（Esc）")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(showsScore ? preview.scoreLabel : Format.duration(preview.averageSeconds)).font(.title3.weight(.semibold))
                    .foregroundStyle(showsScore && !preview.isLowSample ? scoreColor(preview.pulse) : Color.primary)
                Text("累计 \(Format.duration(preview.seconds))").font(.note).monospacedDigit()
                Spacer(minLength: 0)
            }
            Text("每个\(preview.key.weekdayLabel)平均 \(Format.duration(preview.averageSeconds)) · \(preview.availableDays) 天中有 \(preview.recordedDays) 天记录")
                .font(.note).foregroundStyle(Design.ink2)
            Text("平均含无记录日，不含尚未到来的时段；分数按活动时长加权。")
                .font(.note).foregroundStyle(Design.ink2)
            if preview.seconds > 0 {
                contributionLine(String(localized: "主要分类"), entries: Array(preview.categories.prefix(3)))
                contributionLine(String(localized: "主要应用"), entries: Array(preview.apps.prefix(3)))
            } else {
                Text("此时段没有记录，不代表生产力为零。")
                    .font(.note).foregroundStyle(Design.ink2)
            }
            Text(interaction.pinned != nil ? "已固定 · 点选其他格子可切换，Esc 取消"
                 : "悬停预览 · 点击查看日期 · 方向键浏览，回车固定")
                .font(.note).foregroundStyle(Design.ink2)
        }
        .frame(minHeight: 156, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func contributionLine(_ label: String, entries: [HeatmapData.Contribution]) -> some View {
        Text(String(localized: "\(label)：") + entries.map { "\($0.name) \(Format.duration($0.seconds))" }.joined(separator: " · "))
            .font(.note).fixedSize(horizontal: false, vertical: true)
    }

    private var dateDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("具体日期 · 选择一天查看该时段活动").font(.caption.weight(.semibold))
            ForEach(preview.days) { day in
                Button { onOpenDay(day.interval) } label: {
                    HStack(spacing: 8) {
                        Text(day.date.formatted(.dateTime.month().day().locale(AppLanguage.locale)))
                        if repeatedHour(on: day.date) {
                            Text(day.interval.start.formatted(.dateTime.timeZone(.iso8601(.short))))
                                .foregroundStyle(Design.ink2)
                        }
                        Spacer(minLength: 4)
                        Text(day.seconds > 0 ? Format.duration(day.seconds) : String(localized: "无记录"))
                        Text(day.seconds >= 900 ? "\(day.pulse ?? 0) 分" : "—")
                            .foregroundStyle(Design.ink2).frame(width: 44, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.note)
                    }
                    .padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(day.seconds == 0)
                .font(.note).monospacedDigit()
                .help(day.seconds == 0 ? "这一天此时段没有记录" : day.seconds < 900 ? "此日期的样本不足 15 分钟，暂不显示分数" : "查看这一天此时段的活动")
                .accessibilityLabel("查看 \(day.date.formatted(date: .abbreviated, time: .omitted)) \(preview.key.timeLabel(locale)) 的活动，\(Format.duration(day.seconds))")
            }
            if preview.days.isEmpty {
                Text("所选范围内这个时段尚未到来。").font(.note).foregroundStyle(Design.ink2)
            }
        }
    }

    private func repeatedHour(on day: Date) -> Bool { preview.days.filter { $0.date == day }.count > 1 }
    private func move(horizontal: Int = 0, vertical: Int = 0) {
        interaction.move(horizontal: horizontal, vertical: vertical, fallback: data.suggestedKey)
    }
}

/// Only changed rows/columns rebuild their button visuals on pointer movement.
/// Actions capture the same stable binding and cell key, so equality is based
/// on every displayed value rather than on closure identity.
private struct HeatmapCellView: View, Equatable {
    let cell: HeatmapData.Cell
    let locale: Locale
    let showsScore: Bool
    let highlighted: Bool
    let aligned: Bool
    let pinned: Bool
    let select: () -> Void
    let hover: (Bool) -> Void
    private var intensity: Double { min(1, cell.averageSeconds / 3600) }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.showsScore == rhs.showsScore && lhs.locale == rhs.locale && lhs.cell.key == rhs.cell.key && lhs.cell.seconds == rhs.cell.seconds
            && lhs.cell.pulse == rhs.cell.pulse && lhs.cell.averageSeconds == rhs.cell.averageSeconds
            && lhs.cell.accessibilitySummary == rhs.cell.accessibilitySummary
            && lhs.highlighted == rhs.highlighted && lhs.aligned == rhs.aligned && lhs.pinned == rhs.pinned
    }

    var body: some View {
        Button(action: select) {
            RoundedRectangle(cornerRadius: 3)
                .fill(cell.seconds == 0 || (!showsScore && intensity < 0.04) ? Color.secondary.opacity(0.06)
                      : !showsScore ? RefinedStyle.heat.opacity(0.08 + 0.8 * intensity)
                      : cell.isLowSample ? Color.secondary.opacity(0.25) : scoreColor(cell.pulse))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(highlighted ? Color.primary : Color.secondary.opacity(cell.seconds == 0 ? 0.22 : 0),
                                      lineWidth: highlighted ? 2 : 1)
                }
                .overlay {
                    if cell.isLowSample {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                .padding(1)
                .background(aligned ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 3))
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false)
        .onHover(perform: hover)
        .help("\(cell.key.label(locale))\n\(cell.accessibilitySummary)\n点击固定并查看具体日期")
        .accessibilityLabel(cell.key.label(locale))
        .accessibilityValue(cell.accessibilitySummary)
        .accessibilityAddTraits(pinned ? .isSelected : [])
        .accessibilityHint("查看贡献此格的具体日期和活动")
    }
}
