import SwiftUI
import Charts

struct StatsView: View {
    let model: AppModel
    @Bindable var stats: StatsModel
    @State private var granularity: StatsModel.Granularity = .day
        @State private var showsRadar = false
    private struct RefreshID: Equatable { let range: DateRangeSelection.Window; let version: Int }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.lg) {
                        if stats.hasLoaded {
                            header(width: geometry.size.width)
                            if geometry.size.width >= 850 {
                                // Side by side the chart grows to the ranking's height
                                // instead of leaving a blank block under it.
                                HStack(alignment: .top, spacing: 16) {
                                    categoryHistory.frame(maxWidth: .infinity).revealOnce(index: 2)
                                    ranking.frame(maxWidth: .infinity).revealOnce(index: 3)
                                }.fixedSize(horizontal: false, vertical: true)
                            } else { categoryHistory; ranking }
                            // The radar summary sits beside the heatmap, as the design
                            // draws it; the full radar opens in a sheet.
                            let radar = InterruptionRadarCard(model: model) { showsRadar = true }
                            if let heatmap = stats.heatmapData {
                                let heatmapCard = HeatmapCard(data: heatmap, interaction: $stats.heatmapInteraction) { model.openHeatmapActivities(in: $0) }.id("heatmap")
                                if geometry.size.width >= 1000 {
                                    HStack(alignment: .top, spacing: 16) {
                                        heatmapCard.frame(maxWidth: .infinity)
                                        radar.frame(width: 300)
                                    }.fixedSize(horizontal: false, vertical: true)
                                } else { heatmapCard; radar }
                            } else { radar }
                            appRanking.revealOnce(index: 4)
                            VStack(alignment: .leading, spacing: 12) {
                                CardHeading(title: "评分与连续记录", caption: Text("70 以上算好的一天"))
                                ScoreTrendCard(trend: stats.scoreTrend, streak: stats.trendStreak, updatedAt: stats.lastHeavyUpdate) { day in
                                    model.range = DateRangeSelection(kind: .day, anchor: day)
                                }.frame(height: 240)
                            }.padding(18).workspacePanel().revealOnce(index: 5)
                        } else if stats.loadError == nil {
                            VStack(spacing: 16) {
                                Text("正在读取趋势…").foregroundStyle(.secondary)
                                ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(height: 120) }
                            }.accessibilityLabel("正在读取趋势")
                        }
                        if let error = stats.loadError {
                            Text(error).foregroundStyle(.secondary)
                            Button("重试") { Task { await stats.recompute(model: model) } }
                        }
                    }.padding(.horizontal, Design.Space.page).padding(.top, 8).padding(.bottom, 24)
                        .frame(maxWidth: 1600).frame(maxWidth: .infinity)
                }
            }
            .pageTask(id: RefreshID(range: model.range.window, version: model.dataVersion)) { await stats.recompute(model: model) }
            .whilePageShown {
                if stats.heatmapInteraction.pinned != nil { await Task.yield(); proxy.scrollTo("heatmap", anchor: .top) }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await stats.recompute(model: model)
                }
            }
        }.background(WorkspaceBackground())
        .sheet(isPresented: $showsRadar) {
            VStack(alignment: .trailing, spacing: 12) {
                InterruptionRadarCard(model: model)
                Button("完成") { showsRadar = false }.keyboardShortcut(.defaultAction)
            }.padding(20).frame(minWidth: 820).background(WorkspaceBackground())
        }
    }
    private func header(width: CGFloat) -> some View {
        let range = stats.shownRange ?? model.range
        let time = Text(TodayFmt.long(stats.total)).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
        let sentence: Text
        if stats.total < 60 {
            sentence = Text("这段时间还没有记录。")
        } else if let delta = stats.totalDelta, abs(delta) >= 60 {
            let amount = Format.chineseDuration(abs(delta))
            sentence = delta > 0 ? Text("共记录 \(time)，比上期多了 \(amount)。") : Text("共记录 \(time)，比上期少了 \(amount)。")
        } else {
            sentence = Text("共记录 \(time)，日均 \(Format.chineseDuration(stats.avgPerDay))。")
        }
        let share = Int((stats.focus / max(1, stats.total) * 100).rounded())
        return PageHeaderRow(lead: Text(verbatim: range.label), sentence: sentence, stats: [
            StripStat(id: 0, label: "总时长", value: TodayFmt.clock(stats.total),
                      note: stats.totalDelta.map { String(localized: "比上期 \(Format.durationDelta($0))") } ?? String(localized: "上期暂无记录")),
            StripStat(id: 1, label: "日均", value: TodayFmt.clock(stats.avgPerDay), note: String(localized: "按所选时段已过的天数")),
            StripStat(id: 2, label: "投入", value: TodayFmt.clock(stats.focus), note: String(localized: "占 \(share)% · 按分类估算"), color: Design.accentInk),
            StripStat(id: 3, label: "评分", value: stats.pulse.map(String.init) ?? "—", note: String(localized: "连续 \(stats.trendStreak) 天达标"))
        ], width: width)
    }
    private var categoryHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if granularity == .day { CardHeading(title: "每天的分类时长") } else { CardHeading(title: "每周的分类时长") }
                Spacer()
                Picker("分组", selection: $granularity) { Text("天").tag(StatsModel.Granularity.day); Text("周").tag(StatsModel.Granularity.week) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 90)
            }
            Group { if granularity == .day {
                historyChart(stats.stackedByDay, unit: .day, scale: stats.dayHourScale)
                    .chartXScale(domain: (stats.days.first ?? .now)...(stats.days.last?.addingTimeInterval(86400) ?? .now))
                    .chartXAxis {
                        AxisMarks(values: stats.dayMarks.map(\.midday)) { value in
                            AxisValueLabel(collisionResolution: .disabled) {
                                if let date = value.as(Date.self), let mark = stats.dayMarks.first(where: { $0.midday == date }) {
                                    Text(mark.label).font(.system(size: 11, weight: mark.isToday ? .bold : .regular))
                                        .foregroundStyle(mark.isToday ? .primary : .secondary)
                                }
                            }
                        }
                    }
            } else {
                historyChart(stats.stackedByWeek, unit: .weekOfYear, scale: stats.weekHourScale)
            } }
            .frame(minHeight: 200, maxHeight: .infinity)
        }.frame(maxHeight: .infinity, alignment: .top).padding(18).workspacePanel()
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
                AxisGridLine(); AxisValueLabel { if let hours = value.as(Double.self) { Text("\(hours.formatted())h").font(.system(size: 11)) } }
            }
        }
    }
    private var ranking: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeading(title: "分类")
                Spacer()
                Text("\((stats.shownRange ?? model.range).label) · 与上期差").font(.system(size: 11)).foregroundStyle(Design.ink3)
            }
            if stats.categoryRows.isEmpty { Text("这段时间还没有记录。").font(.system(size: 12)).foregroundStyle(.secondary) }
            let nameWidth = RefinedStyle.nameColumn(stats.categoryRows.map(\.name), font: .systemFont(ofSize: 12), cap: 140)
            ForEach(stats.categoryRows) { row in
                Button { model.openActivities(category: row.id, range: model.range) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(RefinedStyle.category(row.id, hex: row.colorHex)).frame(width: 8, height: 8)
                        Text(row.name).frame(width: nameWidth, alignment: .leading).lineLimit(1)
                        GeometryReader { geo in
                            Capsule().fill(.quaternary)
                            Capsule().fill(RefinedStyle.category(row.id, hex: row.colorHex))
                                .frame(width: geo.size.width * row.seconds / max(1, stats.categoryRows.first?.seconds ?? 1))
                        }.frame(height: 5)
                        Text(Format.duration(row.seconds)).monospacedDigit().frame(width: 58, alignment: .trailing)
                        Text(stats.categoryDeltas[row.id].map(Format.durationDelta) ?? "—").monospacedDigit().foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
                    }.font(.system(size: 12)).frame(height: 26).contentShape(Rectangle())
                }.buttonStyle(RefinedRowButtonStyle())
            }
        }.frame(maxWidth: .infinity, minHeight: 235, maxHeight: .infinity, alignment: .topLeading).padding(18).workspacePanel()
    }
    private var appRanking: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { CardHeading(title: "应用与网站"); Spacer(); Text((stats.shownRange ?? model.range).label).font(.system(size: 12)).foregroundStyle(Design.ink3) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 28)], spacing: 4) {
                ForEach(stats.appRows) { row in
                    HStack(spacing: 10) {
                        ActivityIcon(bundleID: row.id, domain: row.isDomain ? row.id : nil)
                        Text(row.name).font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(.quaternary)
                            Capsule().fill(RefinedStyle.category(row.categoryID ?? "", hex: row.colorHex)).frame(width: geo.size.width * row.seconds / max(1, stats.appRows.first?.seconds ?? 1))
                        }.frame(width: 90, height: 5)
                        Text(Format.duration(row.seconds)).font(.system(size: 12)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }.frame(height: 32)
                }
            }
        }.padding(18).workspacePanel()
    }
}
