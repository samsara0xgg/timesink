import SwiftUI

/// 会话: the day's sessions in order, away stretches between them. A session
/// can be joined onto the one before it; the two fuse, and the toast offers
/// to undo it.
struct SessionListCard: View {
    let model: AppModel
    @Bindable var activities: ActivitiesModel
    var onSelect: () -> Void = {}
    @State private var filter: String?
    @State private var toast: Toast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Toast: Equatable { let message: String; let start: Date }

    private var sessions: [WorkSession] { activities.sessions }
    private var projects: [(name: String, count: Int)] {
        Dictionary(grouping: sessions.compactMap { model.sessionProject($0) }, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeading(title: "会话", caption: Text("\(sessions.count) 段 · 按时间"))
            if projects.count > 1 { chips }
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
        .padding(.horizontal, 14).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .workspacePanel()
        .overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 12) {
                    Text(toast.message).font(.system(size: 12, weight: .semibold))
                    Button("撤销") { undo(toast) }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Design.link)
                }
                .padding(.horizontal, 16).frame(height: 36).glassSurface(in: Capsule()).padding(.bottom, 12)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(nil, label: Text("全部"), count: sessions.count)
                ForEach(projects, id: \.name) { chip($0.name, label: Text(verbatim: $0.name), count: $0.count) }
            }
        }.scrollIndicators(.never)
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

    private func awayBefore(_ index: Int) -> TimeInterval? {
        let gap = sessions[index].start.timeIntervalSince(sessions[index - 1].end)
        return gap >= 60 ? gap : nil
    }

    private func away(_ gap: TimeInterval) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(Design.track).overlay(StripeOverlay().opacity(0.6)).frame(width: 3, height: 14).clipShape(RoundedRectangle(cornerRadius: 1.5))
            Text("离开 \(Format.chineseDuration(gap))").font(.num(11)).foregroundStyle(Design.ink3)
            Spacer(minLength: 0)
        }.padding(.horizontal, 8).frame(height: 24)
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
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.sessionTitle(session) ?? apps).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(model.time(session.start))–\(model.time(session.end))\(model.sessionProject(session).map { " · \($0)" } ?? "")")
                            .font(.num(11)).foregroundStyle(Design.ink3).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(Format.duration(session.recorded)).font(.num(12)).foregroundStyle(Design.ink2)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
                .padding(.horizontal, 8).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Design.rowHover : .clear))
                .contentShape(Rectangle())
            }.buttonStyle(HoverRowStyle())
            if selected && index > 0 {
                HStack {
                    Spacer()
                    Button { join(session, at: index) } label: { Label("并入上一段", systemImage: "arrow.up.to.line").font(.system(size: 12)) }
                        .buttonStyle(PillButtonStyle(height: 26))
                }.padding(.horizontal, 8).padding(.bottom, 6)
                .transition(.opacity)
            }
        }
    }

    private func join(_ session: WorkSession, at index: Int) {
        let message = String(localized: "已并入上一段")
        // The later row slides up into the earlier one and its time ticks.
        withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) {
            model.joinSession(session)
            activities.selectedSession = sessions[index - 1].start
            toast = Toast(message: message, start: session.start)
        }
        let shown = session.start
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast?.start == shown { withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { toast = nil } }
        }
    }

    private func undo(_ toast: Toast) {
        withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) {
            model.unjoinSession(startingAt: toast.start)
            self.toast = nil
        }
    }
}
