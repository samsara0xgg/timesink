import SwiftUI
import AppKit
import ApplicationServices
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
    @State private var accessibilityGranted = false
    @State private var chromeStatus: OSStatus = noErr

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
            }

            Section("权限") {
                accessibilityRow
                chromeRow
            }
        }
        .formStyle(.grouped)
        .onAppear {
            idleThreshold = model.settings.idleThreshold
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            refreshAccessibility()
            refreshChrome()
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

    private var accessibilityRow: some View {
        HStack {
            Circle()
                .fill(accessibilityGranted ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text("辅助功能")
            Spacer()
            Text(accessibilityGranted ? "已授权" : "未授权")
                .foregroundStyle(accessibilityGranted ? .green : .red)
            Button("去授权") {
                _ = Permissions.accessibilityGranted(prompt: true)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
                refreshAccessibility()
            }
        }
    }

    private var chromeRow: some View {
        HStack {
            Circle()
                .fill(chromeStatusColor)
                .frame(width: 8, height: 8)
            Text("Chrome 自动化")
            Spacer()
            Text(chromeStatusText)
                .foregroundStyle(chromeStatusColor)
            Button("去授权") {
                chromeStatus = Permissions.chromeAutomationStatus(ask: true)
            }
        }
    }

    private var chromeStatusText: String {
        switch chromeStatus {
        case noErr: return "已授权"
        case -600: return "Chrome 未运行"
        default: return "未授权"
        }
    }

    private var chromeStatusColor: Color {
        switch chromeStatus {
        case noErr: return .green
        case -600: return .secondary
        default: return .red
        }
    }

    private func refreshAccessibility() {
        accessibilityGranted = Permissions.accessibilityGranted(prompt: false)
    }

    private func refreshChrome() {
        chromeStatus = Permissions.chromeAutomationStatus(ask: false)
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

/// All URL classification rules. Builtin rows are grayed and undeletable;
/// user rows carry a delete button. The add row is rejected (button
/// disabled) for an empty pattern or the degenerate `re:` pattern, whose
/// empty regex would match every URL.
struct RulesSettingsPane: View {
    let model: AppModel
    @State private var rules: [URLRule] = []
    @State private var newPattern = ""
    @State private var newCategoryID = ""

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var isPatternValid: Bool {
        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "re:"
    }

    var body: some View {
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
        .onAppear {
            load()
            if newCategoryID.isEmpty {
                newCategoryID = sortedCategories.first?.id ?? ""
            }
        }
        .onChange(of: model.dataVersion) { _, _ in load() }
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
