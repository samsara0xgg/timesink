import SwiftUI

/// The first run: one welcome card. Accessibility is required; Chrome,
/// screen recording and the calendar are optional and can wait.
///
/// It opens with a three-second "long exposure": a light trail sweeps the
/// card, the headline lights up, the trail settles into the hourglass and
/// the rest rises into place. Everything on screen is a function of one
/// `progress` in 0...1; a click, Return or Space jumps to the end.
struct OnboardingView: View {
    static let size = CGSize(width: 500, height: 570)
    private static let duration = 3.0
    private static let hourglassY: CGFloat = 64   // top padding 30 + half of the 68 pt glyph slot
    private static let titleY: CGFloat = 122      // the headline's centre once settled

    /// Debug renders: a frozen frame and fixture data instead of the clock and the system.
    struct Preview { var progress: Double; var live: (name: String, bundleID: String, elapsed: TimeInterval)? }

    let model: AppModel
    var checksPermissions = true
    var preview: Preview?
    /// Debug `--onboarding-demo`: permissions are simulated, "继续" calls `onContinue`.
    var demo = false
    var onContinue: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var axState: PermissionState = .denied
    @State private var chromeState: PermissionState = .notDetermined
    @State private var screenState: PermissionState = .notDetermined
    @State private var calendarState: PermissionState = .notDetermined
    @State private var introStart = Date()
    @State private var introDone = false
    @State private var pulse = false
    @State private var demoStart = Date()

    private var ax: PermissionState { preview.map { $0.live == nil ? .denied : .granted } ?? axState }

    var body: some View {
        if let preview { card(preview.progress) }
        else {
            TimelineView(.animation(paused: introDone || reduceMotion)) { context in
                card(introDone || reduceMotion ? 1 : min(1, context.date.timeIntervalSince(introStart) / Self.duration))
            }
        }
    }

    private func card(_ p: Double) -> some View {
        let headline = String(localized: "你的时间，从这一刻开始被看见")
        // Words for spaced languages, characters otherwise.
        let units = headline.contains(" ") ? headline.split(separator: " ", omittingEmptySubsequences: false).map { $0 + " " } : headline.map(String.init)
        let settle = Self.ease(Self.ramp(p, 0.62, 0.88))
        let caption = Self.ramp(p, 0.86, 1), rest = Self.ramp(p, 0.84, 1)
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "hourglass").font(.system(size: 56, weight: .light)).foregroundStyle(.tint).frame(height: 68)
                    .opacity(Self.ramp(p, 0.88, 1)).scaleEffect(0.9 + 0.1 * Self.ramp(p, 0.88, 1))
                HStack(spacing: 0) {
                    ForEach(Array(units.enumerated()), id: \.offset) { index, unit in
                        let lit = Self.ramp(p, 0.25 + 0.28 * Double(index) / Double(units.count), 0.37 + 0.28 * Double(index) / Double(units.count))
                        Text(unit).opacity(lit).blur(radius: 4 * (1 - lit))
                    }
                }
                .font(.display).accessibilityElement(children: .ignore).accessibilityLabel(headline)
                .scaleEffect(1 + 0.18 * (1 - settle)).offset(y: (1 - settle) * (Self.size.height / 2 + 30 - Self.titleY))
                VStack(spacing: 2) {
                    Text("它住在菜单栏里，点图标就能看到今天").font(.body)
                    Text("所有记录都留在这台 Mac 上。").font(.note)
                }
                .foregroundStyle(Design.ink2).multilineTextAlignment(.center)
                .opacity(caption).offset(y: 8 * (1 - caption))
            }
            VStack(spacing: 8) {
                if ax == .granted { liveRow.transition(.opacity.combined(with: .move(edge: .top))) }
                permission("hand.raised", String(localized: "辅助功能"), required: true, String(localized: "读取前台应用和窗口标题"), ax) {
                    if demo { axState = .granted; demoStart = Date(); return }
                    _ = Permissions.accessibilityGranted(prompt: true)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                permission("globe", String(localized: "Chrome 网址"), required: false, String(localized: "只读取当前标签页的网址"), chromeState) {
                    if demo { chromeState = .granted; return }
                    model.settings.set("chromeTrackingEnabled", "true")
                    if chromeState == .denied { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
                    else { chromeState = Permissions.chromeAutomationState(ask: true) }
                }
                permission("viewfinder", String(localized: "屏幕录制"), required: false,
                           String(localized: "屏幕回看，只存 \(model.settings.captureRetentionDays) 天"), screenState) {
                    if demo { screenState = .granted; return }
                    model.setScreenCapturePaused(false)
                    CGRequestScreenCaptureAccess()
                }
                permission("calendar", String(localized: "日历"), required: false, String(localized: "补记离开时间时给出建议"), calendarState) {
                    if demo { calendarState = .granted; return }
                    model.calendarOverlayEnabled = true; model.settings.setCalendarOverlayEnabled(true)
                    Task {
                        _ = await Permissions.requestCalendarAccess()
                        calendarState = await Permissions.calendarStateInBackground()
                        await model.refreshCalendarWindows()
                    }
                }
            }
            .animation(.smooth, value: ax == .granted)
            .padding(.top, 22).opacity(rest).offset(y: 14 * (1 - rest))
            Spacer(minLength: 16)
            HStack {
                Text(ax == .granted ? "可选项以后都能在设置里打开。" : "打开「辅助功能」后才能开始记录。")
                    .font(.body).foregroundStyle(Design.ink2)
                Spacer()
                Button("继续") { if let onContinue { onContinue() } else { dismiss() } }
                    .glassProminentButton().controlSize(.large).keyboardShortcut(p < 1 ? nil : .defaultAction)
                    .disabled(ax != .granted)
            }
            .opacity(rest).offset(y: 14 * (1 - rest))
            .allowsHitTesting(p >= 1)
        }
        .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 24).frame(width: Self.size.width, height: Self.size.height)
        .background(WorkspaceBackground())
        .overlay { trail(p) }
        .overlay { if p < 1 { skipTargets } }
        .task {
            guard preview == nil else { return }
            try? await Task.sleep(for: .seconds(Self.duration + 0.05))
            introDone = true
        }
        .task {
            guard preview == nil, !demo else { return }
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

    private static func ramp(_ p: Double, _ from: Double, _ to: Double) -> Double { min(1, max(0, (p - from) / (to - from))) }
    private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// The long exposure: a line sweeps left to right trailing a fade, holds,
    /// then contracts into the hourglass's place and gives way to the glyph.
    private func trail(_ p: Double) -> some View {
        let width = Self.size.width
        let head = Self.ease(Self.ramp(p, 0, 0.35)) * width
        let settle = Self.ease(Self.ramp(p, 0.62, 0.88))  // with the headline's, so the line stays above it
        let from = settle * (width / 2 - 14), to = head + settle * (width / 2 + 14 - head)
        let y = Self.size.height / 2 + settle * (Self.hourglassY - Self.size.height / 2)
        let line = Rectangle().fill(LinearGradient(colors: [Design.accent.opacity(settle), Design.accent], startPoint: .leading, endPoint: .trailing))
            .frame(width: max(0, to - from))
        return ZStack {
            line.frame(height: 7).blur(radius: 4).opacity(0.25)
            line.frame(height: 1.5)
        }
        .frame(width: width, height: 8, alignment: .leading).offset(x: from, y: y - Self.size.height / 2)
        .frame(width: width, height: Self.size.height, alignment: .center)
        .opacity(1 - Self.ramp(p, 0.9, 1)).allowsHitTesting(false).accessibilityHidden(true)
    }

    /// Click, Return or Space during the intro lands on the final state.
    @ViewBuilder private var skipTargets: some View {
        Color.clear.contentShape(Rectangle()).onTapGesture { introDone = true }
        Button("") { introDone = true }.keyboardShortcut(.defaultAction).opacity(0).frame(width: 0, height: 0)
        Button("") { introDone = true }.keyboardShortcut(.space, modifiers: []).opacity(0).frame(width: 0, height: 0)
    }

    /// The first record: what the tracker is on right now, ticking, the
    /// moment Accessibility lets it see. Same source as the popover's status line.
    private var liveRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live: (name: String, bundleID: String, since: Date)? = preview.map { $0.live.map { ($0.name, $0.bundleID, context.date.addingTimeInterval(-$0.elapsed)) } }
                ?? (demo ? ("Safari", "com.apple.Safari", demoStart) : nil)
                ?? model.engine.currentActivity.map { ($0.appName, $0.appBundleID, $0.start) }
            HStack(spacing: 10) {
                Circle().fill(Design.live).frame(width: 7, height: 7).opacity(pulse ? 0.35 : 1).accessibilityHidden(true)
                if let live {
                    AppIcon(bundleID: live.bundleID, size: 20)
                    Text("正在记录：\(live.name)").font(.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    let seconds = max(0, Int(context.date.timeIntervalSince(live.since)))
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).font(.body).monospacedDigit().foregroundStyle(Design.ink2)
                } else {
                    Text("正在记录").font(.body.weight(.semibold))
                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Design.live.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .onAppear {
            guard preview == nil, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
        }
    }

    private func permission(_ icon: String, _ title: String, required: Bool, _ detail: String,
                            _ state: PermissionState, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.figure.weight(.regular)).foregroundStyle(.tint)
                .frame(width: 34, height: 34).background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    Text(required ? "需要" : "可选").font(.note.weight(.medium))
                        .foregroundStyle(required ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                Text(detail).font(.body).foregroundStyle(Design.ink2)
            }
            Spacer(minLength: 8)
            if state == .granted {
                Label("已允许", systemImage: "checkmark").font(.body).foregroundStyle(.green)
            } else {
                Button("允许…", action: action).controlSize(.small).disabled(state.isUnavailable)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
