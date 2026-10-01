import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    private let tabs: [(SettingsTab, String, String)] = [
        (.general, String(localized: "通用"), "gearshape"), (.recording, String(localized: "记录"), "hourglass"),
        (.llm, String(localized: "智能"), "sparkles"), (.notifications, String(localized: "通知与提示"), "bell"),
        (.focus, String(localized: "专注与限额"), "scope"),
        (.account, String(localized: "同步"), "icloud"), (.privacy, String(localized: "隐私"), "lock")
    ]
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.settingsTab }, set: { if let tab = $0 { model.settingsTab = tab } })) {
                ForEach(tabs, id: \.0) { tab in Label(tab.1, systemImage: tab.2).tag(tab.0) }
            }
            .frame(minWidth: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch model.settingsTab {
                case .recording: RefinedRecordingPane(model: model)
                case .privacy: RefinedPrivacyPane(model: model)
                case .notifications: RefinedNotificationsPane(model: model)
                case .focus: FocusSettingsPane(model: model)
                case .account: AccountSettingsPane(model: model)
                case .llm: LLMSettingsPane(model: model)
                default: RefinedGeneralPane(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(tabs.first { $0.0 == model.settingsTab }?.1 ?? "")
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear { redirectLegacyTab() }
        .onChange(of: model.settingsTab) { _, _ in redirectLegacyTab() }
    }
    private func redirectLegacyTab() {
        switch model.settingsTab {
        case .budget: model.settingsTab = .focus
        case .categories, .rules, .uncategorized: model.sidebarSelection = .organization; model.settingsTab = .general
        // 2.0 folded 权限 into 隐私 and 关于 into 通用.
        case .permissions: model.settingsTab = .privacy
        case .about: model.settingsTab = .general
        default: break
        }
    }
}

struct RefinedGeneralPane: View {
    @Bindable var model: AppModel
    @State private var loginEnabled = false
    @State private var language = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("登录时启动", isOn: Binding(get: { loginEnabled }, set: { value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch { self.error = String(localized: "登录项无法更新：\(error.localizedDescription)") }
                    loginEnabled = SMAppService.mainApp.status == .enabled
                })).disabled(!Bundle.main.bundlePath.hasPrefix("/Applications"))
                if !Bundle.main.bundlePath.hasPrefix("/Applications") {
                    Text("安装到应用程序文件夹后可设置登录时启动。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                }
                Picker("菜单栏显示", selection: Binding(get: { model.menuDisplayMode }, set: { model.setMenuDisplayMode($0) })) {
                    Text("图标").tag("icon")
                    Text("时长").tag("total")
                    Text("分类").tag("category")
                }.pickerStyle(.segmented).fixedSize()
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("打开弹出层") { ShortcutRecorder(model: model).frame(width: 122, height: 24) }
                if !model.popoverShortcutAvailable {
                    Text("快捷键当前不可用，可点按上方重新设置。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                }
            }
            Section("显示") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("显示评分", isOn: $model.showScore)
                Text("关闭后只在「趋势」里显示。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Picker("一周从哪天开始", selection: $model.firstWeekday) {
                    Text("周一").tag(2); Text("周日").tag(1)
                }
                Picker("时间格式", selection: $model.timeFormat) {
                    Text("跟随系统").tag("system"); Text("24 小时").tag("24"); Text("12 小时").tag("12")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker("语言", selection: $language) {
                        Text("跟随系统").tag("")
                        Text(verbatim: "中文").tag("zh-Hans") // l10n: data
                        Text(verbatim: "English").tag("en")
                    }
                    Text("重启 TimeSink 后生效。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            AboutSection(model: model)
        }.formStyle(.grouped)
        .onAppear {
            loginEnabled = SMAppService.mainApp.status == .enabled
            // AppleLanguages also holds the system list when never overridden; only our own two values count as a choice.
            language = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"].flatMap { ($0 as? [String])?.first } ?? ""
        }
        .onChange(of: language) { _, value in
            if value.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([value], forKey: "AppleLanguages") }
        }
    }
}

/// 记录: what is recorded and how -- pause, away time, Chrome sites, what
/// counts as an interruption, screen capture and the calendar.
struct RefinedRecordingPane: View {
    let model: AppModel
    @State private var idleMinutes: Double = 3
    @State private var retention = 7
    @State private var summary = ObservationStore.Summary(count: 0, latestAt: nil)
    @State private var confirmingDelete = false
    @State private var status: String?
    @State private var chromeEnabled = true
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("暂停记录"); Spacer(); RecordingPauseMenu(model: model) }
                    caption(String(localized: "暂停期间不记录、不采集，也不补记。"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $idleMinutes, in: 1...15, step: 0.5) {
                        LabeledContent(String(localized: "离开多久算空闲"), value: String(localized: "\(idleMinutes.formatted()) 分钟"))
                    }.onChange(of: idleMinutes) { _, value in model.settings.setIdleThreshold(value * 60) }
                    caption(String(localized: "空闲的时间不计入，回来自动继续。"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("按网站记录 Chrome", isOn: $chromeEnabled)
                        .onChange(of: chromeEnabled) { _, value in model.settings.set("chromeTrackingEnabled", value ? "true" : "false") }
                    HStack {
                        caption(chromeEnabled ? String(localized: "按网站分类需 Chrome 自动化权限。") : String(localized: "已关闭；Chrome 只记录应用时长。"))
                        Spacer(minLength: 4)
                        Button("查看权限…") { model.settingsTab = .privacy }.buttonStyle(.link)
                    }
                }
            }
            Section("什么算打断") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("停留满", selection: Binding(get: { model.interruptionRule.dwell }, set: { model.interruptionRule.dwell = $0 })) {
                        ForEach(InterruptionRule.dwellChoices, id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                    }
                    caption(String(localized: "切到无关的窗口，待多久算打断"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("在那里打了字", isOn: Binding(get: { model.interruptionRule.countsTyping }, set: { model.interruptionRule.countsTyping = $0 }))
                    caption(String(localized: "只数有按键的秒数，不记录按了什么"))
                }
            }
            Section("屏幕采集") {
                VStack(alignment: .leading, spacing: 4) {
                    ScreenCaptureRow(model: model, compact: true)
                    caption(String(localized: "最前面的窗口画面与识别文字只保存在本机。"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker("保留", selection: $retention) { ForEach([1, 3, 7, 14, 30], id: \.self) { Text("\($0) 天").tag($0) } }
                        .onChange(of: retention) { _, days in
                            model.settings.set("captureRetentionDays", "\(days)")
                            Task { await model.screenCollector?.setRetentionDays(days) }
                        }
                    caption(String(localized: "截图到期自动删除；识别文字保留。"))
                }
                HStack {
                    Text("今天"); Spacer(); Text("\(summary.count) 次采集").foregroundStyle(.secondary).monospacedDigit()
                    Button("删除今天的截图…") { confirmingDelete = true }.disabled(model.screenCollector == nil || summary.count == 0)
                }
                if let status { caption(status) }
            }
            Section("日历") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("在时间轴上显示日程", isOn: Binding(get: { model.calendarOverlayEnabled }, set: { value in
                        model.calendarOverlayEnabled = value; model.settings.setCalendarOverlayEnabled(value)
                        Task { await model.refreshCalendarWindows() }
                    }))
                    caption(String(localized: "标出会议时间；开会时不会因没碰键盘而算作空闲。"))
                }
            }
        }.formStyle(.grouped).onAppear {
            idleMinutes = model.settings.idleThreshold / 60
            chromeEnabled = model.settings.get("chromeTrackingEnabled") != "false"
            retention = model.settings.captureRetentionDays
            summary = model.observationStore?.summary(since: Calendar.current.startOfDay(for: Date())) ?? summary
        }
        .confirmationDialog("删除今天保存的截图？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除截图", role: .destructive) {
                Task {
                    do {
                        let count = try await model.screenCollector?.deleteImages(in: DateRangeSelection.today().interval) ?? 0
                        status = String(localized: "已删除 \(count) 张截图。"); model.settingsChanged()
                    } catch { status = String(localized: "截图未能全部删除，请重试。") }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("截图删除后无法恢复。活动记录和已识别的文字会保留。") }
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// 隐私: what is never recorded, what TimeSink may see (permissions), and
/// taking your data out.
struct RefinedPrivacyPane: View {
    let model: AppModel
    @State private var apps: [String] = []
    @State private var domains: [String] = []
    @State private var newDomain = ""
    @State private var editApps = false
    @State private var editDomains = false
    var body: some View {
        Form {
            Section {
                LabeledContent("不记录这些应用") {
                    Text(apps.prefix(3).map { AppIcon.name(for: $0) }.joined(separator: String(localized: "、"))).lineLimit(1)
                    Button { editApps = true } label: { Image(systemName: "plus") }.help("编辑不记录的应用")
                }
                LabeledContent("不记录这些网站") {
                    Text(domains.joined(separator: String(localized: "、"))).lineLimit(1)
                    Button { editDomains = true } label: { Image(systemName: "plus") }.help("编辑不记录的网站")
                }
                Text("已识别的无痕窗口不记录；无法识别时，只记录应用时长，不保存标题、网址或截图。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            PermissionsSection(model: model)
            DataSection(model: model)
        }.formStyle(.grouped).onAppear {
            apps = model.settings.excludedApps.sorted(); domains = model.settings.excludedDomains.sorted()
        }
        .sheet(isPresented: $editApps) {
            FocusBlockedAppsEditor(model: model, title: String(localized: "不记录这些应用"), onSave: { values in
                model.settings.setExcludedApps(Set(values)); apps = model.settings.excludedApps.sorted()
            }, blockedApps: $apps)
        }
        .popover(isPresented: $editDomains) {
            VStack(alignment: .leading, spacing: 14) {
                Text("不记录这些网站").font(.headline)
                ForEach(domains, id: \.self) { domain in
                    HStack { Text(domain); Spacer(); Button { domains.removeAll { $0 == domain }; saveDomains() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("移除 \(domain)") }
                }
                HStack {
                    TextField("例如 accounts.google.com", text: $newDomain).textFieldStyle(.roundedBorder)
                    Button("添加", action: addDomain).disabled(normalizedDomain == nil)
                }
                Text("同时适用于子域名。不会保存这些网站的活动、标题或截图。").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(18).frame(width: 360)
        }
    }
    private var normalizedDomain: String? {
        let text = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" "), let url = URL(string: text.contains("://") ? text : "https://" + text), let host = url.host, host.contains("."), url.user == nil, url.password == nil else { return nil }
        return host
    }
    private func addDomain() {
        guard let domain = normalizedDomain else { return }
        domains = Set(domains + [domain]).sorted(); newDomain = ""; saveDomains()
    }
    private func saveDomains() { model.settings.setExcludedDomains(Set(domains)) }
}

struct PermissionsSection: View {
    let model: AppModel
    @State private var ax: PermissionState = .denied
    @State private var chrome: PermissionState = .notDetermined
    @State private var screen: PermissionState = .notDetermined
    @State private var calendar: PermissionState = .notDetermined
    @State private var notification: PermissionState = .notDetermined
    var body: some View {
        Section {
                PermissionRow(title: String(localized: "辅助功能 · 必需"), explanation: String(localized: "看到最前面的应用和窗口标题。"), state: ax,
                    actionTitle: String(localized: "打开系统设置…"), action: { open("Privacy_Accessibility") })
                PermissionRow(title: String(localized: "Chrome 自动化 · 推荐"), explanation: String(localized: "读取当前标签页的网址，按网站分类。不读网页内容。"), state: chrome,
                    actionTitle: chrome == .denied ? String(localized: "打开系统设置…") : String(localized: "允许…"), action: {
                        if chrome == .denied { open("Privacy_Automation") }
                        else { chrome = Permissions.chromeAutomationState(ask: true) }
                    })
                PermissionRow(title: String(localized: "屏幕录制 · 屏幕采集"), explanation: String(localized: "只截取最前面的窗口，保存在本机。"), state: screen,
                    actionTitle: String(localized: "打开系统设置…"), action: { open("Privacy_ScreenCapture") })
                PermissionRow(title: String(localized: "日历 · 可选"), explanation: String(localized: "叠加日程，只读取标题、时间与人数。"), state: calendar,
                    actionTitle: calendar == .denied ? String(localized: "打开系统设置…") : String(localized: "允许…"), action: {
                        if calendar == .denied { open("Privacy_Calendars") }
                        else { Task { _ = await Permissions.requestCalendarAccess(); await refresh() } }
                    })
                PermissionRow(title: String(localized: "通知 · 可选"), explanation: String(localized: "限额提醒、每日小结、专注结束。"), state: notification,
                    actionTitle: notification == .denied ? String(localized: "打开系统设置…") : String(localized: "允许…"), action: {
                        if notification == .denied { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!) }
                        else { Task { _ = await model.notifier?.requestAuthorization(); await refresh() } }
                    })
        } header: {
            Text("权限")
        } footer: {
            Text("回到 TimeSink 时自动重新检查。其他浏览器目前只按应用记录。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }
    private func open(_ pane: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!) }
    private func refresh() async {
        ax = Permissions.accessibilityState(prompt: false)
        model.accessibilityGranted = ax == .granted
        chrome = Permissions.chromeAutomationState(ask: false)
        screen = Permissions.screenRecordingState()
        calendar = await Permissions.calendarStateInBackground()
        notification = await Permissions.notificationState(model.notifier)
    }
}

struct RefinedNotificationsPane: View {
    let model: AppModel
    @State private var warn = 20
    @State private var summary = false
    @State private var hour = 19
    @State private var budgetAlerts = true
    @State private var focusAlerts = true
    @State private var sound = false
    @State private var returnOffer = true
    @State private var awayPrompt = true
    var body: some View {
        Form {
            Section("限额提醒") {
                Toggle("限额提醒", isOn: $budgetAlerts).onChange(of: budgetAlerts) { _, value in
                    model.settings.set("budgetNotificationsEnabled", value ? "true" : "false")
                    if value { model.requestNotificationPermission() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Stepper("剩余 \(warn)% 时提醒", value: $warn, in: 10...30, step: 10)
                    .onChange(of: warn) { _, value in model.settings.setBudgetWarnPercent(value) }
                Text("接近上限和达到上限时各提醒一次。限额只提醒，不会拦截。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("每日小结") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("每日小结", isOn: $summary).onChange(of: summary) { _, value in
                        model.settings.setDailySummaryEnabled(value)
                        if value { model.requestNotificationPermission() }
                    }
                Stepper("每天 \(model.time(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()))", value: $hour, in: 0...23).disabled(!summary)
                    .onChange(of: hour) { _, value in model.settings.setDailySummaryHour(value) }
                Text("今天记录了多久、投入多少、评分。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("回到刚才", isOn: $returnOffer).onChange(of: returnOffer) { _, value in
                        model.settings.set("returnOfferEnabled", value ? "true" : "false")
                        if !value { model.setReturnOffer(nil) }
                    }
                    Text("打了字或停留满 \(Int(model.interruptionRule.dwell)) 秒时出现，⌃⌥← 回去").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("离开补记", isOn: $awayPrompt).onChange(of: awayPrompt) { _, value in
                        model.settings.set("awayPromptEnabled", value ? "true" : "false")
                        if !value { model.awayOffer = nil }
                    }
                    Text("离开 10 分钟以上回来时问一次，一天最多 5 次").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("专注结束", isOn: $focusAlerts).onChange(of: focusAlerts) { _, value in model.settings.set("focusNotificationsEnabled", value ? "true" : "false") }
                Toggle("提醒声音", isOn: $sound).onChange(of: sound) { _, value in model.settings.set("notificationSound", value ? "true" : "false") }
            }
        }.formStyle(.grouped).onAppear {
            warn = model.settings.budgetWarnPercent; summary = model.settings.dailySummaryEnabled; hour = model.settings.dailySummaryHour
            budgetAlerts = model.settings.budgetNotificationsEnabled; focusAlerts = model.settings.focusNotificationsEnabled; sound = model.settings.notificationSound
            returnOffer = model.returnEnabled; awayPrompt = model.awayPromptEnabled
        }
    }
}

/// 专注与限额: what a focus session starts with.
struct FocusSettingsPane: View {
    let model: AppModel
    @State private var minutes = 45
    @State private var blockedApps: [String] = []
    @State private var editApps = false
    @State private var editCategories = false
    var body: some View {
        Form {
            Section {
                Picker("默认时长", selection: $minutes) {
                    ForEach(FocusPresets.minutes, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                    if !FocusPresets.minutes.contains(minutes) { Text(verbatim: "\(minutes)").tag(minutes) }
                }.pickerStyle(.segmented).fixedSize().onChange(of: minutes) { _, value in model.settings.setFocusDurationMinutes(value) }
                LabeledContent("隐藏的应用") {
                    HStack(spacing: 4) {
                        ForEach(Array(blockedApps.prefix(5)), id: \.self) { AppIcon(bundleID: $0, size: 18).help(AppIcon.name(for: $0)) }
                        if blockedApps.isEmpty { Text("未选择").foregroundStyle(.secondary) }
                        Button("编辑…") { editApps = true }.controlSize(.small).padding(.leading, 6)
                    }
                }
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(model.settings.focusBlockedCategories.isEmpty ? String(localized: "未选择") : model.settings.focusBlockedCategories.compactMap { model.resolver.categoriesByID[$0]?.name }.joined(separator: String(localized: "、")))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Button("编辑…") { editCategories = true }.controlSize(.small)
                            .popover(isPresented: $editCategories) { FocusCategoriesEditor(model: model) { editCategories = false } }
                    }
                } label: {
                    Text("拦截的网站")
                    Text("在 Chrome 中")
                }
            }
        }.formStyle(.grouped)
        .sheet(isPresented: $editApps) { FocusBlockedAppsEditor(model: model, blockedApps: $blockedApps) }
        .onAppear { minutes = model.settings.focusDurationMinutes; blockedApps = model.settings.focusBlockedApps }
    }
}

/// The app itself, at the bottom of 通用 (2.0 folded 关于 in).
struct AboutSection: View {
    let model: AppModel
    @State private var autoCheckUpdates = false
    var body: some View {
        Section("关于") {
            LabeledContent("TimeSink", value: String(localized: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "开发版"))"))
            if let updates = model.updates {
                Toggle("自动检查更新", isOn: Binding(
                    get: { autoCheckUpdates },
                    set: { autoCheckUpdates = $0; updates.automaticallyChecks = $0 }
                ))
                Button("检查更新…") { updates.checkForUpdates() }
            } else {
                Text("开发版不检查更新。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onAppear { autoCheckUpdates = model.updates?.automaticallyChecks ?? false }
    }
}

/// Taking your data out, in 隐私.
struct DataSection: View {
    let model: AppModel
    @State private var document: TextExportDocument?
    @State private var exportType: UTType = .commaSeparatedText
    @State private var exportName = "TimeSink-records"
    @State private var exporting = false
    @State private var preparing = false
    @State private var diagnostic: String?
    @State private var error: String?
    var body: some View {
        Section {
            LabeledContent("导出全部记录") {
                Button(preparing ? "正在准备…" : "导出为 CSV…") { prepareExport(diagnostics: false) }.disabled(preparing)
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("诊断信息") {
                    Button("预览并导出…") { prepareExport(diagnostics: true) }.disabled(preparing)
                }
                Text("诊断信息默认不含窗口标题、网址、截图和识别文字。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: {
            Text("你的数据")
        } footer: {
            Text("活动记录保存在这台 Mac。云端同步、智能分类与屏幕采集分别控制。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let failure) = result { error = String(localized: "导出失败：\(failure.localizedDescription)") }
        }
        .sheet(isPresented: Binding(get: { diagnostic != nil }, set: { if !$0 { diagnostic = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("诊断信息预览").font(.headline)
                ScrollView { Text(diagnostic ?? "").font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("取消") { diagnostic = nil }; Button("导出…") { document = TextExportDocument(text: diagnostic ?? ""); diagnostic = nil; exportType = .plainText; exportName = "TimeSink-diagnostics"; exporting = true } }
            }.padding(24).frame(width: 480, height: 350)
        }
    }
    private func prepareExport(diagnostics: Bool) {
        preparing = true; error = nil
        let store = model.spanStore
        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) { diagnostics ? try store.diagnosticSummary() : try store.exportCSV() }.value
                if diagnostics { diagnostic = text }
                else { document = TextExportDocument(text: text); exportType = .commaSeparatedText; exportName = "TimeSink-records"; exporting = true }
            } catch { self.error = String(localized: "未能准备导出：\(error.localizedDescription)") }
            preparing = false
        }
    }
}

struct TextExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
