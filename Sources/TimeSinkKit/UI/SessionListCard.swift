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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CardHeading(title: "会话", caption: Text("\(sessions.count) 段 · 按时间"))
                Spacer(minLength: 8)
                if projects.count > 1 { chips }
                modeSwitch
            }
            if sessions.isEmpty {
                Text("这一天还没有会话。").font(.system(size: 13)).foregroundStyle(Design.ink3).frame(maxWidth: .infinity, minHeight: 80)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if filter == nil || model.sessionProject(session) == filter {
                            if filter == nil, index > 0, let gap = awayBefore(index) { away(gap) }
                            row(session, index: index)
                                .transition(reduceMotion ? .opacity : .asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .top).combined(with: .opacity)))
                        }
                    }
                }
                .animation(reduceMotion ? nil : Design.settle, value: sessions.map(\.id))
            }.scrollIndicators(.never)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .workspacePanel()
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(nil, label: Text("全部"), count: sessions.count)
                ForEach(projects, id: \.name) { chip($0.name, label: Text(verbatim: $0.name), count: $0.count) }
            }
        }.scrollIndicators(.never).frame(maxWidth: 360)
    }

    private func chip(_ name: String?, label: Text, count: Int) -> some View {
        Button {
            withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { filter = name }
        } label: {
            HStack(spacing: 5) { label; Text("\(count)").font(.num(11)).foregroundStyle(Design.ink3) }
                .font(.system(size: 12, weight: filter == name ? .bold : .regular))
                .foregroundStyle(filter == name ? Design.accentInk : Design.ink)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(filter == name ? Design.pillTop : Design.track))
        }.buttonStyle(.plain)
    }

    private func awayBefore(_ index: Int) -> DateInterval? {
        let start = sessions[index - 1].end, end = sessions[index].start
        return end.timeIntervalSince(start) >= 60 ? DateInterval(start: start, end: end) : nil
    }

    private func away(_ gap: DateInterval) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Design.track).overlay(StripeOverlay().opacity(0.6)).frame(width: 3, height: 16).clipShape(RoundedRectangle(cornerRadius: 1.5))
            Text("\(model.time(gap.start))–\(model.time(gap.end))").font(.num(11)).foregroundStyle(Design.ink3)
            Text("离开 \(Format.chineseDuration(gap.duration))").font(.num(11)).foregroundStyle(Design.ink3)
            Spacer(minLength: 0)
            if gap.duration >= 60 {
                Button("补记") { filling = gap.start }
                    .buttonStyle(PillButtonStyle(height: 22, tint: Design.accentInk, font: .system(size: 11)))
                    .popover(isPresented: Binding(get: { filling == gap.start }, set: { if !$0 { filling = nil } }), arrowEdge: .bottom) {
                        AwayPrompt(model: model, interval: gap, manual: true) { filling = nil }.frame(width: 316).padding(4)
                    }
            }
        }.padding(.horizontal, 8).frame(height: 30)
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
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 32)
                    Text("\(model.time(session.start))–\(model.time(session.end))").font(.num(12)).foregroundStyle(Design.ink2).frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.sessionTitle(session) ?? apps).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let sub = model.sessionProject(session) ?? (model.sessionTitle(session) != nil ? apps : nil) {
                            Text(sub).font(.system(size: 11)).foregroundStyle(Design.ink3).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(Format.duration(session.recorded, compact: true)).font(.num(12)).foregroundStyle(Design.ink2)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
                .padding(.horizontal, 8).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Design.rowHover : .clear))
                .contentShape(Rectangle())
            }.buttonStyle(HoverRowStyle())
            if selected && index > 0 {
                HStack {
                    Spacer()
                    Button { withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { activities.join(session, model: model) } } label: {
                        Label("并入上一段", systemImage: "arrow.up.to.line").font(.system(size: 12))
                    }.buttonStyle(PillButtonStyle(height: 26))
                }.padding(.horizontal, 8).padding(.bottom, 6)
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
        VStack(alignment: .leading, spacing: 8) {
            if let first = sessions.first, let last = sessions.last {
                let start = Calendar.current.dateInterval(of: .hour, for: first.start)?.start ?? first.start
                let end = (Calendar.current.dateInterval(of: .hour, for: last.end)?.end ?? last.end)
                let span = max(3600, end.timeIntervalSince(start))
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Design.track).overlay(StripeOverlay().opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        ForEach(sessions) { session in
                            let x = width * session.start.timeIntervalSince(start) / span
                            let w = max(3, width * session.end.timeIntervalSince(session.start) / span - 1)
                            let on = activities.selectedSession == session.start
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(hex: model.resolver.categoriesByID[session.categoryID]?.colorHex ?? "#8E8E93"))
                                .overlay { if on { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Design.ink, lineWidth: 2) } }
                                .frame(width: w, height: 38).offset(x: x)
                                .onTapGesture { activities.selectedActivity = nil; activities.selectedStart = nil; activities.selectedSession = on ? nil : session.start; if !on { onSelect() } }
                                .help(model.sessionTitle(session) ?? session.apps.prefix(2).map(\.name).joined(separator: String(localized: "、")))
                                .accessibilityLabel(Text(model.sessionTitle(session) ?? session.apps.first?.name ?? ""))
                        }
                        ForEach(hours(from: start, to: end, width: width, span: span), id: \.0) { tick in
                            Text(tick.1).font(.num(11)).foregroundStyle(Design.ink3).fixedSize().offset(x: tick.2, y: 44)
                        }
                    }
                }.frame(height: 62)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .workspacePanel()
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
