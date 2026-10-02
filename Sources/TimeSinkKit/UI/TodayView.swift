import SwiftUI
import AppKit

/// 今天: one glance at the day. A headline, four numbers, what is going on
/// now, the day as a timeline of sessions, where the time went by project
/// and by category, and what is waiting for an answer.
///
/// All of it comes from one `TodayPlan`, built off the main actor; `body`
/// only lays it out.
struct TodayView: View {
    let model: AppModel
    let activities: ActivitiesModel
    @State private var today = TodayModel()
    @State private var selected: Date?
    @State private var filter: ProjectFilter = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct RefreshKey: Equatable { let version: Int; let offset: Int }
    private var offset: Int { model.todayDayOffset }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content(width: geometry.size.width - 2 * Design.Space.page, height: geometry.size.height)
                    .padding(.horizontal, Design.Space.page).padding(.top, 8).padding(.bottom, 24)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                    .frame(maxWidth: 1600).frame(maxWidth: .infinity)
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
    }

    private func refresh() async { await today.refresh(model: model, dayOffset: offset) }

    // MARK: Layout

    @ViewBuilder private func content(width: CGFloat, height: CGFloat) -> some View {
        if let plan = today.plan {
            if plan.hasRecords {
                if width >= 1104 { wide(plan, height: height) } else { narrow(plan) }
            } else {
                empty(plan)
            }
        } else if today.loadError == nil {
            loading
        }
        if let error = today.loadError {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("重试") { Task { await refresh() } }
            }.font(.callout).padding(.top, 12)
        }
    }

    private func wide(_ plan: TodayPlan, height: CGFloat) -> some View {
        VStack(spacing: Design.Space.lg) {
            HStack(alignment: .center, spacing: Design.Space.xxl) {
                TodayHeadline(plan: plan, model: model).frame(maxWidth: .infinity, alignment: .leading)
                TodayStats(plan: plan, model: model, today: today).frame(width: 600)
            }.frame(height: 92)
            HStack(alignment: .top, spacing: Design.Space.lg) {
                nowCard(plan).frame(width: 392, height: 256)
                timeline(plan).frame(height: 256)
            }
            HStack(alignment: .top, spacing: Design.Space.lg) {
                projectsCard(plan).frame(width: 392)
                categoriesCard(plan).frame(width: 400)
                todosCard(plan).frame(maxWidth: .infinity)
            }
            // What is left under the first two rows, never less than 400: a
            // card's long list scrolls inside it instead of stretching the page.
            .frame(height: max(400, height - 8 - 92 - 256 - 3 * Design.Space.lg - 24))
        }
    }

    private func narrow(_ plan: TodayPlan) -> some View {
        VStack(spacing: Design.Space.lg) {
            VStack(alignment: .leading, spacing: Design.Space.md) {
                TodayHeadline(plan: plan, model: model)
                TodayStats(plan: plan, model: model, today: today).frame(height: 84)
            }.frame(maxWidth: .infinity, alignment: .leading)
            timeline(plan).frame(height: 256)
            Grid(horizontalSpacing: Design.Space.lg, verticalSpacing: Design.Space.lg) {
                GridRow { nowCard(plan).frame(height: 256); projectsCard(plan).frame(height: 256) }
                GridRow { categoriesCard(plan).frame(height: 400); todosCard(plan).frame(height: 400) }
            }
        }
    }

    private func empty(_ plan: TodayPlan) -> some View {
        ContentUnavailableView {
            if offset == 0 { Label("今天，还没有记录", systemImage: "sun.max") } else { Label("这一天没有记录", systemImage: "sun.max") }
        } description: {
            Text(model.trackingPaused ? "记录已暂停。继续后，新的活动会出现在这里。" : "使用 Mac 后，应用和网站活动会出现在这里。空档不会计入总时长。")
        } actions: {
            if model.trackingPaused { Button("继续记录") { model.resumeTracking() } }
            else if offset == 0 { SettingsLink { Text("检查记录与权限设置") } }
        }
        .frame(maxWidth: .infinity, minHeight: 360).designCard().padding(.top, 8)
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: Design.Space.lg) {
            Text("正在读取今天的记录").foregroundStyle(Design.ink3)
            ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Design.track).frame(height: 96) }
        }
        .padding(.top, 8).accessibilityLabel("正在读取今天的记录")
    }

    // MARK: Cards

    private func timeline(_ plan: TodayPlan) -> some View {
        TodayTimelineCard(plan: plan, model: model, filter: filter, selected: $selected, open: open)
            .revealOnce(index: 3)
    }

    private func nowCard(_ plan: TodayPlan) -> some View {
        TodayNowCard(plan: plan, model: model, open: open, start: startFocus).revealOnce(index: 2)
    }

    private func projectsCard(_ plan: TodayPlan) -> some View {
        TodayProjectsCard(plan: plan, filter: $filter, selected: $selected).revealOnce(index: 4)
    }

    private func categoriesCard(_ plan: TodayPlan) -> some View {
        TodayCategoriesCard(plan: plan, model: model).revealOnce(index: 5)
    }

    private func todosCard(_ plan: TodayPlan) -> some View {
        TodayTodosCard(plan: plan, model: model, changed: { Task { await refresh() } }, start: startFocus).revealOnce(index: 6)
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

// MARK: - Headline and numbers

/// "已经投入 4 小时，多在求职和 TimeSink 上。" with the projects in their colours.
private struct TodayHeadline: View {
    let plan: TodayPlan
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var subtitle: String {
        plan.isToday ? String(localized: "到 \(model.time(plan.now)) 为止") : String(localized: "整天的记录")
    }

    /// Up to two places the time went: projects, else categories.
    private var places: [(name: String, color: Color)] {
        let projects = plan.projects.compactMap { project in project.name.map { ($0, Design.projectColor(project.slot)) } }
        if !projects.isEmpty { return Array(projects.prefix(2)) }
        return plan.categories.prefix(2).map { ($0.name, RefinedStyle.category($0.id, hex: $0.colorHex)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subtitle).font(.num(13)).foregroundStyle(Design.ink2)
            headline
                .font(.system(size: 28, weight: scheme == .dark ? .semibold : .bold)).tracking(-0.4)
                .foregroundStyle(Design.ink).lineLimit(2).minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .revealOnce(index: 0)
    }

    @ViewBuilder private var headline: some View {
        let places = places
        if plan.engaged < 60 {
            if plan.isToday { Text("还没有投入的时间。") } else { Text("这一天没有投入的时间。") }
        } else {
            let time = Text(TodayFmt.long(plan.engaged)).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
            if places.count >= 2 {
                let a = place(places[0]), b = place(places[1])
                if plan.isToday { Text("已经投入 \(time)，多在\(a)和 \(b) 上。") } else { Text("投入了 \(time)，多在\(a)和 \(b) 上。") }
            } else if let first = places.first {
                let a = place(first)
                if plan.isToday { Text("已经投入 \(time)，多在\(a)上。") } else { Text("投入了 \(time)，多在\(a)上。") }
            } else {
                if plan.isToday { Text("已经投入 \(time)。") } else { Text("投入了 \(time)。") }
            }
        }
    }

    private func place(_ place: (name: String, color: Color)) -> Text {
        Text(verbatim: place.name).foregroundColor(place.color)
    }
}

/// 已记录, 投入, 打断, 评分: four numbers on one card.
private struct TodayStats: View {
    let plan: TodayPlan
    let model: AppModel
    let today: TodayModel

    private struct Stat: Identifiable {
        let id: Int
        let label: LocalizedStringKey
        let value: String
        let note: String
        let color: Color
    }

    private var stats: [Stat] {
        var recordedNote = ""
        if let yesterday = today.yesterdayTotal {
            let delta = Format.minuteDelta(plan.total, yesterday)
            recordedNote = delta >= 0 ? String(localized: "比昨天此时多 \(Format.chineseDuration(delta))")
                : String(localized: "比昨天此时少 \(Format.chineseDuration(-delta))")
        } else if let first = plan.firstRecord {
            recordedNote = String(localized: "\(model.time(first)) 开始")
        }
        let share = Int((plan.engaged / max(1, plan.total) * 100).rounded())
        let count = plan.interruptions.count
        let interruptionNote: String
        if let worst = plan.messiest {
            interruptionNote = String(localized: "\(model.time(worst.session.start)) 那段占 \(worst.interruptions) 次")
        } else {
            interruptionNote = count == 0 ? String(localized: "没有被打断") : ""
        }
        var result = [
            Stat(id: 0, label: "已记录", value: TodayFmt.clock(plan.total), note: recordedNote, color: Design.ink),
            Stat(id: 1, label: "投入", value: TodayFmt.clock(plan.engaged), note: String(localized: "占 \(share)%"), color: Design.accentInk),
            Stat(id: 2, label: "打断", value: String(localized: "\(count) 次"), note: interruptionNote, color: Design.interruption)
        ]
        if model.showScore {
            result.append(Stat(id: 3, label: "评分", value: plan.pulse.map { "\($0)" } ?? "—",
                               note: plan.isToday && today.streakDays > 0 ? String(localized: "连续 \(today.streakDays) 天 ≥ 70") : "",
                               color: Design.ink))
        }
        return result
    }

    var body: some View {
        let stats = stats
        HStack(spacing: 0) {
            ForEach(stats) { stat in
                HStack(spacing: 0) {
                    if stat.id > 0 { Rectangle().fill(Design.line).frame(width: 1, height: 52) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stat.label).font(.system(size: 12)).foregroundStyle(Design.ink3)
                        Text(verbatim: stat.value).font(.num(22, .bold)).foregroundStyle(stat.color)
                            .glowInDark(stat.color, radius: 9, strength: 0.35)
                            .refinedNumberMotion(stat.value)
                        Text(verbatim: stat.note).font(.num(11)).foregroundStyle(Design.ink3).lineLimit(1)
                    }
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 6).frame(maxHeight: .infinity)
        .designCard(radius: Design.Radius.strip)
        .revealOnce(index: 1)
    }
}

// MARK: - Now

private struct TodayNowCard: View {
    let plan: TodayPlan
    let model: AppModel
    let open: (TodayPlan.Row) -> Void
    let start: (Int) -> Void

    /// The suggestion on the button: the first preset of 45 minutes or more.
    private static let suggested = 45

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let row = plan.current { content(row) }
        }
        .padding(.horizontal, Design.Space.xl).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
    }

    @ViewBuilder private func content(_ row: TodayPlan.Row) -> some View {
        let live = plan.currentIsLive
        HStack(spacing: 8) {
            Circle().fill(live ? Design.live : Design.ink3).frame(width: 8, height: 8)
                .background(Circle().fill(live ? Design.liveHalo : .clear).frame(width: 16, height: 16))
            Text(heading(live: live)).cardTitle()
            Text(live ? String(localized: "\(model.time(row.session.start)) 开始，还在继续")
                 : String(localized: "\(model.time(row.session.start))–\(model.time(row.session.end))"))
                .font(.num(12)).foregroundStyle(Design.ink3).lineLimit(1)
        }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: title(row)).font(.system(size: 24, weight: .bold)).foregroundStyle(Design.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(verbatim: TodayFmt.long(row.session.recorded)).font(.num(22, .bold)).foregroundStyle(Design.ink2).lineLimit(1)
                .refinedNumberMotion(TodayFmt.long(row.session.recorded))
        }
        HStack(spacing: 6) {
            ForEach(row.session.apps.prefix(3), id: \.bundleID) { app in
                Text(verbatim: "\(app.name) \(TodayFmt.long(app.seconds))").font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(Design.ink).padding(.horizontal, 9).frame(height: 24)
                    .background(Design.chip, in: Capsule())
                    .overlay(Capsule().strokeBorder(Design.pillRing, lineWidth: 0.5))
            }
        }
        interruptionBanner(row)
        Spacer(minLength: 0)
        HStack(spacing: 8) {
            if plan.isToday, model.focus?.running == nil {
                Button("接下来专注 \(Self.suggested) 分钟") { start(Self.suggested) }
                    .buttonStyle(AccentButtonStyle()).disabled(model.focus == nil)
            }
            Button("看这一段") { open(row) }.buttonStyle(PillButtonStyle(height: 32, font: .system(size: 13)))
        }
    }

    private func heading(live: Bool) -> LocalizedStringKey {
        live ? "现在" : plan.isToday ? "最近一段" : "最后一段"
    }

    private func title(_ row: TodayPlan.Row) -> String {
        model.sessionTitle(row.session) ?? row.project
            ?? row.session.apps.prefix(2).map(\.name).joined(separator: String(localized: "、"))
    }

    private func interruptionBanner(_ row: TodayPlan.Row) -> some View {
        let count = row.interruptions
        let busiest = plan.messiest?.id == row.id
        let count1 = Text(verbatim: "\(count)").font(.num(13, .bold)).foregroundColor(Design.interruption)
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if count == 0 { Text("这一段没有被打断，切换 \(row.switches) 次。") }
                else if busiest { Text("这一段被打断 \(count1) 次，切换 \(row.switches) 次，是今天最乱的一段。") }
                else { Text("这一段被打断 \(count1) 次，切换 \(row.switches) 次。") }
            }
            .font(.system(size: 13)).foregroundStyle(Design.ink).fixedSize(horizontal: false, vertical: true)
            if count > 0 {
                GeometryReader { proxy in
                    ForEach(plan.interruptions.filter { $0.start >= row.session.start && $0.start < row.session.end }, id: \.id) { episode in
                        let fraction = episode.start.timeIntervalSince(row.session.start) / max(1, row.session.duration)
                        RoundedRectangle(cornerRadius: 1).fill(Design.interruption).frame(width: 3, height: 8)
                            .offset(x: proxy.size.width * fraction - 1.5)
                    }
                }.frame(height: 8).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(count == 0 ? Design.liveHalo : Design.interruptionSoft, in: RoundedRectangle(cornerRadius: Design.Radius.well, style: .continuous))
    }
}

// MARK: - Projects

private struct TodayProjectsCard: View {
    let plan: TodayPlan
    @Binding var filter: ProjectFilter
    @Binding var selected: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("项目").cardTitle()
                Text("点一下只看它").font(.system(size: 12)).foregroundStyle(Design.ink3)
            }.padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(plan.projects) { project in row(project) }
                }
            }
            .scrollIndicators(.never).scrollBounceBehavior(.basedOnSize)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            Text("项目从窗口标题里的仓库名认出来；认不出的按前后时间推测，会标出来让你确认。")
                .font(.system(size: 11)).foregroundStyle(Design.ink3).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
        .padding(.horizontal, Design.Space.xl).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
    }

    private func isOn(_ project: TodayPlan.Project) -> Bool { filter == .some(project.name) }

    private func row(_ project: TodayPlan.Project) -> some View {
        let color = Design.projectColor(project.slot)
        let dimmed = filter != nil && !isOn(project)
        return Button {
            withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) {
                filter = isOn(project) ? nil : .some(project.name)
                selected = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(project.name ?? String(localized: "未归入项目")).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(project.sessions.count) 段").font(.num(12)).foregroundStyle(Design.ink3)
                    Text(verbatim: TodayFmt.clock(project.seconds)).font(.num(15, .bold)).padding(.leading, 8)
                }
                track(project, color: color)
                Text(verbatim: note(project)).font(.num(11)).foregroundStyle(Design.ink3).lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Design.line2).frame(height: 1) }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isOn(project) ? Design.rowHover : .clear))
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
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color)
                        .overlay { if row.guessed { StripeOverlay().clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous)) } }
                        .frame(width: max(2, proxy.size.width * length)).offset(x: proxy.size.width * start)
                }
            }
        }.frame(height: 8).accessibilityHidden(true)
    }

    private func note(_ project: TodayPlan.Project) -> String {
        if project.name == nil { return String(localized: "没认出项目名") }
        if project.guessedCount > 0 { return String(localized: "\(project.guessedCount) 段是推测的，右边可以确认") }
        if project.carriedSeconds > 0 { return String(localized: "其中 \(TodayFmt.long(project.carriedSeconds)) 是凌晨接着昨晚") }
        return project.interruptions > 0 ? String(localized: "打断 \(project.interruptions) 次") : String(localized: "没有打断")
    }
}

// MARK: - Categories

private struct TodayCategoriesCard: View {
    let plan: TodayPlan
    let model: AppModel

    private func color(_ category: TodayPlan.CategoryRow) -> Color { RefinedStyle.category(category.id, hex: category.colorHex) }

    var body: some View {
        let top = plan.categories.first?.seconds ?? 1
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("时间去了哪").cardTitle()
                Text("按分类").font(.system(size: 12)).foregroundStyle(Design.ink3)
                Spacer(minLength: 8)
                Button { model.sidebarSelection = .organization } label: {
                    Text("分类与规则 ›").font(.system(size: 12)).foregroundStyle(Design.link)
                }.buttonStyle(.plain)
            }
            GeometryReader { proxy in
                let usable = proxy.size.width - CGFloat(max(0, plan.categories.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(plan.categories) { category in
                        color(category).frame(width: max(2, usable * category.seconds / max(1, plan.total)))
                    }
                }
            }
            .frame(height: 12).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).accessibilityHidden(true)
            HStack {
                Text("投入 \(Text(verbatim: TodayFmt.clock(plan.engaged)).fontWeight(.bold).foregroundColor(Design.ink)) · \(Int((plan.engaged / max(1, plan.total) * 100).rounded()))%")
                Spacer()
                Text("其他 \(TodayFmt.long(max(0, plan.total - plan.engaged)))")
            }.font(.num(12)).foregroundStyle(Design.ink2)
            VStack(spacing: 0) {
                ForEach(plan.categories.prefix(7)) { category in
                    Button {
                        model.openActivities(category: category.id, range: DateRangeSelection(kind: .day, anchor: plan.day.start))
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(color(category)).frame(width: 9, height: 9).frame(width: 10)
                            HStack(spacing: 6) {
                                Text(category.name).font(.system(size: 13)).lineLimit(1)
                                if category.engaged { Text("投入").font(.system(size: 11)).foregroundStyle(Design.ink3) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Capsule().fill(Design.track).frame(width: 120, height: 5)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(color(category)).frame(width: max(3, 120 * category.seconds / max(1, top)), height: 5)
                                }
                            Text(verbatim: category.seconds < 60 ? String(localized: "<1 分") : TodayFmt.clock(category.seconds))
                                .font(.num(13)).foregroundStyle(Design.ink2).frame(width: 52, alignment: .trailing)
                        }
                        .frame(height: 31).contentShape(Rectangle())
                        .overlay(alignment: .bottom) { Rectangle().fill(Design.line2).frame(height: 1) }
                    }
                    .buttonStyle(HoverRowStyle(radius: 6))
                    .help("\(category.name) · \(Format.duration(category.seconds))")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.xl).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("要你处理").cardTitle()
                Text("\(plan.todos.count) 件").font(.num(12)).foregroundStyle(Design.ink3)
            }.padding(.bottom, 6)
            if plan.todos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(Design.liveInk)
                    Text("都处理好了").font(.system(size: 13)).foregroundStyle(Design.ink2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(plan.todos) { todo in row(todo).transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading))) }
                Spacer(minLength: 0)
            }
        }
        .animation(reduceMotion ? nil : Design.settle, value: plan.todos.map(\.id))
        .padding(.horizontal, Design.Space.xl).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
    }

    private struct Presentation {
        let symbol: String
        let color: Color
        let title: String
        let note: String
        let action: LocalizedStringKey
    }

    private func presentation(_ todo: TodayPlan.Todo) -> Presentation {
        switch todo {
        case .fill(let gap):
            return Presentation(symbol: "hourglass", color: Design.accent,
                                title: String(localized: "补记 \(model.time(gap.start))–\(model.time(gap.end))"),
                                note: String(localized: "离开了 \(Format.chineseDuration(gap.duration))，是吃饭还是开会？"), action: "补记")
        case .confirm(let count, let projects):
            let slot = plan.guessedRows.first?.slot
            return Presentation(symbol: "questionmark", color: Design.projectColor(slot),
                                title: String(localized: "确认 \(count) 段的项目"),
                                note: String(localized: "标题里没有项目名，我猜是 \(projects.joined(separator: String(localized: "、")))"), action: "确认")
        case .classify(let seconds, let names):
            return Presentation(symbol: "number", color: Design.color(light: 0xA1A1AA, dark: 0x6F727B),
                                title: String(localized: "\(Format.chineseDuration(seconds))还没分类"),
                                note: names.joined(separator: String(localized: "、")), action: "去分类")
        case .focus(let day, let minutes):
            let note = day.flatMap { day in minutes.map { String(localized: "最近一次是 \(day.formatted(.dateTime.month().day())) · \($0) 分钟") } }
                ?? String(localized: "选一个时长，开始计时")
            return Presentation(symbol: "scope", color: Design.accent, title: String(localized: "今天还没专注过"), note: note, action: "开始")
        }
    }

    private func row(_ todo: TodayPlan.Todo) -> some View {
        let p = presentation(todo)
        return HStack(spacing: 12) {
            Image(systemName: p.symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(p.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: p.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(verbatim: p.note).font(.num(11)).foregroundStyle(Design.ink3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            action(todo, p)
        }
        .padding(.vertical, 12).padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Design.line2).frame(height: 1) }
    }

    @ViewBuilder private func action(_ todo: TodayPlan.Todo, _ p: Presentation) -> some View {
        let style = PillButtonStyle(height: 26, tint: Design.link, font: .system(size: 12, weight: .semibold))
        switch todo {
        case .fill(let gap):
            Button(p.action) { filling = todo.id }
                .buttonStyle(style)
                .popover(isPresented: Binding(get: { filling == todo.id }, set: { if !$0 { filling = nil } }), arrowEdge: .leading) {
                    AwayPrompt(model: model, interval: gap, manual: true) { filling = nil }.frame(width: 316).padding(4)
                }
        case .confirm:
            Button(p.action) {
                for row in plan.guessedRows { if let project = row.project { model.assignSession(row.session, toProject: project) } }
                changed()
            }.buttonStyle(style)
        case .classify:
            Button(p.action) { model.organizationTab = .uncategorized; model.sidebarSelection = .organization }.buttonStyle(style)
        case .focus:
            Menu {
                ForEach(FocusPresets.minutes, id: \.self) { minutes in
                    Button("\(minutes) 分钟") { start(minutes) }.disabled(model.focus == nil || model.focus?.running != nil)
                }
            } label: { Text(p.action) }
            .menuStyle(.button).buttonStyle(style).menuIndicator(.hidden).fixedSize()
        }
    }
}
