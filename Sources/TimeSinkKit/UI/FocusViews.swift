import SwiftUI
import AppKit
import os

/// Local file:// block page written to disk and shown to the user (via a
/// Chrome tab redirect) when a category-blocked domain is visited during a
/// focus session.
public enum FocusBlockPage {
    /// The page's `<title>` -- also the Chrome AX/ScriptingBridge window
    /// title once the tab has navigated there, which
    /// `FocusSessionController.intercept(sample:at:)` uses as a
    /// redirect-independent signal that a sample IS the block page itself
    /// (decision 2).
    public static let pageMarkerTitle = "TimeSink 拦截页"

    private static let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "focusBlockPage")

    /// Pure (no I/O) -- `NSHomeDirectory()` is an environment lookup, not a
    /// filesystem call. Used both by `ensureWritten()` (the actual write)
    /// and by `FocusSessionController.isBlockPageSample`'s url-prefix check,
    /// which runs on every `intercept(sample:at:)` call and must not touch
    /// disk on that hot path.
    static var location: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/TimeSink/blocked.html")
    }

    /// Writes `blocked.html` to `Application Support/TimeSink/` whenever the
    /// on-disk content doesn't already match the embedded template --
    /// R-T12g: a plain `fileExists` guard would write once ever and then
    /// silently ignore every future template change for the lifetime of the
    /// install. Called ONLY from the production `redirectChrome` closure
    /// (`TimeSinkApp` assembly), immediately before the real Chrome
    /// redirect -- never from `FocusSessionController`, so no test or pure
    /// decision path ever performs this write (`blockPageURL` uses the pure
    /// `location` instead). Returns the file URL either way, even if the
    /// write itself fails (falls back to the intended URL; the redirect
    /// will subsequently fail loading a missing/stale file, a visible-enough
    /// degradation).
    @discardableResult
    public static func ensureWritten() -> URL {
        let url = location
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != html {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                logger.error("ensureWritten failed: \(String(describing: error))")
            }
        }
        return url
    }

    private static let html = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="UTF-8">
    <title>\(pageMarkerTitle)</title>
    <style>
      html, body { height: 100%; margin: 0; background: #1c1c1e; color: #f2f2f7;
        font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; }
      .card { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
        text-align: center; padding: 32px 40px; border-radius: 16px; background: #2c2c2e;
        box-shadow: 0 8px 32px rgba(0,0,0,0.4); min-width: 320px; }
      h1 { font-size: 20px; margin: 0 0 8px; }
      p { font-size: 14px; color: #a1a1a6; margin: 0 0 24px; }
      .buttons { display: flex; gap: 12px; justify-content: center; }
      a.btn { display: inline-block; padding: 10px 18px; border-radius: 8px; text-decoration: none;
        font-size: 14px; font-weight: 600; }
      a.back { background: #0a84ff; color: white; }
      a.allow { background: #3a3a3c; color: #f2f2f7; }
    </style>
    </head>
    <body>
      <div class="card">
        <h1>专注中，此站点已被拦截</h1>
        <p id="sub"></p>
        <div class="buttons">
          <a class="btn back" href="timesink://focus/back">返回工作</a>
          <a class="btn allow" id="allowLink" href="#">放行 5 分钟</a>
        </div>
      </div>
      <script>
        const params = new URLSearchParams(location.search);
        const domain = params.get('domain') || '';
        const remaining = params.get('remaining') || '';
        document.getElementById('sub').textContent = domain + (remaining ? (' · 剩余 ' + remaining) : '');
        document.getElementById('allowLink').href = 'timesink://focus/allow?domain=' + encodeURIComponent(domain);
      </script>
    </body>
    </html>
    """
}

/// The menu-bar popover's two focus-related states, switched by
/// `MenuBarDashboardView`'s `@State private var popoverMode`. `.dashboard`
/// (the default) shows the normal dashboard with a "开始专注" button;
/// `.focusConfig` shows `FocusConfigView`. Both are superseded entirely by
/// `FocusRunningView` whenever `model.focus?.running != nil`, regardless of
/// `popoverMode`.
enum PopoverMode {
    case dashboard, focusConfig
}

/// Focus session configuration state: duration chips, app/site block
/// toggles with read-only chip summaries (the lists themselves are
/// maintained in Settings · 预算, per Task 11), and 开始/取消.
struct FocusConfigView: View {
    let model: AppModel
    let onCancel: () -> Void
    /// Called with the selected duration when "开始 · N 分钟" is tapped --
    /// the actual (throwing) `FocusSessionController.start(minutes:)` call
    /// lives in the caller (`MenuBarDashboardView`) so it can handle the
    /// error without this view needing to know about it.
    let onStart: (Int) -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var minutes: Int

    private static let durationOptions = [15, 25, 45, 90]

    init(model: AppModel, onCancel: @escaping () -> Void, onStart: @escaping (Int) -> Void) {
        self.model = model
        self.onCancel = onCancel
        self.onStart = onStart
        _minutes = State(initialValue: model.settings.focusDurationMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专注设置").font(.headline)

            durationChips

            Toggle("拦截应用", isOn: appBlockBinding)
                .toggleStyle(.switch)
            chipsSummary(model.settings.focusBlockedApps.isEmpty ? [] : model.settings.focusBlockedApps)

            Toggle("拦截网站分类", isOn: siteBlockBinding)
                .toggleStyle(.switch)
            chipsSummary(model.settings.focusBlockedCategories.compactMap { model.resolver.categoriesByID[$0]?.name })

            Button("编辑…") {
                model.settingsTab = .budget
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("开始 · \(minutes) 分钟") {
                    onStart(minutes)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var durationChips: some View {
        HStack(spacing: 6) {
            ForEach(Self.durationOptions, id: \.self) { option in
                Button {
                    minutes = option
                    // 选中即写记忆 (brief), not deferred to 开始 -- so the
                    // duration sticks even if the user cancels this time.
                    model.settings.setFocusDurationMinutes(option)
                } label: {
                    Text("\(option)")
                        .font(.caption)
                        .frame(minWidth: 28)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(minutes == option ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func chipsSummary(_ items: [String]) -> some View {
        if items.isEmpty {
            Text("未设置").font(.caption2).foregroundStyle(.secondary)
        } else {
            Text(items.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var appBlockBinding: Binding<Bool> {
        Binding(
            get: { model.settings.focusAppBlockEnabled },
            set: { model.settings.setFocusAppBlockEnabled($0) }
        )
    }

    private var siteBlockBinding: Binding<Bool> {
        Binding(
            get: { model.settings.focusSiteBlockEnabled },
            set: { model.settings.setFocusSiteBlockEnabled($0) }
        )
    }
}

/// Focus session in-progress state: big countdown, distraction count, and
/// blocked-list chips, plus 结束会话.
struct FocusRunningView: View {
    let model: AppModel

    var body: some View {
        if let focus = model.focus, let running = focus.running {
            VStack(alignment: .leading, spacing: 10) {
                Text(Format.mmss(focus.remaining))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("已拦下 \(focus.appBlocks + focus.siteBlocks) 次分心")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !running.blockedApps.isEmpty || !running.blockedCategories.isEmpty {
                    // Category ids map to display names (same as
                    // `FocusConfigView`'s chip summary two screens earlier);
                    // bundle ids have no better display form, so they stay raw.
                    let categoryNames = running.blockedCategories.map { model.resolver.categoriesByID[$0]?.name ?? $0 }
                    let labels = (Array(running.blockedApps) + categoryNames).sorted()
                    Text(labels.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button("结束会话") { focus.finish(completed: false) }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// The HUD's SwiftUI content: countdown + "已被隐藏" message, plus 坚持专注/结束会话.
struct FocusHUDContentView: View {
    let message: String
    let onKeepFocus: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button("坚持专注", action: onKeepFocus)
                Button("结束会话", action: onFinish)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 260)
    }
}

/// Non-activating floating HUD shown briefly when an app is hidden during a
/// focus session. Holds one `NSPanel`, reused across shows (repositioned/
/// re-armed each time rather than recreated).
@MainActor
public final class FocusHUDController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    public init() {}

    /// Shows (or updates, if already visible) the HUD, auto-dismissing after
    /// 4s. `hideCount == 0` is the R-T12e degraded-notice case (a
    /// non-Chrome browser's site couldn't be hard-blocked -- nothing was
    /// actually hidden), which drops the "已被隐藏（第 n 次）" suffix entirely
    /// rather than claiming a hide that never happened; any other count
    /// renders "专注中 mm:ss · \(appName) 已被隐藏（第 n 次）". `keepFocusAppKey`
    /// is the key `keepFocusTapped` should be called with for the HUD's
    /// "坚持专注" button (the blocked app's bundle ID).
    public func show(remaining: TimeInterval, appName: String, hideCount: Int,
                      keepFocusAppKey: String, controller: FocusSessionController) {
        let message = hideCount == 0
            ? "专注中 \(Format.mmss(remaining)) · \(appName)"
            : "专注中 \(Format.mmss(remaining)) · \(appName) 已被隐藏（第 \(hideCount) 次）"
        let content = FocusHUDContentView(
            message: message,
            onKeepFocus: { [weak controller] in
                controller?.keepFocusTapped(appKey: keepFocusAppKey, at: Date())
            },
            onFinish: { [weak self, weak controller] in
                controller?.finish(completed: false)
                // Fold-in: 结束会话 dismisses the HUD immediately rather than
                // leaving it up for the remainder of the 4s auto-dismiss timer.
                self?.hide()
            }
        )

        let panel = self.panel ?? Self.makePanel()
        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting
        hosting.layout()
        // Fold-in: size the panel to the SwiftUI content's own fitting size
        // before positioning -- the panel is otherwise stuck at whatever
        // fixed size `makePanel()` created it with, regardless of how tall
        // the message/button row actually renders.
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    public func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        return panel
    }

    /// Top-right of the screen containing the mouse (falls back to the main
    /// screen), with a small inset.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16)
        panel.setFrameOrigin(origin)
    }
}
