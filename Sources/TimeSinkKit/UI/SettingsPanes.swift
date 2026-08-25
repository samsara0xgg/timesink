import SwiftUI
import AppKit
import ServiceManagement
import os

private let settingsLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "settings")

// MARK: - 通用

/// Idle threshold, login-item registration, and permission status rows.
/// Permission checks use `prompt: false` / `ask: false` on every render (the
/// pane's `onAppear`) so opening Settings never itself triggers a system
/// prompt — only the explicit "去授权" buttons do.
struct GeneralSettingsPane: View {
    let model: AppModel

    @State private var idleThreshold: Double = 180
    @State private var loginItemEnabled = false
    @State private var loginItemAlertMessage: String?
    @State private var axState: PermissionState = .denied
    @State private var chromeState: PermissionState = .notDetermined
    @State private var calendarState: PermissionState = .notDetermined

    /// SMAppService.mainApp only functions when the app runs from
    /// /Applications; toggling elsewhere silently fails, so the control is
    /// disabled instead.
    private var runningFromApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications")
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: $idleThreshold, in: 60...900, step: 30) {
                    Text("空闲阈值：\(Int(idleThreshold)) 秒")
                }
                .onChange(of: idleThreshold) { _, newValue in
                    model.settings.setIdleThreshold(newValue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("登录时启动", isOn: loginItemBinding)
                        .disabled(!runningFromApplications)
                    if !runningFromApplications {
                        Text("安装到 /Applications 后可用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("菜单栏显示今日专注时长", isOn: menuTextBinding)
            }

            Section("权限") {
                PermissionRow(
                    title: "辅助功能",
                    state: axState,
                    action: {
                        _ = Permissions.accessibilityGranted(prompt: true)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                        refreshAccessibility()
                    }
                )
                PermissionRow(
                    title: "Chrome 自动化",
                    state: chromeState,
                    action: {
                        chromeState = Permissions.chromeAutomationState(ask: true)
                    }
                )
                Toggle("日历叠加", isOn: calendarOverlayBinding)
                PermissionRow(
                    title: "日历",
                    state: calendarState,
                    action: {
                        if calendarState == .denied {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        } else {
                            Task { @MainActor in
                                _ = await Permissions.requestCalendarAccess()
                                refreshCalendar()
                            }
                        }
                    }
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            idleThreshold = model.settings.idleThreshold
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            refreshAccessibility()
            refreshChrome()
            refreshCalendar()
        }
        .alert("登录项设置失败", isPresented: alertIsPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(loginItemAlertMessage ?? "")
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { loginItemAlertMessage != nil },
            set: { if !$0 { loginItemAlertMessage = nil } }
        )
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItemEnabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    loginItemAlertMessage = "无法\(newValue ? "启用" : "关闭")登录时启动：\(error.localizedDescription)"
                }
                loginItemEnabled = SMAppService.mainApp.status == .enabled
            }
        )
    }

    private var menuTextBinding: Binding<Bool> {
        Binding(
            get: { model.menuTextEnabled },
            set: { newValue in
                model.menuTextEnabled = newValue
                model.settings.setMenuBarTextEnabled(newValue)
            }
        )
    }

    /// Makes the overlay a real two-way switch -- previously only
    /// `ActivitiesView`'s enable card could turn it ON, with no Settings
    /// control to turn it back OFF (a one-way switch the doc comments on
    /// `AppModel.calendarOverlayEnabled` and `ActivitiesView.CalendarTaskKey`
    /// already (aspirationally) described as having a "Settings row" writer).
    private var calendarOverlayBinding: Binding<Bool> {
        Binding(
            get: { model.calendarOverlayEnabled },
            set: { newValue in
                model.calendarOverlayEnabled = newValue
                model.settings.setCalendarOverlayEnabled(newValue)
            }
        )
    }

    private func refreshAccessibility() {
        axState = Permissions.accessibilityState(prompt: false)
    }

    private func refreshChrome() {
        chromeState = Permissions.chromeAutomationState(ask: false)
    }

    private func refreshCalendar() {
        calendarState = Permissions.calendarState()
    }
}

// MARK: - 分类

/// All 12 taxonomy categories, each editable in place. Any field change
/// (color, name, productivity) persists immediately via `updateCategory`,
/// then refreshes the resolver and bumps `model.dataVersion` so Stats/
/// Activities pick up the new color/productivity right away.
struct CategoriesSettingsPane: View {
    let model: AppModel
    @State private var categories: [Category] = []

    var body: some View {
        List {
            ForEach($categories, id: \.id) { $category in
                CategoryEditRow(model: model, category: $category)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        categories = (try? model.categoryStore.allCategories()) ?? []
    }
}

/// A row's `updateCategory` write is cheap (single-row SQLite UPDATE) and
/// happens on every field mutation, per-keystroke included. But
/// `resolver.refresh()` re-reads the full domain/app/rule tables (8k+ rows)
/// on the main actor, and `model.dataChanged()` fans `dataVersion` out to
/// every open view (including this pane's own siblings — `RulesSettingsPane`
/// reloads and `UncategorizedSettingsPane` re-runs its 30-day query, and
/// `TabView` keeps visited tabs alive so both are live even when not the
/// selected tab). Doing that on every keystroke/drag event is wasteful, so
/// the two are decoupled: the write is immediate and unconditional, while
/// the refresh+dataChanged only fires once the edit "settles" —
/// `onSubmit`/focus-loss for the name field, a short debounce for the
/// continuous ColorPicker drag stream, and immediately for the productivity
/// `Picker` (a single discrete selection per event, not a continuous stream,
/// so no debounce is needed there).
private struct CategoryEditRow: View {
    let model: AppModel
    @Binding var category: Category

    @FocusState private var isNameFocused: Bool
    @State private var pendingColorRefresh: Task<Void, Never>?

    private static let colorRefreshDebounce: Duration = .milliseconds(400)

    var body: some View {
        HStack(spacing: 12) {
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28)
            TextField("名称", text: $category.name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
                .focused($isNameFocused)
                .onSubmit { commitRefresh() }
            Spacer()
            Picker("生产力", selection: $category.productivity) {
                ForEach(-2...2, id: \.self) { level in
                    Text(Self.productivityLabel(level)).tag(level)
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }
        .padding(.vertical, 2)
        .onChange(of: category.name) { _, _ in persistOnly() }
        .onChange(of: isNameFocused) { _, focused in
            if !focused { commitRefresh() }
        }
        .onChange(of: category.productivity) { _, _ in
            persistOnly()
            commitRefresh()
        }
        .onDisappear { pendingColorRefresh?.cancel() }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: category.colorHex) },
            set: { newColor in
                category.colorHex = newColor.toHex()
                persistOnly()
                scheduleDebouncedRefresh()
            }
        )
    }

    /// Writes the current `category` value to the store. Cheap and safe to
    /// call on every field mutation.
    private func persistOnly() {
        do {
            try model.categoryStore.updateCategory(category)
        } catch {
            settingsLogger.error("updateCategory failed for \(category.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Cancels any pending debounced refresh and runs the resolver
    /// refresh + `dataChanged()` fan-out immediately — the "settled" path.
    private func commitRefresh() {
        pendingColorRefresh?.cancel()
        pendingColorRefresh = nil
        model.resolver.refresh()
        model.dataChanged()
    }

    /// Debounces the refresh+dataChanged fan-out behind a short delay,
    /// restarting the timer on every call — used for the ColorPicker's
    /// continuous drag stream so the expensive work only runs once after
    /// the user stops moving the color wheel.
    private func scheduleDebouncedRefresh() {
        pendingColorRefresh?.cancel()
        pendingColorRefresh = Task { @MainActor in
            try? await Task.sleep(for: Self.colorRefreshDebounce)
            guard !Task.isCancelled else { return }
            model.resolver.refresh()
            model.dataChanged()
        }
    }

    private static func productivityLabel(_ level: Int) -> String {
        switch level {
        case -2: return "非常分心"
        case -1: return "分心"
        case 0: return "中性"
        case 1: return "生产"
        default: return "非常生产"
        }
    }
}

// MARK: - 规则

/// The two rule kinds `RulesSettingsPane` switches between via its top
/// segmented picker.
enum RuleMode: String, CaseIterable {
    case url, title

    var label: String {
        switch self {
        case .url: return "URL 规则"
        case .title: return "标题规则"
        }
    }
}

/// URL and title classification rules, switched via a top segmented picker.
/// Builtin rows are grayed and undeletable (URL rows show no delete button;
/// title rows show a Toggle instead, since a builtin title rule can be
/// disabled but never removed — see `CategoryStore.upsertUserTitleRule`).
/// The URL add row is rejected (button disabled) for an empty pattern or the
/// degenerate `re:` pattern, whose empty regex would match every URL.
struct RulesSettingsPane: View {
    let model: AppModel
    @State private var mode: RuleMode = .url

    @State private var rules: [URLRule] = []
    @State private var newPattern = ""
    @State private var newCategoryID = ""

    @State private var titleRules: [TitleRule] = []
    @State private var pendingTitleRule: PendingTitleRule?

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var isPatternValid: Bool {
        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "re:"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(RuleMode.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            if mode == .url {
                urlRuleSection
            } else {
                titleRuleSection
            }
        }
        .onAppear {
            load()
            loadTitleRules()
            if newCategoryID.isEmpty {
                newCategoryID = sortedCategories.first?.id ?? ""
            }
        }
        .onChange(of: model.dataVersion) { _, _ in
            load()
            loadTitleRules()
        }
        .sheet(item: $pendingTitleRule) { pending in
            TitleRuleEditor(model: model, pending: pending)
        }
    }

    // MARK: URL rules

    private var urlRuleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(rules, id: \.id) { rule in
                    ruleRow(rule)
                }
            }
            Divider()
            HStack {
                TextField("URL 模式", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                Picker("分类", selection: $newCategoryID) {
                    ForEach(sortedCategories, id: \.id) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button("添加") { addRule() }
                    .disabled(!isPatternValid || newCategoryID.isEmpty)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: URLRule) -> some View {
        HStack {
            Text(rule.pattern)
            Spacer()
            Text(model.resolver.categoriesByID[rule.categoryID]?.name ?? rule.categoryID)
                .foregroundStyle(.secondary)
            if rule.source == "user" {
                Button {
                    delete(rule)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(rule.source == "builtin" ? .secondary : .primary)
    }

    private func load() {
        rules = (try? model.categoryStore.urlRules())?.sorted { lhs, rhs in
            lhs.priority != rhs.priority ? lhs.priority > rhs.priority : lhs.pattern < rhs.pattern
        } ?? []
    }

    private func addRule() {
        guard isPatternValid else { return }
        let pattern = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryID = newCategoryID.isEmpty ? (sortedCategories.first?.id ?? "") : newCategoryID
        guard !categoryID.isEmpty else { return }
        do {
            try model.categoryStore.addUserURLRule(pattern: pattern, categoryID: categoryID, priority: 1000)
            model.resolver.refresh()
            model.dataChanged()
            newPattern = ""
            load()
        } catch {
            settingsLogger.error("addUserURLRule failed for \(pattern, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func delete(_ rule: URLRule) {
        guard let id = rule.id else { return }
        do {
            try model.categoryStore.deleteURLRule(id: id)
            model.resolver.refresh()
            model.dataChanged()
            load()
        } catch {
            settingsLogger.error("deleteURLRule failed for \(id): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Title rules

    private var titleRuleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(titleRules, id: \.id) { rule in
                    titleRuleRow(rule)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("+ 新建标题规则…") {
                    pendingTitleRule = PendingTitleRule(
                        prefill: "", scopeKey: "", scopeLabel: "",
                        categoryID: sortedCategories.first?.id ?? ""
                    )
                }
            }
            .padding()
        }
    }

    /// A `re:`-prefixed pattern displays as a single chip (splitting it on
    /// `|` would break a regex that itself uses `|` alternation); any other
    /// pattern splits into its keyword chips.
    private func chips(for rule: TitleRule) -> [String] {
        rule.pattern.hasPrefix("re:") ? [rule.pattern] : rule.pattern.split(separator: "|").map(String.init)
    }

    private func todayHit(for rule: TitleRule) -> (count: Int, seconds: TimeInterval) {
        TitleRuleInput.affected(items: model.rangedSpans(for: .today()), pattern: rule.pattern, scopeKey: rule.scopeKey)
    }

    @ViewBuilder
    private func titleRuleRow(_ rule: TitleRule) -> some View {
        let hit = todayHit(for: rule)
        HStack {
            HStack(spacing: 4) {
                ForEach(chips(for: rule), id: \.self) { chip in
                    Text(chip)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            Text(rule.scopeKey.isEmpty ? "全局" : rule.scopeKey)
                .foregroundStyle(.secondary)
            Spacer()
            Text(model.resolver.categoriesByID[rule.categoryID]?.name ?? rule.categoryID)
                .foregroundStyle(.secondary)
            Text(rule.source == "builtin" ? "内置" : "用户")
                .foregroundStyle(.secondary)
            Text("今日命中 \(Format.duration(hit.seconds))")
                .foregroundStyle(.secondary)
            if rule.source == "user" {
                Button {
                    deleteTitleRule(rule)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            } else {
                Toggle("", isOn: titleRuleEnabledBinding(rule))
                    .labelsHidden()
            }
        }
        .foregroundStyle(rule.source == "builtin" ? .secondary : .primary)
    }

    private func titleRuleEnabledBinding(_ rule: TitleRule) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { newValue in setTitleRuleEnabled(rule, enabled: newValue) }
        )
    }

    private func loadTitleRules() {
        titleRules = (try? model.categoryStore.titleRules())?.sorted { lhs, rhs in
            if lhs.scopeKey.isEmpty != rhs.scopeKey.isEmpty {
                return !lhs.scopeKey.isEmpty // scoped rows before global ones
            }
            if lhs.scopeKey != rhs.scopeKey {
                return lhs.scopeKey < rhs.scopeKey
            }
            return lhs.pattern < rhs.pattern
        } ?? []
    }

    private func deleteTitleRule(_ rule: TitleRule) {
        guard let id = rule.id else { return }
        do {
            try model.categoryStore.deleteTitleRule(id: id)
            model.resolver.refresh()
            model.dataChanged()
            loadTitleRules()
        } catch {
            settingsLogger.error("deleteTitleRule failed for \(id): \(String(describing: error), privacy: .public)")
        }
    }

    private func setTitleRuleEnabled(_ rule: TitleRule, enabled: Bool) {
        guard let id = rule.id else { return }
        do {
            try model.categoryStore.setTitleRuleEnabled(id: id, enabled: enabled)
            model.resolver.refresh()
            model.dataChanged()
            loadTitleRules()
        } catch {
            settingsLogger.error("setTitleRuleEnabled failed for \(id): \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - 未分类

/// Last-30-days spans that resolve to "uncategorized", aggregated by domain
/// (or bundleID for spans with no URL) and sorted by duration descending.
/// Picking a category for a row writes the user override (routed by
/// domain-vs-app exactly like `ActivityListView`'s reassignment), refreshes,
/// and removes the row from the list.
struct UncategorizedSettingsPane: View {
    let model: AppModel
    @State private var rows: [Row] = []

    private struct Row: Identifiable {
        let id: String
        let label: String
        let seconds: TimeInterval
        let isDomain: Bool
    }

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .onAppear { recompute() }
        .onChange(of: model.dataVersion) { _, _ in recompute() }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("近 30 天没有未分类的活动")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowView(_ row: Row) -> some View {
        HStack {
            Text(row.label)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Format.duration(row.seconds))
                .foregroundStyle(.secondary)
            Picker("分类", selection: pickerBinding(for: row)) {
                Text("选择分类").tag(Optional<String>.none)
                ForEach(sortedCategories, id: \.id) { category in
                    Text(category.name).tag(Optional(category.id))
                }
            }
            .labelsHidden()
            .frame(width: 140)
        }
    }

    private func pickerBinding(for row: Row) -> Binding<String?> {
        Binding(
            get: { nil },
            set: { newValue in
                guard let categoryID = newValue else { return }
                assign(row: row, categoryID: categoryID)
            }
        )
    }

    private func assign(row: Row, categoryID: String) {
        do {
            if row.isDomain {
                try model.categoryStore.setUserDomain(row.id, categoryID: categoryID)
            } else {
                try model.categoryStore.setUserApp(row.id, categoryID: categoryID)
            }
            model.resolver.refresh()
            model.dataChanged()
            rows.removeAll { $0.id == row.id }
        } catch {
            settingsLogger.error("assign failed for \(row.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func recompute() {
        let interval = DateRangeSelection(kind: .last30, anchor: Date()).interval
        do {
            let spans = try model.spanStore.spans(overlapping: interval)
            let uncategorized = spans.filter { model.resolver.categoryID(for: $0) == "uncategorized" }
            var isDomainByKey: [String: Bool] = [:]
            for span in uncategorized {
                let key = span.domain ?? span.appBundleID
                isDomainByKey[key] = span.domain != nil
            }
            let items = uncategorized.map { CategorizedSpan(span: $0, categoryID: "uncategorized") }
            rows = Aggregator.durationByDomainOrApp(items).map { entry in
                Row(id: entry.key, label: entry.label, seconds: entry.seconds, isDomain: isDomainByKey[entry.key] ?? false)
            }
        } catch {
            settingsLogger.error("uncategorized recompute failed: \(String(describing: error), privacy: .public)")
            rows = []
        }
    }
}

// MARK: - 智能分类

/// Optional OpenAI-compatible LLM classification fallback, default off. The
/// API key never touches the database -- it is read/written directly via
/// `Keychain`, keyed by `LLMCoordinator.apiKeyAccount`. Endpoint/model are
/// ordinary settings (`SettingsStore`), persisted on submit like the other
/// text fields in this file.
struct LLMSettingsPane: View {
    let model: AppModel

    @State private var enabled = false
    @State private var endpoint = ""
    @State private var modelName = ""
    @State private var apiKeyInput = ""
    @State private var apiKeyStatus: String?
    @State private var testStatus: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Toggle("启用 LLM 分类兜底", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        model.settings.setLLMEnabled(newValue)
                    }
                Text("本地规则无法归类的活动，才会调用一次 LLM 做兜底分类。默认关闭，不影响其余功能。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI 兼容服务") {
                TextField("Endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.settings.setLLMEndpoint(endpoint)
                        model.engine.llmCoordinator?.invalidateService()
                    }
                TextField("模型", text: $modelName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.settings.setLLMModel(modelName)
                        model.engine.llmCoordinator?.invalidateService()
                    }
                SecureField("API Key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveKey() }
                if let apiKeyStatus {
                    Text(apiKeyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("测试") { runTest() }
                        .disabled(isTesting)
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let testStatus {
                    Text(testStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            enabled = model.settings.llmEnabled
            endpoint = model.settings.llmEndpoint
            modelName = model.settings.llmModel
        }
    }

    private func saveKey() {
        do {
            try Keychain.set(apiKeyInput, account: LLMCoordinator.apiKeyAccount)
            model.engine.llmCoordinator?.invalidateService()
            apiKeyStatus = "已保存"
        } catch {
            apiKeyStatus = "保存失败：\(String(describing: error))"
        }
    }

    /// Runs one classification against `example-blog.net` with the
    /// currently-entered fields (falling back to the stored Keychain key if
    /// the field is empty, so a previously-saved key can be re-tested
    /// without retyping it), and shows the resulting category id or error.
    private func runTest() {
        guard let url = URL(string: endpoint) else {
            testStatus = "Endpoint 无效"
            return
        }
        let key = apiKeyInput.isEmpty ? (Keychain.get(account: LLMCoordinator.apiKeyAccount) ?? "") : apiKeyInput
        guard !key.isEmpty else {
            testStatus = "请先填写 API Key"
            return
        }
        isTesting = true
        testStatus = nil
        let classifier = OpenAIDomainClassifier(endpoint: url, apiKey: key, model: modelName)
        Task { @MainActor in
            do {
                let categoryID = try await classifier.classify(domain: "example-blog.net", title: nil)
                testStatus = "分类结果：\(categoryID)"
            } catch {
                testStatus = "测试失败：\(String(describing: error))"
            }
            isTesting = false
        }
    }
}
