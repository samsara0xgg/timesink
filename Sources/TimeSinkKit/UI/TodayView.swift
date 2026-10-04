import SwiftUI
import AppKit

/// 今天: one glance at the day. A sentence and three numbers, the day as a
/// timeline of sessions (with what is going on now in its heading), then
/// where the time went by category and by project, and what is waiting for
/// an answer.
///
/// All of it comes from one `TodayPlan`, built off the main actor; `body`
/// only lays it out. Loading and empty days keep the same frame, so nothing
/// below the header moves when the plan arrives.
struct TodayView: View {
    let model: AppModel
    let activities: ActivitiesModel
    @State private var today = TodayModel()
    @State private var selected: Date?
    @State private var filter: ProjectFilter = nil
    /// What the person chose for the timeline's colours; empty until they do.
    @AppStorage("todayTimelineColors") private var chosenColors = ""
    /// Whether the last plan had a project: the loading frame keeps its cards.
    @AppStorage("todayHadProjects") private var hadProjects = true

    private struct RefreshKey: Equatable { let version: Int; let offset: Int }
    private var offset: Int { model.todayDayOffset }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 2 * Design.Space.page
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.lg) {
                    header(width: width)
                    if let error = today.loadError {
                        HStack(spacing: Design.Space.sm) {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Design.ink2)
                            Button("重试") { Task { await refresh() } }.buttonStyle(PillButtonStyle())
                        }
                    }
                    if let plan = today.plan, !plan.hasRecords {
                        empty
                    } else {
                        cards(today.plan, wide: width >= PageLayout.wideWidth)
                    }
                }
                .pagePadding()
            }
            .scrollIndicators(.never)
        }
        .background(WorkspaceBackground())
        .pageTask(id: RefreshKey(version: model.dataVersion, offset: offset)) { await refresh() }
        .whilePageShown {
            // The now line and the headline move with the clock; nothing else
            // does while nothing is written. A past day never moves.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if offset == 0 { await refresh() }
            }
        }
        .onChange(of: offset) { _, _ in selected = nil; filter = nil }
        .onChange(of: today.plan.map(hasProjects)) { _, value in if let value { hadProjects = value } }
    }

    private func refresh() async { await today.refresh(model: model, dayOffset: offset) }

    // MARK: Layout

    private func header(width: CGFloat) -> some View {
        PageHeader(sentence: sentence, stats: stats, width: width) {
            DayStepper(model: model)
        } actions: {
            if offset == 0 { FocusStartButton(model: model) }
        }
    }

    /// The same cards whether the plan is here or not: an empty card holds
    /// the place of one still loading.
    @ViewBuilder private func cards(_ plan: TodayPlan?, wide: Bool) -> some View {
        Group {
            if let plan {
                TodayTimelineCard(plan: plan, model: model, filter: filter, colors: colors(for: plan),
                                  choose: { chosenColors = $0.rawValue }, selected: $selected, open: open)
            } else { placeholder }
        }
        .frame(height: TodayTimelineCard.height)
        let categories = Group {
            if let plan { TodayCategoriesCard(plan: plan, model: model) } else { placeholder }
        }
        let projects = Group {
            if let plan { TodayProjectsCard(plan: plan, filter: $filter, selected: $selected) } else { placeholder }
        }
        // With no project to show, its card gives its width to the other two.
        let showsProjects = plan.map(hasProjects) ?? hadProjects
        let todos = Group {
            if let plan { TodayTodosCard(plan: plan, model: model, changed: { Task { await refresh() } }, start: startFocus) } else { placeholder }
        }
        if !showsProjects {
            HStack(alignment: .top, spacing: Design.Space.lg) { categories; todos }
                .frame(minHeight: 240).fixedSize(horizontal: false, vertical: true)
        } else if wide {
            HStack(alignment: .top, spacing: Design.Space.lg) {
                categories; projects; todos
            }
            .frame(minHeight: 240).fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: Design.Space.lg) { categories; projects }
                .frame(minHeight: 240).fixedSize(horizontal: false, vertical: true)
            todos
        }
    }

    private func hasProjects(_ plan: TodayPlan) -> Bool { plan.projects.contains { $0.name != nil } }

    /// The chosen colours, else by project when any was recognised.
    private func colors(for plan: TodayPlan) -> TimelineColors {
        TimelineColors(rawValue: chosenColors) ?? (hasProjects(plan) ? .project : .category)
    }

    private var placeholder: some View {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).designCard()
            .accessibilityLabel("正在读取今天的记录")
    }

    private var empty: some View {
        ContentUnavailableView {
            if offset == 0 { Label("今天，还没有记录", systemImage: "sun.max") } else { Label("这一天没有记录", systemImage: "sun.max") }
        } description: {
            Text(model.trackingPaused ? "记录已暂停。继续后，新的活动会出现在这里。" : "使用 Mac 后，应用和网站活动会出现在这里。空档不会计入总时长。")
        } actions: {
            if model.trackingPaused { Button("继续记录") { model.resumeTracking() } }
            else if offset == 0 { SettingsLink { Text("检查记录与权限设置") } }
        }
        .frame(maxWidth: .infinity, minHeight: TodayTimelineCard.height + 240 + Design.Space.lg).designCard()
    }

    // MARK: Header

    /// "已经投入 4 小时，多在求职和 TimeSink 上。"
    private var sentence: Text {
        guard let plan = today.plan else { return Text(" ") }
        if plan.engaged < 60 {
            return plan.isToday ? Text("还没有投入的时间。") : Text("这一天没有投入的时间。")
        }
        let time = Text(TodayFmt.long(plan.engaged)).monospacedDigit()
        // Up to two places the time went: projects, else categories.
        let named = plan.projects.compactMap(\.name)
        let places = named.isEmpty ? plan.categories.prefix(2).map(\.name) : Array(named.prefix(2))
        if places.count >= 2 {
            let a = places[0], b = places[1]
            return plan.isToday ? Text("已经投入 \(time)，多在\(a)和\(b)上。") : Text("投入了 \(time)，多在\(a)和\(b)上。")
        } else if let a = places.first {
            return plan.isToday ? Text("已经投入 \(time)，多在\(a)上。") : Text("投入了 \(time)，多在\(a)上。")
        }
        return plan.isToday ? Text("已经投入 \(time)。") : Text("投入了 \(time)。")
    }

    /// 已记录, 打断, 评分. 投入 is the sentence.
    private var stats: [StripStat] {
        guard let plan = today.plan else {
            return [StripStat(id: 0, label: "已记录", value: "—"), StripStat(id: 1, label: "打断", value: "—")]
                + (model.showScore ? [StripStat(id: 2, label: "评分", value: "—")] : [])
        }
        var recordedNote = String(localized: "投入占 \(Int((plan.engaged / max(1, plan.total) * 100).rounded()))%")
        if let yesterday = today.yesterdayTotal {
            let delta = Format.minuteDelta(plan.total, yesterday)
            recordedNote = delta >= 0 ? String(localized: "比昨天此时多 \(Format.chineseDuration(delta))")
                : String(localized: "比昨天此时少 \(Format.chineseDuration(-delta))")
        }
        let count = plan.interruptions.count
        let interruptionNote: String = plan.messiest.map { String(localized: "\(model.time($0.session.start)) 那段占 \($0.interruptions) 次") }
            ?? (count == 0 ? String(localized: "没有被打断") : "")
        var result = [
            StripStat(id: 0, label: "已记录", value: TodayFmt.clock(plan.total), note: recordedNote),
            StripStat(id: 1, label: "打断", value: String(localized: "\(count) 次"), note: interruptionNote)
        ]
        if model.showScore {
            result.append(StripStat(id: 2, label: "评分", value: plan.pulse.map { "\($0)" } ?? "—",
                                    note: plan.isToday && today.streakDays > 0 ? String(localized: "连续 \(today.streakDays) 天 ≥ 70") : ""))
        }
        return result
    }

    // MARK: Actions

    /// 在活动里打开: that day's Activities page with the session selected.
    private func open(_ row: TodayPlan.Row) {
        model.activitySearch = ""
        model.openActivities(category: nil, range: DateRangeSelection(kind: .day, anchor: row.session.start))
        activities.pendingSession = row.session.start
    }

    private func startFocus(_ minutes: Int) {
        try? model.focus?.start(minutes: minutes)
    }
}

// MARK: - Projects

private struct TodayProjectsCard: View {
    let plan: TodayPlan
    @Binding var filter: ProjectFilter
    @Binding var selected: Date?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let collapsedRows = 4

    var body: some View {
        // Time with no named project stays under its category, not here.
        let all = plan.projects.filter { $0.name != nil }
        let overflow = all.count > Self.collapsedRows
        let shown = expanded || !overflow ? all : Array(all.prefix(Self.collapsedRows))
        VStack(alignment: .leading, spacing: Design.Space.sm) {
            CardHeading(title: "项目", caption: all.isEmpty ? nil : Text("点一下只看它"))
                .help("项目从窗口标题里的仓库名认出来；认不出的按前后时间推测，会标出来让你确认。")
            if all.isEmpty {
                // The same empty state as 要你处理 beside it; how projects are found is in the help.
                Label("还没认出项目", systemImage: "folder").foregroundStyle(Design.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 0) { ForEach(shown) { row($0) } }
            if overflow {
                Button {
                    withAnimation(Design.motion(Design.layout, reduced: reduceMotion)) { expanded.toggle() }
                } label: {
                    if expanded { Text("收起") } else { Text("还有 \(all.count - shown.count) 个项目 ›") }
                }
                .buttonStyle(LinkButtonStyle()).font(.note)
            }
        }
        .cardBox()
    }

    private func isOn(_ project: TodayPlan.Project) -> Bool { filter == .some(project.name) }

    private func row(_ project: TodayPlan.Project) -> some View {
        let color = Design.projectColor(project.slot)
        let dimmed = filter != nil && !isOn(project)
        return Button {
            withAnimation(Design.motion(Design.quick, reduced: reduceMotion)) {
                filter = isOn(project) ? nil : .some(project.name)
                selected = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Design.Space.sm) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(project.name ?? String(localized: "未归入项目")).font(.body.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: TodayFmt.clock(project.seconds)).font(.body.weight(.semibold)).monospacedDigit()
                }
                track(project, color: color)
                Text(verbatim: note(project)).font(.note).foregroundStyle(Design.ink2).lineLimit(1)
            }
            .padding(.horizontal, Design.Space.sm).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn(project) ? Design.selectedFill : .clear, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            .opacity(dimmed ? 0.4 : 1)
        }
        .buttonStyle(HoverRowStyle())
        .accessibilityAddTraits(isOn(project) ? .isSelected : [])
    }

    /// The day in a hairline: where this project's sessions sit between midnight and midnight.
    private func track(_ project: TodayPlan.Project, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Design.track)
                ForEach(plan.rows.filter { project.sessions.contains($0.id) }) { row in
                    let start = row.session.start.timeIntervalSince(plan.day.start) / plan.day.duration
                    let length = max(row.session.duration / plan.day.duration, 0.006)
                    Capsule().fill(color)
                        .overlay { if row.guessed { StripeOverlay().clipShape(Capsule()) } }
                        .frame(width: max(2, proxy.size.width * length)).offset(x: proxy.size.width * start)
                }
            }
        }.frame(height: 6).accessibilityHidden(true)
    }

    private func note(_ project: TodayPlan.Project) -> String {
        let sessions = String(localized: "\(project.sessions.count) 段")
        if project.guessedCount > 0 { return String(localized: "\(sessions) · \(project.guessedCount) 段是推测的") }
        if project.carriedSeconds > 0 { return String(localized: "\(sessions) · 其中 \(TodayFmt.long(project.carriedSeconds)) 接着昨晚") }
        return project.interruptions > 0 ? String(localized: "\(sessions) · 打断 \(project.interruptions) 次") : String(localized: "\(sessions) · 没有打断")
    }
}

// MARK: - Categories

private struct TodayCategoriesCard: View {
    let plan: TodayPlan
    let model: AppModel

    private static let shownRows = 6

    private func color(_ category: TodayPlan.CategoryRow) -> Color { RefinedStyle.category(category.id, hex: category.colorHex) }

    var body: some View {
        let top = plan.categories.first?.seconds ?? 1
        VStack(alignment: .leading, spacing: Design.Space.md) {
            let share = Text("投入 \(Int((plan.engaged / max(1, plan.total) * 100).rounded()))%")
            let link = Button("分类与规则 ›") { model.sidebarSelection = .organization }.buttonStyle(LinkButtonStyle()).font(.note)
            // Narrow, the caption goes first, then the link: the title never wraps.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { CardHeading(title: "时间去了哪", caption: share); Spacer(minLength: Design.Space.sm); link }
                HStack(alignment: .firstTextBaseline) { CardHeading(title: "时间去了哪"); Spacer(minLength: Design.Space.sm); link }
                CardHeading(title: "时间去了哪")
            }
            GeometryReader { proxy in
                let usable = proxy.size.width - CGFloat(max(0, plan.categories.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(plan.categories) { category in
                        color(category).frame(width: max(2, usable * category.seconds / max(1, plan.total)))
                    }
                }
            }
            .frame(height: 8).clipShape(Capsule()).accessibilityHidden(true)
            VStack(spacing: 0) {
                ForEach(plan.categories.prefix(Self.shownRows)) { category in
                    Button {
                        model.openActivities(category: category.id, range: DateRangeSelection(kind: .day, anchor: plan.day.start))
                    } label: {
                        HStack(spacing: Design.Space.sm) {
                            Circle().fill(color(category)).frame(width: 8, height: 8)
                            Text(category.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Capsule().fill(Design.track).frame(width: 72, height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(color(category)).frame(width: max(3, 72 * category.seconds / max(1, top)), height: 4)
                                }
                            Text(verbatim: category.seconds < 60 ? String(localized: "<1 分") : TodayFmt.clock(category.seconds))
                                .monospacedDigit().foregroundStyle(Design.ink2).frame(width: Design.durationWidth, alignment: .trailing)
                        }
                        .padding(.horizontal, Design.Space.sm)
                        .frame(height: Design.rowHeight).contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                    .help("\(category.name) · \(Format.duration(category.seconds))\(category.engaged ? String(localized: " · 算投入") : "")")
                }
                if plan.categories.count > Self.shownRows {
                    let rest = plan.categories.dropFirst(Self.shownRows)
                    Text("其他 \(rest.count) 类 · \(TodayFmt.clock(rest.reduce(0) { $0 + $1.seconds }))")
                        .font(.note).foregroundStyle(Design.ink2).padding(.horizontal, Design.Space.sm).padding(.top, Design.Space.xs)
                }
            }
            .padding(.horizontal, -Design.Space.sm)
        }
        .cardBox()
    }
}

// MARK: - To do

/// 要你处理: what the page cannot settle by itself.
private struct TodayTodosCard: View {
    let plan: TodayPlan
    let model: AppModel
    let changed: () -> Void
    let start: (Int) -> Void
    @State private var filling: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.sm) {
            CardHeading(title: "要你处理", caption: plan.todos.isEmpty ? nil : Text("\(plan.todos.count) 件"))
            if plan.todos.isEmpty {
                Label("都处理好了", systemImage: "checkmark.circle").foregroundStyle(Design.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(plan.todos) { todo in row(todo).transition(.opacity) }
                }
            }
        }
        .animation(Design.motion(Design.layout, reduced: reduceMotion), value: plan.todos.map(\.id))
        .cardBox()
    }

    private struct Presentation {
        let symbol: String
        let title: String
        let note: String
        let action: LocalizedStringKey
    }

    private func presentation(_ todo: TodayPlan.Todo) -> Presentation {
        switch todo {
        case .fill(let gap):
            return Presentation(symbol: "hourglass",
                                title: String(localized: "补记 \(model.time(gap.start))–\(model.time(gap.end))"),
                                note: String(localized: "离开了 \(Format.chineseDuration(gap.duration))，是吃饭还是开会？"), action: "补记")
        case .confirm(let count, let projects):
            return Presentation(symbol: "questionmark",
                                title: String(localized: "确认 \(count) 段的项目"),
                                note: String(localized: "标题里没有项目名，我猜是 \(projects.joined(separator: String(localized: "、")))"), action: "确认")
        case .classify(let seconds, let names):
            return Presentation(symbol: "tag",
                                title: String(localized: "\(Format.chineseDuration(seconds))还没分类"),
                                note: names.joined(separator: String(localized: "、")), action: "去分类")
        case .focus(let day, let minutes):
            let note = day.flatMap { day in minutes.map { String(localized: "最近一次是 \(day.formatted(.dateTime.month().day().locale(model.textLocale))) · \($0) 分钟") } }
                ?? String(localized: "选一个时长，开始计时")
            return Presentation(symbol: "scope", title: String(localized: "今天还没专注过"), note: note, action: "开始")
        }
    }

    private func row(_ todo: TodayPlan.Todo) -> some View {
        let p = presentation(todo)
        return HStack(spacing: Design.Space.md) {
            Image(systemName: p.symbol).foregroundStyle(Design.iconInk)
                .frame(width: 28, height: 28).background(Design.hoverFill, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: p.title).font(.body.weight(.semibold)).lineLimit(1)
                Text(verbatim: p.note).font(.note).foregroundStyle(Design.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            action(todo, p)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Design.line2).frame(height: 1) }
    }

    @ViewBuilder private func action(_ todo: TodayPlan.Todo, _ p: Presentation) -> some View {
        switch todo {
        case .fill(let gap):
            Button(p.action) { filling = todo.id }
                .buttonStyle(PillButtonStyle())
                .help("补记画成虚线框，和电脑上的时间分开统计，不计入评分。")
                .popover(isPresented: Binding(get: { filling == todo.id }, set: { if !$0 { filling = nil } }), arrowEdge: .leading) {
                    AwayPrompt(model: model, interval: gap, manual: true) { filling = nil }.frame(width: 316).padding(4)
                }
        case .confirm:
            Button(p.action) {
                for row in plan.guessedRows { if let project = row.project { model.assignSession(row.session, toProject: project) } }
                changed()
            }.buttonStyle(PillButtonStyle())
        case .classify:
            Button(p.action) { model.organizationTab = .uncategorized; model.sidebarSelection = .organization }.buttonStyle(PillButtonStyle())
        case .focus:
            Menu {
                ForEach(FocusPresets.minutes, id: \.self) { minutes in
                    Button("\(minutes) 分钟") { start(minutes) }.disabled(model.focus == nil || model.focus?.running != nil)
                }
            } label: { Text(p.action) }
            .menuStyle(.button).buttonStyle(PillButtonStyle()).menuIndicator(.hidden).fixedSize()
        }
    }
}
