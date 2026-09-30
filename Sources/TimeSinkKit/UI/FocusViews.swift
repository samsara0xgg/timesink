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
    public static let pageMarkerTitle = String(localized: "TimeSink 拦截页")

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

    static var html: String {
        page(lightAccent: accentHex(appearance: .aqua), darkAccent: accentHex(appearance: .darkAqua))
    }

    private static func accentHex(appearance: NSAppearance.Name) -> String {
        var result = "#007AFF"
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return }
            result = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
        return result
    }

    private static func htmlText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func javascriptString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }

    static func page(lightAccent: String, darkAccent: String) -> String { """
    <!doctype html><html lang="\(Bundle.main.preferredLocalizations.first ?? "zh-Hans")"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>\(pageMarkerTitle)</title><style>
    :root{color-scheme:light dark;--work:#f6f6f7;--panel:#fff;--text:#1d1d1f;--secondary:#6e6e73;--accent:\(lightAccent);--line:rgba(0,0,0,.12)}
    @media(prefers-color-scheme:dark){:root{--work:#1b1b1d;--panel:#252528;--text:#f5f5f7;--secondary:#a1a1a6;--accent:\(darkAccent);--line:rgba(255,255,255,.12)}}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--work);color:var(--text);font:13px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
    main{width:min(560px,calc(100vw - 32px));padding:54px 40px 48px;text-align:center;border:.5px solid var(--line);border-radius:12px;background:var(--panel);box-shadow:0 12px 40px #00000012}
    .symbol{color:var(--accent);font-size:32px}h1{font-size:20px;font-weight:700;letter-spacing:-.2px;margin:12px 0 10px;overflow-wrap:anywhere}p{margin:0;color:var(--secondary);line-height:1.6}b{font-variant-numeric:tabular-nums;color:var(--text)}
    .actions{display:flex;gap:8px;justify-content:center;margin:22px 0}a,button{font:inherit;text-decoration:none;border:.5px solid var(--line);border-radius:6px;padding:7px 14px;background:var(--panel);color:var(--text);cursor:pointer}button{background:var(--accent);border-color:transparent;color:#fff}a:focus-visible,button:focus-visible{outline:3px solid var(--accent);outline-offset:3px}.note{font-size:11px}
    @media(prefers-reduced-motion:no-preference){main{animation:enter .16s ease-out}@keyframes enter{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}}
    </style></head><body><main>
    <div class="symbol" aria-hidden="true"><svg width="32" height="32" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="5.6"/><circle cx="8" cy="8" r="2.1"/><path d="M8 .9v2M8 13.1v2M.9 8h2M13.1 8h2"/></svg></div><h1 id="title">\(htmlText(String(localized: "此网站在专注期间被拦截")))</h1>
    <p>\(htmlText(String(localized: "还剩"))) <b id="countdown" role="timer">—</b><span id="deadline"></span></p>
    <div class="actions"><button id="back">\(htmlText(String(localized: "回到上一页")))</button><a id="allow" href="#">\(htmlText(String(localized: "放行 5 分钟")))</a></div>
    <p class="note">\(htmlText(String(localized: "专注期间拦截此类网站 · 放行后回到原来的页面")))</p>
    </main><script>
    const params=new URLSearchParams(location.search),domain=params.get('domain')||'',endsAt=Number(params.get('endsAt'))*1000;
    document.getElementById('title').textContent=\(javascriptString(String(localized: "\(String("{domain}")) 在专注期间被拦截"))).replace('{domain}',domain||\(javascriptString(String(localized: "此网站"))));
    document.getElementById('allow').href='timesink://focus/allow?domain='+encodeURIComponent(domain);
    document.getElementById('back').onclick=()=>{if(history.length>2)history.go(-2);else history.back()};
    function tick(){if(!Number.isFinite(endsAt)||endsAt<=0)return;const remaining=Math.max(0,Math.ceil((endsAt-Date.now())/1000));document.getElementById('countdown').textContent=String(Math.floor(remaining/60)).padStart(2,'0')+':'+String(remaining%60).padStart(2,'0');document.getElementById('deadline').textContent=remaining>0?\(javascriptString(String(localized: "，\(String("{time}")) 结束。"))).replace('{time}',new Date(endsAt).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})):\(javascriptString(String(localized: "，这段专注已结束。")));if(remaining===0)document.getElementById('allow').textContent=\(javascriptString(String(localized: "回到原来的页面")))}tick();setInterval(tick,1000);
    </script></body></html>
    """ }
}

/// The focus lengths every start control offers.
enum FocusPresets {
    static let minutes = [15, 25, 45, 90]
}

/// The length of the next focus: an arc around a dial, set by dragging its
/// glass knob in 5-minute steps from 15 minutes to 2 hours.
struct FocusDial: View {
    @Binding var minutes: Int
    private let range = 15...120
    private let size: CGFloat = 236, radius: CGFloat = 98, line: CGFloat = 18

    var body: some View {
        let fraction = min(1, CGFloat(minutes) / CGFloat(range.upperBound))
        let angle = Angle.degrees(Double(fraction) * 360 - 90)
        ZStack {
            Canvas { context, canvas in
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                for index in 0..<24 {
                    let a = Double(index) / 24 * 2 * .pi - .pi / 2
                    let major = index % 6 == 0
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + 112 * cos(a), y: center.y + 112 * sin(a)))
                    path.addLine(to: CGPoint(x: center.x + (major ? 104 : 108) * cos(a), y: center.y + (major ? 104 : 108) * sin(a)))
                    context.stroke(path, with: .style(.tertiary), style: StrokeStyle(lineWidth: major ? 2 : 1, lineCap: .round))
                }
            }
            Circle().stroke(.quaternary, lineWidth: line).frame(width: radius * 2, height: radius * 2)
            Circle().trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: radius * 2, height: radius * 2)
            Color.clear.frame(width: 34, height: 34).glassSurface(in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .offset(x: radius * cos(angle.radians), y: radius * sin(angle.radians))
            VStack(spacing: 2) {
                Text("\(minutes)").font(.system(size: 50, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
                Text("分钟 · \(Date().addingTimeInterval(Double(minutes) * 60), format: .dateTime.hour().minute()) 结束")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let dx = value.location.x - size / 2, dy = value.location.y - size / 2
            var turn = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
            if turn < 0 { turn += 1 }
            let stepped = Int((turn * CGFloat(range.upperBound) / 5).rounded()) * 5
            minutes = min(range.upperBound, max(range.lowerBound, stepped == 0 ? range.upperBound : stepped))
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("专注时长")
        .accessibilityValue("\(minutes) 分钟")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: minutes = min(range.upperBound, minutes + 5)
            case .decrement: minutes = max(range.lowerBound, minutes - 5)
            @unknown default: break
            }
        }
    }
}

/// Focus session in-progress state: big countdown, distraction count, and
/// blocked-list chips, plus 结束会话.
struct FocusRunningView: View {
    let model: AppModel
    @State private var confirmingEnd = false
    @State private var error: String?
    var body: some View {
        if let focus = model.focus, let running = focus.running {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 7)
                        Circle().trim(from: 0, to: min(1, focus.remaining / Double(running.plannedSeconds)))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text(Format.mmss(focus.remaining)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                            Text("还剩").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(running.start.addingTimeInterval(Double(running.plannedSeconds)), format: .dateTime.hour().minute()) 结束")
                        Text("已专注 \(Int((Double(running.plannedSeconds) - focus.remaining) / 60)) 分钟")
                        Text("已拦下 \(focus.appBlocks + focus.siteBlocks) 次分心")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if !running.blockedApps.isEmpty {
                    HStack(spacing: 5) {
                        Text("隐藏应用").foregroundStyle(.secondary)
                        ForEach(Array(running.blockedApps.sorted().prefix(3)), id: \.self) { AppIcon(bundleID: $0, size: 16).help(AppIcon.name(for: $0)) }
                        Text(running.blockedApps.sorted().prefix(3).map { AppIcon.name(for: $0) }.joined(separator: String(localized: "、"))).lineLimit(1)
                    }.font(.system(size: 11))
                }
                if !running.blockedCategories.isEmpty {
                    let label = Text("拦截网站").font(.system(size: 11)).foregroundStyle(.secondary)
                    let chips = ForEach(Array(running.blockedCategories.sorted().prefix(3)), id: \.self) { CategoryChip(category: model.resolver.categoriesByID[$0]) }
                    // Chips move under the label rather than truncate.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) { label; chips }
                        VStack(alignment: .leading, spacing: 5) { label; HStack(spacing: 5) { chips } }
                    }
                }
                HStack {
                    Button("结束会话") { confirmingEnd = true }
                    Spacer()
                    Button(String(localized: "延长 10 分钟")) { do { try focus.extend() } catch { self.error = String(localized: "未能延长专注，请重试。") } }
                }.controlSize(.small)
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            }
            .confirmationDialog("提前结束这段专注？", isPresented: $confirmingEnd, titleVisibility: .visible) {
                Button("结束会话", role: .destructive) { focus.finish(completed: false) }
                Button("继续专注", role: .cancel) {}
            } message: { Text("已经完成的时间会保留在历史记录中。") }
        }
    }
}

struct FocusHUDContentView: View {
    let appName: String
    let appKey: String
    let hideCount: Int
    let controller: FocusSessionController
    let onReturn: () -> Void
    let onAllow: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIcon(bundleID: appKey, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hideCount == 0 ? appName : String(localized: "\(appName) 在专注期间已隐藏")).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(String(localized: "还剩 \(Format.mmss(controller.remaining))") + (hideCount > 0 ? String(localized: " · 本次第 \(hideCount) 次打开") : ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(spacing: 6) {
                Button(action: onReturn) { Text("回到工作").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                if hideCount > 0 { Button("允许 5 分钟", action: onAllow) }
            }.controlSize(.large)
        }.padding(14).frame(width: 312).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
        let content = FocusHUDContentView(
            appName: appName, appKey: keepFocusAppKey, hideCount: hideCount, controller: controller,
            onReturn: { [weak self] in self?.hide() },
            onAllow: { [weak self, weak controller] in
                controller?.allowApp(keepFocusAppKey)
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: keepFocusAppKey).first {
                    app.activate(options: [])
                }
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
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
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
