import SwiftUI

struct OnboardingView: View {
    let model: AppModel
    var checksPermissions = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Int
    @State private var axState: PermissionState = .denied
    @State private var chromeState: PermissionState = .notDetermined
    @State private var chromeEnabled = true

    init(model: AppModel, initialStep: Int = 0, checksPermissions: Bool = true) {
        self.model = model; self.checksPermissions = checksPermissions
        _step = State(initialValue: initialStep)
    }
    private let titles = [String(localized: "让 TimeSink 替你记住时间"), String(localized: "会记录什么"), String(localized: "允许「辅助功能」"), String(localized: "按网站记录 Chrome（可选）"), String(localized: "已经准备好记录")]
    private let details = [String(localized: "它在后台记录你用了哪些应用和网站、各用了多久。你只需要偶尔看一眼菜单栏。"), String(localized: "先看清楚，再决定开哪些。可选功能以后都能在设置里改。"), String(localized: "macOS 需要你亲自打开这个开关，TimeSink 才能看到最前面的应用。"), String(localized: "不开也能用：浏览时间会记成「Chrome」，不区分网站。"), String(localized: "TimeSink 住在菜单栏右上角。点一下看今天，悬停看细节。")]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<5) { index in Capsule().fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.15)).frame(height: 4) }
            }.accessibilityLabel("第 \(step + 1) 步，共 5 步")
            Text(titles[step]).font(.system(size: 22, weight: .bold)).padding(.top, 14)
            Text(details[step]).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            Group {
                switch step {
                case 0:
                    VStack(alignment: .leading, spacing: 14) {
                        feature("lock", String(localized: "记录只保存在这台 Mac"), String(localized: "登录账号后可以选择备份，默认不上传。"))
                        feature("list.bullet", String(localized: "按应用、网站和窗口标题"), String(localized: "不读取网页内容、输入和文件。屏幕采集可单独开启。"))
                        feature("pause", String(localized: "随时暂停"), String(localized: "在菜单栏一键暂停，暂停期间什么都不记。"))
                    }.padding(.top, 10)
                case 1:
                    VStack(spacing: 0) {
                        choice(String(localized: "应用和窗口标题"), String(localized: "核心功能")) { Text(String(localized: "必需")).foregroundStyle(.secondary) }
                        Divider()
                        choice(String(localized: "Chrome 网址"), String(localized: "按网站分类")) {
                            Toggle("Chrome 网址", isOn: $chromeEnabled).labelsHidden().onChange(of: chromeEnabled) { _, value in model.settings.set("chromeTrackingEnabled", value ? "true" : "false") }
                        }
                        Divider()
                        choice(String(localized: "屏幕画面"), String(localized: "回看当时在做什么 · 保存 \(model.settings.captureRetentionDays) 天")) {
                            Toggle("屏幕画面", isOn: Binding(get: { !model.screenCapturePaused }, set: { model.setScreenCapturePaused(!$0) })).labelsHidden()
                        }
                        Divider()
                        choice(String(localized: "日历日程"), String(localized: "标出会议时间")) {
                            Toggle("日历日程", isOn: Binding(get: { model.calendarOverlayEnabled }, set: { value in
                                model.calendarOverlayEnabled = value; model.settings.setCalendarOverlayEnabled(value)
                                if value { Task { _ = await Permissions.requestCalendarAccess(); await model.refreshCalendarWindows() } }
                            })).labelsHidden()
                        }
                    }.toggleStyle(.switch).controlSize(.small).workspacePanel().padding(.top, 8)
                case 2:
                    VStack(alignment: .leading, spacing: 12) {
                        PermissionRow(title: String(localized: "等待你在系统设置中打开"), explanation: String(localized: "系统设置 › 隐私与安全性 › 辅助功能 › TimeSink"), state: axState,
                            actionTitle: String(localized: "打开系统设置…"), action: {
                                _ = Permissions.accessibilityGranted(prompt: true)
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }).padding(12).workspacePanel()
                        Text("打开开关后回到这里，会自动进入下一步。").foregroundStyle(.secondary)
                    }.padding(.top, 10)
                case 3:
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            AppIcon(bundleID: "com.google.Chrome", size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Chrome").fontWeight(.semibold)
                                Text(chromeStateText).foregroundStyle(chromeState == .denied ? AnyShapeStyle(RefinedStyle.warning) : AnyShapeStyle(.secondary))
                            }
                            Spacer()
                            Button(chromeState == .granted ? "已允许" : chromeState == .denied ? "打开系统设置…" : "允许") {
                                chromeEnabled = true; model.settings.set("chromeTrackingEnabled", "true")
                                if chromeState == .denied { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
                                else { chromeState = Permissions.chromeAutomationState(ask: true) }
                            }.disabled(chromeState == .granted || chromeState.isUnavailable)
                        }.padding(12).workspacePanel()
                        Button("跳过，只按应用记录") { chromeEnabled = false; model.settings.set("chromeTrackingEnabled", "false"); advance(1) }.buttonStyle(.link)
                    }.padding(.top, 10)
                default:
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.right").foregroundStyle(.tint)
                            Label(model.menuTitle, systemImage: "hourglass").monospacedDigit().padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        RecordingStatusView(model: model)
                    }.padding(.top, 10)
                }
            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                Text("\(step + 1) / 5").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if step > 0 { Button("返回") { advance(-1) } }
                Button(step == 0 ? "开始设置" : step == 4 ? "完成" : "继续") {
                    if step == 4 { dismiss() } else { advance(1) }
                }.buttonStyle(.borderedProminent).disabled(step == 2 && axState != .granted).keyboardShortcut(.defaultAction)
            }.controlSize(.large)
        }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 22).frame(width: 500, height: 470)
        .background(WorkspaceBackground())
        .task {
            chromeEnabled = model.settings.get("chromeTrackingEnabled") != "false"
            guard checksPermissions else { return }
            while !Task.isCancelled {
                axState = Permissions.accessibilityState(prompt: false)
                model.accessibilityGranted = axState == .granted
                if step == 2 && axState == .granted { advance(1) }
                if step == 3 { chromeState = Permissions.chromeAutomationState(ask: false) }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private var chromeStateText: String {
        switch chromeState {
        case .granted: return String(localized: "已允许 · 只读取当前标签页的网址")
        case .denied: return String(localized: "已拒绝 · 需在系统设置 › 自动化中打开")
        case .unavailable: return String(localized: "先打开 Chrome，再回到这里允许")
        case .notDetermined: return String(localized: "只读取当前标签页的网址")
        }
    }
    /// The Chrome step is skipped when Chrome recording was switched off.
    private func advance(_ delta: Int) {
        var next = max(0, min(4, step + delta))
        if next == 3, !chromeEnabled { next += delta }
        withAnimation(RefinedStyle.motion(reduced: reduceMotion)) { step = max(0, min(4, next)) }
    }
    private func choice<Content: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Content) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 13)); Text(detail).foregroundStyle(.secondary) }
            Spacer(); control()
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
