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
                VStack(alignment: .leading, spacing: 12) {
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
                            DayColumnsView(overview: overview, productivity: productivity, onSelect: onSelect)
                                .padding(.bottom, 4)
                            cards(overview, wide: geometry.size.width >= 760)
                            if geometry.size.width >= 860 {
                                HStack(alignment: .top, spacing: 12) {
                                    pieces(overview).frame(maxWidth: .infinity)
                                    context(overview).frame(width: 316)
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

    /// Four equal cards, two by two when narrow.
    private func cards(_ overview: DayOverview, wide: Bool) -> some View {
        let recorded = card(String(localized: "已记录"), detail: recordedDetail(overview)) { DurationHero(seconds: overview.total, size: 30) }
        let engaged = card(String(localized: "投入"),
                           detail: String(localized: "占已记录 \(Int((overview.engaged / max(1, overview.total) * 100).rounded()))% · 按分类估算")) {
            DurationHero(seconds: overview.engaged, size: 30)
        }
        let focus = card(String(localized: "专注会话"),
                         detail: String(localized: "\(overview.sessions.count) 次，\(overview.sessions.filter(\.completed).count) 次已完成")) {
            DurationHero(seconds: overview.sessionSeconds, size: 30)
        }
        let score = card(String(localized: "评分"), detail: String(localized: "连续 \(dashboard.streakDays) 天 ≥ 70")) {
            let value = dashboard.pulse.map { "\($0)" } ?? "—"
            Text(verbatim: value).font(.system(size: 30, weight: .semibold)).tracking(-0.5).monospacedDigit().refinedNumberMotion(value)
        }
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            if wide {
                GridRow { recorded; engaged; focus; if model.showScore { score } }
            } else {
                GridRow { recorded; engaged }
                GridRow { focus; if model.showScore { score } }
            }
        }
    }

    private func card<Value: View>(_ title: String, detail: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            value()
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2...)
        }
        // Every card in a row takes the tallest one's height, tops aligned.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16).padding(.vertical, 14).workspacePanel()
    }

    private func recordedDetail(_ overview: DayOverview) -> String {
        [overview.firstRecord.map { String(localized: "\(model.time($0)) 开始") },
         dashboard.yesterdayTotal.map { yesterday in
             let delta = Format.minuteDelta(overview.total, yesterday)
             return delta >= 0 ? String(localized: "比昨天此时多 \(Format.chineseDuration(delta))")
                 : String(localized: "比昨天此时少 \(Format.chineseDuration(-delta))")
         }]
            .compactMap { $0 }.joined(separator: " · ")
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
                let event = events.first { !$0.isAllDay && $0.start < piece.end && $0.end > piece.start }
                Image(systemName: event == nil ? "moon" : "person.2").foregroundStyle(.secondary).frame(width: 22)
                ((event.map { Text(verbatim: "\($0.title) · ") } ?? Text(verbatim: "")) + Text("未记录"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.duration(piece.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 48).contentShape(Rectangle())
    }

    private func context(_ overview: DayOverview) -> some View {
        TimeRankingCard(categories: overview.categories,
                        limits: Dictionary(dayModel.budgets.map { ($0.categoryID, TimeInterval($0.dailySeconds)) }) { a, _ in a },
                        warningPercent: model.settings.budgetWarnPercent) {
            model.openActivities(category: $0, range: .today())
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
    private func productivity(_ id: String) -> Int { model.resolver.categoriesByID[id]?.productivity ?? 0 }
    private func categoryColor(_ id: String) -> Color { RefinedStyle.category(id, hex: model.resolver.categoriesByID[id]?.colorHex ?? "#C7C7CC") }
}

struct DayRibbonView: View {
    let overview: DayOverview
    var compact = false
    var events: [CalendarEvent] = []
    var onSelect: ((DayOverview.Piece) -> Void)?
    private var interval: DateInterval { overview.displayInterval }
    @Environment(\.locale) private var locale
    private struct Tick: Identifiable {
        let id: Date
        let text: String
        let width: CGFloat
        let x: CGFloat
        var isNow = false
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
        // The popover's band reads at a glance: 8:00, 11:00, 14:00, 17:00.
        let step: Int = [1, 2, 3, 4, 6].first(where: { (!compact || $0 >= 3) && CGFloat($0) * perHour >= widest * 1.5 + 8 }) ?? 6
        var result: [Tick] = []
        // The right edge gets a label only on the step's grid; an off-grid
        // edge label would crowd out the last even tick.
        let alignedEnd = interval.duration.truncatingRemainder(dividingBy: Double(step) * 3600) == 0
        func tick(_ date: Date) -> Tick {
            let (text, labelWidth) = label(date)
            let x = max(0, min(width - labelWidth, bounds(start: date, end: date, width: width).minX - labelWidth / 2))
            return Tick(id: date, text: text, width: labelWidth, x: x)
        }
        for date in hours(every: step) + (alignedEnd ? [interval.end] : []) {
            let next = tick(date)
            if date == interval.end {
                while let last = result.last, next.x < last.x + last.width + 8 { result.removeLast() }
            }
            if result.last.map({ next.x >= $0.x + $0.width + 8 }) ?? true { result.append(next) }
        }
        // Now's own label wins over any hour label it would touch.
        var now = tick(overview.now)
        now.isNow = true
        return result.filter { $0.x + $0.width + 6 <= now.x || $0.x >= now.x + now.width + 6 } + [now]
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
                    let nowX = bounds(start: overview.now, end: overview.now, width: geometry.size.width).minX
                    ZStack(alignment: .topLeading) {
                        let past = bounds(start: interval.start, end: overview.now, width: geometry.size.width)
                        Rectangle().fill(.quaternary.opacity(0.5)).frame(width: past.width)
                        // The rest of the day is still to come: a faint dashed outline.
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .frame(width: max(0, geometry.size.width - past.width)).offset(x: past.width)
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
                            .help(Self.tooltip(piece, overview: overview, locale: locale))
                            .onTapGesture { if piece.item != nil { onSelect?(piece) } }
                            .accessibilityHidden(true)
                        }
                    }.frame(height: compact ? 12 : 26).clipShape(RoundedRectangle(cornerRadius: 5)).offset(y: compact ? 0 : 20)
                    Rectangle().fill(.primary).frame(width: 1.5, height: compact ? 18 : 32)
                        .offset(x: nowX, y: compact ? -3 : 17)
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
                    Text(tick.text).font(.system(size: 11, weight: tick.isNow ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(tick.isNow ? .primary : .secondary)
                        .fixedSize().frame(width: tick.width)
                        .offset(x: tick.x)
                }

            }.frame(height: 14)
            if !compact {
                HStack(spacing: 14) {
                    Label("专注会话", systemImage: "minus").foregroundStyle(.tint)
                    Label("日程", systemImage: "rectangle")
                    Label("未记录", systemImage: "rectangle.dashed")
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

    static func tooltip(_ piece: DayOverview.Piece, overview: DayOverview, locale: Locale) -> String {
        let time = "\(piece.start.formatted(.dateTime.hour().minute().locale(locale)))–\(piece.end.formatted(.dateTime.hour().minute().locale(locale)))"
        guard let segment = piece.segment else {
            return String(localized: "未记录 · \(time) · \(Format.duration(piece.seconds))")
        }
        let name = overview.categories.first { $0.id == segment.leadingCategoryID }?.name ?? String(localized: "未分类")
        return ([String(localized: "\(name) · \(time) · \(Format.duration(segment.recorded))")]
            + TimelineSegmentText.composition(segment)).joined(separator: "\n")
    }
}

/// Today's hero: a column per stretch, as tall as its category is
/// productive, gaps hatched low, and a marked now.
struct DayColumnsView: View {
    let overview: DayOverview
    let productivity: (String) -> Int
    let onSelect: (DayOverview.Piece) -> Void
    @Environment(\.locale) private var locale
    private var interval: DateInterval { overview.displayInterval }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width, height = geometry.size.height
                let nowX = x(overview.now, width: width)
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(.quaternary).frame(width: max(0, width - nowX), height: 2).offset(x: nowX)
                    ForEach(pieces(width: width)) { piece in
                        let left = x(piece.start, width: width)
                        let columnWidth = max(1, x(piece.end, width: width) - left - 2)
                        column(piece, width: columnWidth)
                            .frame(width: columnWidth, height: columnHeight(piece, chart: height - 26))
                            .offset(x: left)
                            .help(DayRibbonView.tooltip(piece, overview: overview, locale: locale))
                            .onTapGesture { if piece.item != nil { onSelect(piece) } }
                    }
                    RoundedRectangle(cornerRadius: 1.5).fill(.primary)
                        .frame(width: 3, height: height - 20).offset(x: nowX - 1.5, y: 6)
                }
                .frame(width: width, height: height, alignment: .bottomLeading)
                .overlay(alignment: .topLeading) {
                    Text(overview.now, format: .dateTime.hour().minute().locale(locale))
                        .font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.primary, in: RoundedRectangle(cornerRadius: 6))
                        .fixedSize().frame(width: 64).offset(x: min(max(0, nowX - 32), width - 64), y: -6)
                }
            }
            .frame(height: 150)
            GeometryReader { geometry in
                ForEach(hours, id: \.self) { hour in
                    let text = hour.formatted(.dateTime.hour().minute().locale(locale))
                    Text(verbatim: text).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                        .fixedSize().frame(width: 60).offset(x: min(max(0, x(hour, width: geometry.size.width) - 30), geometry.size.width - 60))
                }
            }.frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("时间带，\(interval.start.formatted(.dateTime.hour().minute().locale(locale))) 至 \(interval.end.formatted(.dateTime.hour().minute().locale(locale)))，已记录 \(Format.duration(overview.total))。片段详情见活动列表。")
    }

    @ViewBuilder private func column(_ piece: DayOverview.Piece, width: CGFloat) -> some View {
        let radius = min(9, width / 2)
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: min(4, radius),
                                           bottomTrailingRadius: min(4, radius), topTrailingRadius: radius)
        if let segment = piece.segment {
            let id = segment.leadingCategoryID
            let color = RefinedStyle.category(id, hex: overview.categories.first { $0.id == id }?.colorHex ?? "#C7C7CC")
            shape.fill(color).overlay(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom).clipShape(shape))
                .overlay { if id == "uncategorized" { HatchFill().clipShape(shape) } }
        } else {
            HatchFill().background(.quaternary.opacity(0.4)).clipShape(shape)
        }
    }

    /// Productivity -2...+2 sets the height; a gap stays low.
    private func columnHeight(_ piece: DayOverview.Piece, chart: CGFloat) -> CGFloat {
        guard let segment = piece.segment else { return chart * 0.3 }
        let score = max(-2, min(2, productivity(segment.leadingCategoryID)))
        return chart * (0.45 + CGFloat(score + 2) * 0.1375)
    }

    private var hours: [Date] {
        let calendar = Calendar.current
        let first = calendar.dateInterval(of: .hour, for: interval.start)?.start ?? interval.start
        let span = interval.duration / 3600
        let step = span > 12 ? 3 : 2
        return stride(from: 0, through: Int(span.rounded(.up)), by: step)
            .compactMap { calendar.date(byAdding: .hour, value: $0, to: first) }
            .filter { $0 >= interval.start && $0 <= interval.end }
    }

    private func x(_ date: Date, width: CGFloat) -> CGFloat {
        width * max(0, min(1, date.timeIntervalSince(interval.start) / interval.duration))
    }

    private func pieces(width: CGFloat) -> [DayOverview.Piece] {
        let resolution = TimelineSegmenter.resolution(points: 6, pointsPerHour: width / max(interval.duration / 3600, 1))
        return DayOverview.pieces(overview.items, resolution: resolution, grouping: .category, forDrawing: true)
            .filter { $0.end > interval.start }
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

/// Today's categories ranked by time, bars scaled to the top one; a daily
/// limit is drawn on its category's bar and captioned under it.
struct TimeRankingCard: View {
    let categories: [DayOverview.CategoryTotal]
    let limits: [String: TimeInterval]
    let warningPercent: Int
    let onSelect: (String) -> Void

    var body: some View {
        let scale = max(categories.first?.seconds ?? 0, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("时间去了哪").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(categories.count) 个分类 · 限额在条上").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.bottom, 6)
            ForEach(categories) { category in
                let limit = limits[category.id]
                let status = limit.map { LimitStatus(spent: category.seconds, limit: $0, warningPercent: warningPercent) }
                Button { onSelect(category.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Circle().fill(RefinedStyle.category(category.id, hex: category.colorHex)).frame(width: 7, height: 7)
                            Text(category.name).lineLimit(1).frame(width: 80, alignment: .leading)
                            bar(category, limit: limit, over: status?.isOver ?? false, scale: scale)
                            Text(Format.duration(category.seconds)).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }.frame(minHeight: 24)
                        if let status { caption(status).padding(.leading, 95) }
                    }.font(.system(size: 12)).contentShape(Rectangle())
                }.buttonStyle(.plain).help("\(category.name) · \(Format.duration(category.seconds))")
            }
        }.padding(.horizontal, 18).padding(.vertical, 16).workspacePanel()
    }

    private func bar(_ category: DayOverview.CategoryTotal, limit: TimeInterval?, over: Bool, scale: TimeInterval) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(RefinedStyle.category(category.id, hex: category.colorHex))
                    .overlay { if category.id == "uncategorized" { HatchFill() } }
                    .frame(width: width * category.seconds / scale)
                if let limit {
                    RoundedRectangle(cornerRadius: 1).fill(over ? Color.red : Color.secondary)
                        .frame(width: 2, height: 14)
                        .offset(x: min(width, width * limit / scale) - 1)
                }
            }.frame(height: 8).frame(maxHeight: .infinity)
        }.frame(height: 14)
    }

    @ViewBuilder private func caption(_ status: LimitStatus) -> some View {
        switch status {
        case .over(let minutes):
            Label("超出限额 \(minutes) 分钟", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).fontWeight(.semibold)
        case .near(let minutes):
            Label("离限额还剩 \(minutes) 分钟", systemImage: "gauge.with.dots.needle.67percent")
                .foregroundStyle(RefinedStyle.warning).fontWeight(.semibold)
        case .within(let minutes):
            Text("限额 \(minutes) 分钟").foregroundStyle(.secondary)
        }
    }
}

/// A daily limit as captioned under its category, in whole minutes as shown.
enum LimitStatus: Equatable {
    case over(minutes: Int)
    /// Within `warningPercent` of the limit.
    case near(minutes: Int)
    /// Comfortably under; carries the limit itself.
    case within(minutes: Int)

    init(spent: TimeInterval, limit: TimeInterval, warningPercent: Int) {
        let left = Int(Format.minuteDelta(limit, spent) / 60)
        if left < 0 { self = .over(minutes: -left) }
        else if limit - spent <= limit * Double(warningPercent) / 100 { self = .near(minutes: left) }
        else { self = .within(minutes: Int(limit / 60)) }
    }

    var isOver: Bool { if case .over = self { true } else { false } }
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
