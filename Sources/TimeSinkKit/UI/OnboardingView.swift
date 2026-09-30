import SwiftUI

/// The first run: one welcome card. Accessibility is required; Chrome,
/// screen recording and the calendar are optional and can wait.
struct OnboardingView: View {
    let model: AppModel
    var checksPermissions = true
    @Environment(\.dismiss) private var dismiss
    @State private var axState: PermissionState = .denied
    @State private var chromeState: PermissionState = .notDetermined
    @State private var screenState: PermissionState = .notDetermined
    @State private var calendarState: PermissionState = .notDetermined

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "hourglass").font(.system(size: 56, weight: .light)).foregroundStyle(.tint)
                    .frame(height: 68)
                Text("欢迎使用 TimeSink").font(.system(size: 22, weight: .semibold))
                Text("它在菜单栏里安静地记下你的时间，把一天连成片。所有记录都留在这台 Mac 上。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 340).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                permission("hand.raised", String(localized: "辅助功能"), required: true, String(localized: "读取前台应用和窗口标题"), axState) {
                    _ = Permissions.accessibilityGranted(prompt: true)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                permission("globe", String(localized: "Chrome 网址"), required: false, String(localized: "只读取当前标签页的网址"), chromeState) {
                    model.settings.set("chromeTrackingEnabled", "true")
                    if chromeState == .denied { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
                    else { chromeState = Permissions.chromeAutomationState(ask: true) }
                }
                permission("viewfinder", String(localized: "屏幕录制"), required: false,
                           String(localized: "屏幕回看，只存 \(model.settings.captureRetentionDays) 天"), screenState) {
                    model.setScreenCapturePaused(false)
                    CGRequestScreenCaptureAccess()
                }
                permission("calendar", String(localized: "日历"), required: false, String(localized: "补记离开时间时给出建议"), calendarState) {
                    model.calendarOverlayEnabled = true; model.settings.setCalendarOverlayEnabled(true)
                    Task {
                        _ = await Permissions.requestCalendarAccess()
                        calendarState = await Permissions.calendarStateInBackground()
                        await model.refreshCalendarWindows()
                    }
                }
            }.padding(.top, 22)
            Spacer(minLength: 16)
            HStack {
                Text(axState == .granted ? "可选项以后都能在设置里打开。" : "打开「辅助功能」后才能开始记录。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("继续") { dismiss() }
                    .glassProminentButton().controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(axState != .granted)
            }
        }
        .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 24).frame(width: 500, height: 520)
        .background(WorkspaceBackground())
        .task {
            guard checksPermissions else { axState = .granted; return }
            calendarState = await Permissions.calendarStateInBackground()
            while !Task.isCancelled {
                axState = Permissions.accessibilityState(prompt: false)
                model.accessibilityGranted = axState == .granted
                chromeState = Permissions.chromeAutomationState(ask: false)
                screenState = Permissions.screenRecordingState()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func permission(_ icon: String, _ title: String, required: Bool, _ detail: String,
                            _ state: PermissionState, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.tint)
                .frame(width: 34, height: 34).background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(required ? "需要" : "可选").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(required ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if state == .granted {
                Label("已允许", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.green)
            } else {
                Button("允许…", action: action).controlSize(.small).disabled(state.isUnavailable)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
