import SwiftUI

/// First-launch permission onboarding sheet: two cards (辅助功能 / Chrome
/// 自动化), each with an explanation, a status dot, and a "授权" button that
/// triggers the prompting check. A 2s timer re-polls both statuses
/// (non-prompting) so the dots update once the user grants access in System
/// Settings, without needing to click back into TimeSink. Once both are
/// green, the footer shows "完成" and a button to dismiss the sheet.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var axState: PermissionState = .denied
    @State private var chromeState: PermissionState = .notDetermined

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Whether onboarding can be considered finished. Chrome automation can
    /// only ever be *granted* while Chrome is running (macOS has nothing to
    /// prompt otherwise), so requiring `chromeState == .granted` here would
    /// make 完成 unreachable for anyone who hasn't opened Chrome yet.
    /// Accessibility being granted is therefore sufficient on its own when
    /// Chrome is merely not running (`.unavailable`) -- TimeSink re-checks
    /// (and re-prompts if needed) the first time it actually samples a
    /// Chrome tab. A real denial still blocks 完成.
    private var canFinish: Bool {
        axState == .granted && (chromeState == .granted || chromeState.isUnavailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("欢迎使用 TimeSink")
                    .font(.title2).bold()
                Text("需要以下两项系统权限才能自动追踪你的时间，且数据始终只保存在本机。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            PermissionRow(
                title: "辅助功能",
                explanation: "用于读取当前活跃窗口所属的应用与标题，据此统计你在各应用上花费的时间。",
                state: axState,
                actionTitle: "授权",
                action: {
                    axState = Permissions.accessibilityState(prompt: true)
                },
                compact: false
            )

            PermissionRow(
                title: "Chrome 自动化",
                explanation: "用于读取 Chrome 当前标签页的网址，以便按网站对浏览时间分类。",
                state: chromeState,
                actionTitle: "授权",
                action: {
                    chromeState = Permissions.chromeAutomationState(ask: true)
                },
                compact: false
            )

            HStack {
                Spacer()
                if canFinish {
                    Text("完成")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Button("好的") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("稍后设置") { dismiss() }
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        axState = Permissions.accessibilityState(prompt: false)
        chromeState = Permissions.chromeAutomationState(ask: false)
    }
}
