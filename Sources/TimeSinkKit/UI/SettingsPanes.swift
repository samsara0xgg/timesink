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
    /// Spec §11's fourth permission. Cached rather than read per render
    /// because the underlying read is async/callback-based -- refreshed on
    /// `onAppear` and after the row's own action, never polled.
    @State private var notificationState: PermissionState = .notDetermined
    @State private var autoCheckUpdates = false

    /// Whether the four permission probes have run since the app last became
    /// active -- see `refreshPermissionsIfNeeded()`.
    @State private var didProbePermissions = false

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
                Toggle("日历叠加", isOn: calendarOverlayBinding)
            }

            if let updates = model.updates {
                Section("更新") {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { autoCheckUpdates },
                        set: { updates.automaticallyChecks = $0; autoCheckUpdates = $0 }
                    ))
                    HStack {
                        Text("当前版本 \(Updates.version)")
                        Spacer()
                        Button("检查更新…") { updates.checkForUpdates() }
                    }
                }
            }

            Section("权限") {
                PermissionRow(
                    title: String(localized: "辅助功能"),
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
                    title: String(localized: "Chrome 自动化"),
                    state: chromeState,
                    action: {
                        chromeState = Permissions.chromeAutomationState(ask: true)
                    }
                )
                PermissionRow(
                    title: String(localized: "日历"),
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
                // Spec §8: once the one-shot authorization prompt (fired by
                // 首次启用预算 / 首次开始专注) has been declined, the system
                // never prompts again -- this row is the ONLY user-visible
                // recovery path, and the only place the app admits that
                // budget alerts / 每日小结 / 专注结束提醒 are being dropped.
                PermissionRow(
                    title: String(localized: "通知"),
                    state: notificationState,
                    action: {
                        if notificationState == .denied {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        } else {
                            Task { @MainActor in
                                _ = await model.notifier?.requestAuthorization()
                                await refreshNotification()
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
            autoCheckUpdates = model.updates?.automaticallyChecks ?? false
            refreshPermissionsIfNeeded()
        }
        // The user grants or revokes a permission in System Settings, which
        // means leaving and returning to this app -- so reactivation, not a
        // tab switch, is when the answers can actually have changed. This
        // only marks them stale; `refreshPermissionsIfNeeded` decides whether
        // 通用 is actually on screen, because `TabView` keeps this pane (and
        // this subscription) alive while the user works on another tab.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            didProbePermissions = false
            refreshPermissionsIfNeeded()
        }
        .onChange(of: model.settingsTab) { _, _ in refreshPermissionsIfNeeded() }
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
                    loginItemAlertMessage = newValue
                        ? String(localized: "无法启用登录时启动：\(error.localizedDescription)")
                        : String(localized: "无法关闭登录时启动：\(error.localizedDescription)")
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
    ///
    /// The `Task { await model.refreshCalendarWindows() }` closes the same
    /// gap FOLD-IN 10 closed on the Activities card's enable path, on this
    /// second path into the same setting: without it, turning the overlay
    /// OFF here leaves `AppModel.todayMeetingEvents` (and therefore
    /// `isNowInMeeting`) stale for up to 5 minutes -- exempting idle
    /// detection off a meeting window that, from the user's perspective,
    /// should have stopped applying the instant they flipped the switch --
    /// and turning it ON here leaves the exemption inert for the same
    /// window instead of picking up today's meetings immediately.
    /// `refreshCalendarWindows()` itself already clears `todayMeetingEvents`
    /// on the disabled path (its `guard` short-circuits on
    /// `calendarOverlayEnabled` before ever reaching `Permissions
    /// .calendarState()`), so this is safe to call unconditionally on
    /// either direction of the toggle.
    private var calendarOverlayBinding: Binding<Bool> {
        Binding(
            get: { model.calendarOverlayEnabled },
            set: { newValue in
                model.calendarOverlayEnabled = newValue
                model.settings.setCalendarOverlayEnabled(newValue)
                Task { @MainActor in
                    await model.refreshCalendarWindows()
                }
            }
        )
    }

    /// `TabView` re-runs `onAppear` every time 通用 becomes the selected tab,
    /// and `refreshChrome()` is a synchronous
    /// `AEDeterminePermissionToAutomateTarget` -- an Apple Event/TCC
    /// round-trip to another process on the main thread, and the
    /// `Permissions.chromeAutomationStatus(ask:)` frame the 60s sample caught
    /// 108 times. None of these four answers can change while the app stays
    /// frontmost, so probe once per activation instead of once per tab
    /// switch.
    ///
    /// Gated on 通用 being the selected tab for the same reason its sibling
    /// panes are: `TabView` keeps every visited pane mounted, so this pane's
    /// activation subscription stays live while the user works on 规则 or
    /// 预算, and without the guard every Cmd-Tab back into the app would run
    /// the Chrome round-trip for a pane nobody is looking at. Reactivation
    /// only marks the answers stale; the probe itself waits until the pane is
    /// on screen, which `onChange(of: model.settingsTab)` delivers.
    private func refreshPermissionsIfNeeded() {
        guard model.settingsTab == .general, !didProbePermissions else { return }
        didProbePermissions = true
        refreshAccessibility()
        refreshChrome()
        refreshCalendar()
        Task { @MainActor in await refreshNotification() }
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

    /// Reads through the injected `Notifying` (never `UNUserNotificationCenter`
    /// directly) so this pane stays safe in a bundle-less process.
    private func refreshNotification() async {
        notificationState = await Permissions.notificationState(model.notifier)
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
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach($categories, id: \.id) { $category in
                    CategoryEditRow(model: model, category: $category)
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

    @FocusState private var isNameFocused: Bool
    @State private var pendingColorRefresh: Task<Void, Never>?

    private static let colorRefreshDebounce: Duration = .milliseconds(400)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ColorPicker("分类颜色", selection: colorBinding, supportsOpacity: false).labelsHidden().fixedSize()
                TextField("名称", text: $category.name)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .focused($isNameFocused).onSubmit { commitRefresh() }
                let seconds = model.rangedSpans(for: .today()).filter { $0.categoryID == category.id }.reduce(0) { $0 + $1.span.duration }
                Text(seconds == 0 ? "—" : Format.duration(seconds)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            Picker("投入程度", selection: $category.productivity) {
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
        .onDisappear { pendingColorRefresh?.cancel() }
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

// MARK: - 规则

/// The two rule kinds `RulesSettingsPane` switches between via its top
/// segmented picker.
enum RuleMode: String, CaseIterable {
    case url, title

    var label: String {
        switch self {
        case .url: return String(localized: "URL 规则")
        case .title: return String(localized: "标题规则")
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

    /// Set when `dataVersion` bumps while this pane is not the selected tab.
    /// `TabView` keeps every visited pane mounted, so its `.onChange`
    /// handlers keep firing for edits made on other tabs -- without this the
    /// pane reloads itself while off screen, and an edit on one tab pays for
    /// the work of every other tab the user has ever opened. Reloading on
    /// becoming visible again is not enough on its own either: that would
    /// put the cost back on every tab switch even when nothing changed.
    @State private var needsReload = true

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
            reloadIfVisibleAndStale()
            if newCategoryID.isEmpty {
                newCategoryID = sortedCategories.first?.id ?? ""
            }
        }
        .onChange(of: model.dataVersion) { _, _ in
            needsReload = true
            reloadIfVisibleAndStale()
        }
        .onChange(of: model.organizationTab) { _, _ in reloadIfVisibleAndStale() }
        .sheet(item: $pendingTitleRule) { pending in
            TitleRuleEditor(model: model, pending: pending)
        }
    }

    private func reloadIfVisibleAndStale() {
        guard model.organizationTab == .rules, needsReload else { return }
        needsReload = false
        load()
        loadTitleRules()
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
            Text(rule.scopeKey.isEmpty ? String(localized: "全局") : rule.scopeKey)
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
    @State private var accepted: [String: String] = [:]
    @State private var error: String?
    @State private var suggestions: [String: ClassificationSuggestion] = [:]

    /// Set when `dataVersion` bumps while this pane is not the selected tab.
    /// `TabView` keeps every visited pane mounted, so its `.onChange`
    /// handlers keep firing for edits made on other tabs -- without this the
    /// pane reloads itself while off screen, and an edit on one tab pays for
    /// the work of every other tab the user has ever opened. Reloading on
    /// becoming visible again is not enough on its own either: that would
    /// put the cost back on every tab switch even when nothing changed.
    @State private var needsRecompute = true

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
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("近 30 天有 \(rows.filter { accepted[$0.id] == nil }.count) 项还没有分类，合计 \(Format.duration(rows.filter { accepted[$0.id] == nil }.reduce(0) { $0 + $1.seconds }))")
                            .font(.system(size: 13, weight: .semibold))
                        Text("按用时从多到少。建议只在你点接受后生效。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if !suggestions.isEmpty {
                            Button("接受全部建议") {
                                for row in rows where accepted[row.id] == nil {
                                    if let suggestion = suggestions[row.id] { assign(row: row, categoryID: suggestion.categoryID) }
                                }
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
        .onChange(of: model.dataVersion) { _, _ in
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
            if row.isDomain { Image(systemName: "globe").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 22) }
            else { AppIcon(bundleID: row.id) }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label).font(.system(size: 13)).lineLimit(1)
                Text(row.isDomain ? "网站" : "应用").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.duration(row.seconds)).font(.system(size: 12)).monospacedDigit()
                ProgressView(value: row.seconds, total: max(1, rows.map(\.seconds).max() ?? 1)).tint(.secondary)
            }.frame(width: 110)
            if let category = accepted[row.id] {
                CategoryChip(category: model.resolver.categoriesByID[category]).frame(width: 140)
                Label("已归类", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.green).frame(width: 90)
            } else {
                if let suggestion = suggestions[row.id] {
                    VStack(alignment: .leading, spacing: 3) {
                        CategoryChip(category: model.resolver.categoriesByID[suggestion.categoryID])
                        Text("模型建议").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(width: 100, alignment: .leading)
                    Button("接受") { assign(row: row, categoryID: suggestion.categoryID) }.controlSize(.small)
                }
                Picker("分类", selection: pickerBinding(for: row)) {
                    Text("选择分类").tag(Optional<String>.none)
                    ForEach(sortedCategories, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 130)
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

    private func assign(row: Row, categoryID: String) {
        do {
            if row.isDomain {
                try model.categoryStore.setUserDomain(row.id, categoryID: categoryID)
            } else {
                try model.categoryStore.setUserApp(row.id, categoryID: categoryID)
            }
            try model.categoryStore.dismissSuggestion(key: row.id, kind: row.isDomain ? "domain" : "app")
            suggestions[row.id] = nil
            accepted[row.id] = categoryID
            model.resolver.refresh()
            model.dataChanged()
            error = nil
        } catch {
            self.error = String(localized: "分类未保存，请重试。")
            settingsLogger.error("assign failed for \(row.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
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
            let retained = rows.filter { accepted[$0.id] != nil }
            rows = Aggregator.durationByDomainOrApp(items).map { entry in
                Row(id: entry.key, label: entry.label, seconds: entry.seconds, isDomain: isDomainByKey[entry.key] ?? false)
            } + retained
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
                SecureField("API 密钥", text: $apiKeyInput)
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
            apiKeyStatus = String(localized: "已保存")
        } catch {
            apiKeyStatus = String(localized: "保存失败：\(String(describing: error))")
        }
    }

    /// Runs one classification against `example-blog.net` with the
    /// currently-entered fields (falling back to the stored Keychain key if
    /// the field is empty, so a previously-saved key can be re-tested
    /// without retyping it), and shows the resulting category id or error.
    private func runTest() {
        guard let url = URL(string: endpoint) else {
            testStatus = String(localized: "Endpoint 无效")
            return
        }
        let key = apiKeyInput.isEmpty ? (Keychain.get(account: LLMCoordinator.apiKeyAccount) ?? "") : apiKeyInput
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
                testStatus = "example-blog.net → \(model.resolver.categoriesByID[categoryID]?.name ?? categoryID)"
            } catch {
                testStatus = String(localized: "测试失败：\(String(describing: error))")
            }
            isTesting = false
        }
    }
}
