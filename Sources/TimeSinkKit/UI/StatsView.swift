import SwiftUI
import Charts

struct StatsView: View {
    let model: AppModel
    @Bindable var stats: StatsModel
    @State private var granularity: StatsModel.Granularity = .day
    @State private var showsScore = false
    private struct RefreshID: Equatable { let range: DateRangeSelection; let version: Int }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if stats.hasLoaded {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: geometry.size.width >= 650 ? 4 : 2), spacing: 12) {
                                metric(String(localized: "总时长"), Format.duration(stats.total), stats.totalDelta.map { String(localized: "比上期 \(Format.durationDelta($0))") } ?? String(localized: "上期暂无记录"))
                                metric(String(localized: "日均"), Format.duration(stats.avgPerDay), String(localized: "按所选时段已过的天数"))
                                metric(String(localized: "投入"), Format.duration(stats.focus), String(localized: "占 \(Int((stats.focus / max(1, stats.total) * 100).rounded()))% · 按分类估算"))
                                metric(String(localized: "评分"), stats.pulse.map(String.init) ?? "—", String(localized: "连续 \(stats.trendStreak) 天达标"))
                            }
                            if geometry.size.width >= 850 {
                                // Side by side the chart grows to the ranking's height
                                // instead of leaving a blank block under it.
                                HStack(alignment: .top, spacing: 16) {
                                    categoryHistory.frame(maxWidth: .infinity)
                                    ranking.frame(maxWidth: .infinity)
                                }.fixedSize(horizontal: false, vertical: true)
                            } else { categoryHistory; ranking }
                            if let heatmap = stats.heatmapData {
                                HeatmapCard(data: heatmap, interaction: $stats.heatmapInteraction) { model.openHeatmapActivities(in: $0) }.id("heatmap")
                            }
                            appRanking
                            DisclosureGroup("评分与连续记录", isExpanded: $showsScore) {
                                ScoreTrendCard(trend: stats.scoreTrend, streak: stats.trendStreak, updatedAt: stats.lastHeavyUpdate) { day in
                                    model.range = DateRangeSelection(kind: .day, anchor: day)
                                }.frame(height: 240).padding(.top, 12)
                            }.font(.system(size: 13, weight: .semibold)).padding(18).workspacePanel()
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
                    }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 28)
                        .frame(maxWidth: 1500).frame(maxWidth: .infinity)
                }
            }
            .task(id: RefreshID(range: model.range, version: model.dataVersion)) { await stats.recompute(model: model) }
            .task {
                if stats.heatmapInteraction.pinned != nil { await Task.yield(); proxy.scrollTo("heatmap", anchor: .top) }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await stats.recompute(model: model)
                }
            }
        }.background(WorkspaceBackground())
    }
    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 16).workspacePanel()
    }
    private var categoryHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(granularity == .day ? "每天的分类时长" : "每周的分类时长").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("分组", selection: $granularity) { Text("天").tag(StatsModel.Granularity.day); Text("周").tag(StatsModel.Granularity.week) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 90)
            }
            Chart(granularity == .day ? stats.stackedByDay : stats.stackedByWeek) { point in
                BarMark(x: .value("日期", point.bucketStart, unit: granularity == .day ? .day : .weekOfYear), y: .value("小时", point.hours))
                    .foregroundStyle(RefinedStyle.category(point.categoryID, hex: point.colorHex))
                    .accessibilityLabel("\(point.bucketStart.formatted(.dateTime.month().day())) · \(point.categoryName)")
                    .accessibilityValue(Format.duration(point.hours * 3600))
            }
            .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(); AxisValueLabel { if let hours = value.as(Double.self) { Text("\(hours.formatted())h").font(.system(size: 11)) } } } }
            .frame(minHeight: 200, maxHeight: .infinity)
        }.frame(maxHeight: .infinity, alignment: .top).padding(18).workspacePanel()
    }
    private var ranking: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("分类").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.range.label) · 与上期差").font(.system(size: 11)).foregroundStyle(.secondary)
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
            HStack { Text("应用与网站").font(.system(size: 13, weight: .semibold)); Spacer(); Text(model.range.label).font(.system(size: 12)).foregroundStyle(.secondary) }
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
