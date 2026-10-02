import SwiftUI

/// Wording for lengths of time on the Today page: short, in whole minutes.
enum TodayFmt {
    private static func minutes(_ seconds: TimeInterval) -> Int { max(0, Int((seconds / 60).rounded())) }

    /// "55 分" or "4:42": a figure and its unit in a narrow place.
    static func clock(_ seconds: TimeInterval) -> String {
        let m = minutes(seconds)
        return m < 60 ? String(localized: "\(m) 分") : String(format: "%d:%02d", m / 60, m % 60)
    }

    /// "55 分", "4 小时", "2 小时 49 分".
    static func long(_ seconds: TimeInterval) -> String {
        let m = minutes(seconds)
        if m < 60 { return String(localized: "\(m) 分") }
        return m % 60 == 0 ? String(localized: "\(m / 60) 小时") : String(localized: "\(m / 60) 小时 \(m % 60) 分")
    }
}

/// Which project the page is narrowed to, if any; `.some(nil)` is "no project".
typealias ProjectFilter = String??

/// 今天的时间轴: the day's sessions as blocks, coloured by project, on an hour
/// axis. Gaps are hatched, interruptions are ticks under the block where they
/// happened, and now is a line. A block opens a small glass card.
struct TodayTimelineCard: View {
    let plan: TodayPlan
    let model: AppModel
    let filter: ProjectFilter
    @Binding var selected: Date?
    let open: (TodayPlan.Row) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var grown = false
    @State private var filling: Date?

    private static let chartHeight: CGFloat = 140
    private static let top: CGFloat = 26
    private static let blockHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 12)
            chart.frame(height: Self.chartHeight)
            legend.padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.xl).padding(.top, 18).padding(.bottom, 12)
        .designCard()
        .onAppear { grown = true }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("今天的时间轴").cardTitle()
            Text("\(plan.rows.count) 段会话，按项目上色").font(.system(size: 12)).foregroundStyle(Design.ink3)
            Spacer(minLength: 8)
            if let carried = plan.carriedOver {
                Button { withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { selected = carried.id } } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Design.projectColor(carried.slot)).frame(width: 7, height: 7)
                        Text("\(model.time(carried.session.start))–\(model.time(carried.session.end)) 接着昨晚 · \(TodayFmt.long(carried.session.recorded))")
                            .font(.num(11)).lineLimit(1)
                    }
                }
                .buttonStyle(PillButtonStyle(height: 24, font: .system(size: 11)))
            }
        }
    }

    // MARK: Chart

    private var axisSeconds: TimeInterval { max(1, plan.axis.duration) }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        width * CGFloat(max(0, min(1, date.timeIntervalSince(plan.axis.start) / axisSeconds)))
    }

    private var chart: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                if plan.isToday { future(width) }
                grid(width)
                ForEach(plan.gaps) { gap in away(gap, width) }
                ForEach(Array(plan.rows.enumerated()), id: \.element.id) { index, row in block(row, index: index, width) }
                ticks(width)
                if plan.isToday { nowMark(width) }
                if let row = plan.rows.first(where: { $0.id == selected }) { card(row, width) }
            }
            .frame(width: width, height: Self.chartHeight, alignment: .topLeading)
        }
    }

    private func future(_ width: CGFloat) -> some View {
        let nowX = x(plan.now, width) + 6
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Design.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .overlay(Text("还没到").font(.system(size: 11)).foregroundStyle(Design.ink3))
            .frame(width: max(0, width - nowX), height: Self.blockHeight + 12)
            .offset(x: nowX, y: Self.top - 6)
            .opacity(width - nowX > 56 ? 1 : 0)
    }

    private struct Tick: Identifiable { let id: Date; let text: String; let x: CGFloat }

    private func hourTicks(_ width: CGFloat) -> [Tick] {
        let calendar = Calendar.current
        let hours = max(1, axisSeconds / 3600)
        let perHour = width / hours
        let step = [1, 2, 3, 4, 6].first { CGFloat($0) * perHour >= 58 } ?? 6
        var result: [Tick] = []
        var cursor = plan.axis.start
        while cursor <= plan.axis.end {
            let text = cursor == plan.axis.end && calendar.component(.hour, from: cursor) == 0 && model.timeFormat != "12" ? "24:00" : model.time(cursor)
            result.append(Tick(id: cursor, text: text, x: x(cursor, width)))
            guard let next = calendar.date(byAdding: .hour, value: step, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private func grid(_ width: CGFloat) -> some View {
        let ticks = hourTicks(width)
        return ZStack(alignment: .topLeading) {
            ForEach(ticks) { tick in
                Rectangle().fill(Design.line2).frame(width: 1, height: 100).offset(x: tick.x)
                Text(verbatim: tick.text).font(.num(11)).foregroundStyle(Design.ink3).fixedSize()
                    .position(x: min(max(tick.x, 22), width - 22), y: 114)
            }
        }
    }

    // MARK: Gaps

    private func away(_ gap: DayGap, _ width: CGFloat) -> some View {
        let left = x(gap.interval.start, width), right = x(gap.interval.end, width)
        let w = max(0, right - left)
        let note = plan.notes.first { TodayPlan.isNoted(gap.interval, by: [$0]) }
        let fillable = !gap.ongoing && gap.interval.duration >= 1800 && note == nil
        return ZStack {
            HatchFill(away: true).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(spacing: 4) {
                if w >= 86 {
                    if let note {
                        Label(note.label, systemImage: note.symbol.isEmpty ? "moon" : note.symbol)
                            .labelStyle(.titleAndIcon).font(.system(size: 11)).foregroundStyle(Design.ink2).lineLimit(1)
                    } else if gap.interval.duration >= 1800 {
                        Text("离开 \(TodayFmt.long(gap.interval.duration))").font(.num(11)).foregroundStyle(Design.ink2).lineLimit(1)
                    }
                }
                if fillable, w >= 60 {
                    Button("补记") { filling = gap.id }
                        .buttonStyle(PillButtonStyle(height: 22, tint: Design.accentInk, font: .system(size: 11)))
                        .popover(isPresented: Binding(get: { filling == gap.id }, set: { if !$0 { filling = nil } }), arrowEdge: .bottom) {
                            AwayPrompt(model: model, interval: gap.interval, manual: true) { filling = nil }.frame(width: 316).padding(4)
                        }
                }
            }
        }
        .frame(width: w, height: Self.blockHeight)
        .offset(x: left, y: Self.top)
        .help(Text("离开 \(TodayFmt.long(gap.interval.duration))"))
        .opacity(grown ? 1 : 0)
        .animation(reduceMotion ? nil : Design.reveal.delay(0.1), value: grown)
    }

    // MARK: Blocks

    private func dimmed(_ row: TodayPlan.Row) -> Bool {
        guard let filter else { return false }
        return filter != row.project
    }

    private func block(_ row: TodayPlan.Row, index: Int, _ width: CGFloat) -> some View {
        let left = x(row.session.start, width)
        let w = max(x(row.session.end, width) - left - 2, 3)
        let color = Design.projectColor(row.slot)
        let isSelected = selected == row.id
        let shape = RoundedRectangle(cornerRadius: Design.Radius.block, style: .continuous)
        return Button {
            withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { selected = isSelected ? nil : row.id }
        } label: {
            ZStack(alignment: .leading) {
                shape.fill(color)
                if row.guessed { StripeOverlay().clipShape(shape) }
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.25 : 0.38), .clear, .black.opacity(0.10)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
                if w >= 34 {
                    Text(TodayFmt.clock(row.session.recorded)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).padding(.horizontal, 6)
                }
            }
            .frame(width: w, height: Self.blockHeight)
            .overlay { if isSelected { shape.strokeBorder(Color.white.opacity(0.95), lineWidth: 2).padding(-2).overlay(shape.strokeBorder(color, lineWidth: 2).padding(-4)) } }
            .contentShape(shape)
        }
        .buttonStyle(BlockPressStyle())
        .hoverBrighten()
        .opacity(dimmed(row) ? 0.2 : 1)
        .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
        .animation(reduceMotion ? nil : Design.reveal.delay(0.15 + Double(min(index, 20)) * 0.03), value: grown)
        .animation(reduceMotion ? nil : Design.settle, value: dimmed(row))
        .zIndex(isSelected ? 3 : 1)
        .offset(x: left, y: Self.top)
        .accessibilityLabel(Text(verbatim: "\(title(row)) \(model.time(row.session.start))–\(model.time(row.session.end))"))
    }

    private func ticks(_ width: CGFloat) -> some View {
        Canvas { context, _ in
            let color = Design.interruptionResolved(scheme)
            for episode in plan.interruptions {
                let row = plan.rows.first { episode.start >= $0.session.start && episode.start < $0.session.end }
                let faded = row.map(dimmed) ?? false
                let origin = CGPoint(x: x(episode.start, width) - 1, y: Self.top + Self.blockHeight + 6)
                context.fill(Path(roundedRect: CGRect(origin: origin, size: CGSize(width: 2, height: 9)), cornerRadius: 1),
                             with: .color(color.opacity(faded ? 0.25 : 1)))
            }
        }
        .frame(width: width, height: Self.chartHeight).allowsHitTesting(false)
        .opacity(grown ? 1 : 0)
        .animation(reduceMotion ? nil : Design.reveal.delay(0.4), value: grown)
        .accessibilityHidden(true)
    }

    private func nowMark(_ width: CGFloat) -> some View {
        let nowX = x(plan.now, width)
        return ZStack(alignment: .topLeading) {
            Text(model.time(plan.now)).font(.num(11, .bold)).foregroundStyle(Design.ink).fixedSize()
                .position(x: min(max(nowX, 24), width - 24), y: 6)
            RoundedRectangle(cornerRadius: 1).fill(Design.ink).frame(width: 2, height: Self.blockHeight + 30)
                .offset(x: nowX - 1, y: Self.top - 10)
        }.allowsHitTesting(false)
    }

    // MARK: The card a block opens

    private func title(_ row: TodayPlan.Row) -> String {
        model.sessionTitle(row.session) ?? row.project
            ?? row.session.apps.prefix(2).map(\.name).joined(separator: String(localized: "、"))
    }

    private func card(_ row: TodayPlan.Row, _ width: CGFloat) -> some View {
        let cardWidth: CGFloat = 244
        let center = x(row.session.start.addingTimeInterval(row.session.duration / 2), width)
        let left = min(max(center - cardWidth / 2, 0), max(0, width - cardWidth))
        let category = model.resolver.categoriesByID[row.session.categoryID]?.name ?? String(localized: "未分类")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(Design.projectColor(row.slot)).frame(width: 9, height: 9)
                Text(row.guessed ? String(localized: "\(title(row))（推测）") : title(row))
                    .font(.system(size: 14, weight: .bold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button { withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { selected = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Design.ink2)
                        .frame(width: 22, height: 22).background(Design.track, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("关闭")
            }
            Text(verbatim: "\(model.time(row.session.start)) – \(model.time(row.session.end)) · \(TodayFmt.long(row.session.recorded)) · \(category)")
                .font(.num(12)).foregroundStyle(Design.ink2).lineLimit(2)
            Text(row.interruptions > 0 ? String(localized: "切换 \(row.switches) 次 · 打断 \(row.interruptions) 次")
                 : String(localized: "切换 \(row.switches) 次 · 没有打断"))
                .font(.num(12)).foregroundStyle(Design.ink2)
            Button { open(row) } label: { Text("在活动里打开 ›").font(.system(size: 12, weight: .semibold)).foregroundStyle(Design.link) }
                .buttonStyle(.plain).padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(width: cardWidth, alignment: .leading)
        .glassSurface(cornerRadius: 18)
        .offset(x: left, y: Self.top + Self.blockHeight + 6)
        .zIndex(6)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .top).combined(with: .opacity))
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                HatchFill(away: true).frame(width: 14, height: 10).clipShape(RoundedRectangle(cornerRadius: 3))
                Text("离开")
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(Design.interruption).frame(width: 3, height: 8)
                Text("打断")
            }
            if plan.isToday {
                HStack(spacing: 6) {
                    Rectangle().fill(Design.ink).frame(width: 2, height: 10)
                    Text("现在")
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(Design.ink3)
    }
}

/// A block gives a little under the finger, nothing more.
private struct BlockPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : Design.press, value: configuration.isPressed)
    }
}

extension Design {
    /// `interruption` for places that need a concrete value, not a dynamic one.
    static func interruptionResolved(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#FF4D6D") : Color(hex: "#E5345A")
    }
}
