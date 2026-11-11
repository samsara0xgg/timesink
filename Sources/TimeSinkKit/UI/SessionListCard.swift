import SwiftUI

/// 会话: the day's sessions in order, away stretches between them (with 补记),
/// and project chips. A session can be joined onto the one before it: the
/// two fuse, and a toast offers 撤销.
struct SessionListCard<Switch: View>: View {
    let model: AppModel
    @Bindable var activities: ActivitiesModel
    var onSelect: () -> Void = {}
    @ViewBuilder var modeSwitch: Switch
    @State private var filter: String?
    @State private var filling: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sessions: [WorkSession] { activities.sessions }
    private var projects: [(name: String, count: Int)] {
        Dictionary(grouping: sessions.compactMap { model.sessionProject($0) }, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            HStack(alignment: .center, spacing: Design.Space.md) {
                CardHeading(title: "会话", caption: Text("\(sessions.count) 段 · 按时间"))
                Spacer(minLength: Design.Space.sm)
                if projects.count > 1 { chips }
                modeSwitch
            }
            if sessions.isEmpty && activities.sessionsLoaded {
                Text("这一天还没有会话。").foregroundStyle(Design.ink2).frame(maxWidth: .infinity, minHeight: 80)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if filter == nil || model.sessionProject(session) == filter {
                            if filter == nil, index > 0, let gap = awayBefore(index) { away(gap) }
                            row(session, index: index)
                                .transition(.opacity)
                        }
                    }
                }
                .animation(Design.motion(Design.layout, reduced: reduceMotion), value: sessions.map(\.id))
                .padding(.bottom, Design.Space.lg)
            }
            .scrollIndicators(.never)
            .cardList()
        }
        .padding([.horizontal, .top], Design.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                chip(nil, label: Text("全部"), count: sessions.count)
                ForEach(projects, id: \.name) { chip($0.name, label: Text(verbatim: $0.name), count: $0.count) }
            }
        }.scrollIndicators(.never).frame(maxWidth: 360)
    }

    private func chip(_ name: String?, label: Text, count: Int) -> some View {
        SegmentButton(selected: filter == name, height: 24) {
            withAnimation(Design.motion(Design.layout, reduced: reduceMotion)) { filter = name }
        } label: {
            HStack(spacing: 5) { label; Text("\(count)").font(.note).monospacedDigit().foregroundStyle(Design.ink2) }
        }
    }

    private func awayBefore(_ index: Int) -> DateInterval? {
        let start = sessions[index - 1].end, end = sessions[index].start
        return end.timeIntervalSince(start) >= 60 ? DateInterval(start: start, end: end) : nil
    }

    private func away(_ gap: DateInterval) -> some View {
        HStack(spacing: Design.Space.md) {
            RoundedRectangle(cornerRadius: 1.5).fill(Design.track).frame(width: 3, height: 16)
            Text("\(model.time(gap.start))–\(model.time(gap.end))").monospacedDigit().frame(width: 96, alignment: .leading)
            Text("离开 \(Format.chineseDuration(gap.duration))")
            Spacer(minLength: 0)
            if gap.duration >= 60 {
                Button("补记") { filling = gap.start }
                    .buttonStyle(PillButtonStyle(height: 22, font: .note))
                    .popover(isPresented: Binding(get: { filling == gap.start }, set: { if !$0 { filling = nil } }), arrowEdge: .bottom) {
                        AwayPrompt(model: model, interval: gap, manual: true) { filling = nil }.frame(width: 316).padding(4)
                    }
            }
        }
        .font(.note).foregroundStyle(Design.ink2)
        .padding(.horizontal, Design.Space.sm).frame(height: 30)
    }

    private func row(_ session: WorkSession, index: Int) -> some View {
        let selected = activities.selectedSession == session.start
        let color = RefinedStyle.category(session.categoryID, hex: model.resolver.categoriesByID[session.categoryID]?.colorHex ?? "#8E8E93")
        let apps = session.apps.prefix(2).map(\.name).joined(separator: String(localized: "、"))
        return VStack(spacing: 0) {
            Button {
                activities.selectedActivity = nil; activities.selectedStart = nil
                activities.selectedSession = selected ? nil : session.start
                if !selected { onSelect() }
            } label: {
                HStack(spacing: Design.Space.md) {
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 30)
                    Text("\(model.time(session.start))–\(model.time(session.end))").monospacedDigit().foregroundStyle(Design.ink2).frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.sessionTitle(session) ?? apps).fontWeight(.semibold).foregroundStyle(Design.ink).lineLimit(1)
                        if let sub = model.sessionProject(session) ?? (model.sessionTitle(session) != nil ? apps : nil) {
                            Text(sub).font(.note).foregroundStyle(Design.ink2).lineLimit(1)
                        }
                    }
                    Spacer(minLength: Design.Space.sm)
                    if let breaks = activities.dayInterruptions.map({ SessionKPIs.interruptions(in: session, episodes: $0.episodes) }), breaks > 0 {
                        // Whole or not at all: a narrow list keeps the title, not half a count.
                        ViewThatFits(in: .horizontal) {
                            Text("打断 \(breaks)").font(.note).foregroundStyle(Design.ink2).fixedSize()
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                    Text(Format.duration(session.recorded)).monospacedDigit().foregroundStyle(Design.ink2)
                        .frame(minWidth: 52, alignment: .trailing)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
                .padding(.horizontal, Design.Space.sm).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(selected ? Design.selectedFill : .clear))
                .contentShape(Rectangle())
            }.buttonStyle(HoverRowStyle())
            if selected && index > 0 {
                HStack {
                    Spacer()
                    Button { withAnimation(Design.motion(Design.layout, reduced: reduceMotion)) { activities.join(session, model: model) } } label: {
                        Label("并入上一段", systemImage: "arrow.up.to.line")
                    }.buttonStyle(PillButtonStyle(height: 24, font: .note))
                }.padding(.horizontal, Design.Space.sm).padding(.bottom, Design.Space.sm)
                .transition(.opacity)
            }
        }
    }
}

/// The day at a glance: a row of session lines over what every five minutes were made of, as one column
/// per slot (构成) or a row per project (泳道). Away stretches are hatched. A click on a session line, or
/// on a column or cell inside a session, selects the session.
struct SessionRibbon: View {
    enum Style: String, CaseIterable { case composition, lanes }

    let model: AppModel
    @Bindable var activities: ActivitiesModel
    var onSelect: () -> Void = {}
    /// Shared with the Today timeline: what the person chose for the colours; empty until they do.
    @AppStorage("todayTimelineColors") private var chosenColors = ""
    @AppStorage("activitiesRibbonStyle") private var style = Style.composition
    @State private var focus: String?
    @State private var hover: String?

    #if DEBUG
    /// Captures: the legend item that starts out focused.
    @MainActor static var previewFocus: String?
    #endif

    private static let bodyHeight: CGFloat = 64
    private static let labelWidth: CGFloat = 96

    private var colors: TimelineColors {
        TimelineColors(rawValue: chosenColors) ?? (activities.composition?.projectTotals.contains { $0.id != DayComposition.noProject } == true ? .project : .category)
    }

    var body: some View {
        let sessions = activities.sessions
        let series = activities.composition.map { model.compositionSeries($0, colors) } ?? []
        VStack(alignment: .leading, spacing: Design.Space.sm) {
            if let first = sessions.first, let last = sessions.last {
                let start = Calendar.current.dateInterval(of: .hour, for: first.start)?.start ?? first.start
                let end = (Calendar.current.dateInterval(of: .hour, for: last.end)?.end ?? last.end)
                chart(DateInterval(start: start, duration: max(3600, end.timeIntervalSince(start))), sessions, series)
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous).fill(Design.track)
                    .frame(height: CompositionSessionLines.height + Self.bodyHeight + 16)
            }
            controls(series)
        }
        .padding(Design.Space.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .designCard()
        .onChange(of: colors) { _, _ in focus = nil }
        #if DEBUG
        .onAppear { focus = Self.previewFocus }
        #endif
    }

    private func chart(_ axis: DateInterval, _ sessions: [WorkSession], _ series: [CompositionSeries]) -> some View {
        let rows = CompositionLanes.rows(series, limit: colors == .project ? 8 : 6)
        let active = hover ?? focus
        return HStack(alignment: .top, spacing: Design.Space.sm) {
            if style == .lanes {
                CompositionLaneLabels(rows: rows, height: Self.bodyHeight, focus: active)
                    .frame(width: Self.labelWidth, alignment: .leading).padding(.top, CompositionSessionLines.height)
            }
            VStack(alignment: .leading, spacing: 0) {
                CompositionSessionLines(lines: sessions.map { session in
                    .init(id: session.start, start: session.start, end: session.end, name: name(session), selected: activities.selectedSession == session.start)
                }, axis: axis, pick: select)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        if style == .composition { RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous).fill(Design.track) }
                        ForEach(Array(zip(sessions, sessions.dropFirst()).enumerated()), id: \.offset) { _, pair in
                            if pair.1.start.timeIntervalSince(pair.0.end) >= TodayPlan.gapMinimum {
                                let left = proxy.size.width * axis.fraction(of: pair.0.end)
                                HatchFill(away: true).clipShape(RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous))
                                    .frame(width: proxy.size.width * axis.fraction(of: pair.1.start) - left).offset(x: left)
                            }
                        }
                        if let composition = activities.composition {
                            Group {
                                if style == .composition {
                                    CompositionBars(composition: composition, colors: colors, series: series, axis: axis, focus: active, tap: pick(at:))
                                } else {
                                    CompositionLanes(composition: composition, colors: colors, rows: rows, axis: axis, focus: active, tap: pick(at:))
                                }
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                }
                .frame(height: Self.bodyHeight)
                if !activities.callSpans.isEmpty {
                    CompositionCallLane(lines: model.callLines(activities.callSpans), axis: axis).padding(.top, 3)
                }
                hourLabels(axis)
            }
        }
    }

    /// The legend, which focuses a colour on a click, and the two switches.
    private func controls(_ series: [CompositionSeries]) -> some View {
        HStack(spacing: Design.Space.md) {
            ViewThatFits(in: .horizontal) {
                CompositionLegend(series: Array(series.prefix(8)), focus: $focus, hover: $hover)
                CompositionLegend(series: Array(series.prefix(5)), focus: $focus, hover: $hover)
                CompositionLegend(series: Array(series.prefix(3)), focus: $focus, hover: $hover)
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: 0)
            Segmented(options: TimelineColors.allCases, selection: Binding(get: { colors }, set: { chosenColors = $0.rawValue }), height: 24) { option in
                option == .project ? Text("按项目") : Text("按分类")
            }
            .accessibilityLabel("时间轴颜色")
            Segmented(options: Style.allCases, selection: $style, height: 24) { option in
                option == .composition ? Text("构成") : Text("泳道")
            }
            .accessibilityLabel("时间带样式")
        }
        .font(.note).foregroundStyle(Design.ink2)
    }

    private func name(_ session: WorkSession) -> String {
        model.sessionTitle(session) ?? model.sessionProject(session) ?? session.apps.prefix(2).map(\.name).joined(separator: String(localized: "、"))
    }

    private func select(_ start: Date) {
        let on = activities.selectedSession == start
        activities.selectedActivity = nil
        activities.selectedStart = nil
        activities.selectedSession = on ? nil : start
        if !on { onSelect() }
    }

    private func pick(at date: Date) {
        if let session = activities.sessions.first(where: { $0.start <= date && date < $0.end }) { select(session.start) }
    }

    private func hourLabels(_ axis: DateInterval) -> some View {
        GeometryReader { proxy in
            ForEach(hours(from: axis.start, to: axis.end, width: proxy.size.width, span: axis.duration), id: \.0) { tick in
                Text(tick.1).font(.note).monospacedDigit().foregroundStyle(Design.ink2).fixedSize().offset(x: tick.2, y: 4)
            }
        }
        .frame(height: 18)
    }

    /// Hour labels spaced so none touches the next.
    private func hours(from start: Date, to end: Date, width: CGFloat, span: TimeInterval) -> [(Date, String, CGFloat)] {
        let perHour = width / max(1, span / 3600)
        let step = [1, 2, 3, 4, 6].first { CGFloat($0) * perHour >= 56 } ?? 6
        var result: [(Date, String, CGFloat)] = []
        var time = start
        while time <= end {
            result.append((time, model.time(time), width * time.timeIntervalSince(start) / span))
            guard let next = Calendar.current.date(byAdding: .hour, value: step, to: time) else { break }
            time = next
        }
        return result.filter { $0.2 < width - 40 }
    }
}
