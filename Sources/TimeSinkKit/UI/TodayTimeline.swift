import SwiftUI

/// Wording for lengths of time on the Today page: short, in whole minutes.
enum TodayFmt {
    /// "55 分" or "4:42": a figure and its unit in a narrow place.
    static func clock(_ seconds: TimeInterval) -> String { Format.duration(seconds) }

    /// "55 分", "2 小时 49 分" (en "55m", "2h 49m").
    static func long(_ seconds: TimeInterval) -> String { Format.duration(seconds) }
}

/// Which project the page is narrowed to, if any; `.some(nil)` is "no project".
typealias ProjectFilter = String??

/// 今天的时间轴: the day's sessions as blocks, coloured by project, on an hour
/// axis. Gaps are hatched, interruptions are ticks under the block where they
/// happened, and now is a line. The heading says what is going on now; a
/// block opens a small card.
struct TodayTimelineCard: View {
    let plan: TodayPlan
    let model: AppModel
    let filter: ProjectFilter
    @Binding var selected: Date?
    let open: (TodayPlan.Row) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filling: Date?

    private static let headerHeight: CGFloat = 24
    private static let chartHeight: CGFloat = 140
    private static let legendHeight: CGFloat = 16
    /// The card's whole height, so the page can hold its place while loading.
    static let height = headerHeight + Design.Space.md + chartHeight + Design.Space.sm + legendHeight + 2 * Design.Space.card
    private static let top: CGFloat = 24
    private static let blockHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.frame(height: Self.headerHeight).padding(.bottom, Design.Space.md)
            chart.frame(height: Self.chartHeight)
            legend.frame(height: Self.legendHeight).padding(.top, Design.Space.sm)
        }
        .cardBox()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.sm) {
            CardHeading(title: plan.isToday ? "今天的时间轴" : "这一天的时间轴", caption: Text("\(plan.rows.count) 段会话，按项目上色"))
            Spacer(minLength: Design.Space.sm)
            if let carried = plan.carriedOver {
                Button { select(carried) } label: {
                    Text("\(model.time(carried.session.start))–\(model.time(carried.session.end)) 接着昨晚 · \(TodayFmt.long(carried.session.recorded))")
                        .monospacedDigit()
                }
                .buttonStyle(LinkButtonStyle()).font(.note).lineLimit(1)
            }
            if let row = plan.current { now(row) }
        }
    }

    /// 现在 / 最近一段: the last session in one line; a click opens its card.
    private func now(_ row: TodayPlan.Row) -> some View {
        let live = plan.currentIsLive
        let heading: LocalizedStringKey = live ? "现在" : plan.isToday ? "最近一段" : "最后一段"
        return Button { select(row) } label: {
            HStack(spacing: 6) {
                Circle().fill(live ? Design.live : Design.ink2.opacity(0.5)).frame(width: 7, height: 7)
                Text(heading).foregroundStyle(Design.ink2)
                Text(verbatim: title(row)).foregroundStyle(Design.ink).lineLimit(1)
                Text(verbatim: TodayFmt.long(row.session.recorded)).monospacedDigit().foregroundStyle(Design.ink2)
                    .refinedNumberMotion(TodayFmt.long(row.session.recorded))
            }
            .font(.body)
            .padding(.horizontal, Design.Space.sm).frame(height: 24)
        }
        .buttonStyle(HoverRowStyle())
        .layoutPriority(-1)
        .help(row.interruptions > 0 ? String(localized: "这一段被打断 \(row.interruptions) 次，切换 \(row.switches) 次。")
              : String(localized: "这一段没有被打断，切换 \(row.switches) 次。"))
    }

    private func select(_ row: TodayPlan.Row) {
        withAnimation(Design.motion(Design.quick, reduced: reduceMotion)) { selected = selected == row.id ? nil : row.id }
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
        return RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous)
            .strokeBorder(Design.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .overlay(Text("还没到").font(.note).foregroundStyle(Design.ink2))
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
                Rectangle().fill(Design.line2).frame(width: 1, height: 102).offset(x: tick.x)
                Text(verbatim: tick.text).font(.note).monospacedDigit().foregroundStyle(Design.ink2).fixedSize()
                    .position(x: min(max(tick.x, 22), width - 22), y: 120)
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
            HatchFill(away: true).clipShape(RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous))
            VStack(spacing: Design.Space.xs) {
                if w >= 86 {
                    if let note {
                        Label(note.label, systemImage: note.symbol.isEmpty ? "moon" : note.symbol)
                            .labelStyle(.titleAndIcon).font(.note).foregroundStyle(Design.ink2).lineLimit(1)
                    } else if gap.interval.duration >= 1800 {
                        Text("离开 \(TodayFmt.long(gap.interval.duration))").font(.note).monospacedDigit().foregroundStyle(Design.ink2).lineLimit(1)
                    }
                }
                if fillable, w >= 60 {
                    Button("补记") { filling = gap.id }
                        .buttonStyle(PillButtonStyle(height: 22, font: .note))
                        .popover(isPresented: Binding(get: { filling == gap.id }, set: { if !$0 { filling = nil } }), arrowEdge: .bottom) {
                            AwayPrompt(model: model, interval: gap.interval, manual: true) { filling = nil }.frame(width: 316).padding(4)
                        }
                }
            }
        }
        .frame(width: w, height: Self.blockHeight)
        .offset(x: left, y: Self.top)
        .help(Text("离开 \(TodayFmt.long(gap.interval.duration))"))
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
        let shape = RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous)
        return Button { select(row) } label: {
            ZStack(alignment: .leading) {
                shape.fill(color)
                if row.guessed { StripeOverlay().clipShape(shape) }
                // The label shows only if it fits whole; never an ellipsis.
                ViewThatFits(in: .horizontal) {
                    Text(TodayFmt.clock(row.session.recorded)).font(.note.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                        .lineLimit(1).fixedSize().padding(.horizontal, 6)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .frame(width: w, height: Self.blockHeight)
            .overlay { if isSelected { shape.strokeBorder(Design.ink, lineWidth: 2).padding(-3) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(dimmed(row) ? 0.2 : 1)
        .animation(Design.motion(Design.quick, reduced: reduceMotion), value: dimmed(row))
        .zIndex(isSelected ? 3 : 1)
        .offset(x: left, y: Self.top)
        .accessibilityLabel(Text(verbatim: "\(title(row)) \(model.time(row.session.start))–\(model.time(row.session.end))"))
    }

    private func ticks(_ width: CGFloat) -> some View {
        Canvas { context, _ in
            let color = Design.alert
            for episode in plan.interruptions {
                let row = plan.rows.first { episode.start >= $0.session.start && episode.start < $0.session.end }
                let faded = row.map(dimmed) ?? false
                let origin = CGPoint(x: x(episode.start, width) - 1, y: Self.top + Self.blockHeight + 6)
                context.fill(Path(roundedRect: CGRect(origin: origin, size: CGSize(width: 2, height: 9)), cornerRadius: 1),
                             with: .color(color.opacity(faded ? 0.25 : 1)))
            }
        }
        .frame(width: width, height: Self.chartHeight).allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func nowMark(_ width: CGFloat) -> some View {
        let nowX = x(plan.now, width)
        return ZStack(alignment: .topLeading) {
            Text(model.time(plan.now)).font(.note.weight(.semibold)).monospacedDigit().foregroundStyle(Design.ink).fixedSize()
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
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.sm) {
                Circle().fill(Design.projectColor(row.slot)).frame(width: 8, height: 8)
                Text(row.guessed ? String(localized: "\(title(row))（推测）") : title(row))
                    .font(.body.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button { select(row) } label: {
                    Image(systemName: "xmark").font(.note.weight(.semibold)).foregroundStyle(Design.ink2)
                        .frame(width: 20, height: 20).background(Design.hoverFill, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("关闭")
            }
            Text(verbatim: "\(model.time(row.session.start))–\(model.time(row.session.end)) · \(TodayFmt.long(row.session.recorded)) · \(category)")
                .font(.note).monospacedDigit().foregroundStyle(Design.ink2).lineLimit(2)
            Text(row.interruptions > 0 ? String(localized: "切换 \(row.switches) 次 · 打断 \(row.interruptions) 次")
                 : String(localized: "切换 \(row.switches) 次 · 没有打断"))
                .font(.note).monospacedDigit().foregroundStyle(Design.ink2)
            Button("在活动里打开 ›") { open(row) }.buttonStyle(LinkButtonStyle()).font(.note).padding(.top, 2)
        }
        .padding(Design.Space.md).frame(width: cardWidth, alignment: .leading)
        .floatingCard()
        .offset(x: left, y: Self.top + Self.blockHeight + 6)
        .zIndex(6)
        .transition(.opacity)
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: Design.Space.lg) {
            HStack(spacing: 6) {
                HatchFill(away: true).frame(width: 14, height: 10).clipShape(RoundedRectangle(cornerRadius: 2))
                Text("离开")
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(Design.alert).frame(width: 2, height: 9)
                Text("打断")
            }
            if plan.isToday {
                HStack(spacing: 6) {
                    Rectangle().fill(Design.ink).frame(width: 2, height: 10)
                    Text("现在")
                }
            }
        }
        .font(.note).foregroundStyle(Design.ink2)
    }
}
