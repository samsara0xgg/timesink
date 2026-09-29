#if DEBUG
import AppKit
import SwiftUI
import Observation
import WebKit

/// Deterministic design review, isolated from tracking, permissions, sync and personal data.
public enum RefinedPreview {
    @MainActor private static var stage: RefinedPreviewStage?
    @MainActor public static func run() { RefinedPreviewApp.main() }
    @MainActor fileprivate static func start(stage: RefinedPreviewStage) async {
        guard !stage.started else { return }
        stage.started = true
        self.stage = stage
        do { try await renderAll() }
        catch { print("Preview failed: \(error)"); exit(1) }
        exit(0)
    }
    @MainActor private static func renderAll() async throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/design-audit-images/refined")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--motion-review") {
            try await renderMotion(to: output)
            try await renderBlockPage(to: output)
            return
        }
        let model = try fixture()
        model.timeFormat = "12"
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for (name, page) in [("today", SidebarItem.today), ("activities", .activities), ("trends", .stats), ("focus", .focus), ("organization", .organization)] {
                model.sidebarSelection = page
                model.range = DateRangeSelection(kind: page == .stats ? .last7 : .day, anchor: Date())
                let selectedActivities = ActivitiesModel()
                selectedActivities.recompute(model: model, events: [])
                if page == .activities, let item = model.rangedSpans().last {
                    selectedActivities.select(ActivitiesModel.selection(for: item), start: item.span.start)
                }
                try await render(MainWindowView(model: model, activities: selectedActivities), size: .init(width: 1200, height: 820), dark: dark, to: output.appendingPathComponent("\(name)-\(suffix).png"))
            }
            let activityModel = ActivitiesModel()
            model.range = .today()
            activityModel.recompute(model: model, events: [])
            if let item = model.rangedSpans(for: .today()).first {
                activityModel.select(ActivitiesModel.selection(for: item), start: item.span.start)
                try await render(ActivityInspector(model: model, activities: activityModel), size: .init(width: 272, height: 760), dark: dark, to: output.appendingPathComponent("inspector-\(suffix).png"))
            }
            try await render(TitleRuleEditor(model: model, pending: .init(prefill: "SwiftUI", scopeKey: "com.apple.Safari", scopeLabel: "Safari", categoryID: "learning")), size: .init(width: 460, height: 380), dark: dark, to: output.appendingPathComponent("title-rule-\(suffix).png"))
            for step in 0..<5 {
                try await render(OnboardingView(model: model, initialStep: step, checksPermissions: false), size: .init(width: 500, height: 470), dark: dark, to: output.appendingPathComponent("onboarding-\(step + 1)-\(suffix).png"))
            }
            model.sidebarSelection = .organization
            for (name, tab) in [("categories", SettingsTab.categories), ("rules", .rules)] {
                model.organizationTab = tab
                try await render(MainWindowView(model: model), size: .init(width: 1200, height: 820), dark: dark, to: output.appendingPathComponent("\(name)-\(suffix).png"))
            }
            model.organizationTab = .uncategorized
            for (name, tab) in [("general", SettingsTab.general), ("privacy", .privacy), ("notifications", .notifications), ("account", .account), ("ai", .llm), ("about", .about)] {
                model.settingsTab = tab
                try await render(SettingsView(model: model), size: .init(width: 640, height: 560), dark: dark, to: output.appendingPathComponent("settings-\(name)-\(suffix).png"))
            }
            try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 760), dark: dark, to: output.appendingPathComponent("menu-\(suffix).png"))
            model.pauseTracking(minutes: 15)
            try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 570), dark: dark, to: output.appendingPathComponent("menu-paused-\(suffix).png"))
            model.resumeTracking()
            try model.focus?.start(minutes: 25)
            try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 510), dark: dark, to: output.appendingPathComponent("menu-focus-\(suffix).png"))
            if let focus = model.focus {
                try await render(FocusHUDContentView(appName: "信息", appKey: "com.apple.MobileSMS", hideCount: 1, controller: focus, onReturn: {}, onAllow: {}), size: .init(width: 312, height: 122), dark: dark, to: output.appendingPathComponent("focus-hud-\(suffix).png")) // l10n: data
            }
            model.focus?.finish(completed: false)
            model.accessibilityGranted = false
            try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 520), dark: dark, to: output.appendingPathComponent("menu-permission-\(suffix).png"))
            model.accessibilityGranted = true
        }
        model.sidebarSelection = .today
        try await render(MainWindowView(model: model), size: .init(width: 800, height: 580), dark: false, to: output.appendingPathComponent("today-compact.png"))
        model.timeFormat = "24"
        try await render(MainWindowView(model: model), size: .init(width: 800, height: 580), dark: false, to: output.appendingPathComponent("today-compact-24h.png"))
        try await render(MenuBarDashboardView(model: model), size: .init(width: 340, height: 760), dark: false, to: output.appendingPathComponent("menu-24h.png"))
        try FocusBlockPage.html.write(to: output.appendingPathComponent("blocked.html"), atomically: true, encoding: .utf8)
        print("Rendered native review surfaces to \(output.path)")
    }
    @MainActor private static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) async throws {
        guard let stage else { throw CocoaError(.fileWriteUnknown) }
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        stage.window?.appearance = NSApp.appearance
        stage.dark = dark
        stage.size = size
        stage.content = AnyView(view.id(url.lastPathComponent))
        try await Task.sleep(for: .milliseconds(650))
        guard let window = stage.window else { throw CocoaError(.fileWriteUnknown) }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(250))
        guard let content = window.contentView else { throw CocoaError(.fileWriteUnknown) }
        // Main/settings captures include the real SwiftUI scene toolbar/titlebar.
        let capturesFrame = url.lastPathComponent.hasPrefix("settings-") || size.width >= 800
        let host = capturesFrame ? (content.superview ?? content) : content
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        FileHandle.standardError.write(Data(("Captured " + url.lastPathComponent + "\n").utf8))
    }
    @MainActor private static func renderMotion(to output: URL) async throws {
        guard let stage else { return }
        let frames = output.appendingPathComponent("number-motion-frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try await render(RefinedMotionProof(stage: stage), size: .init(width: 860, height: 260), dark: false, to: output.appendingPathComponent("number-motion-start.png"))
        var times: [[String: Any]] = []
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<120 {
            if index == 20 { stage.motionValue = "5h 59m" }
            if index == 70 { stage.motionValue = "6h 00m" }
            try await Task.sleep(for: .milliseconds(33))
            guard let content = stage.window?.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw CocoaError(.fileWriteUnknown) }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let filename = String(format: "%03d.png", index)
            try bitmap.representation(using: .png, properties: [:])!.write(to: frames.appendingPathComponent(filename))
            times.append(["file": filename, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start, "value": stage.motionValue])
        }
        let log: [String: Any] = ["origin": "Native SwiftUI frame recording; same RefinedNumberMotion modifier as Today and menu; synthetic values; left normal 280ms, right Reduce Motion 150ms", "frames": times]
        try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("number-motion-timing.json"))
    }

    @MainActor private static func renderBlockPage(to output: URL) async throws {
        let file = output.appendingPathComponent("blocked.html")
        try FocusBlockPage.html.write(to: file, atomically: true, encoding: .utf8)
        for dark in [false, true] {
            guard let stage else { return }
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "dark" : "light"
            stage.dark = dark; stage.size = NSSize(width: 900, height: 600)
            stage.content = AnyView(RefinedBlockProof(web: web).id(suffix))
            stage.window?.appearance = web.appearance
            try await Task.sleep(for: .milliseconds(350))
            stage.window?.setContentSize(stage.size)
            var url = URLComponents(url: file, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "domain", value: "bilibili.com"), URLQueryItem(name: "endsAt", value: String(Date().addingTimeInterval(1122).timeIntervalSince1970))]
            web.loadFileURL(url.url!, allowingReadAccessTo: output)
            try await Task.sleep(for: .seconds(2))
            let snapshot = try await web.takeSnapshot(configuration: nil)
            guard let data = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: output.appendingPathComponent("blocked-\(suffix).png"))
            FileHandle.standardError.write(Data(("Captured blocked-" + suffix + ".png\n").utf8))
        }
    }
    @MainActor private static func fixture() throws -> AppModel {
        let db = try AppDatabase.openInMemory()
        let categories = CategoryStore(db), spans = SpanStore(db), settings = SettingsStore(db)
        let apps = [("com.apple.dt.Xcode", "Xcode", "softwareDev", "TimeSink · TimelineView.swift"),
                    ("com.apple.Safari", "Safari", "learning", "SwiftUI · Layout fundamentals"),
                    ("com.apple.iWork.Pages", "Pages", "writing", "产品设计与本周计划"), // l10n: data
                    ("com.apple.Terminal", "Terminal", "softwareDev", "timesink — swift build"),
                    ("com.apple.MobileSMS", "信息", "communication", "产品团队讨论"), // l10n: data
                    ("com.apple.Music", "音乐", "entertainment", "播放列表"), // l10n: data
                    ("com.apple.systempreferences", "系统设置", "utilities", "系统设置"), // l10n: data
                    ("app.unknown", "Excalidraw", "uncategorized", "新的设计想法")] // l10n: data
        for app in apps where app.2 != "uncategorized" { try categories.setUserApp(app.0, categoryID: app.2) }
        for offset in 0..<30 {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date()))!
            for index in 0..<18 {
                let app = apps[(index + offset % 3) % apps.count]
                let start = day.addingTimeInterval(Double(8 * 3600 + index * 1680))
                guard start < Date() else { continue }
                try spans.insert(Span(start: start, end: min(Date(), start.addingTimeInterval(Double([1440, 960, 1500, 1200][index % 4]))), appBundleID: app.0, appName: app.1, title: app.3, url: nil, domain: nil))
            }
        }
        let engine = TrackerEngine(spanStore: spans, settings: settings)
        let model = AppModel(categoryStore: categories, spanStore: spans, settings: settings, resolver: CategoryResolver(categoryStore: categories), engine: engine)
        let budget = BudgetStore(db)
        try budget.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        try budget.setBudget(categoryID: "communication", dailySeconds: 2700)
        model.budgetStore = budget
        let sessions = FocusSessionStore(db)
        model.focusStore = sessions
        model.focus = FocusSessionController(store: sessions, settings: settings)
        settings.setFocusBlockedApps(["com.apple.MobileSMS", "com.apple.Music"])
        settings.setFocusBlockedCategories(["socialMedia", "entertainment", "shopping"])
        for offset in 0..<4 {
            let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(-offset * 86400 + 10 * 3600))
            let session = try sessions.start(at: start, plannedSeconds: 2700)
            try sessions.finish(id: session.id!, end: start.addingTimeInterval(2700), appBlocks: offset % 2, siteBlocks: 1, completed: true)
        }
        model.dataChanged()
        return model
    }
}
@MainActor @Observable fileprivate final class RefinedPreviewStage {
    var motionValue = "5h 58m"
    var started = false
    var content = AnyView(Color.clear)
    var size = NSSize(width: 1200, height: 820)
    var dark = false
    var window: NSWindow?
    var anchor: NSView?
}

private struct RefinedMotionProof: View {
    let stage: RefinedPreviewStage
    var body: some View {
        HStack(spacing: 20) {
            column(reduced: false)
            column(reduced: true)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(RefinedStyle.work)
    }
    private func column(reduced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reduced ? "减弱动态效果 · 150ms 淡变" : "普通模式 · 280ms 数字滚动") // l10n: data
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("今天已记录").font(.system(size: 12)).foregroundStyle(.secondary) // l10n: data
            Text(stage.motionValue).font(.system(size: 34, weight: .semibold)).tracking(-0.68).monospacedDigit()
                .modifier(RefinedNumberMotion(value: stage.motionValue, reducedOverride: reduced))
            Text("隔离预览 · 示例数据").font(.system(size: 11)).foregroundStyle(.secondary) // l10n: data
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).workspacePanel()
    }
}
private struct RefinedBlockProof: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

@MainActor private struct RefinedPreviewApp: App {
    @State private var stage = RefinedPreviewStage()
    var body: some Scene {
        Window("TimeSink · 示例数据验收", id: "refined-preview") { // l10n: data
            stage.content
                .frame(width: stage.size.width, height: stage.size.height)
                .environment(\.colorScheme, stage.dark ? .dark : .light)
                .preferredColorScheme(stage.dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .background(RefinedWindowProbe(window: $stage.window))
                .task { NSApp.setActivationPolicy(.regular); await RefinedPreview.start(stage: stage) }
        }.windowResizability(.contentSize)
    }
}
private struct RefinedWindowProbe: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if self.window !== view.window { self.window = view.window } }
    }
}
#endif
