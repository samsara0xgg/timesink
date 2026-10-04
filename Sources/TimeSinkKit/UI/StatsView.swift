import SwiftUI
import Charts

/// 趋势: how a stretch of days compares with the one before. The header says
/// the total and the change; then where the time went day by day and by
/// category, when in the week the computer is used, apps and sites, and
/// the score over thirty days.
struct StatsView: View {
    let model: AppModel
    @Bindable var stats: StatsModel
    @State private var granularity: StatsModel.Granularity = .day
    @State private var showsRadar = false
    private struct RefreshID: Equatable { let range: DateRangeSelection.Window; let version: Int }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let width = geometry.size.width - 2 * Design.Space.page
                let wide = width >= PageLayout.wideWidth
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.lg) {
                        header(width: width)
                        if let error = stats.loadError {
                            HStack(spacing: Design.Space.sm) {
                                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Design.ink2)
                                Button("重试") { Task { await stats.recompute(model: model) } }.buttonStyle(PillButtonStyle())
                            }
                        }
                        if stats.hasLoaded {
                            pair(wide: wide) { categoryHistory } trailing: { ranking }
                            // The radar summary sits beside the heatmap; the full radar opens in a sheet.
                            let radar = InterruptionRadarCard(model: model) { showsRadar = true }
                            if let heatmap = stats.heatmapData {
                                let heatmapCard = HeatmapCard(data: heatmap, interaction: $stats.heatmapInteraction) { model.openHeatmapActivities(in: $0) }.id("heatmap")
                                if wide {
                                    HStack(alignment: .top, spacing: Design.Space.lg) {
                                        heatmapCard.frame(maxWidth: .infinity)
                                        radar.frame(width: 300)
                                    }.fixedSize(horizontal: false, vertical: true)
                                } else { heatmapCard; radar }
                            } else { radar }
                            appRanking
                            scoreTrend
                        } else if stats.loadError == nil {
                            // The first two cards' places, so nothing moves when they fill.
                            pair(wide: wide) { placeholder } trailing: { placeholder }
                                .accessibilityLabel("正在读取趋势")
                        }
                    }
                    .pagePadding()
                }
                .scrollIndicators(.never)
            }
            .pageTask(id: RefreshID(range: model.range.window, version: model.dataVersion)) { await stats.recompute(model: model) }
            .whilePageShown {
                if stats.heatmapInteraction.pinned != nil { await Task.yield(); proxy.scrollTo("heatmap", anchor: .top) }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await stats.recompute(model: model)
                }
            }
        }
        .background(WorkspaceBackground())
        .sheet(isPresented: $showsRadar) {
            VStack(alignment: .trailing, spacing: Design.Space.md) {
                InterruptionRadarCard(model: model)
                Button("完成") { showsRadar = false }.keyboardShortcut(.defaultAction)
            }.padding(Design.Space.card).frame(minWidth: 820).background(WorkspaceBackground())
        }
    }

    /// Two cards side by side at one height, or stacked when narrow.
    @ViewBuilder private func pair(wide: Bool, @ViewBuilder leading: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
        if wide {
            HStack(alignment: .top, spacing: Design.Space.lg) {
                leading().frame(maxWidth: .infinity)
                trailing().frame(maxWidth: .infinity)
            }
            .frame(minHeight: 300).fixedSize(horizontal: false, vertical: true)
        } else {
            leading().frame(minHeight: 300)
            trailing()
        }
    }

    private var placeholder: some View {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).designCard()
    }

    private func header(width: CGFloat) -> some View {
        let sentence: Text
        if !stats.hasLoaded {
            sentence = Text(verbatim: " ")
        } else if stats.total < 60 {
            sentence = Text("这段时间还没有记录。")
        } else {
            let time = Text(TodayFmt.long(stats.total)).monospacedDigit()
            if let delta = stats.totalDelta, abs(delta) >= 60 {
                let amount = Format.chineseDuration(abs(delta))
                sentence = delta > 0 ? Text("共记录 \(time)，比上期多了 \(amount)。") : Text("共记录 \(time)，比上期少了 \(amount)。")
            } else {
                sentence = Text("共记录 \(time)，和上期差不多。")
            }
        }
        let share = Int((stats.focus / max(1, stats.total) * 100).rounded())
        let loaded = stats.hasLoaded
        return PageHeader(sentence: sentence, stats: [
            StripStat(id: 0, label: "日均", value: loaded ? TodayFmt.clock(stats.avgPerDay) : "—", note: String(localized: "按已过的天数")),
            StripStat(id: 1, label: "投入", value: loaded ? TodayFmt.clock(stats.focus) : "—", note: loaded ? String(localized: "占 \(share)%") : ""),
            StripStat(id: 2, label: "评分", value: stats.pulse.map(String.init) ?? "—", note: loaded && stats.trendStreak > 0 ? String(localized: "连续 \(stats.trendStreak) 天达标") : "")
        ], width: width) {
            RangeControls(model: model, lenses: true)
        } actions: { EmptyView() }
    }

    private var categoryHistory: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            HStack {
                if granularity == .day { CardHeading(title: "每天的分类时长") } else { CardHeading(title: "每周的分类时长") }
                Spacer()
                Segmented(options: [StatsModel.Granularity.day, .week], selection: $granularity, height: 24) { item in
                    item == .day ? Text("天") : Text("周")
                }
            }
            Group { if granularity == .day {
                historyChart(stats.stackedByDay, unit: .day, scale: stats.dayHourScale)
                    .chartXScale(domain: (stats.days.first ?? .now)...(stats.days.last?.addingTimeInterval(86400) ?? .now))
                    .chartXAxis {
                        AxisMarks(values: stats.dayMarks.map(\.midday)) { value in
                            AxisValueLabel(collisionResolution: .disabled) {
                                if let date = value.as(Date.self), let mark = stats.dayMarks.first(where: { $0.midday == date }) {
                                    Text(mark.label).font(.note.weight(mark.isToday ? .semibold : .regular))
                                        .foregroundStyle(mark.isToday ? Design.ink : Design.ink2)
                                }
                            }
                        }
                    }
            } else {
                historyChart(stats.stackedByWeek, unit: .weekOfYear, scale: stats.weekHourScale)
            } }
            .frame(minHeight: 200, maxHeight: .infinity)
        }
        .cardBox()
    }

    private func historyChart(_ points: [StatsModel.StackedPoint], unit: Calendar.Component, scale: (top: Double, step: Double)) -> some View {
        Chart(points) { point in
            BarMark(x: .value("日期", point.bucketStart, unit: unit), y: .value("小时", point.hours))
                .foregroundStyle(RefinedStyle.category(point.categoryID, hex: point.colorHex))
                .accessibilityLabel("\(point.bucketStart.formatted(.dateTime.month().day())) · \(point.categoryName)")
                .accessibilityValue(Format.duration(point.hours * 3600))
        }
        .chartYScale(domain: 0...scale.top)
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: 0, through: scale.top, by: scale.step))) { value in
                AxisGridLine().foregroundStyle(Design.line2)
                AxisValueLabel { if let hours = value.as(Double.self) { Text("\(hours.formatted())h").font(.note).foregroundStyle(Design.ink2) } }
            }
        }
    }

    private var ranking: some View {
        VStack(alignment: .leading, spacing: Design.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                CardHeading(title: "分类")
                Spacer()
                Text("与上期差").font(.note).foregroundStyle(Design.ink2)
            }
            if stats.categoryRows.isEmpty { Text("这段时间还没有记录。").foregroundStyle(Design.ink2) }
            let nameWidth = RefinedStyle.nameColumn(stats.categoryRows.map(\.name), font: .systemFont(ofSize: NSFont.systemFontSize), cap: 140)
            VStack(spacing: 0) {
                ForEach(stats.categoryRows) { row in
                    Button { model.openActivities(category: row.id, range: model.range) } label: {
                        HStack(spacing: Design.Space.sm) {
                            Circle().fill(RefinedStyle.category(row.id, hex: row.colorHex)).frame(width: 8, height: 8)
                            Text(row.name).frame(width: nameWidth, alignment: .leading).lineLimit(1)
                            GeometryReader { geo in
                                Capsule().fill(Design.track)
                                Capsule().fill(RefinedStyle.category(row.id, hex: row.colorHex))
                                    .frame(width: max(3, geo.size.width * row.seconds / max(1, stats.categoryRows.first?.seconds ?? 1)))
                            }.frame(height: 4)
                            Text(Format.duration(row.seconds)).monospacedDigit().frame(width: Design.durationWidth, alignment: .trailing)
                            Text(stats.categoryDeltas[row.id].map { Format.durationDelta($0) } ?? "—").monospacedDigit()
                                .foregroundStyle(Design.ink2).frame(width: Design.durationWidth, alignment: .trailing)
                        }
                        .padding(.horizontal, Design.Space.sm)
                        .frame(height: Design.rowHeight).contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                }
            }
            .padding(.horizontal, -Design.Space.sm)
        }
        .cardBox()
    }

    private var appRanking: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            CardHeading(title: "应用与网站")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Design.Space.page)], spacing: 0) {
                ForEach(stats.appRows) { row in
                    HStack(spacing: Design.Space.sm) {
                        ActivityIcon(bundleID: row.id, domain: row.isDomain ? row.id : nil, size: 20)
                        Text(row.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(Design.track)
                            Capsule().fill(RefinedStyle.category(row.categoryID ?? "", hex: row.colorHex))
                                .frame(width: max(3, geo.size.width * row.seconds / max(1, stats.appRows.first?.seconds ?? 1)))
                        }.frame(width: 88, height: 4)
                        Text(Format.duration(row.seconds)).monospacedDigit().foregroundStyle(Design.ink2)
                            .frame(width: Design.durationWidth, alignment: .trailing)
                    }
                    .frame(height: Design.rowHeight)
                }
            }
        }
        .cardBox()
    }

    private var scoreTrend: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            CardHeading(title: "评分 · 近 30 天",
                        caption: stats.trendStreak >= 2 ? Text("70 以上算好的一天 · 连续 \(stats.trendStreak) 天") : Text("70 以上算好的一天"))
            ScoreTrendCard(trend: stats.scoreTrend, streak: stats.trendStreak, updatedAt: stats.lastHeavyUpdate) { day in
                model.range = DateRangeSelection(kind: .day, anchor: day)
            }
            .frame(height: 220)
        }
        .cardBox()
    }
}
