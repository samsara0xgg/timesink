import SwiftUI
import AppKit

/// 专注: start a focus session, see this week's, and set daily limits.
struct FocusWorkspaceView: View {
    let model: AppModel
    @State private var minutes = 45
    @State private var sessions: [FocusSession] = []
    @State private var budgets: [Budget] = []
    @State private var used: [String: TimeInterval] = [:]
    @State private var blockedApps: [String] = []
    @State private var appBlock = true
    @State private var siteBlock = true
    @State private var editApps = false
    @State private var editCategories = false
    @State private var editingBudget: String?
    @State private var warn = 20
    @State private var error: String?
    @State private var last: FocusSession?
    /// Which week the history shows: 0 is this one, 1 the one before.
    @State private var weeksBack = FocusWorkspaceView.previewWeeksBack
    @State private var browsed: [FocusSession] = []
    @State private var earliestBack = 0
    /// Screen captures open the page on an earlier week.
    @MainActor static var previewWeeksBack = 0
    @State private var interruptions: (count: Int, recorded: TimeInterval)?
    @State private var suggestions: [LimitSuggestion] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct LoadKey: Equatable { let version: Int; let running: Int64? }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 2 * Design.Space.page
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.lg) {
                    header(width: width)
                    if width >= PageLayout.wideWidth {
                        HStack(alignment: .top, spacing: Design.Space.lg) {
                            VStack(spacing: Design.Space.lg) { sessionColumn; weekChart }
                                .frame(maxWidth: .infinity)
                            VStack(spacing: Design.Space.lg) { budgetColumn; if model.focus?.running == nil { blockCard } }
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        sessionColumn
                        budgetColumn
                        weekChart
                        if model.focus?.running == nil { blockCard }
                    }
                }
                .pagePadding()
            }.scrollIndicators(.never)
        }.background(WorkspaceBackground())
        .onAppear { loadSettings(); load() }
        // Settings can change elsewhere while the page is hidden; popovers
        // must not stay open over another page.
        .onPageVisibilityChange { shown in
            if shown { loadSettings() } else { editingBudget = nil; editCategories = false }
        }
        .onChange(of: weeksBack) { _, _ in loadBrowsed() }
        .onPageChange(of: LoadKey(version: model.dataVersion, running: model.focus?.running?.id)) { load() }
        .pageTask(id: model.dataVersion) { await loadInterruptions() }
        .sheet(isPresented: $editApps) { FocusBlockedAppsEditor(model: model, blockedApps: $blockedApps) }
        .popover(isPresented: $editCategories) { FocusCategoriesEditor(model: model) { editCategories = false } }
    }

    /// This week's focus, from the focus log, and how often you are pulled away.
    private func header(width: CGFloat) -> some View {
        let total = sessions.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let longest = sessions.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
        let blocks = sessions.reduce(0) { $0 + $1.appBlocks + $1.siteBlocks }
        let time = Text(TodayFmt.long(total)).monospacedDigit()
        // How often you are pulled away, from the last seven days.
        let gap = interruptions.flatMap { $0.count > 0 ? max(1, Int(($0.recorded / Double($0.count) / 60).rounded())) : nil }
        let sentence: Text
        if let gap {
            sentence = sessions.isEmpty ? Text("这周没开过专注，每 \(gap) 分钟被打断一次。") : Text("这周专注 \(time)，每 \(gap) 分钟被打断一次。")
        } else {
            sentence = sessions.isEmpty ? Text("这周还没有专注。") : Text("这周专注 \(time)。")
        }
        return PageHeader(sentence: sentence, stats: [
            StripStat(id: 0, label: "专注", value: String(localized: "\(sessions.count) 次"), note: String(localized: "做完 \(sessions.filter(\.completed).count) 次")),
            StripStat(id: 1, label: "最长一次", value: longest > 0 ? TodayFmt.clock(longest) : "—"),
            StripStat(id: 2, label: "拦下", value: String(localized: "\(blocks) 次"), note: String(localized: "分心被挡回")),
            StripStat(id: 3, label: "打断", value: interruptions.map { String(localized: "\($0.count) 次") } ?? "—",
                      note: interruptions.map { String(localized: "近 7 天 · 日均 \($0.count / 7) 次") } ?? "")
        ], width: width) {
            HeaderLabel(text: Text("本周"))
        } actions: {
            AddLimitMenu(model: model)
        }
    }

    private var sessionColumn: some View {
        VStack(spacing: Design.Space.md) {
            if model.focus?.running != nil {
                FocusRunningView(model: model).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CardHeading(title: "专注", caption: Text("拖动圆环上的把手，15 分钟到 2 小时")).frame(maxWidth: .infinity, alignment: .leading)
                FocusDial(minutes: $minutes)
                HStack(spacing: 2) {
                    ForEach(FocusPresets.minutes, id: \.self) { preset in
                        SegmentButton(selected: minutes == preset) {
                            withAnimation(Design.motion(Design.layout, reduced: reduceMotion)) { minutes = preset }
                        } label: { Text("\(preset) 分钟").monospacedDigit() }
                    }
                }
                Button(action: start) {
                    Label("开始 \(minutes) 分钟专注", systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(AccentButtonStyle(height: 36)).disabled(model.focus == nil)
            }
            if let error { Text(error).font(.note).foregroundStyle(Design.alert) }
        }
        .cardBox()
    }

    /// 隐藏应用 and the Chrome block, with what each does and a sample of the
    /// prompt you see when a hidden app is switched to.
    private var blockCard: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            CardHeading(title: "专注时拦什么", caption: Text("只在专注时生效"))
            VStack(spacing: Design.Space.sm) {
                toggleRow("隐藏应用", isOn: $appBlock, edit: { editApps = true }) {
                    HStack(spacing: Design.Space.xs) {
                        ForEach(Array(blockedApps.prefix(3)), id: \.self) { app in
                            AppIcon(bundleID: app, size: 18).help(AppIcon.name(for: app))
                        }
                        if blockedApps.isEmpty { Text("未选择").foregroundStyle(Design.ink2) }
                    }
                }.onChange(of: appBlock) { _, value in model.settings.setFocusAppBlockEnabled(value) }
                toggleRow("在 Chrome 中拦截", isOn: $siteBlock, edit: { editCategories = true }) {
                    Text(model.settings.focusBlockedCategories.isEmpty ? String(localized: "未选择") : model.settings.focusBlockedCategories.compactMap { model.resolver.categoriesByID[$0]?.name }.joined(separator: String(localized: "、")))
                        .lineLimit(1).foregroundStyle(Design.ink2)
                }.onChange(of: siteBlock) { _, value in model.settings.setFocusSiteBlockEnabled(value) }
            }
            Text("切过去的隐藏应用会被挡回来，菜单栏可以临时放行 5 分钟。").font(.note).foregroundStyle(Design.ink2)
            HStack(spacing: Design.Space.md) {
                HStack(spacing: Design.Space.sm) {
                    Text("\(AppIcon.name(for: blockedApps.first ?? "com.tencent.xinWeChat")) 已隐藏").fontWeight(.semibold)
                    Text("允许 5 分钟").foregroundStyle(Design.ink2)
                }
                .padding(.horizontal, Design.Space.md).frame(height: 32).floatingCard()
                Text("示例").font(.note).foregroundStyle(Design.ink2)
            }
            .padding(.vertical, Design.Space.xs)
            Text("专注时菜单栏显示倒计时；结束后这一段会标成专注，在今天和活动里单独显示。").font(.note).foregroundStyle(Design.ink2)
        }
        .cardBox()
    }

    /// A filled row: a title, what it covers (click to edit), a switch.
    private func toggleRow<Detail: View>(_ title: LocalizedStringKey, isOn: Binding<Bool>, edit: @escaping () -> Void,
                                         @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: Design.Space.md) {
            Text(title)
            Spacer(minLength: Design.Space.sm)
            Button(action: edit) { detail() }.buttonStyle(.plain).help("编辑…")
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, Design.Space.md).frame(minHeight: 40)
        .background(Design.floor, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
    }

    private var budgetColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeading(title: "限额", caption: Text("每个分类每天的上限"))
                .padding(.bottom, Design.Space.xs)
            if budgets.isEmpty && suggestions.isEmpty {
                Text("添加一个分类的每日时长上限。").foregroundStyle(Design.ink2).padding(.vertical, Design.Space.md)
            }
            ForEach(Array(budgets.enumerated()), id: \.element.categoryID) { index, budget in
                if index > 0 { Divider() }
                budgetRow(budget)
            }
            if !suggestions.isEmpty { suggestionRows }
            Text("限额只发提醒，不拦截任何东西；拦截只在专注时发生。").font(.note).foregroundStyle(Design.ink2)
                .padding(.top, Design.Space.md)
        }
        .cardBox()
    }

    /// 建议: from the last seven days of use, the categories worth a limit.
    private var suggestionRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if budgets.isEmpty { Text("还没设。按近 7 天的用量，建议这几个：") } else { Text("再加几个？按近 7 天的用量：") }
            }.font(.note).foregroundStyle(Design.ink2).padding(.top, Design.Space.md).padding(.bottom, Design.Space.xs)
            ForEach(suggestions) { item in
                let color = RefinedStyle.category(item.id, hex: item.colorHex)
                HStack(spacing: Design.Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) { Circle().fill(color).frame(width: 7, height: 7); Text(item.name).fontWeight(.semibold) }
                        Text("近 7 天 \(Format.duration(item.week))").font(.note).monospacedDigit().foregroundStyle(Design.ink2)
                    }
                    Spacer(minLength: Design.Space.sm)
                    HStack(alignment: .bottom, spacing: 2) {
                        let top = max(item.days.max() ?? 1, Double(item.capMinutes * 60))
                        ForEach(item.days.indices, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5).fill(item.days[index] > Double(item.capMinutes * 60) ? Design.alert : color.opacity(0.6))
                                .frame(width: 5, height: max(2, 22 * item.days[index] / top))
                        }
                    }.frame(height: 22, alignment: .bottom)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("每天 \(item.capMinutes) 分钟").foregroundStyle(Design.ink2)
                        Text(item.over > 0 ? "超出 \(item.over) 天" : "都在内").foregroundStyle(item.over > 0 ? Design.alert : Design.ink2)
                    }
                    .font(.note).monospacedDigit()
                    Button("添加") { addSuggestion(item) }.buttonStyle(PillButtonStyle(height: 24))
                }
                .padding(.vertical, Design.Space.sm)
                Divider()
            }
        }
    }

    private func lastNote(_ session: FocusSession) -> String {
        let length = String(localized: "\(Int(session.end.timeIntervalSince(session.start) / 60)) 分钟")
        let blocked = session.appBlocks + session.siteBlocks
        let how = session.completed ? String(localized: "做完了") : String(localized: "提前结束")
        return blocked == 0 ? String(localized: "\(length)，\(how)，没有拦下什么") : String(localized: "\(length)，\(how)，拦下 \(blocked) 次")
    }

    private func addSuggestion(_ item: LimitSuggestion) {
        writeBudget {
            try model.budgetStore?.setBudget(categoryID: item.id, dailySeconds: item.capMinutes * 60)
            model.requestNotificationPermission()
        }
    }

    /// Minutes of focus per weekday for the chosen week, with its numbers and sessions;
    /// the arrows walk back to the first week with a focus in it.
    private var weekChart: some View {
        let calendar = model.displayCalendar
        let week = FocusWeek.make(weeksBack == 0 ? sessions : browsed, in: FocusWeek.interval(weeksBack: weeksBack, now: Date(), calendar: calendar), calendar: calendar)
        let top = max(week.perDay.max().map { Int($0 / 60) } ?? 0, 1)
        let listed = weeksBack == 0 && week.sessions.isEmpty ? last.map { [$0] } ?? [] : Array(week.sessions.prefix(5))
        return VStack(alignment: .leading, spacing: Design.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.sm) {
                Text(verbatim: rangeLabel(week.interval, calendar: calendar)).cardTitle()
                Text("分钟").font(.note).foregroundStyle(Design.ink2)
                Spacer(minLength: Design.Space.sm)
                HStack(spacing: 0) {
                    StepperButton(symbol: "chevron.left", label: "上一周") { weeksBack += 1 }.disabled(weeksBack >= earliestBack)
                    StepperButton(symbol: "chevron.right", label: "下一周") { weeksBack -= 1 }.disabled(weeksBack == 0)
                }
                .padding(.vertical, -Design.Space.xs)
            }
            if !week.sessions.isEmpty {
                Text("专注 \(TodayFmt.long(week.total)) · \(String(localized: "\(week.sessions.count) 次")) · 最长 \(TodayFmt.clock(week.longest))")
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(alignment: .bottom, spacing: Design.Space.sm) {
                ForEach(week.days.indices, id: \.self) { index in
                    let value = Int(week.perDay[index] / 60), today = calendar.isDateInToday(week.days[index])
                    VStack(spacing: Design.Space.xs) {
                        Text(value > 0 ? "\(value)" : " ").font(.note).monospacedDigit().foregroundStyle(Design.ink2)
                        RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous)
                            .fill(value == 0 ? AnyShapeStyle(Design.track) : today || weeksBack > 0 ? AnyShapeStyle(ColorSystem.ramp(0.85)) : AnyShapeStyle(ColorSystem.ramp(0.4)))
                            .frame(height: value == 0 ? 4 : max(4, 56 * CGFloat(value) / CGFloat(top)))
                        Text(week.days[index].formatted(.dateTime.weekday(.narrow).locale(model.textLocale))).font(.note)
                            .fontWeight(today ? .semibold : .regular).foregroundStyle(today ? Design.ink : Design.ink2)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 90, alignment: .bottom)
            if week.sessions.isEmpty {
                Text(weeksBack == 0 ? "开一次专注，这里会按天记下时长。" : "这一周没有专注记录。").foregroundStyle(Design.ink2)
            }
            ForEach(Array(listed.enumerated()), id: \.offset) { index, session in
                let planned = session.plannedSeconds / 60
                Divider()
                HStack(spacing: Design.Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(session.start.formatted(.dateTime.month().day().locale(model.textLocale))) \(model.time(session.start))").fontWeight(.semibold)
                        Text(lastNote(session)).font(.note).foregroundStyle(Design.ink2)
                    }
                    Spacer(minLength: Design.Space.sm)
                    if weeksBack == 0 && index == 0 {
                        Button("再来一次 \(planned) 分钟") { minutes = planned; start() }
                            .buttonStyle(PillButtonStyle()).disabled(model.focus == nil || model.focus?.running != nil)
                    }
                }
            }
            if week.sessions.count > listed.count {
                Text("另有 \(week.sessions.count - listed.count) 次").font(.note).foregroundStyle(Design.ink2)
            }
        }
        .cardBox()
    }

    /// "10月 5日 – 10月 11日": the week's first and last day.
    private func rangeLabel(_ interval: DateInterval, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.month().day().locale(model.textLocale)
        style.calendar = calendar
        let last = calendar.date(byAdding: .day, value: 6, to: interval.start) ?? interval.start
        return "\(interval.start.formatted(style)) – \(last.formatted(style))"
    }

    private func budgetRow(_ budget: Budget) -> some View {
        let seconds = used[budget.categoryID, default: 0]
        let limit = Double(budget.dailySeconds)
        let category = model.resolver.categoriesByID[budget.categoryID]
        let name = category?.name ?? String(localized: "未分类")
        let status = LimitStatus(spent: seconds, limit: limit, warningPercent: warn)
        let within = { if case .within = status { true } else { false } }()
        let color: Color = switch status {
        case .over: Design.alert
        case .near: Design.warning
        case .within: RefinedStyle.category(budget.categoryID, hex: category?.colorHex ?? "808080")
        }
        return Button { editingBudget = budget.categoryID } label: {
            VStack(spacing: Design.Space.sm) {
                HStack(spacing: 6) {
                    switch status {
                    case .over(let minutes):
                        Label("\(name)超出 \(minutes) 分钟", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Design.alert).fontWeight(.semibold)
                    case .near(let minutes):
                        Label("\(name)还剩 \(minutes) 分钟", systemImage: "gauge.with.dots.needle.67percent").foregroundStyle(Design.warning).fontWeight(.semibold)
                    case .within:
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(name).foregroundStyle(Design.ink)
                    }
                    Spacer(minLength: Design.Space.sm)
                    Text("\(Int(seconds / 60)) / \(budget.dailySeconds / 60) 分钟").foregroundStyle(Design.ink2).monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Design.track)
                        Capsule().fill(within ? Design.ink2.opacity(0.6) : color)
                            .frame(width: geometry.size.width * min(1, seconds / max(1, limit)))
                    }
                }.frame(height: 6)
            }.padding(.vertical, Design.Space.md).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(budget.enabled ? 1 : 0.5)
        .popover(isPresented: Binding(get: { editingBudget == budget.categoryID }, set: { if !$0 { editingBudget = nil } })) {
            VStack(alignment: .leading, spacing: Design.Space.md) {
                CategoryChip(category: category)
                Stepper("\(budget.dailySeconds / 60) 分钟", value: Binding(get: { budget.dailySeconds / 60 }, set: { value in
                    writeBudget { try model.budgetStore?.setBudget(categoryID: budget.categoryID, dailySeconds: value * 60) }
                }), in: 5...1440, step: 5)
                Toggle("启用限额", isOn: Binding(get: { budget.enabled }, set: { value in
                    writeBudget { try model.budgetStore?.setEnabled(categoryID: budget.categoryID, enabled: value) }
                    if value { model.requestNotificationPermission() }
                })).toggleStyle(.switch)
                Button("删除限额", systemImage: "trash", role: .destructive) {
                    editingBudget = nil
                    writeBudget { try model.budgetStore?.deleteBudget(categoryID: budget.categoryID) }
                }
            }.padding(Design.Space.card).frame(width: 240)
        }
        .contextMenu { Button("删除限额", systemImage: "trash", role: .destructive) { writeBudget { try model.budgetStore?.deleteBudget(categoryID: budget.categoryID) } } }
    }
    private func writeBudget(_ action: () throws -> Void) {
        do { try action(); load(); model.settingsChanged(); error = nil }
        catch { self.error = String(localized: "限额未保存：\(error.localizedDescription)") }
    }
    private func start() {
        do { model.settings.setFocusDurationMinutes(minutes); try model.focus?.start(minutes: minutes); error = nil }
        catch { self.error = String(localized: "无法开始专注：\(error.localizedDescription)") }
    }
    private func loadSuggestions() {
        let calendar = model.displayCalendar
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return }
        var perDay: [String: [TimeInterval]] = [:]
        for item in model.rangedSpans(for: DateInterval(start: start, end: Date())) {
            let day = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: item.span.start)).day ?? 0
            guard (0..<7).contains(day) else { continue }
            perDay[item.categoryID, default: Array(repeating: 0, count: 7)][day] += item.span.duration
        }
        let taken = Set(budgets.map(\.categoryID))
        let ranked = perDay.compactMap { id, days -> (Category, [TimeInterval])? in
            guard id != "uncategorized", !taken.contains(id), days.reduce(0, +) >= 30 * 60, let category = model.resolver.categoriesByID[id] else { return nil }
            return (category, days)
        }.sorted { a, b in
            // What pulls you away comes first, then the biggest.
            if (a.0.productivity <= 0) != (b.0.productivity <= 0) { return a.0.productivity <= 0 }
            return a.1.reduce(0, +) > b.1.reduce(0, +)
        }
        suggestions = ranked.prefix(max(0, 3 - budgets.count)).map { category, days in
            let week = days.reduce(0, +)
            return LimitSuggestion(id: category.id, name: category.name, colorHex: category.colorHex, week: week, days: days, capMinutes: LimitSuggestion.cap(forWeek: week))
        }
    }

    /// Seven days of episodes and recorded time: how often you are pulled away.
    private func loadInterruptions() async {
        let calendar = model.displayCalendar
        let today = calendar.startOfDay(for: Date())
        var count = 0, recorded: TimeInterval = 0
        for back in 0..<7 {
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let day = DateInterval(start: start, end: end)
            count += await model.interruptions(for: day).episodes.count
            recorded += model.rangedSpans(for: day).reduce(0) { $0 + $1.span.duration }
        }
        interruptions = (count, recorded)
    }

    private func loadSettings() {
        minutes = model.settings.focusDurationMinutes
        blockedApps = model.settings.focusBlockedApps
        appBlock = model.settings.focusAppBlockEnabled; siteBlock = model.settings.focusSiteBlockEnabled
        warn = model.settings.budgetWarnPercent
    }
    /// The chosen week's sessions, when it is not this week.
    private func loadBrowsed() {
        guard weeksBack > 0 else { browsed = []; return }
        let interval = FocusWeek.interval(weeksBack: weeksBack, now: Date(), calendar: model.displayCalendar)
        browsed = (try? model.focusStore?.sessions(overlapping: interval)) ?? []
    }
    private func load() {
        do {
            sessions = try model.focusStore?.sessions(overlapping: DateRangeSelection(kind: .week, anchor: Date(), firstWeekday: model.firstWeekday).interval) ?? []
            earliestBack = FocusWeek.weeksBack(of: try model.focusStore?.earliestStart(), now: Date(), calendar: model.displayCalendar)
            loadBrowsed()
            budgets = try model.budgetStore?.budgets() ?? []
            loadSuggestions()
            last = try model.focusStore?.sessions(overlapping: DateInterval(start: Date().addingTimeInterval(-90 * 86400), end: Date().addingTimeInterval(86400)))
                .filter { $0.end <= Date() }.max { $0.end < $1.end }
            used = model.rangedSpans(for: .today()).reduce(into: [:]) { $0[$1.categoryID, default: 0] += $1.span.duration }
        } catch { self.error = String(localized: "专注记录暂时无法读取。") }
    }
}

/// A category worth a daily limit, judged from seven days of use.
struct LimitSuggestion: Identifiable {
    let id: String
    let name: String
    let colorHex: String
    let week: TimeInterval
    /// Seconds per day, oldest first.
    let days: [TimeInterval]
    let capMinutes: Int
    var over: Int { days.filter { $0 > Double(capMinutes * 60) }.count }

    /// A cap of about three quarters of the daily average, in 15-minute steps.
    static func cap(forWeek week: TimeInterval) -> Int { max(15, Int((week / 7 * 0.75 / 60 / 15).rounded()) * 15) }
}

/// Which categories' sites a focus session blocks in Chrome.
struct FocusCategoriesEditor: View {
    let model: AppModel
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            Text("拦截这些分类的网站").cardTitle()
            ForEach(model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { category in
                Toggle(isOn: Binding(get: { model.settings.focusBlockedCategories.contains(category.id) }, set: { enabled in
                    var ids = Set(model.settings.focusBlockedCategories)
                    if enabled { ids.insert(category.id) } else { ids.remove(category.id) }
                    model.settings.setFocusBlockedCategories(ids.sorted()); model.settingsChanged()
                })) { CategoryChip(category: category) }
            }
            Text("修改从下一次专注开始生效。").font(.note).foregroundStyle(Design.ink2)
            Button("完成", action: done).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(Design.Space.card).frame(width: 260)
    }
}

/// 分类: what is sorted automatically, what is waiting, and the rules.
struct OrganizationView: View {
    @Bindable var model: AppModel
    @State private var pending: (count: Int, seconds: TimeInterval)?
    @State private var coverage: (auto: TimeInterval, total: TimeInterval)?
    @State private var byCategory: [String: TimeInterval] = [:]
    @State private var category: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct CoverageKey: Equatable { let version: Int }

    var body: some View {
        if model.organizationTab == .projects { ProjectsView(model: model) } else { categoriesBody }
    }

    private var categoriesBody: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 2 * Design.Space.page
            if width >= PageLayout.wideWidth {
                VStack(alignment: .leading, spacing: Design.Space.lg) {
                    header(width: width)
                    HStack(alignment: .top, spacing: Design.Space.lg) {
                        VStack(spacing: Design.Space.lg) { ToConfirmCard(model: model); queue; rules }
                        CategoryListCard(model: model, seconds: byCategory, selected: $category).frame(width: 480)
                    }
                }
                .pagePadding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.lg) {
                        header(width: width)
                        ToConfirmCard(model: model)
                        queue
                        CategoryListCard(model: model, seconds: byCategory, selected: $category).frame(height: 460)
                        rules.frame(height: 420)
                    }
                    .pagePadding()
                }.scrollIndicators(.never)
            }
        }
        .background(WorkspaceBackground())
        .pageTask(id: CoverageKey(version: model.dataVersion)) { await loadCoverage() }
        .pageSearchable(text: $model.organizationSearch, prompt: "搜索规则")
    }

    /// 应用 / 建议: what is not sorted yet, with a suggestion to accept.
    private var queue: some View {
        VStack(alignment: .leading, spacing: Design.Space.sm) {
            CardHeading(title: "应用与建议", caption: pending.map { Text("\($0.count) 项待分类") })
            UncategorizedSettingsPane(model: model) { count, seconds in pending = (count, seconds) }
        }
        .padding(Design.Space.card)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .designCard()
    }

    private var rules: some View {
        RefinedRulesPane(model: model, categoryFilter: category, onClearFilter: {
            withAnimation(Design.motion(Design.layout, reduced: reduceMotion)) { category = nil }
        })
        .frame(maxHeight: .infinity)
    }

    private func header(width: CGFloat) -> some View {
        let percent = coverage.map { Int(($0.auto / max(1, $0.total) * 100).rounded()) }
        let sentence: Text
        if let percent, let coverage, coverage.total >= 60 {
            sentence = Text("\(Text(verbatim: "\(percent)%").monospacedDigit()) 的时间已经自动分好了。")
        } else if coverage != nil {
            sentence = Text("近 7 天还没有记录。")
        } else {
            sentence = Text(verbatim: " ")
        }
        let categories = model.resolver.categoriesByID.values.filter { $0.id != "uncategorized" }.count
        return PageHeader(sentence: sentence, stats: [
            StripStat(id: 0, label: "待分类", value: pending.map { String(localized: "\($0.count) 项") } ?? "—",
                      note: pending.map { String(localized: "近 30 天共 \(Format.duration($0.seconds))") } ?? ""),
            StripStat(id: 1, label: "分类", value: String(localized: "\(categories) 个"), note: String(localized: "投入程度决定评分"))
        ], width: width) {
            OrganizationTabs(model: model)
        } actions: { HeaderLabel(text: Text("近 7 天")) }
    }

    /// Seven days, read and classified off the main thread: how much is
    /// sorted, and the time of each category.
    private func loadCoverage() async {
        let interval = DateRangeSelection(kind: .last7, anchor: Date()).interval
        let spanStore = model.spanStore
        let classification = model.resolver.snapshot()
        let result = await Task.detached(priority: .userInitiated) { () -> (TimeInterval, TimeInterval, [String: TimeInterval])? in
            guard let spans = try? spanStore.spans(overlapping: interval) else { return nil }
            var classification = classification
            var total: TimeInterval = 0, auto: TimeInterval = 0
            var byCategory: [String: TimeInterval] = [:]
            for span in spans {
                let seconds = min(span.end, interval.end).timeIntervalSince(max(span.start, interval.start))
                guard seconds > 0 else { continue }
                total += seconds
                let id = classification.categoryID(for: span)
                byCategory[id, default: 0] += seconds
                if id != "uncategorized" { auto += seconds }
            }
            return (auto, total, byCategory)
        }.value
        if let result { coverage = (result.0, result.1); byCategory = result.2 }
    }
}
