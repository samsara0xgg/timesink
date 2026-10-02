import SwiftUI
import AppKit

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
    private struct LoadKey: Equatable { let version: Int; let running: Int64? }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.lg) {
                    header(width: geometry.size.width - 2 * Design.Space.page)
                    if geometry.size.width >= 860 {
                        HStack(alignment: .top, spacing: Design.Space.lg) {
                            sessionColumn.frame(maxWidth: .infinity).revealOnce(index: 2)
                            budgetColumn.frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: Design.Space.lg) { sessionColumn.revealOnce(index: 2); budgetColumn }
                    }
                }
                .padding(.horizontal, Design.Space.page).padding(.top, 8).padding(.bottom, 24)
                .frame(maxWidth: 1600).frame(maxWidth: .infinity)
            }.scrollIndicators(.never)
        }.background(WorkspaceBackground())
        .onAppear { loadSettings(); load() }
        // Settings can change elsewhere while the page is hidden; popovers
        // must not stay open over another page.
        .onPageVisibilityChange { shown in
            if shown { loadSettings() } else { editingBudget = nil; editCategories = false }
        }
        .onPageChange(of: LoadKey(version: model.dataVersion, running: model.focus?.running?.id)) { load() }
        .sheet(isPresented: $editApps) { FocusBlockedAppsEditor(model: model, blockedApps: $blockedApps) }
        .popover(isPresented: $editCategories) { FocusCategoriesEditor(model: model) { editCategories = false } }
    }

    /// This week's focus, from the focus log: the sentence and four numbers
    /// that stood in the toolbar before.
    private func header(width: CGFloat) -> some View {
        let total = sessions.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let longest = sessions.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
        let blocks = sessions.reduce(0) { $0 + $1.appBlocks + $1.siteBlocks }
        let time = Text(TodayFmt.long(total)).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
        let sentence: Text = sessions.isEmpty ? Text("这周还没有专注。") : Text("这周专注了 \(time)。")
        return PageHeaderRow(lead: Text("本周"), sentence: sentence, stats: [
            StripStat(id: 0, label: "专注", value: TodayFmt.clock(total), color: Design.accentInk),
            StripStat(id: 1, label: "次数", value: String(localized: "\(sessions.count) 次"), note: longest > 0 ? String(localized: "最长 \(Format.chineseDuration(longest))") : ""),
            StripStat(id: 2, label: "拦下", value: String(localized: "\(blocks) 次"), note: String(localized: "分心被挡回")),
            StripStat(id: 3, label: "限额", value: String(localized: "\(budgets.count) 个"), note: String(localized: "只提醒，不拦截"))
        ], width: width)
    }

    private var sessionColumn: some View {
        VStack(spacing: 12) {
            if model.focus?.running != nil {
                FocusRunningView(model: model).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CardHeading(title: "专注", caption: Text("拖动圆环上的把手，15 分钟到 2 小时")).frame(maxWidth: .infinity, alignment: .leading)
                FocusDial(minutes: $minutes)
                HStack(spacing: 8) {
                    ForEach(FocusPresets.minutes, id: \.self) { preset in
                        Button { withAnimation(Design.motion(Design.settle, reduced: false)) { minutes = preset } } label: {
                            Text("\(preset) 分钟").font(.num(12, minutes == preset ? .bold : .regular))
                        }.buttonStyle(PillButtonStyle(height: 28, font: .system(size: 12)))
                    }
                }
                VStack(spacing: 8) {
                    toggleRow("隐藏应用", isOn: $appBlock, edit: { editApps = true }) {
                        HStack(spacing: 4) {
                            ForEach(Array(blockedApps.prefix(3)), id: \.self) { app in
                                AppIcon(bundleID: app, size: 18).help(AppIcon.name(for: app))
                            }
                            if blockedApps.isEmpty { Text("未选择").font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                    }.onChange(of: appBlock) { _, value in model.settings.setFocusAppBlockEnabled(value) }
                    toggleRow("在 Chrome 中拦截", isOn: $siteBlock, edit: { editCategories = true }) {
                        Text(model.settings.focusBlockedCategories.isEmpty ? String(localized: "未选择") : model.settings.focusBlockedCategories.compactMap { model.resolver.categoriesByID[$0]?.name }.joined(separator: String(localized: "、")))
                            .font(.system(size: 12)).lineLimit(1).foregroundStyle(.secondary)
                    }.onChange(of: siteBlock) { _, value in model.settings.setFocusSiteBlockEnabled(value) }
                }
                Button(action: start) {
                    Label("开始 \(minutes) 分钟专注", systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(AccentButtonStyle(height: 44)).disabled(model.focus == nil)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }.font(.system(size: 13)).frame(maxWidth: .infinity).padding(20).workspacePanel()
    }

    /// A filled row: a title, what it covers (click to edit), a switch.
    private func toggleRow<Detail: View>(_ title: LocalizedStringKey, isOn: Binding<Bool>, edit: @escaping () -> Void,
                                         @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            Button(action: edit) { detail() }.buttonStyle(.plain).help("编辑…")
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 12).frame(minHeight: 40)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var budgetColumn: some View {
        VStack(spacing: Design.Space.lg) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    CardHeading(title: "限额"); Spacer()
                    Text("快到时黄色，超出时红色加图标").font(.system(size: 11)).foregroundStyle(Design.ink3)
                }.padding(.bottom, 4)
                if budgets.isEmpty { Text("添加一个分类的每日时长上限。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 10) }
                ForEach(Array(budgets.enumerated()), id: \.element.categoryID) { index, budget in
                    if index > 0 { Divider() }
                    budgetRow(budget)
                }
                Divider().padding(.top, 4)
                Text("限额只发提醒，不拦截任何东西；拦截只在专注会话里发生。").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(18).workspacePanel().revealOnce(index: 3)
            weekChart
        }
    }

    /// Minutes of focus per weekday this week, today's bar solid.
    private var weekChart: some View {
        let calendar = { var c = Calendar.current; c.firstWeekday = model.firstWeekday; return c }()
        let week = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
        let minutes = days.map { day in
            Int(sessions.filter { calendar.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60)
        }
        let top = max(minutes.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CardHeading(title: "本周的专注")
                Spacer()
                Text("\(sessions.count) 次 · \(Format.duration(sessions.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days.indices, id: \.self) { index in
                    let value = minutes[index], today = calendar.isDateInToday(days[index])
                    VStack(spacing: 4) {
                        Text(value > 0 ? "\(value)" : " ").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(value == 0 ? AnyShapeStyle(Design.track) : today ? AnyShapeStyle(Design.accent) : AnyShapeStyle(Design.accent.opacity(0.4)))
                            .frame(height: value == 0 ? 4 : max(4, 56 * CGFloat(value) / CGFloat(top)))
                        Text(days[index].formatted(.dateTime.weekday(.narrow).locale(model.textLocale))).font(.system(size: 11)).foregroundStyle(Design.ink3)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 90, alignment: .bottom)
        }.font(.system(size: 13)).padding(18).workspacePanel().revealOnce(index: 4)
    }

    private func budgetRow(_ budget: Budget) -> some View {
        let seconds = used[budget.categoryID, default: 0]
        let limit = Double(budget.dailySeconds)
        let category = model.resolver.categoriesByID[budget.categoryID]
        let name = category?.name ?? String(localized: "未分类")
        let status = LimitStatus(spent: seconds, limit: limit, warningPercent: warn)
        let within = { if case .within = status { true } else { false } }()
        let color: Color = switch status {
        case .over: .red
        case .near: RefinedStyle.warning
        case .within: RefinedStyle.category(budget.categoryID, hex: category?.colorHex ?? "808080")
        }
        return Button { editingBudget = budget.categoryID } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    switch status {
                    case .over(let minutes):
                        Label("\(name)超出 \(minutes) 分钟", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fontWeight(.semibold)
                    case .near(let minutes):
                        Label("\(name)还剩 \(minutes) 分钟", systemImage: "gauge.with.dots.needle.67percent").foregroundStyle(RefinedStyle.warning).fontWeight(.semibold)
                    case .within:
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(name)
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(seconds / 60)) / \(budget.dailySeconds / 60) 分钟").foregroundStyle(.secondary).monospacedDigit()
                }.font(.system(size: 12))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(within ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                            .frame(width: geometry.size.width * min(1, seconds / max(1, limit)))
                    }
                }.frame(height: 5)
            }.padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(budget.enabled ? 1 : 0.5)
        .popover(isPresented: Binding(get: { editingBudget == budget.categoryID }, set: { if !$0 { editingBudget = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
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
            }.padding(18).frame(width: 240)
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
    private func loadSettings() {
        minutes = model.settings.focusDurationMinutes
        blockedApps = model.settings.focusBlockedApps
        appBlock = model.settings.focusAppBlockEnabled; siteBlock = model.settings.focusSiteBlockEnabled
        warn = model.settings.budgetWarnPercent
    }
    private func load() {
        do {
            sessions = try model.focusStore?.sessions(overlapping: DateRangeSelection(kind: .week, anchor: Date(), firstWeekday: model.firstWeekday).interval) ?? []
            budgets = try model.budgetStore?.budgets() ?? []
            used = model.rangedSpans(for: .today()).reduce(into: [:]) { $0[$1.categoryID, default: 0] += $1.span.duration }
        } catch { self.error = String(localized: "专注记录暂时无法读取。") }
    }
}

/// Which categories' sites a focus session blocks in Chrome.
struct FocusCategoriesEditor: View {
    let model: AppModel
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("拦截这些分类的网站").font(.headline)
            ForEach(model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { category in
                Toggle(isOn: Binding(get: { model.settings.focusBlockedCategories.contains(category.id) }, set: { enabled in
                    var ids = Set(model.settings.focusBlockedCategories)
                    if enabled { ids.insert(category.id) } else { ids.remove(category.id) }
                    model.settings.setFocusBlockedCategories(ids.sorted()); model.settingsChanged()
                })) { CategoryChip(category: category) }
            }
            Text("修改从下一次专注开始生效。").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("完成", action: done).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(18).frame(width: 260)
    }
}

struct OrganizationView: View {
    @Bindable var model: AppModel
    @State private var tab: SettingsTab = .uncategorized
    @State private var pending: (count: Int, seconds: TimeInterval)?
    @State private var coverage: (auto: TimeInterval, total: TimeInterval)?
    private struct CoverageKey: Equatable { let version: Int }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: Design.Space.lg) {
                header(width: geometry.size.width - 2 * Design.Space.page)
                VStack(alignment: .leading, spacing: 12) {
                    tabs
                    Group {
                        switch tab {
                        case .rules: RefinedRulesPane(model: model)
                        case .categories: CategoriesSettingsPane(model: model)
                        default: UncategorizedSettingsPane(model: model) { count, seconds in pending = (count, seconds) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: tab == .uncategorized ? nil : .infinity)
                }
                .padding(Design.Space.xl)
                // The queue sizes to its rows; the other two fill the page.
                .frame(maxWidth: .infinity, maxHeight: tab == .uncategorized ? nil : .infinity, alignment: .top)
                .designCard().revealOnce(index: 2)
            }
            .padding(.horizontal, Design.Space.page).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: 1600).frame(maxWidth: .infinity)
        }
        .background(WorkspaceBackground())
        .pageTask(id: CoverageKey(version: model.dataVersion)) { await loadCoverage() }
        .onChange(of: model.organizationTab, initial: true) { _, value in tab = value }
        .onChange(of: tab) { _, value in model.organizationTab = value }
        // Only rules can be searched, so only their tab shows the field.
        .pageSearchable(text: $model.organizationSearch, prompt: "搜索规则", isEnabled: tab == .rules)
        .onChange(of: model.organizationSearch) { _, value in
            if !value.isEmpty { tab = .rules; model.organizationTab = .rules }
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach([SettingsTab.uncategorized, .rules, .categories], id: \.self) { item in
                Button { withAnimation(Design.motion(Design.settle, reduced: false)) { tab = item } } label: {
                    HStack(spacing: 6) {
                        switch item {
                        case .rules: Text("规则")
                        case .categories: Text("分类列表")
                        default: Text("待分类")
                        }
                        if item == .uncategorized, let pending, pending.count > 0 {
                            Text("\(pending.count)").font(.num(11)).foregroundStyle(Design.ink3)
                        }
                    }
                    .font(.system(size: 13, weight: tab == item ? .bold : .regular))
                    .foregroundStyle(tab == item ? Design.accentInk : Design.ink)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background { if tab == item { Capsule().fill(Design.pillTop).shadow(color: .black.opacity(0.08), radius: 2, y: 1) } }
                    .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(3).background(Capsule().fill(Design.track)).fixedSize()
    }

    private func header(width: CGFloat) -> some View {
        let percent = coverage.map { Int(($0.auto / max(1, $0.total) * 100).rounded()) }
        let sentence: Text
        if let percent, let coverage, coverage.total >= 60 {
            sentence = Text("\(Text("\(percent)%").font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()) 的时间已经自动分好了。")
        } else if coverage != nil {
            sentence = Text("近 7 天还没有记录。")
        } else {
            sentence = Text(verbatim: " ")
        }
        let categories = model.resolver.categoriesByID.values.filter { $0.id != "uncategorized" }.count
        return PageHeaderRow(lead: Text("近 7 天"), sentence: sentence, stats: [
            StripStat(id: 0, label: "自动分好", value: percent.map { "\($0)%" } ?? "—", note: String(localized: "按规则和应用类型"), color: Design.accentInk),
            StripStat(id: 1, label: "待分类", value: pending.map { String(localized: "\($0.count) 项") } ?? "—",
                      note: pending.map { String(localized: "近 30 天共 \(Format.duration($0.seconds))") } ?? ""),
            StripStat(id: 2, label: "分类", value: String(localized: "\(categories) 个"), note: String(localized: "投入程度决定评分"))
        ], width: width)
    }

    /// Seven days, read and classified off the main thread.
    private func loadCoverage() async {
        let interval = DateRangeSelection(kind: .last7, anchor: Date()).interval
        let spanStore = model.spanStore
        let classification = model.resolver.snapshot()
        let result = await Task.detached(priority: .userInitiated) { () -> (TimeInterval, TimeInterval)? in
            guard let spans = try? spanStore.spans(overlapping: interval) else { return nil }
            var classification = classification
            var total: TimeInterval = 0, auto: TimeInterval = 0
            for span in spans {
                let seconds = min(span.end, interval.end).timeIntervalSince(max(span.start, interval.start))
                guard seconds > 0 else { continue }
                total += seconds
                if classification.categoryID(for: span) != "uncategorized" { auto += seconds }
            }
            return (auto, total)
        }.value
        if let result { coverage = result }
    }
}
