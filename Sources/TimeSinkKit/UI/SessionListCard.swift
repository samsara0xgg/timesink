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
        let color = Color(hex: model.resolver.categoriesByID[session.categoryID]?.colorHex ?? "#8E8E93")
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

/// The day at a glance: sessions as blocks on one line, away stretches hatched.
/// A click selects the session.
struct SessionRibbon: View {
    let model: AppModel
    @Bindable var activities: ActivitiesModel
    var onSelect: () -> Void = {}

    var body: some View {
        let sessions = activities.sessions
        ZStack(alignment: .topLeading) {
            if let first = sessions.first, let last = sessions.last {
                let start = Calendar.current.dateInterval(of: .hour, for: first.start)?.start ?? first.start
                let end = (Calendar.current.dateInterval(of: .hour, for: last.end)?.end ?? last.end)
                let span = max(3600, end.timeIntervalSince(start))
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous).fill(Design.track).frame(height: 32)
                        ForEach(sessions) { session in
                            let x = width * session.start.timeIntervalSince(start) / span
                            let w = max(3, width * session.end.timeIntervalSince(session.start) / span - 1)
                            let on = activities.selectedSession == session.start
                            RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous)
                                .fill(Color(hex: model.resolver.categoriesByID[session.categoryID]?.colorHex ?? "#8E8E93"))
                                .overlay { if on { RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous).strokeBorder(Design.ink, lineWidth: 2) } }
                                .frame(width: w, height: 32).offset(x: x)
                                .onTapGesture { activities.selectedActivity = nil; activities.selectedStart = nil; activities.selectedSession = on ? nil : session.start; if !on { onSelect() } }
                                .help(model.sessionTitle(session) ?? session.apps.prefix(2).map(\.name).joined(separator: String(localized: "、")))
                                .accessibilityLabel(Text(model.sessionTitle(session) ?? session.apps.first?.name ?? ""))
                        }
                        ForEach(hours(from: start, to: end, width: width, span: span), id: \.0) { tick in
                            Text(tick.1).font(.note).monospacedDigit().foregroundStyle(Design.ink2).fixedSize().offset(x: tick.2, y: 38)
                        }
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous).fill(Design.track).frame(height: 32)
            }
        }
        .frame(height: 52, alignment: .top)
        .padding(Design.Space.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .designCard()
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
