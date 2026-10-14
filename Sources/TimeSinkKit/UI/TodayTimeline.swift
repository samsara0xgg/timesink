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

/// What the timeline's blocks are coloured by. A session whose project is not
/// known takes its main category's colour in either mode.
enum TimelineColors: String, CaseIterable {
    case project, category
}

/// 今天的时间轴, 分轨: one lane per category (or project), its total on the
/// left and where its time sits on an hour axis to the right, so the card
/// answers where the day went and when in one look. A run is cut wherever
/// something else held the window, so an interruption shows as a mark in
/// another lane. Gaps are hatched across every lane, interruptions are ticks
/// under the lanes, and now is a line. A mark opens its session's card.
struct TodayTimelineCard: View {
    let plan: TodayPlan
    let model: AppModel
    let filter: ProjectFilter
    let colors: TimelineColors
    let choose: (TimelineColors) -> Void
    @Binding var selected: Date?
    let open: (TodayPlan.Row) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filling: Date?
    /// The lane of the mark that opened the card, so the card hangs under it.
    @State private var selectedLane: Int?

    private static let headerHeight: CGFloat = 24
    /// Room above the lanes for the time now.
    private static let top: CGFloat = 22
    private static let laneHeight: CGFloat = 26
    private static let markHeight: CGFloat = 18
    /// The narrowest mark drawn; runs closer than this on screen are drawn as one.
    private static let minMark: CGFloat = 2
    /// Always room for every lane, so the page doesn't jump with the day's mix.
    private static let lanesHeight = CGFloat(TodayPlan.laneLimit + 1) * laneHeight
    private static let chartHeight: CGFloat = top + lanesHeight + 26
    private static let legendHeight: CGFloat = 16
    private static let labelWidth: CGFloat = 164
    /// The card's whole height, so the page can hold its place while loading.
    static let height = headerHeight + Design.Space.md + chartHeight + Design.Space.sm + legendHeight + 2 * Design.Space.card

    var body: some View {
        let lanes = colors == .project ? plan.projectLanes : plan.lanes
        VStack(alignment: .leading, spacing: 0) {
            header.frame(height: Self.headerHeight).padding(.bottom, Design.Space.md)
            HStack(alignment: .top, spacing: Design.Space.md) {
                laneLabels(lanes).frame(width: Self.labelWidth)
                chart(lanes)
            }
            .frame(height: Self.chartHeight).zIndex(1)
            legend.frame(height: Self.legendHeight).padding(.top, Design.Space.sm)
        }
        .cardBox()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.sm) {
            CardHeading(title: plan.isToday ? "今天的时间轴" : "这一天的时间轴",
                        caption: colors == .project ? Text("每个项目一条轨，左边是总时长") : Text("每类一条轨，左边是总时长"))
            Spacer(minLength: Design.Space.sm)
            if let carried = plan.carriedOver {
                Button { select(carried) } label: {
                    Text("\(model.time(carried.session.start))–\(model.time(carried.session.end)) 接着昨晚 · \(TodayFmt.long(carried.session.recorded))")
                        .monospacedDigit()
                }
                .buttonStyle(LinkButtonStyle()).font(.note).lineLimit(1)
            }
            if let row = plan.current { now(row) }
            Segmented(options: TimelineColors.allCases, selection: Binding(get: { colors }, set: choose), height: 24) { option in
                option == .project ? Text("按项目") : Text("按分类")
            }
            .accessibilityLabel("时间轴颜色")
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

    private func select(_ row: TodayPlan.Row, lane: Int? = nil) {
        withAnimation(Design.motion(Design.quick, reduced: reduceMotion)) {
            if selected == row.id, lane == nil || lane == selectedLane {
                selected = nil
            } else {
                selected = row.id
                selectedLane = lane
            }
        }
    }

    // MARK: Lane names

    /// Each lane's name and total. A category's name opens its records of the day.
    private func laneLabels(_ lanes: [TodayPlan.Lane]) -> some View {
        VStack(spacing: 0) {
            ForEach(lanes) { lane in
                let content = HStack(spacing: Design.Space.sm) {
                    Circle().fill(swatch(lane)).frame(width: 8, height: 8)
                    Text(verbatim: lane.name).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: lane.seconds < 60 ? String(localized: "<1 分") : TodayFmt.clock(lane.seconds))
                        .monospacedDigit().fontWeight(.semibold)
                }
                .font(.body).foregroundStyle(Design.ink)
                .padding(.horizontal, Design.Space.sm)
                .frame(height: Self.laneHeight)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                if colors == .category, !lane.isOther {
                    Button {
                        model.openActivities(category: lane.id, range: DateRangeSelection(kind: .day, anchor: plan.day.start))
                    } label: { content }
                    .buttonStyle(HoverRowStyle())
                } else {
                    content
                }
            }
        }
        .padding(.top, Self.top)
        .padding(.horizontal, -Design.Space.sm)
    }

    // MARK: Chart

    private var axisSeconds: TimeInterval { max(1, plan.axis.duration) }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        width * CGFloat(max(0, min(1, date.timeIntervalSince(plan.axis.start) / axisSeconds)))
    }

    private func laneY(_ index: Int) -> CGFloat { Self.top + CGFloat(index) * Self.laneHeight }

    private func chart(_ lanes: [TodayPlan.Lane]) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pointsPerSecond = width / axisSeconds
            let labelFrom = BlockLabel.minutes(pointsPerSecond: pointsPerSecond, width: { BlockLabel.noteWidth($0) })
            let bottom = laneY(max(1, lanes.count))
            let row = plan.rows.first { $0.id == selected }
            ZStack(alignment: .topLeading) {
                if plan.isToday { future(width, bottom: bottom) }
                grid(width, bottom: bottom)
                ForEach(Array(lanes.indices), id: \.self) { index in
                    RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous).fill(Design.track.opacity(0.6))
                        .frame(width: width, height: Self.markHeight)
                        .offset(y: laneY(index) + (Self.laneHeight - Self.markHeight) / 2)
                }
                ForEach(plan.gaps) { gap in away(gap, width, bottom: bottom) }
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    ForEach(TodayPlan.fold(lane.runs, gap: Double(Self.minMark / pointsPerSecond))) { run in
                        mark(run, lane: index, width, labelFrom: labelFrom)
                    }
                }
                if let row { selection(row, width, bottom: bottom) }
                ticks(width, bottom: bottom)
                if plan.isToday { nowMark(width, bottom: bottom) }
                if let row { card(row, width, y: (selectedLane.map { laneY($0 + 1) } ?? bottom) + 4) }
            }
            .frame(width: width, height: Self.chartHeight, alignment: .topLeading)
        }
    }

    private func future(_ width: CGFloat, bottom: CGFloat) -> some View {
        let nowX = x(plan.now, width) + 6
        return RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous)
            .strokeBorder(Design.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .overlay(Text("还没到").font(.note).foregroundStyle(Design.ink2))
            .frame(width: max(0, width - nowX), height: bottom - Self.top + 8)
            .offset(x: nowX, y: Self.top - 4)
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

    private func grid(_ width: CGFloat, bottom: CGFloat) -> some View {
        let ticks = hourTicks(width)
        return ZStack(alignment: .topLeading) {
            ForEach(ticks) { tick in
                Rectangle().fill(Design.line2).frame(width: 1, height: bottom - Self.top + 8).offset(x: tick.x, y: Self.top - 4)
                Text(verbatim: tick.text).font(.note).monospacedDigit().foregroundStyle(Design.ink2).fixedSize()
                    .position(x: min(max(tick.x, 22), width - 22), y: bottom + 16)
            }
        }
    }

    // MARK: Gaps

    /// Time away: hatched across every lane, with what the person said about it or a way to say it.
    private func away(_ gap: DayGap, _ width: CGFloat, bottom: CGFloat) -> some View {
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
        .frame(width: w, height: bottom - Self.top)
        .offset(x: left, y: Self.top)
        .help(Text("离开 \(TodayFmt.long(gap.interval.duration))"))
    }

    // MARK: Marks

    /// The session a run belongs to: the one holding its middle, else any it overlaps.
    private func row(at run: TodayPlan.Lane.Run) -> TodayPlan.Row? {
        let middle = run.start.addingTimeInterval(run.end.timeIntervalSince(run.start) / 2)
        return plan.rows.first { $0.session.start <= middle && middle < $0.session.end }
            ?? plan.rows.first { $0.session.start < run.end && run.start < $0.session.end }
    }

    private func dimmed(_ row: TodayPlan.Row?) -> Bool {
        guard let filter else { return false }
        guard let row else { return true }
        return filter != row.project
    }

    private func mark(_ run: TodayPlan.Lane.Run, lane: Int, _ width: CGFloat, labelFrom: Int?) -> some View {
        let left = x(run.start, width)
        let w = max(x(run.end, width) - left - 1, Self.minMark)
        let color = color(of: run)
        let session = self.row(at: run)
        let shape = RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous)
        return Button { if let session { select(session, lane: lane) } } label: {
            ZStack(alignment: .leading) {
                if run.pending {
                    // Waiting for Jev's project answer: an outline, unlike the hatch of time away.
                    shape.fill(Design.hoverFill)
                    shape.strokeBorder(Design.ink2.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                } else {
                    shape.fill(color)
                }
                if run.guessed, !run.pending { StripeOverlay().clipShape(shape) }
                // One rule for every mark (`BlockLabel`): a duration from the timeline's threshold up, in the longest form that fits.
                if let text = BlockLabel.text(run.seconds, threshold: labelFrom, available: w - 2 * BlockLabel.padding, width: { BlockLabel.noteWidth($0) }) {
                    // A guessed run's stripes would lower the ink's contrast: its label sits on a flat patch of the fill.
                    let patch = run.guessed && !run.pending
                    Text(text).font(.note.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(run.pending ? Design.ink2 : labelColor(of: run))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, patch ? 3 : BlockLabel.padding)
                        .background { if patch { RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color) } }
                        .padding(.horizontal, patch ? BlockLabel.padding - 3 : 0)
                }
            }
            .frame(width: w, height: Self.markHeight)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(dimmed(session) ? 0.2 : 1)
        .animation(Design.motion(Design.quick, reduced: reduceMotion), value: dimmed(session))
        .offset(x: left, y: laneY(lane) + (Self.laneHeight - Self.markHeight) / 2)
        .help(Text(verbatim: "\(session.map(title) ?? "") \(model.time(run.start))–\(model.time(run.end)) · \(TodayFmt.long(run.seconds))"))
        .accessibilityLabel(Text(verbatim: "\(session.map(title) ?? "") \(model.time(run.start))–\(model.time(run.end)) \(TodayFmt.long(run.seconds))"))
    }

    /// The open session, outlined across every lane.
    private func selection(_ row: TodayPlan.Row, _ width: CGFloat, bottom: CGFloat) -> some View {
        let left = x(row.session.start, width), right = x(row.session.end, width)
        return RoundedRectangle(cornerRadius: Design.Radius.mark + 3, style: .continuous)
            .strokeBorder(Design.ink.opacity(0.6), lineWidth: 1.5)
            .frame(width: max(right - left, Self.minMark) + 8, height: bottom - Self.top + 8)
            .offset(x: left - 4, y: Self.top - 4)
            .allowsHitTesting(false)
            .zIndex(3)
    }

    /// A category's colour, or a project's in "By project"; "no project" is the neutral slate.
    private func color(of run: TodayPlan.Lane.Run) -> Color {
        if colors == .project { return Design.projectColor(run.slot) }
        let category = model.resolver.categoriesByID[run.categoryID]
        return RefinedStyle.category(run.categoryID, hex: category?.colorHex ?? "#C7C7CC")
    }

    /// The ink of a mark's label: white, or the dark ink where white would not reach 4.5:1.
    private func labelColor(of run: TodayPlan.Lane.Run) -> Color {
        if colors == .project { return Design.projectLabel(run.slot) }
        let category = model.resolver.categoriesByID[run.categoryID]
        return RefinedStyle.categoryLabel(run.categoryID, hex: category?.colorHex ?? "#C7C7CC")
    }

    /// The dot beside a lane's name; the shared lane has none of its own colours.
    private func swatch(_ lane: TodayPlan.Lane) -> Color {
        if lane.isOther { return Design.ink2.opacity(0.45) }
        if colors == .project { return Design.projectColor(lane.slot) }
        return RefinedStyle.category(lane.id, hex: lane.colorHex)
    }

    /// "By project" with no project created at all: the legend says how to make one.
    private var noProjectsYet: Bool { colors == .project && model.projects.isEmpty && !plan.rows.contains { $0.slot != nil } }

    /// Some session in "By project" mode is still waiting for Jev.
    private var anyPending: Bool { colors == .project && plan.rows.contains { $0.projectPending } }

    private func ticks(_ width: CGFloat, bottom: CGFloat) -> some View {
        Canvas { context, _ in
            let color = Design.interruption
            for episode in plan.interruptions {
                let row = plan.rows.first { episode.start >= $0.session.start && episode.start < $0.session.end }
                let faded = dimmed(row)
                let origin = CGPoint(x: x(episode.start, width) - 1, y: bottom + 1)
                context.fill(Path(roundedRect: CGRect(origin: origin, size: CGSize(width: 2, height: 6)), cornerRadius: 1),
                             with: .color(color.opacity(faded ? 0.25 : 1)))
            }
        }
        .frame(width: width, height: Self.chartHeight).allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func nowMark(_ width: CGFloat, bottom: CGFloat) -> some View {
        let nowX = x(plan.now, width)
        return ZStack(alignment: .topLeading) {
            Text(model.time(plan.now)).font(.note.weight(.semibold)).monospacedDigit().foregroundStyle(Design.ink).fixedSize()
                .position(x: min(max(nowX, 24), width - 24), y: 8)
            RoundedRectangle(cornerRadius: 1).fill(Design.ink).frame(width: 2, height: bottom - Self.top + 10)
                .offset(x: nowX - 1, y: Self.top - 6)
        }.allowsHitTesting(false)
    }

    // MARK: The card a mark opens

    private func title(_ row: TodayPlan.Row) -> String {
        model.sessionTitle(row.session) ?? row.project
            ?? row.session.apps.prefix(2).map(\.name).joined(separator: String(localized: "、"))
    }

    private func card(_ row: TodayPlan.Row, _ width: CGFloat, y: CGFloat) -> some View {
        let cardWidth: CGFloat = 244
        let center = x(row.session.start.addingTimeInterval(row.session.duration / 2), width)
        let left = min(max(center - cardWidth / 2, 0), max(0, width - cardWidth))
        let category = model.resolver.categoriesByID[row.session.categoryID]?.name ?? String(localized: "未分类")
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.sm) {
                Circle().fill(colors == .project ? Design.projectColor(row.slot)
                              : RefinedStyle.category(row.session.categoryID, hex: model.resolver.categoriesByID[row.session.categoryID]?.colorHex ?? "#C7C7CC"))
                    .frame(width: 8, height: 8)
                Text(row.guessed ? String(localized: "\(title(row))（推测）") : title(row))
                    .font(.body.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button { select(row) } label: {
                    Image(systemName: "xmark").font(.note.weight(.semibold)).foregroundStyle(Design.ink2)
                        .frame(width: 20, height: 20).background(Design.hoverFill, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("关闭")
            }
            Text(verbatim: "\(model.time(row.session.start))–\(model.time(row.session.end)) · \(TodayFmt.long(row.session.recorded)) · \(category)")
                .font(.note).monospacedDigit().foregroundStyle(Design.ink2).lineLimit(2)
            if colors == .project {
                Text(row.projectPending ? String(localized: "项目：判定中…")
                     : String(localized: "项目：\(row.project ?? String(localized: "没有项目"))"))
                    .font(.note).foregroundStyle(Design.ink2).lineLimit(1)
            }
            Text(row.interruptions > 0 ? String(localized: "切换 \(row.switches) 次 · 打断 \(row.interruptions) 次")
                 : String(localized: "切换 \(row.switches) 次 · 没有打断"))
                .font(.note).monospacedDigit().foregroundStyle(Design.ink2)
            Button("在活动里打开 ›") { open(row) }.buttonStyle(LinkButtonStyle()).font(.note).padding(.top, 2)
        }
        .padding(Design.Space.md).frame(width: cardWidth, alignment: .leading)
        .floatingCard()
        .offset(x: left, y: y)
        .zIndex(6)
        .transition(.opacity)
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: Design.Space.lg) {
            if noProjectsYet {
                HStack(spacing: Design.Space.sm) {
                    Text("还没有项目。去创建一个，或看看 TimeSink 的推荐。").lineLimit(1)
                    Button("去项目 ›") { model.organizationTab = .projects; model.sidebarSelection = .organization }.buttonStyle(LinkButtonStyle())
                }
            } else if anyPending {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Design.ink2.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: 14, height: 10)
                    Text("Jev 正在判定项目…")
                }.fixedSize()
            }
            if colors == .project, !noProjectsYet {
                Button("管理项目 ›") { model.organizationTab = .projects; model.sidebarSelection = .organization }
                    .buttonStyle(LinkButtonStyle()).fixedSize()
            }
            HStack(spacing: 6) {
                HatchFill(away: true).frame(width: 14, height: 10).clipShape(RoundedRectangle(cornerRadius: 2))
                Text("离开")
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(Design.interruption).frame(width: 2, height: 9)
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
