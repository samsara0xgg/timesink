import SwiftUI
import AppKit
import os

private let budgetSettingsLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "budgetSettings")

/// 预算 tab: per-category daily budgets (add/enable/step/delete), the
/// early-warn percent, the daily summary toggle+hour, and the two
/// focus-block lists (apps via a running-apps picker sheet, site categories
/// via multi-select chips). Follows `RulesSettingsPane`'s load/mutate/reload
/// convention: every write goes straight to the store, then `load()` re-reads
/// so the list shown always reflects what's actually persisted.
struct BudgetSettingsPane: View {
    let model: AppModel

    @State private var budgets: [Budget] = []
    @State private var warnPercent = 20
    @State private var summaryEnabled = false
    @State private var summaryHour = 19
    @State private var blockedApps: [String] = []
    @State private var blockedCategories: [String] = []
    @State private var showingAppEditor = false

    private static let stepSeconds = 900   // 15 分钟
    private static let minSeconds = 900    // 下限 15 分钟
    private static let newBudgetDefaultSeconds = 3600

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var categoriesWithoutBudget: [Category] {
        let budgeted = Set(budgets.map(\.categoryID))
        return sortedCategories.filter { !budgeted.contains($0.id) }
    }

    var body: some View {
        Form {
            Section("分类预算") {
                ForEach(budgets, id: \.categoryID) { budget in
                    budgetRow(budget)
                }
                Menu("+ 添加分类预算…") {
                    ForEach(categoriesWithoutBudget, id: \.id) { category in
                        Button(category.name) { addBudget(categoryID: category.id) }
                    }
                }
                .disabled(categoriesWithoutBudget.isEmpty)

                Stepper(value: warnPercentBinding, in: 10...30, step: 10) {
                    Text("提前预警：剩 \(warnPercent)% 时提醒")
                }
            }

            Section("每日小结") {
                Toggle("启用每日小结", isOn: summaryEnabledBinding)
                Stepper(value: summaryHourBinding, in: 0...23) {
                    Text("整点：\(summaryHour) 点")
                }
            }

            Section("专注拦截应用") {
                blockedAppsChips
                Button("编辑…") { showingAppEditor = true }
            }

            Section("专注拦截网站分类") {
                categoryChipsGrid
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
        .sheet(isPresented: $showingAppEditor) {
            FocusBlockedAppsEditor(model: model, blockedApps: $blockedApps)
        }
    }

    // MARK: - 分类预算 row

    @ViewBuilder
    private func budgetRow(_ budget: Budget) -> some View {
        let category = model.resolver.categoriesByID[budget.categoryID]
        HStack(spacing: 8) {
            Circle().fill(Color(hex: category?.colorHex ?? "#8E8E93")).frame(width: 8, height: 8)
            Text(category?.name ?? budget.categoryID)
                .frame(width: 80, alignment: .leading)
            Toggle("", isOn: enabledBinding(budget))
                .labelsHidden()
            Spacer()
            Button {
                adjustBudget(budget, deltaSeconds: -Self.stepSeconds)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .disabled(budget.dailySeconds <= Self.minSeconds)
            Text("每日上限 \(Format.duration(TimeInterval(budget.dailySeconds)))")
                .frame(width: 110, alignment: .center)
            Button {
                adjustBudget(budget, deltaSeconds: Self.stepSeconds)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            Button {
                deleteBudget(budget)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private func enabledBinding(_ budget: Budget) -> Binding<Bool> {
        Binding(
            get: { budget.enabled },
            set: { newValue in setEnabled(budget, enabled: newValue) }
        )
    }

    // MARK: - 专注拦截应用 chips

    @ViewBuilder
    private var blockedAppsChips: some View {
        if blockedApps.isEmpty {
            Text("未设置").font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(blockedApps, id: \.self) { bundleID in
                        Text(bundleID)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
        }
    }

    // MARK: - 专注拦截网站分类 chips

    private var categoryChipsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(sortedCategories, id: \.id) { category in
                categoryChip(category)
            }
        }
    }

    private func categoryChip(_ category: Category) -> some View {
        let isOn = blockedCategories.contains(category.id)
        return Button {
            toggleBlockedCategory(category.id)
        } label: {
            Text(category.name)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Load

    private func load() {
        if let store = model.budgetStore {
            let categories = model.resolver.categoriesByID
            budgets = ((try? store.budgets()) ?? []).sorted { lhs, rhs in
                (categories[lhs.categoryID]?.sortOrder ?? 0) < (categories[rhs.categoryID]?.sortOrder ?? 0)
            }
        } else {
            budgets = []
        }
        warnPercent = model.settings.budgetWarnPercent
        summaryEnabled = model.settings.dailySummaryEnabled
        summaryHour = model.settings.dailySummaryHour
        blockedApps = model.settings.focusBlockedApps
        blockedCategories = model.settings.focusBlockedCategories
    }

    // MARK: - Mutations

    /// Fired the first time any budget is enabled (a fresh add, or flipping
    /// an existing row's Toggle on) or the daily summary is turned on, per
    /// the brief -- `requestAuthorization()` is safe to call repeatedly (a
    /// no-op once already authorized/denied), so no extra "was this really
    /// the first time" bookkeeping is needed.
    private func requestNotificationAuthorizationIfNeeded() {
        guard let notifier = model.notifier else { return }
        Task { await notifier.requestAuthorization() }
    }

    private func addBudget(categoryID: String) {
        do {
            try model.budgetStore?.setBudget(categoryID: categoryID, dailySeconds: Self.newBudgetDefaultSeconds)
            requestNotificationAuthorizationIfNeeded()
            load()
        } catch {
            budgetSettingsLogger.error("setBudget(add) failed for \(categoryID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func setEnabled(_ budget: Budget, enabled: Bool) {
        do {
            try model.budgetStore?.setEnabled(categoryID: budget.categoryID, enabled: enabled)
            if enabled { requestNotificationAuthorizationIfNeeded() }
            load()
        } catch {
            budgetSettingsLogger.error("setEnabled failed for \(budget.categoryID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func adjustBudget(_ budget: Budget, deltaSeconds: Int) {
        let newValue = max(Self.minSeconds, budget.dailySeconds + deltaSeconds)
        do {
            try model.budgetStore?.setBudget(categoryID: budget.categoryID, dailySeconds: newValue)
            load()
        } catch {
            budgetSettingsLogger.error("setBudget(adjust) failed for \(budget.categoryID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func deleteBudget(_ budget: Budget) {
        do {
            try model.budgetStore?.deleteBudget(categoryID: budget.categoryID)
            load()
        } catch {
            budgetSettingsLogger.error("deleteBudget failed for \(budget.categoryID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private var warnPercentBinding: Binding<Int> {
        Binding(
            get: { warnPercent },
            set: { newValue in
                warnPercent = newValue
                model.settings.setBudgetWarnPercent(newValue)
            }
        )
    }

    private var summaryEnabledBinding: Binding<Bool> {
        Binding(
            get: { summaryEnabled },
            set: { newValue in
                summaryEnabled = newValue
                model.settings.setDailySummaryEnabled(newValue)
                if newValue { requestNotificationAuthorizationIfNeeded() }
            }
        )
    }

    private var summaryHourBinding: Binding<Int> {
        Binding(
            get: { summaryHour },
            set: { newValue in
                summaryHour = newValue
                model.settings.setDailySummaryHour(newValue)
            }
        )
    }

    private func toggleBlockedCategory(_ categoryID: String) {
        if let idx = blockedCategories.firstIndex(of: categoryID) {
            blockedCategories.remove(at: idx)
        } else {
            blockedCategories.append(categoryID)
        }
        model.settings.setFocusBlockedCategories(blockedCategories)
    }
}

/// Sheet for `BudgetSettingsPane`'s "专注拦截应用" row: a checklist of
/// currently-running regular (Dock-visible, `.activationPolicy == .regular`)
/// apps, plus a manual bundle-ID entry row for apps not running right now
/// (a not-currently-running app can't otherwise be picked). Saves straight
/// to `SettingsStore.setFocusBlockedApps` and writes back through the
/// `blockedApps` binding so the pane's chip row updates immediately.
struct FocusBlockedAppsEditor: View {
    let model: AppModel
    var title = String(localized: "选择专注期间隐藏的应用")
    var onSave: (([String]) -> Void)? = nil
    @Binding var blockedApps: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var apps: [(id: String, name: String)] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .semibold))
            TextField("搜索已安装的应用", text: $search).textFieldStyle(.roundedBorder)
            List(apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.id) { app in
                Toggle(isOn: Binding(get: { selected.contains(app.id) }, set: { value in
                    if value { selected.insert(app.id) } else { selected.remove(app.id) }
                })) {
                    HStack(spacing: 10) { AppIcon(bundleID: app.id); Text(app.name) }
                }.padding(.vertical, 3)
            }.listStyle(.inset)
            Text(onSave == nil ? "只在专注时隐藏，记录照常；修改从下一次专注开始生效。" : "选中的应用不会记录活动或保存屏幕画面。密码管理器始终不记录。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("已选择 \(selected.count) 个").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    blockedApps = selected.sorted(); if let onSave { onSave(blockedApps) } else { model.settings.setFocusBlockedApps(blockedApps) }; dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 420, height: 480)
        .onAppear {
            selected = Set(blockedApps)
            // Only inspect application bundles; never launch or request permissions.
            var found: [String: String] = [:]
            for root in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
                guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in enumerator where url.pathExtension == "app" {
                    if let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier {
                        found[id] = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                    }
                }
            }
            for id in blockedApps where found[id] == nil { found[id] = AppIcon.name(for: id) }
            apps = found.map { (id: $0.key, name: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
