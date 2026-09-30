import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    private let tabs: [(SettingsTab, String, String)] = [
        (.general, String(localized: "通用"), "gearshape"), (.privacy, String(localized: "记录与隐私"), "hand.raised"),
        (.permissions, String(localized: "权限"), "checkmark.shield"), (.notifications, String(localized: "通知"), "bell"),
        (.account, String(localized: "账号与同步"), "icloud"), (.llm, String(localized: "智能分类"), "sparkles"), (.about, String(localized: "关于"), "info.circle")
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.0) { tab in
                    Button { model.settingsTab = tab.0 } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.2).font(.system(size: 22, weight: .regular))
                            Text(tab.1).font(.system(size: 11)).lineLimit(1).fixedSize()
                        }.frame(minWidth: 64).padding(.horizontal, 6).frame(height: 52)
                            .foregroundStyle(model.settingsTab == tab.0 ? Color.accentColor : .secondary)
                            .background(model.settingsTab == tab.0 ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityAddTraits(model.settingsTab == tab.0 ? .isSelected : [])
                }
            }.padding(.vertical, 8).frame(maxWidth: .infinity).background(.bar)
            Divider()
            Group {
                switch model.settingsTab {
                case .privacy: RefinedPrivacyPane(model: model)
                case .permissions: RefinedPermissionsPane(model: model)
                case .notifications: RefinedNotificationsPane(model: model)
                case .account: AccountSettingsPane(model: model)
                case .llm: LLMSettingsPane(model: model)
                case .about: RefinedAboutPane(model: model)
                default: RefinedGeneralPane(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        // Tabs size to their labels ("Smart Categorization" needs 111 pt), so
        // the window grows past 640 pt only where a language needs it.
        }.frame(minWidth: 640, minHeight: 560).background(WorkspaceBackground())
        .onAppear { redirectLegacyTab() }
        .onChange(of: model.settingsTab) { _, _ in redirectLegacyTab() }
    }
    private func redirectLegacyTab() {
        switch model.settingsTab {
        case .budget: model.sidebarSelection = .focus; model.settingsTab = .notifications
        case .categories, .rules, .uncategorized: model.sidebarSelection = .organization; model.settingsTab = .general
        default: break
        }
    }
}

struct RefinedGeneralPane: View {
    @Bindable var model: AppModel
    @State private var loginEnabled = false
    @State private var idleMinutes: Double = 3
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
                    Text("只显示图标").tag("icon")
                    Text("今日已记录时长").tag("total")
                    Text("当前分类与时长").tag("category")
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("打开弹出层") { ShortcutRecorder(model: model).frame(width: 122, height: 24) }
                if !model.popoverShortcutAvailable {
                    Text("快捷键当前不可用，可点按上方重新设置。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $idleMinutes, in: 1...15, step: 0.5) {
                    LabeledContent(String(localized: "离开多久算空闲"), value: String(localized: "\(idleMinutes.formatted()) 分钟"))
                }.onChange(of: idleMinutes) { _, value in model.settings.setIdleThreshold(value * 60) }
                Text("空闲的时间不计入，回来自动继续。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("显示") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("显示评分", isOn: $model.showScore)
                Text("在弹出层和「今天」显示评分与连续达标；关闭后只在「趋势」里出现。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Picker("一周从哪天开始", selection: $model.firstWeekday) {
                    Text("周一").tag(2); Text("周日").tag(1)
                }
                Picker("时间格式", selection: $model.timeFormat) {
                    Text("跟随系统").tag("system"); Text("24 小时").tag("24"); Text("12 小时").tag("12")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped)
        .onAppear { idleMinutes = model.settings.idleThreshold / 60; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}

struct RefinedPrivacyPane: View {
    let model: AppModel
    @State private var apps: [String] = []
    @State private var domains: [String] = []
    @State private var newDomain = ""
    @State private var editApps = false
    @State private var editDomains = false
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
                LabeledContent("不记录这些应用") {
                    Text(apps.prefix(3).map { AppIcon.name(for: $0) }.joined(separator: String(localized: "、"))).lineLimit(1)
                    Button { editApps = true } label: { Image(systemName: "plus") }.help("编辑不记录的应用")
                }
                LabeledContent("不记录这些网站") {
                    Text(domains.joined(separator: String(localized: "、"))).lineLimit(1)
                    Button { editDomains = true } label: { Image(systemName: "plus") }.help("编辑不记录的网站")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("按网站记录 Chrome", isOn: $chromeEnabled)
                        .onChange(of: chromeEnabled) { _, value in model.settings.set("chromeTrackingEnabled", value ? "true" : "false") }
                    HStack {
                        caption(chromeEnabled ? String(localized: "按网站分类需 Chrome 自动化权限。") : String(localized: "已关闭；Chrome 只记录应用时长。"))
                        Spacer(minLength: 4)
                        Button("查看权限…") { model.settingsTab = .permissions }.buttonStyle(.link)
                    }
                    caption(String(localized: "已识别的无痕窗口不记录；无法识别时，只记录应用时长，不保存标题、网址或截图。"))
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
            apps = model.settings.excludedApps.sorted(); domains = model.settings.excludedDomains.sorted()
            chromeEnabled = model.settings.get("chromeTrackingEnabled") != "false"
            retention = model.settings.captureRetentionDays
            summary = model.observationStore?.summary(since: Calendar.current.startOfDay(for: Date())) ?? summary
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

struct RefinedPermissionsPane: View {
    let model: AppModel
    @State private var ax: PermissionState = .denied
    @State private var chrome: PermissionState = .notDetermined
    @State private var screen: PermissionState = .notDetermined
    @State private var calendar: PermissionState = .notDetermined
    @State private var notification: PermissionState = .notDetermined
    var body: some View {
        Form {
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
            }
            Text("回到 TimeSink 时自动重新检查。其他浏览器目前只按应用记录。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.formStyle(.grouped).task { await refresh() }
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
                        if !value { model.returnOffer = nil }
                    }
                    Text("打了字或停留满 \(Int(model.interruptionRule.dwell)) 秒时在菜单栏出现，⌃⌥← 回去").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("专注结束", isOn: $focusAlerts).onChange(of: focusAlerts) { _, value in model.settings.set("focusNotificationsEnabled", value ? "true" : "false") }
                Toggle("提醒声音", isOn: $sound).onChange(of: sound) { _, value in model.settings.set("notificationSound", value ? "true" : "false") }
            }
        }.formStyle(.grouped).onAppear {
            warn = model.settings.budgetWarnPercent; summary = model.settings.dailySummaryEnabled; hour = model.settings.dailySummaryHour
            budgetAlerts = model.settings.budgetNotificationsEnabled; focusAlerts = model.settings.focusNotificationsEnabled; sound = model.settings.notificationSound
            returnOffer = model.returnEnabled
        }
    }
}

struct RefinedAboutPane: View {
    let model: AppModel
    @State private var autoCheckUpdates = false
    @State private var document: TextExportDocument?
    @State private var exportType: UTType = .commaSeparatedText
    @State private var exportName = "TimeSink-records"
    @State private var exporting = false
    @State private var preparing = false
    @State private var diagnostic: String?
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "hourglass").font(.system(size: 40)).foregroundStyle(.tint).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("TimeSink").font(.system(size: 17, weight: .semibold))
                        Text(String(localized: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "开发版"))"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Text("让时间的去向更清楚。").foregroundStyle(.secondary)
            }
            Section {
                if let updates = model.updates {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { autoCheckUpdates },
                        set: { autoCheckUpdates = $0; updates.automaticallyChecks = $0 }
                    ))
                    Button("检查更新…") { updates.checkForUpdates() }
                } else {
                    Text("开发版不检查更新。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
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
            }
            Section("你的数据") {
                Text("活动记录保存在这台 Mac。云端同步、智能分类与屏幕采集分别控制。")
                Button("查看记录与隐私") { model.settingsTab = .privacy }
            }
        }.formStyle(.grouped)
        .onAppear { autoCheckUpdates = model.updates?.automaticallyChecks ?? false }
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
