import SwiftUI
import AppKit

struct TodayView: View {
    let model: AppModel
    @Bindable var dayModel: DayOverviewModel
    let activities: ActivitiesModel
    @State private var dashboard = TodayDashboardModel()
    @State private var visiblePieces = 9
    @State private var events: [CalendarEvent] = []
    /// Moves at midnight, so the day's calendar events are fetched again.
    @State private var day = Calendar.current.startOfDay(for: Date())
    private struct EventsKey: Equatable { let enabled: Bool; let day: Date; let calendars: Int }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let overview = dayModel.overview {
                        if overview.total == 0 {
                            ContentUnavailableView {
                                Label("今天，还没有记录", systemImage: "sun.max")
                            } description: {
                                Text(model.trackingPaused ? "记录已暂停。继续后，新的活动会出现在这里。" : "使用 Mac 后，应用和网站活动会出现在这里。空档不会计入总时长。")
                            } actions: {
                                if model.trackingPaused { Button("继续记录") { model.resumeTracking() } }
                                else { SettingsLink { Text("检查记录与权限设置") } }
                            }.frame(minHeight: 350)
                        } else {
                            summary(overview)
                            if geometry.size.width >= 860 {
                                HStack(alignment: .top, spacing: 16) {
                                    pieces(overview).frame(maxWidth: .infinity)
                                    context(overview).frame(width: 300)
                                }
                            } else {
                                pieces(overview)
                                context(overview)
                            }
                        }
                    } else if dayModel.loadError == nil {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("正在读取今天的记录").foregroundStyle(.secondary)
                            ForEach(0..<5) { _ in RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 40) }
                        }.accessibilityLabel("正在读取今天的记录")
                    }
                    if let error = dayModel.loadError {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle")
                            Button("重试") { Task { await refresh() } }
                        }.font(.callout)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 28)
                .frame(maxWidth: 1500).frame(maxWidth: .infinity)
            }
        }
        .background(WorkspaceBackground())
        .pageTask(id: model.dataVersion) { await refresh() }
        .task(id: EventsKey(enabled: model.calendarOverlayEnabled, day: day, calendars: model.calendarVersion)) {
            events = model.calendarOverlayEnabled ? await model.calendarStore?.events(on: day) ?? [] : []
        }
        .whilePageShown {
            // Keeps the ribbon's now line moving while nothing is written; the
            // headline numbers only move with data or at midnight.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                let today = Calendar.current.startOfDay(for: Date())
                if today != day { day = today; await refresh() } else { await dayModel.refresh(model: model) }
            }
        }
    }

    private func onSelect(_ piece: DayOverview.Piece) {
        guard let item = piece.item else { return }
        model.activitySearch = ""
        model.openActivities(category: nil, range: .today())
        activities.recompute(model: model, events: [])
        activities.select(ActivitiesModel.selection(for: item), start: item.span.start)
    }

    private func refresh() async {
        await dayModel.refresh(model: model)
        await dashboard.recompute(model: model, forceStreak: false, headlineOnly: true)
    }

    private func summary(_ overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    recorded(overview, fixed: true)
                    engaged(overview, divided: true, fixed: true)
                    sessions(overview, divided: true, fixed: true)
                    if model.showScore { score(fixed: true) }
                }
                // Two by two when narrow: captions wrap instead of running
                // into the next column, and each column starts at one edge.
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow { recorded(overview, fixed: false); engaged(overview, divided: true, fixed: false) }
                    GridRow {
                        sessions(overview, divided: false, fixed: false)
                        if model.showScore { score(fixed: false) }
                    }
                }
            }
            DayRibbonView(overview: overview, events: events, onSelect: onSelect)
        }
        .padding(18).workspacePanel()
    }

    private func recorded(_ overview: DayOverview, fixed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("已记录").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(Format.duration(overview.total)).font(.system(size: 34, weight: .semibold))
                .tracking(-0.68).monospacedDigit().refinedNumberMotion(Format.duration(overview.total))
            Text([overview.firstRecord.map { String(localized: "\(model.time($0)) 开始") },
                  dashboard.totalDelta.map { String(localized: "比昨天同时段 \(Format.durationDelta($0))") }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.fixedSize(horizontal: fixed, vertical: !fixed)
    }

    private func engaged(_ overview: DayOverview, divided: Bool, fixed: Bool) -> some View {
        metric(String(localized: "投入"), value: Format.duration(overview.engaged),
               detail: String(localized: "占已记录 \(Int((overview.engaged / max(1, overview.total) * 100).rounded()))% · 按分类估算"),
               divided: divided, fixed: fixed)
    }

    private func sessions(_ overview: DayOverview, divided: Bool, fixed: Bool) -> some View {
        metric(String(localized: "专注会话"), value: Format.duration(overview.sessionSeconds),
               detail: String(localized: "\(overview.sessions.count) 次，\(overview.sessions.filter(\.completed).count) 次已完成"),
               divided: divided, fixed: fixed)
    }

    private func score(fixed: Bool) -> some View {
        metric(String(localized: "评分"), value: dashboard.pulse.map { "\($0)" } ?? "—", detail: String(localized: "连续 \(dashboard.streakDays) 天 ≥ 70"),
               suffix: "/ 100", divided: true, fixed: fixed)
    }

    private func metric(_ title: String, value: String, detail: String, suffix: String = "", divided: Bool, fixed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().refinedNumberMotion(value)
                if !suffix.isEmpty { Text(suffix).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.leading, divided ? 18 : 0)
        .overlay(alignment: .leading) { if divided { Rectangle().fill(.quaternary).frame(width: 0.5) } }
        .fixedSize(horizontal: fixed, vertical: !fixed)
    }

    private func pieces(_ overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("一天的片段").font(.system(size: 13, weight: .semibold))
                Text("最近的在前 · 点按在活动中查看").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button("全部活动") { openActivities() }.buttonStyle(.link).font(.system(size: 12))
            }.padding(14)
            let recent = Array(overview.pieces.reversed())
            ForEach(recent.prefix(visiblePieces)) { piece in
                Divider().opacity(0.6)
                if piece.item != nil {
                    Button { onSelect(piece) } label: { pieceRow(piece, overview: overview) }
                        .buttonStyle(RefinedRowButtonStyle()).help("在活动中查看此片段")
                } else { pieceRow(piece, overview: overview).background { HatchFill().opacity(0.35) } }
            }
            if recent.count > visiblePieces {
                Divider()
                Button {
                    withAnimation(RefinedStyle.motion(reduced: reduceMotion)) { visiblePieces += 20 }
                } label: {
                    HStack {
                        Image(systemName: "chevron.down").font(.system(size: 11))
                        Text("更早的 \(recent.count - visiblePieces) 段")
                        if let first = overview.firstRecord { Text("· \(model.time(first)) 起") }
                        Spacer()
                    }.font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                }.buttonStyle(RefinedRowButtonStyle())
            }
        }.workspacePanel().clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func pieceRow(_ piece: DayOverview.Piece, overview: DayOverview) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(piece.start, format: .dateTime.hour().minute())
                Text(piece.end, format: .dateTime.hour().minute()).foregroundStyle(.tertiary)
            }.font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            if let segment = piece.segment, let item = piece.item {
                ActivityIcon(bundleID: segment.dominant.appBundleID, domain: item.span.domain)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(segment.dominant.label).font(.system(size: 13)).lineLimit(1)
                        if let session = overview.sessions.first(where: { $0.start < piece.end && $0.end > piece.start }) {
                            Label("专注 \(session.plannedSeconds / 60) 分钟", systemImage: "scope")
                                .font(.system(size: 11)).foregroundStyle(.tint).lineLimit(1)
                        }
                    }
                    Text(pieceDetail(segment, item: item))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if segment.isMixed { CompositionBar(segment: segment) { categoryColor($0) }.frame(height: 3) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                CategoryChip(category: model.resolver.categoriesByID[segment.leadingCategoryID])
                Text(Format.duration(piece.seconds)).font(.system(size: 13)).monospacedDigit().frame(minWidth: 45, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Image(systemName: "moon").foregroundStyle(.secondary).frame(width: 22)
                Text("未记录").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.duration(piece.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 48).contentShape(Rectangle())
    }

    private func context(_ overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("时间的去向").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(overview.categories.count) 个分类").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                CategoryVesselView(overview: overview) { model.openActivities(category: $0, range: .today()) }
                Text("刻度：小时 · 容器按 \(Int(overview.vesselHours)) 小时绘制").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 16).workspacePanel()
            if !dayModel.budgets.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("今日限额").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("编辑") { model.sidebarSelection = .focus }.buttonStyle(.link).font(.system(size: 12))
                    }
                    ForEach(dayModel.budgets, id: \.categoryID) { budget in
                        let used = overview.categories.first { $0.id == budget.categoryID }?.seconds ?? 0
                        RefinedBudgetRow(name: categoryName(budget.categoryID), color: categoryColor(budget.categoryID),
                            spent: used, limit: Double(budget.dailySeconds), warningPercent: model.settings.budgetWarnPercent)
                    }
                    Text("限额只提醒，不会拦截。").font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 18).padding(.vertical, 16).workspacePanel()
            }
            if let unclassified = overview.categories.first(where: { $0.id == "uncategorized" }) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "tag").foregroundStyle(RefinedStyle.warning)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("今天还有活动没分类").font(.system(size: 13, weight: .semibold))
                        Text("共 \(Format.duration(unclassified.seconds))。分好以后，以后自动归类。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("去分类") { model.sidebarSelection = .organization }.controlSize(.small)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).workspacePanel()
            }
        }
    }

    /// What else happened in the stretch; a single-row stretch shows its
    /// longest title instead.
    private func pieceDetail(_ segment: TimelineSegment, item: CategorizedSpan) -> String {
        guard segment.parts.count > 1 else {
            return item.span.title ?? categoryName(item.categoryID)
        }
        let others = segment.parts.dropFirst().prefix(2).map { "\($0.label) \(Format.duration($0.seconds))" }
        let rest = segment.parts.count - 1 - others.count
        return String(localized: "另有 \(others.joined(separator: String(localized: "、")))") + (rest > 0 ? String(localized: " 等 \(rest + others.count) 项") : "")
            + String(localized: " · 切换 \(segment.switches) 次")
    }

    private func openActivities() { model.activitySearch = ""; model.openActivities(category: nil, range: .today()) }
    private func categoryName(_ id: String) -> String { model.resolver.categoriesByID[id]?.name ?? String(localized: "未分类") }
    private func categoryColor(_ id: String) -> Color { RefinedStyle.category(id, hex: model.resolver.categoriesByID[id]?.colorHex ?? "#C7C7CC") }
}

struct DayRibbonView: View {
    let overview: DayOverview
    var compact = false
    var events: [CalendarEvent] = []
    var onSelect: ((DayOverview.Piece) -> Void)?
    private var interval: DateInterval {
        let end = Calendar.current.date(bySettingHour: compact ? 18 : 20, minute: 0, second: 0, of: overview.now) ?? overview.displayInterval.end
        return DateInterval(start: overview.displayInterval.start, end: max(end, overview.displayInterval.end))
    }
    @Environment(\.locale) private var locale
    private struct Tick: Identifiable {
        let id: Date
        let text: String
        let width: CGFloat
        let x: CGFloat
    }
    private func ticks(width: CGFloat) -> [Tick] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func label(_ date: Date) -> (text: String, width: CGFloat) {
            let text = date.formatted(.dateTime.hour().minute().locale(locale))
            return (text, min(width, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2))
        }
        func hours(every step: Int) -> [Date] {
            var result: [Date] = []
            var time = interval.start
            while time < interval.end {
                result.append(time)
                guard let next = Calendar.current.date(byAdding: .hour, value: step, to: time) else { break }
                time = next
            }
            return result
        }
        // One even step that fits every label, edge-pinned ones included,
        // rather than hourly labels with gaps where collisions dropped some.
        let widest = hours(every: 1).map { label($0).width }.max() ?? 0
        let perHour = width / max(1, interval.duration / 3600)
        let step: Int = [1, 2, 3, 4, 6].first(where: { CGFloat($0) * perHour >= widest * 1.5 + 8 }) ?? 6
        var result: [Tick] = []
        // The right edge gets a label only on the step's grid; an off-grid
        // edge label would crowd out the last even tick.
        let alignedEnd = interval.duration.truncatingRemainder(dividingBy: Double(step) * 3600) == 0
        for date in hours(every: step) + (alignedEnd ? [interval.end] : []) {
            let (text, labelWidth) = label(date)
            let x = max(0, min(width - labelWidth, bounds(start: date, end: date, width: width).minX - labelWidth / 2))
            if date == interval.end {
                while let last = result.last, x < last.x + last.width + 8 { result.removeLast() }
            }
            if result.last.map({ x >= $0.x + $0.width + 8 }) ?? true {
                result.append(Tick(id: date, text: text, width: labelWidth, x: x))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if !compact {
                        ForEach(events.filter { !$0.isAllDay }) { event in
                            let rect = bounds(start: event.start, end: event.end, width: geometry.size.width)
                            Text(event.title).font(.system(size: 11)).lineLimit(1).padding(.horizontal, 4)
                                .frame(width: rect.width, height: 16, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                .offset(x: rect.minX).help(event.title)
                        }
                    }
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5))
                        ForEach(ribbonPieces(width: geometry.size.width)) { piece in
                            let rect = bounds(start: piece.start, end: piece.end, width: geometry.size.width)
                            Group {
                                if let segment = piece.segment {
                                    let categoryID = segment.leadingCategoryID
                                    Rectangle().fill(RefinedStyle.category(categoryID, hex: categoryHex(categoryID)))
                                        .overlay { if categoryID == "uncategorized" { HatchFill() } }
                                } else { HatchFill() }
                            }
                            .frame(width: rect.width)
                            .offset(x: rect.minX)
                            .help(tooltip(piece))
                            .onTapGesture { if piece.item != nil { onSelect?(piece) } }
                            .accessibilityHidden(true)
                        }
                    }.frame(height: compact ? 12 : 26).clipShape(RoundedRectangle(cornerRadius: 5)).offset(y: compact ? 0 : 20)
                    Rectangle().fill(.primary).frame(width: 1.5, height: compact ? 18 : 32)
                        .offset(x: bounds(start: overview.now, end: overview.now, width: geometry.size.width).minX, y: compact ? -3 : 17)
                    if !compact {
                        ForEach(Array(overview.sessions.enumerated()), id: \.offset) { _, session in
                            let rect = bounds(start: session.start, end: session.end, width: geometry.size.width)
                            Capsule().fill(.tint).frame(width: rect.width, height: 3).offset(x: rect.minX, y: 50)
                        }
                    }
                }
            }.frame(height: compact ? 12 : 54)
            GeometryReader { geometry in
                ForEach(ticks(width: geometry.size.width)) { tick in
                    Text(tick.text).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize().frame(width: tick.width)
                        .offset(x: tick.x)
                }

            }.frame(height: 14)
            if !compact {
                HStack(spacing: 14) {
                    Label("专注会话", systemImage: "minus").foregroundStyle(.tint)
                    Label("日程", systemImage: "rectangle")
                    Label("未记录", systemImage: "rectangle.dashed")
                    Text("现在 \(overview.now.formatted(.dateTime.hour().minute().locale(locale)))")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("时间带，\(interval.start.formatted(.dateTime.hour().minute().locale(locale))) 至 \(interval.end.formatted(.dateTime.hour().minute().locale(locale)))，已记录 \(Format.duration(overview.total))。片段详情见活动列表。")
    }

    private func bounds(start: Date, end: Date, width: CGFloat) -> CGRect {
        let left = max(0, min(1, start.timeIntervalSince(interval.start) / interval.duration))
        let right = max(left, min(1, end.timeIntervalSince(interval.start) / interval.duration))
        return CGRect(x: width * left, y: 0, width: width * (right - left), height: 26)
    }

    /// Folded at the band's own scale: nothing narrower than a few points,
    /// so a day of window switching reads as stretches, not stripes.
    private func ribbonPieces(width: CGFloat) -> [DayOverview.Piece] {
        let hours = max(interval.duration / 3600, 1)
        let resolution = TimelineSegmenter.resolution(points: compact ? 3 : 4, pointsPerHour: width / hours)
        return DayOverview.pieces(overview.items, resolution: resolution, grouping: .category, forDrawing: true)
    }

    private func categoryHex(_ id: String) -> String {
        overview.categories.first { $0.id == id }?.colorHex ?? "#C7C7CC"
    }

    private func tooltip(_ piece: DayOverview.Piece) -> String {
        let time = "\(piece.start.formatted(.dateTime.hour().minute().locale(locale)))–\(piece.end.formatted(.dateTime.hour().minute().locale(locale)))"
        guard let segment = piece.segment else {
            return String(localized: "未记录 · \(time) · \(Format.duration(piece.seconds))")
        }
        let name = overview.categories.first { $0.id == segment.leadingCategoryID }?.name ?? String(localized: "未分类")
        return ([String(localized: "\(name) · \(time) · \(Format.duration(segment.recorded))")]
            + TimelineSegmentText.composition(segment)).joined(separator: "\n")
    }
}

/// A folded segment's mix as one proportional bar, a colour per category.
struct CompositionBar: View {
    let segment: TimelineSegment
    var axis: Axis = .horizontal
    let color: (String) -> Color

    private var shares: [(id: String, seconds: TimeInterval)] {
        var seconds: [String: TimeInterval] = [:]
        for part in segment.parts { seconds[part.categoryID, default: 0] += part.seconds }
        return seconds.map { ($0.key, $0.value) }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    }

    var body: some View {
        GeometryReader { geometry in
            let length = axis == .horizontal ? geometry.size.width : geometry.size.height
            let total = max(1, segment.recorded)
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(VStackLayout(spacing: 1))
            layout {
                ForEach(shares, id: \.id) { share in
                    let size = max(1, (length - CGFloat(shares.count - 1)) * share.seconds / total)
                    Rectangle().fill(color(share.id))
                        .frame(width: axis == .horizontal ? size : nil, height: axis == .vertical ? size : nil)
                }
            }
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Shared wording for a folded segment's contents.
enum TimelineSegmentText {
    /// Up to `limit` rows by time, then what was left out and how choppy it was.
    static func composition(_ segment: TimelineSegment, limit: Int = 4) -> [String] {
        var lines = segment.parts.prefix(limit).map { "\($0.label) \(Format.duration($0.seconds))" }
        if segment.parts.count > limit {
            let rest = segment.parts.dropFirst(limit)
            lines.append(String(localized: "另有 \(rest.count) 项 · \(Format.duration(rest.reduce(0) { $0 + $1.seconds }))"))
        }
        if segment.switches > 0 {
            lines.append(String(localized: "\(segment.spanCount) 条记录 · 切换 \(segment.switches) 次"))
        }
        return lines
    }
}

struct CategoryVesselView: View {
    let overview: DayOverview
    let onSelect: (String) -> Void
    @State private var hovered: String?
    private let height: CGFloat = 230
    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach((0...5).reversed(), id: \.self) { tick in
                    Text((overview.vesselHours * Double(tick) / 5).formatted(.number.precision(.fractionLength(0...1))))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    if tick > 0 { Spacer(minLength: 0) }
                }
            }.frame(width: 18, height: height)
            ZStack(alignment: .bottom) {
                Rectangle().fill(.quaternary.opacity(0.5))
                VStack(spacing: 0) {
                    ForEach(overview.categories.reversed()) { category in
                        Rectangle().fill(RefinedStyle.category(category.id, hex: category.colorHex))
                            .opacity(hovered == nil || hovered == category.id ? 1 : 0.4)
                            .overlay { if category.id == "uncategorized" { HatchFill() } }
                            .frame(height: height * category.seconds / (overview.vesselHours * 3600))
                            .onHover { hovered = $0 ? category.id : nil }
                            .onTapGesture { onSelect(category.id) }
                            .help("\(category.name) · \(Format.duration(category.seconds))")
                    }
                }
                ForEach(1..<10) { line in
                    Rectangle().fill(.primary.opacity(line.isMultiple(of: 2) ? 0.2 : 0.1))
                        .frame(height: 0.5).offset(y: -height * CGFloat(line) / 10)
                }.allowsHitTesting(false)
            }
            .frame(width: 58, height: height)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24))
            .accessibilityLabel("已记录 \(Format.duration(overview.total))，刻度 \(Int(overview.vesselHours)) 小时")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(overview.categories) { category in
                    Button { onSelect(category.id) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(RefinedStyle.category(category.id, hex: category.colorHex)).frame(width: 7, height: 7)
                            // Long names wrap; the column is sized for Chinese.
                            Text(category.name).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 2)
                            Text(Format.duration(category.seconds)).monospacedDigit().fixedSize()
                        }.font(.system(size: 12)).frame(minHeight: 24).padding(.horizontal, 3)
                            .background(hovered == category.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).onHover { hovered = $0 ? category.id : nil }
                }
            }.frame(maxWidth: .infinity)
        }
    }
}

struct RefinedRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RefinedRowButtonBody(configuration: configuration)
    }
    private struct RefinedRowButtonBody: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label.background(Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.05 : 0))
                .onHover { hovered = $0 }
        }
    }
}

struct RefinedBudgetRow: View {
    let name: String
    let color: Color
    let spent: TimeInterval
    let limit: TimeInterval
    var warningPercent = 20
    private var warning: Bool { limit - spent <= limit * Double(warningPercent) / 100 }
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(name)
                Spacer()
                Text(RefinedStyle.remaining(spent: spent, limit: limit)).monospacedDigit()
                    .foregroundStyle(warning ? RefinedStyle.warning : .secondary)
            }.font(.system(size: 12))
            GeometryReader { geometry in
                Capsule().fill(.quaternary)
                Capsule().fill(warning ? RefinedStyle.warning : color)
                    .frame(width: geometry.size.width * min(1, max(0, spent / max(1, limit))))
            }.frame(height: 5)
        }.accessibilityElement(children: .combine)
    }
}

struct RecordingStatusView: View {
    let model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let running = model.engine.isRunning
            let suspended = model.engine.isSuspended
            let recording = running && !suspended && !model.trackingPaused && model.engine.currentActivity != nil
            Label {
                Text(!model.accessibilityGranted ? "未记录 · 需要权限" : model.trackingPaused ? "已暂停" : !running ? "记录未启动" : suspended ? "离开电脑" : recording ? "正在记录" : "等待活动")
            } icon: {
                Circle().fill(model.trackingPaused ? RefinedStyle.warning : recording ? Color.green : Color.secondary).frame(width: 7, height: 7)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
