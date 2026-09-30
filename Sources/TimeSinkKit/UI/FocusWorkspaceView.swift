import SwiftUI
import AppKit

struct FocusWorkspaceView: View {
    let model: AppModel
    @State private var minutes = 45
    @State private var customDuration = false
    @State private var sessions: [FocusSession] = []
    @State private var budgets: [Budget] = []
    @State private var used: [String: TimeInterval] = [:]
    @State private var blockedApps: [String] = []
    @State private var appBlock = true
    @State private var siteBlock = true
    @State private var editApps = false
    @State private var editCategories = false
    @State private var warn = 20
    @State private var summary = false
    @State private var error: String?
    private struct LoadKey: Equatable { let version: Int; let running: Int64? }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if geometry.size.width >= 860 {
                    HStack(alignment: .top, spacing: 16) {
                        sessionColumn.frame(maxWidth: .infinity)
                        budgetColumn.frame(maxWidth: .infinity)
                    }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 28)
                } else {
                    VStack(spacing: 16) { sessionColumn; budgetColumn }
                        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 28)
                }
            }
        }.background(WorkspaceBackground())
        .onAppear { loadSettings(); load() }
        // Settings can change elsewhere while the page is hidden; popovers
        // must not stay open over another page.
        .onPageVisibilityChange { shown in
            if shown { loadSettings() } else { customDuration = false; editCategories = false }
        }
        .onPageChange(of: LoadKey(version: model.dataVersion, running: model.focus?.running?.id)) { load() }
        .sheet(isPresented: $editApps) { FocusBlockedAppsEditor(model: model, blockedApps: $blockedApps) }
        .popover(isPresented: $editCategories) {
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
                Button("完成") { editCategories = false }.frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(18).frame(width: 260)
        }
    }

    private var sessionColumn: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("开始一段专注").fontWeight(.semibold); Spacer(); Text("期间隐藏应用、拦截网站").font(.system(size: 11)).foregroundStyle(.secondary) }
                if model.focus?.running != nil { FocusRunningView(model: model) }
                else {
                    HStack(spacing: 6) {
                        Picker("专注时长", selection: $minutes) {
                            ForEach(FocusPresets.minutes, id: \.self) { Text("\($0) 分钟").tag($0) }
                            if !FocusPresets.minutes.contains(minutes) { Text("\(minutes) 分钟").tag(minutes) }
                        }.pickerStyle(.segmented).labelsHidden()
                        Button("自定义…") { customDuration.toggle() }.controlSize(.small)
                            .popover(isPresented: $customDuration) {
                                VStack(spacing: 12) {
                                    Stepper("\(minutes) 分钟", value: $minutes, in: 5...240, step: 5)
                                    Button("完成") { customDuration = false }
                                }.padding(18).frame(width: 230)
                            }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(minutes)").font(.system(size: 44, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
                        Text("分钟 · \(Date(), format: .dateTime.hour().minute()) → \(Date().addingTimeInterval(Double(minutes) * 60), format: .dateTime.hour().minute()) 结束")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    blockLists
                    Text("切回被隐藏的应用时会提示你；网站在 Chrome 中拦截，需要时可以放行 5 分钟。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(action: start) { Label("开始 \(minutes) 分钟专注", systemImage: "scope") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.focus == nil)
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(20).workspacePanel()
            VStack(spacing: 0) {
                HStack {
                    Text("本周的专注").fontWeight(.semibold)
                    Spacer()
                    Text("\(sessions.count) 次 · \(Format.duration(sessions.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }.padding(14)
                if sessions.isEmpty {
                    Text("完成第一段专注后，在这里回看。").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(sessions.sorted { $0.start > $1.start }, id: \.id) { session in
                    Divider()
                    HStack(spacing: 12) {
                        Text(session.start, format: .dateTime.weekday().hour().minute()).frame(width: 90, alignment: .leading)
                        Text("\(Int(session.end.timeIntervalSince(session.start) / 60)) / \(session.plannedSeconds / 60) 分钟").monospacedDigit()
                        Spacer(minLength: 0)
                        Text(session.appBlocks + session.siteBlocks == 0 ? "没有分心" : "拦下 \(session.appBlocks + session.siteBlocks) 次").foregroundStyle(.secondary)
                        Text(session.id == model.focus?.running?.id ? "进行中" : session.completed ? "完成" : "已提前结束")
                            .font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 3)
                            .background((session.completed ? Color.green : .secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(session.completed ? Color.green : .secondary)
                    }.font(.system(size: 12)).padding(.horizontal, 14).frame(minHeight: 38)
                }
            }.font(.system(size: 13)).workspacePanel()
        }
    }
    private var blockLists: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle("隐藏应用", isOn: $appBlock).toggleStyle(.switch).fixedSize()
                    .onChange(of: appBlock) { _, value in model.settings.setFocusAppBlockEnabled(value) }
                HStack(spacing: 4) {
                    ForEach(Array(blockedApps.prefix(3)), id: \.self) { app in
                        AppIcon(bundleID: app, size: 18).help(AppIcon.name(for: app))
                    }
                    Text(blockedApps.isEmpty ? String(localized: "未选择") : blockedApps.prefix(3).map { AppIcon.name(for: $0) }.joined(separator: String(localized: "、")))
                        .font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("编辑…") { editApps = true }.buttonStyle(.link)
            }
            HStack(spacing: 8) {
                Toggle("拦截网站", isOn: $siteBlock).toggleStyle(.switch).fixedSize()
                    .onChange(of: siteBlock) { _, value in model.settings.setFocusSiteBlockEnabled(value) }
                Text(model.settings.focusBlockedCategories.isEmpty ? String(localized: "未选择") : model.settings.focusBlockedCategories.compactMap { model.resolver.categoriesByID[$0]?.name }.joined(separator: String(localized: "、")))
                    .font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("编辑…") { editCategories = true }.buttonStyle(.link)
            }
        }.controlSize(.small)
    }
    private var budgetColumn: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("每日限额").fontWeight(.semibold); Spacer()
                    Menu {
                        ForEach(model.resolver.categoriesByID.values.filter { category in !budgets.contains { $0.categoryID == category.id } }.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { category in
                            Button(category.name) {
                                writeBudget { try model.budgetStore?.setBudget(categoryID: category.id, dailySeconds: 45 * 60) }
                                model.requestNotificationPermission()
                            }
                        }
                    } label: { Label("添加限额", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                }
                if budgets.isEmpty { Text("添加一个分类的每日时长上限。").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(budgets, id: \.categoryID) { budget in
                    Divider()
                    budgetRow(budget)
                }
                Divider()
                Stepper("剩余 \(warn)% 时提醒", value: $warn, in: 10...30, step: 10)
                    .onChange(of: warn) { _, value in model.settings.setBudgetWarnPercent(value) }
                Text("限额只发提醒，不拦截任何东西；拦截只在专注会话里发生。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(20).workspacePanel()
            VStack(alignment: .leading, spacing: 10) {
                Toggle("每日小结", isOn: $summary).toggleStyle(.switch).fontWeight(.semibold)
                    .onChange(of: summary) { _, value in
                        model.settings.setDailySummaryEnabled(value)
                        if value { model.requestNotificationPermission() }
                    }
                Text("每天 \(model.time(Calendar.current.date(bySettingHour: model.settings.dailySummaryHour, minute: 0, second: 0, of: Date()) ?? Date())) 发一条通知：记录时长、投入、专注次数和评分。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(20).workspacePanel()
        }
    }
    private func budgetRow(_ budget: Budget) -> some View {
        let seconds = used[budget.categoryID, default: 0]
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                CategoryChip(category: model.resolver.categoriesByID[budget.categoryID])
                Spacer(minLength: 0)
                Stepper("\(budget.dailySeconds / 60) 分钟", value: Binding(get: { budget.dailySeconds / 60 }, set: { value in
                    writeBudget { try model.budgetStore?.setBudget(categoryID: budget.categoryID, dailySeconds: value * 60) }
                }), in: 5...1440, step: 5).fixedSize()
                Toggle("启用限额", isOn: Binding(get: { budget.enabled }, set: { value in
                    writeBudget { try model.budgetStore?.setEnabled(categoryID: budget.categoryID, enabled: value) }
                    if value { model.requestNotificationPermission() }
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            ProgressView(value: min(seconds, Double(budget.dailySeconds)), total: Double(budget.dailySeconds))
                // The same threshold the notification uses, not a fixed 80%.
                .tint(BudgetEngine.level(spent: seconds, limit: Double(budget.dailySeconds), warnPercent: warn) == .none
                      ? RefinedStyle.category(budget.categoryID, hex: model.resolver.categoriesByID[budget.categoryID]?.colorHex ?? "808080")
                      : RefinedStyle.warning)
            HStack {
                Text("今天 \(Format.duration(seconds)) · \(RefinedStyle.remaining(spent: seconds, limit: Double(budget.dailySeconds)))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
        }.opacity(budget.enabled ? 1 : 0.5)
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
        warn = model.settings.budgetWarnPercent; summary = model.settings.dailySummaryEnabled
    }
    private func load() {
        do {
            sessions = try model.focusStore?.sessions(overlapping: DateRangeSelection(kind: .week, anchor: Date(), firstWeekday: model.firstWeekday).interval) ?? []
            budgets = try model.budgetStore?.budgets() ?? []
            used = model.rangedSpans(for: .today()).reduce(into: [:]) { $0[$1.categoryID, default: 0] += $1.span.duration }
        } catch { self.error = String(localized: "专注记录暂时无法读取。") }
    }
}

struct OrganizationView: View {
    @Bindable var model: AppModel
    @State private var tab: SettingsTab = .uncategorized

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("管理", selection: $tab) {
                Text("待分类").tag(SettingsTab.uncategorized)
                Text("规则").tag(SettingsTab.rules)
                Text("分类列表").tag(SettingsTab.categories)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Group {
                switch tab {
                case .rules: RefinedRulesPane(model: model)
                case .categories: CategoriesSettingsPane(model: model)
                default: UncategorizedSettingsPane(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 28).background(WorkspaceBackground())
        .onChange(of: model.organizationTab, initial: true) { _, value in tab = value }
        .onChange(of: tab) { _, value in model.organizationTab = value }
        // Only rules can be searched, so only their tab shows the field.
        .pageSearchable(text: $model.organizationSearch, prompt: "搜索规则", isEnabled: tab == .rules)
        .onChange(of: model.organizationSearch) { _, value in
            if !value.isEmpty { tab = .rules; model.organizationTab = .rules }
        }
    }
}
