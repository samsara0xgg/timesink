import SwiftUI
import AppKit
import ServiceManagement
import os

private let settingsLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "settings")

// MARK: - 分类

/// All 12 taxonomy categories, each editable in place. Any field change
/// (color, name, productivity) persists immediately via `updateCategory`,
/// then refreshes the resolver and bumps `model.dataVersion` so Stats/
/// Activities pick up the new color/productivity right away.
struct CategoriesSettingsPane: View {
    let model: AppModel
    @State private var categories: [Category] = []

    var body: some View {
        // One pass for every card, and re-read as today's records grow.
        let today = Aggregator.durationByCategory(model.rangedSpans(for: .today()))
        let _ = model.dataVersion
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach($categories, id: \.id) { $category in
                    CategoryEditRow(model: model, category: $category, todaySeconds: today[category.id] ?? 0)
                }
            }
        }.onAppear { load() }
    }

    private func load() {
        categories = (try? model.categoryStore.allCategories()) ?? []
    }
}

/// A row's `updateCategory` write is cheap (single-row SQLite UPDATE) and
/// happens on every field mutation, per-keystroke included. The follow-up
/// used to be `resolver.refresh()` + `model.dataChanged()`, which re-read the
/// full domain/app/rule tables, wiped the classification memo (~600 ms on the
/// next recompute, against 14 ms warm) and cleared the range cache. None of
/// that is needed here: this row edits a category's name, color, productivity
/// and sort order, and a span's classification depends on none of them. It
/// now calls `refreshCategories()` + `categoryMetadataChanged()`, which reload
/// 12 category rows and leave both caches standing.
///
/// The `dataVersion` bump still fans out to every open view (including this
/// pane's own siblings — `TabView` keeps visited tabs alive), so the write and
/// the fan-out remain decoupled: the write is immediate and unconditional,
/// while the refresh+fan-out only fires once the edit "settles" —
/// `onSubmit`/focus-loss for the name field, a short debounce for the
/// continuous ColorPicker drag stream, and immediately for the productivity
/// `Picker` (a single discrete selection per event, not a continuous stream,
/// so no debounce is needed there).
private struct CategoryEditRow: View {
    let model: AppModel
    @Binding var category: Category
    let todaySeconds: TimeInterval

    @FocusState private var isNameFocused: Bool
    @State private var pendingColorRefresh: Task<Void, Never>?
    /// Written to the store but not yet published to the rest of the app.
    @State private var unpublished = false

    private static let colorRefreshDebounce: Duration = .milliseconds(400)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ColorPicker(String(localized: "\(category.name)的颜色"), selection: colorBinding, supportsOpacity: false).labelsHidden().fixedSize()
                    .contextMenu {
                        if let shipped = RefinedStyle.shippedHex(category.id), shipped != category.colorHex {
                            Button("恢复默认颜色") { category.colorHex = shipped; persistOnly(); commitRefresh() }
                        }
                    }
                TextField(String(localized: "\(category.name)的名称"), text: $category.name)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .focused($isNameFocused).onSubmit { commitRefresh() }
                Text(todaySeconds == 0 ? "—" : Format.duration(todaySeconds)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            Picker(String(localized: "\(category.name)的投入程度"), selection: $category.productivity) {
                ForEach(-2...2, id: \.self) { level in
                    Text(level > 0 ? "+\(level)" : "\(level)").tag(level).help(Self.productivityLabel(level))
                }
            }.pickerStyle(.segmented).labelsHidden()
            Text(Self.productivityLabel(category.productivity) + (category.productivity >= 1 ? String(localized: " · 计入投入时长") : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 12).workspacePanel()
        .onChange(of: category.name) { _, _ in persistOnly() }
        .onChange(of: isNameFocused) { _, focused in
            if !focused { commitRefresh() }
        }
        .onChange(of: category.productivity) { _, _ in
            persistOnly()
            commitRefresh()
        }
        // Leaving mid-edit publishes the edit instead of dropping it.
        .onDisappear { if unpublished { commitRefresh() } }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { RefinedStyle.category(category.id, hex: category.colorHex) },
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
        // An empty name is never stored; the field gets the stored one back
        // when editing ends.
        guard !category.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try model.categoryStore.updateCategory(category)
            unpublished = true
        } catch {
            settingsLogger.error("updateCategory failed for \(category.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Cancels any pending debounced refresh and runs the resolver
    /// refresh + `dataChanged()` fan-out immediately — the "settled" path.
    private func commitRefresh() {
        pendingColorRefresh?.cancel()
        pendingColorRefresh = nil
        if category.name.trimmingCharacters(in: .whitespaces).isEmpty,
           let stored = model.resolver.categoriesByID[category.id]?.name {
            category.name = stored
        }
        unpublished = false
        model.resolver.refreshCategories()
        model.categoryMetadataChanged()
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
            unpublished = false
            model.resolver.refreshCategories()
            model.categoryMetadataChanged()
        }
    }

    private static func productivityLabel(_ level: Int) -> String {
        switch level {
        case -2: return String(localized: "非常分心")
        case -1: return String(localized: "分心")
        case 0: return String(localized: "中性")
        case 1: return String(localized: "投入")
        default: return String(localized: "非常投入")
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
    @State private var accepted: [String: String] = [:]
    @State private var error: String?
    @State private var suggestions: [String: ClassificationSuggestion] = [:]

    /// Set by a user edit made elsewhere; the 30-day reload runs once, when
    /// this pane is on screen, instead of once per edit.
    @State private var needsRecompute = true
    /// The edit version this pane's own assignment produced: its rows are
    /// already updated in place, so it skips the 30-day reload.
    @State private var ownEditVersion = -1
    @State private var loadFailed = false

    private struct Row: Identifiable {
        let id: String
        let label: String
        let seconds: TimeInterval
        let isDomain: Bool
    }

    private var chipWidth: CGFloat { RefinedStyle.chipWidth(for: model.resolver.categoriesByID) }
    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Group {
            if rows.isEmpty && loadFailed {
                ContentUnavailableView("待分类暂时无法读取", systemImage: "exclamationmark.triangle",
                                       description: Text("记录没有丢失。稍后切回这里会再试一次。"))
            } else if rows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("近 30 天有 \(rows.filter { accepted[$0.id] == nil }.count) 项还没有分类，合计 \(Format.duration(rows.filter { accepted[$0.id] == nil }.reduce(0) { $0 + $1.seconds }))")
                            .font(.system(size: 13, weight: .semibold))
                        Text("按用时从多到少。建议只在你点接受后生效。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if !suggestions.isEmpty {
                            Button("接受全部建议") {
                                for row in rows where accepted[row.id] == nil {
                                    if let suggestion = suggestions[row.id] { assign(row: row, categoryID: suggestion.categoryID, publish: false) }
                                }
                                publishAssignments()
                            }.controlSize(.small)
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    ScrollView {
                        LazyVStack(spacing: 0) { ForEach(rows) { row in Divider(); rowView(row).padding(.horizontal, 14).frame(minHeight: 48) } }
                    }
                }.workspacePanel()
            }
        }
        .onAppear { recomputeIfVisibleAndStale() }
        // User edits only: a 30-day pass per tracker write would stall the
        // pane every few seconds while it is open.
        .onChange(of: model.dataEditVersion) { _, version in
            guard version != ownEditVersion else { return }
            needsRecompute = true
            recomputeIfVisibleAndStale()
        }
        .onChange(of: model.organizationTab) { _, _ in recomputeIfVisibleAndStale() }
    }

    /// `recompute()` reads 30 days of spans and classifies each one, so it
    /// runs only when this pane is actually on screen and something has
    /// changed since it last ran.
    private func recomputeIfVisibleAndStale() {
        guard model.organizationTab == .uncategorized, needsRecompute else { return }
        needsRecompute = false
        recompute()
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
        HStack(spacing: 12) {
            ActivityIcon(bundleID: row.id, domain: row.isDomain ? row.id : nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label).font(.system(size: 13)).lineLimit(1)
                Text(row.isDomain ? "网站" : "应用").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.duration(row.seconds)).font(.system(size: 12)).monospacedDigit()
                ProgressView(value: row.seconds, total: max(1, rows.map(\.seconds).max() ?? 1)).tint(.secondary)
            }.frame(width: 110)
            if let category = accepted[row.id] {
                CategoryChip(category: model.resolver.categoriesByID[category]).frame(width: max(140, chipWidth), alignment: .leading)
                Label("已归类", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.green).frame(width: 90)
            } else {
                if let suggestion = suggestions[row.id] {
                    VStack(alignment: .leading, spacing: 3) {
                        CategoryChip(category: model.resolver.categoriesByID[suggestion.categoryID])
                        Text("模型建议").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(width: chipWidth, alignment: .leading)
                    Button("接受") { assign(row: row, categoryID: suggestion.categoryID) }.controlSize(.small)
                }
                Picker("分类", selection: pickerBinding(for: row)) {
                    Text("选择分类").tag(Optional<String>.none)
                    ForEach(sortedCategories.filter { $0.id != "uncategorized" }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(minWidth: 130).fixedSize()
            }
        }.opacity(accepted[row.id] == nil ? 1 : 0.55)
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

    /// `publish: false` lets 接受全部建议 refresh the classifier once for the
    /// whole batch instead of once per row.
    private func assign(row: Row, categoryID: String, publish: Bool = true) {
        do {
            if row.isDomain {
                try model.categoryStore.setUserDomain(row.id, categoryID: categoryID)
            } else {
                try model.categoryStore.setUserApp(row.id, categoryID: categoryID)
            }
            try model.categoryStore.dismissSuggestion(key: row.id, kind: row.isDomain ? "domain" : "app")
            suggestions[row.id] = nil
            accepted[row.id] = categoryID
            if publish { publishAssignments() }
            error = nil
        } catch {
            self.error = String(localized: "分类未保存，请重试。")
            settingsLogger.error("assign failed for \(row.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func publishAssignments() {
        model.resolver.refresh()
        model.dataChanged()
        ownEditVersion = model.dataEditVersion
    }

    private func recompute() {
        let interval = DateRangeSelection(kind: .last30, anchor: Date()).interval
        do {
            suggestions = Dictionary(uniqueKeysWithValues: try model.categoryStore.suggestions().map { ($0.key, $0) })
            let spans = try model.spanStore.spans(overlapping: interval).compactMap { span -> Span? in
                guard span.end > interval.start, span.start < interval.end else { return nil }
                var clipped = span; clipped.start = max(span.start, interval.start); clipped.end = min(span.end, interval.end); return clipped
            }
            let uncategorized = spans.filter { model.resolver.categoryID(for: $0) == "uncategorized" }
            var isDomainByKey: [String: Bool] = [:]
            for span in uncategorized {
                let key = span.domain ?? span.appBundleID
                isDomainByKey[key] = span.domain != nil
            }
            let items = uncategorized.map { CategorizedSpan(span: $0, categoryID: "uncategorized") }
            let fresh = Aggregator.durationByDomainOrApp(items).map { entry in
                Row(id: entry.key, label: entry.label, seconds: entry.seconds, isDomain: isDomainByKey[entry.key] ?? false)
            }
            let freshIDs = Set(fresh.map(\.id))
            rows = fresh + rows.filter { accepted[$0.id] != nil && !freshIDs.contains($0.id) }
            loadFailed = false
        } catch {
            settingsLogger.error("uncategorized recompute failed: \(String(describing: error), privacy: .public)")
            loadFailed = true
            needsRecompute = true
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
    @State private var hasStoredKey = false
    @State private var apiKeyStatus: String?
    @State private var testStatus: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                Toggle("用模型给没分类的网站提建议", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        model.settings.setLLMEnabled(newValue)
                    }
                Text("只发送网站域名，不发送标题和网址路径。建议只在你接受后生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("OpenAI 兼容服务") {
                TextField("地址", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitFields)
                TextField("模型", text: $modelName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitFields)
                HStack {
                    // Never shows the stored key; typing replaces it.
                    SecureField(hasStoredKey ? String(localized: "已保存 · 输入新密钥可替换") : String(localized: "API 密钥"), text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveKey() }
                    if hasStoredKey {
                        Button("移除密钥", role: .destructive) { removeKey() }
                    }
                }
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
            hasStoredKey = !(Keychain.get(account: LLMCoordinator.apiKeyAccount) ?? "").isEmpty
        }
        // Switching tabs must not drop what was typed.
        .onDisappear(perform: commitFields)
    }

    private func commitFields() {
        guard endpoint != model.settings.llmEndpoint || modelName != model.settings.llmModel else { return }
        model.settings.setLLMEndpoint(endpoint)
        model.settings.setLLMModel(modelName)
        model.engine.llmCoordinator?.invalidateService()
    }

    /// An empty field is not a request to erase the key; 移除密钥 is.
    private func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try Keychain.set(key, account: LLMCoordinator.apiKeyAccount)
            model.engine.llmCoordinator?.invalidateService()
            apiKeyInput = ""
            hasStoredKey = true
            apiKeyStatus = String(localized: "已保存")
        } catch {
            apiKeyStatus = String(localized: "保存失败：\(error.localizedDescription)")
        }
    }

    private func removeKey() {
        Keychain.delete(account: LLMCoordinator.apiKeyAccount)
        model.engine.llmCoordinator?.invalidateService()
        hasStoredKey = false
        apiKeyStatus = String(localized: "已移除，建议会停止")
    }

    /// Runs one classification against `example-blog.net` with the
    /// currently-entered fields (falling back to the stored Keychain key if
    /// the field is empty, so a previously-saved key can be re-tested
    /// without retyping it), and shows the resulting category id or error.
    private func runTest() {
        commitFields()
        guard let url = URL(string: endpoint) else {
            testStatus = String(localized: "Endpoint 无效")
            return
        }
        let typed = !apiKeyInput.isEmpty
        let key = typed ? apiKeyInput : (Keychain.get(account: LLMCoordinator.apiKeyAccount) ?? "")
        guard !key.isEmpty else {
            testStatus = String(localized: "请先填写 API Key")
            return
        }
        isTesting = true
        testStatus = nil
        let classifier = OpenAIDomainClassifier(endpoint: url, apiKey: key, model: modelName)
        Task { @MainActor in
            do {
                let categoryID = try await classifier.classify(domain: "example-blog.net", title: nil)
                let result = "example-blog.net → \(model.resolver.categoriesByID[categoryID]?.name ?? categoryID)"
                // A typed key proves itself, not the stored one.
                testStatus = typed ? String(localized: "\(result) · 用的是输入框里还没保存的密钥，按回车保存") : result
            } catch {
                testStatus = String(localized: "测试失败：\(error.localizedDescription)")
            }
            isTesting = false
        }
    }
}
