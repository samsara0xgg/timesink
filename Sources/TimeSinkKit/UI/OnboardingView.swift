import SwiftUI
import ApplicationServices

/// First-launch permission onboarding sheet: two cards (辅助功能 / Chrome
/// 自动化), each with an explanation, a status dot, and a "授权" button that
/// triggers the prompting check. A 2s timer re-polls both statuses
/// (non-prompting) so the dots update once the user grants access in System
/// Settings, without needing to click back into TimeSink. Once both are
/// green, the footer shows "完成" and a button to dismiss the sheet.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var accessibilityGranted = false
    /// -600 (procNotFound) means Chrome isn't running yet -- distinct from a
    /// real denial, same three-state handling as `SettingsPanes.chromeRow`.
    @State private var chromeStatus: OSStatus = noErr

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Whether onboarding can be considered finished. Chrome automation can
    /// only ever be *granted* while Chrome is running (macOS has nothing to
    /// prompt otherwise), so requiring `chromeStatus == noErr` here would
    /// make 完成 unreachable for anyone who hasn't opened Chrome yet.
    /// Accessibility being granted is therefore sufficient on its own when
    /// Chrome is merely not running (grey state) -- TimeSink re-checks (and
    /// re-prompts if needed) the first time it actually samples a Chrome
    /// tab. A real denial (any other non-noErr status) still blocks 完成.
    private var canFinish: Bool {
        accessibilityGranted && (chromeStatus == noErr || chromeStatus == chromeNotRunning)
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

            PermissionCard(
                title: "辅助功能",
                explanation: "用于读取当前活跃窗口所属的应用与标题，据此统计你在各应用上花费的时间。",
                dotColor: accessibilityGranted ? .green : .red,
                statusText: accessibilityGranted ? "已授权" : "未授权",
                statusColor: accessibilityGranted ? .green : .red,
                buttonDisabled: accessibilityGranted,
                action: {
                    accessibilityGranted = Permissions.accessibilityGranted(prompt: true)
                }
            )

            PermissionCard(
                title: "Chrome 自动化",
                explanation: "用于读取 Chrome 当前标签页的网址，以便按网站对浏览时间分类。",
                dotColor: chromeDotColor,
                statusText: chromeStatusText,
                statusColor: chromeDotColor,
                buttonDisabled: chromeStatus == noErr,
                action: {
                    chromeStatus = Permissions.chromeAutomationStatus(ask: true)
                }
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

    private var chromeNotRunning: OSStatus { -600 }

    private var chromeStatusText: String {
        switch chromeStatus {
        case noErr: return "已授权"
        case chromeNotRunning: return "Chrome 未运行"
        default: return "未授权"
        }
    }

    private var chromeDotColor: Color {
        switch chromeStatus {
        case noErr: return .green
        case chromeNotRunning: return .secondary
        default: return .red
        }
    }

    private func refresh() {
        accessibilityGranted = Permissions.accessibilityGranted(prompt: false)
        chromeStatus = Permissions.chromeAutomationStatus(ask: false)
    }
}

private struct PermissionCard: View {
    let title: String
    let explanation: String
    let dotColor: Color
    let statusText: String
    let statusColor: Color
    let buttonDisabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("授权", action: action)
                .disabled(buttonDisabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
