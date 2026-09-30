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
                if geometry.size.width >= 860 {
                    HStack(alignment: .top, spacing: 12) {
                        sessionColumn.frame(maxWidth: .infinity)
                        budgetColumn.frame(maxWidth: .infinity)
                    }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 28)
                } else {
                    VStack(spacing: 12) { sessionColumn; budgetColumn }
                        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 28)
                }
            }
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

    private var sessionColumn: some View {
        VStack(spacing: 12) {
            if model.focus?.running != nil {
                FocusRunningView(model: model).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FocusDial(minutes: $minutes)
                Text("拖动圆环上的把手，15 分钟到 2 小时").font(.system(size: 12)).foregroundStyle(.secondary)
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
                }.glassProminentButton().controlSize(.extraLarge).disabled(model.focus == nil)
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
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("限额").fontWeight(.semibold); Spacer()
                    Text("快到时黄色，超出时红色加图标").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.bottom, 4)
                if budgets.isEmpty { Text("添加一个分类的每日时长上限。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 10) }
                ForEach(Array(budgets.enumerated()), id: \.element.categoryID) { index, budget in
                    if index > 0 { Divider() }
                    budgetRow(budget)
                }
                Divider().padding(.top, 4)
                Text("限额只发提醒，不拦截任何东西；拦截只在专注会话里发生。").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(18).workspacePanel()
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
                Text("本周的专注").fontWeight(.semibold)
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
                            .fill(value == 0 ? AnyShapeStyle(.quaternary) : today ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.35)))
                            .frame(height: value == 0 ? 4 : max(4, 56 * CGFloat(value) / CGFloat(top)))
                        Text(days[index], format: .dateTime.weekday(.narrow)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 90, alignment: .bottom)
        }.font(.system(size: 13)).padding(18).workspacePanel()
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
