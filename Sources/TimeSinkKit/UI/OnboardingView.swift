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
    @State private var chromeGranted = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var allGranted: Bool { accessibilityGranted && chromeGranted }

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
                granted: accessibilityGranted,
                action: {
                    accessibilityGranted = Permissions.accessibilityGranted(prompt: true)
                }
            )

            PermissionCard(
                title: "Chrome 自动化",
                explanation: "用于读取 Chrome 当前标签页的网址，以便按网站对浏览时间分类。",
                granted: chromeGranted,
                action: {
                    chromeGranted = Permissions.chromeAutomationStatus(ask: true) == noErr
                }
            )

            HStack {
                Spacer()
                if allGranted {
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
        accessibilityGranted = Permissions.accessibilityGranted(prompt: false)
        chromeGranted = Permissions.chromeAutomationStatus(ask: false) == noErr
    }
}

private struct PermissionCard: View {
    let title: String
    let explanation: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(granted ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(granted ? "已授权" : "未授权")
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .red)
            }
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("授权", action: action)
                .disabled(granted)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
