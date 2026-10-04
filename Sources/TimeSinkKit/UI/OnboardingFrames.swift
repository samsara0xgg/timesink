#if DEBUG
import AppKit
import SwiftUI
import TipKit
import GRDB

/// `--onboarding-frames <outdir>`: the welcome card's intro at progress 0, 0.1 ... 1,
/// the settled card with the first-record row, the flight to the menu bar (`fly-*`),
/// the popover tour (`tour-*`) and the three contextual tips (`tip-*`), as PNGs. No visible window, no activation, a
/// fixture model, never the system's permissions.
public enum OnboardingFrames {
    /// TipKit in a datastore of its own, never the app's: a throwaway directory per process.
    @MainActor static func configureTips() {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("timesink-tips-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try Tips.configure([.datastoreLocation(.url(store))])
        } catch { print("TipKit: \(error)") }
    }

    @MainActor public static func run(outdir: String) {
        configureTips()
        MenuTour.keepsHoverTip = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        Task { @MainActor in
            do {
                let dir = URL(fileURLWithPath: outdir, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let model = try liveModel()
                for step in 0...10 {
                    try await snapshot(OnboardingView(model: model, preview: .init(progress: Double(step) / 10, live: nil)),
                                       size: OnboardingView.size, scale: 2, to: dir.appendingPathComponent(String(format: "intro-%02d.png", step * 10)))
                }
                try await snapshot(OnboardingView(model: model, preview: .init(progress: 1, live: ("Safari", "com.apple.Safari", 3.4))),
                                   size: OnboardingView.size, scale: 2, to: dir.appendingPathComponent("final-live.png"))
                // A 1440x900 screen at 1200 px wide.
                for t in [0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0, 1.15] {
                    try await snapshot(FlightScene(t: t), size: FlightScene.size, scale: 1200 / FlightScene.size.width,
                                       to: dir.appendingPathComponent(String(format: "fly-%03d.png", Int((t * 100).rounded()))))
                }
                try await tourFrames(model, in: dir)
                try await tipFrames(model, in: dir)
            } catch { print("Frames failed: \(error)"); exit(1) }
            exit(0)
        }
        app.run()
    }

    /// The fixture model with the tracker on Safari: the popover reads "recording".
    /// `busyDay`: five more categories with a quarter hour each, as a full day has.
    @MainActor static func liveModel(busyDay: Bool = false) throws -> AppModel {
        let model = try RefinedPreview.fixture()
        model.accessibilityGranted = true
        if busyDay {
            let dayStart = Calendar.current.startOfDay(for: Date())
            for (index, app) in ["com.apple.dt.Xcode", "com.apple.mail", "com.apple.Music", "com.apple.Notes", "us.zoom.xos", "com.apple.MobileSMS"].enumerated() {
                let start = dayStart.addingTimeInterval(Double(300 + index * 1000))
                _ = try model.spanStore.insert(Span(start: start, end: start.addingTimeInterval(900), appBundleID: app, appName: app, title: nil, url: nil, domain: nil))
            }
        }
        // Some time nobody has named, so the popover has something uncategorized to show.
        let start = Date().addingTimeInterval(-9 * 60)
        _ = try model.spanStore.insert(Span(start: start, end: start.addingTimeInterval(6 * 60), appBundleID: "app.unnamed.demo", appName: "Scratchpad",
                                            title: "Untitled", url: nil, domain: nil))
        // On any day the unnamed time must be among the popover's first five rows, or there is
        // nothing to point at: it takes over the third-largest category's spans.
        let today = DateInterval(start: Calendar.current.startOfDay(for: Date()), end: Date())
        var byCategory: [String: [Span]] = [:]
        for span in try model.spanStore.spans(overlapping: today) {
            let id = model.resolver.categoryID(for: span)
            if id != "uncategorized" { byCategory[id, default: []].append(span) }
        }
        let ranked = byCategory.sorted { $0.value.reduce(0) { $0 + $1.duration } > $1.value.reduce(0) { $0 + $1.duration } }
        if ranked.count > 2 {
            try model.spanStore.writer.write { db in
                for var span in ranked[2].value {
                    span.appBundleID = "app.unnamed.demo"; span.appName = "Scratchpad"; span.title = "Untitled"
                    span.url = nil; span.domain = nil; span.document = nil
                    try span.update(db)
                }
            }
        }
        // A first two-hour day lies behind us: yesterday's record is worth a pointer.
        model.settings.set("firstLongDay", String(Calendar.current.startOfDay(for: Date().addingTimeInterval(-86400)).timeIntervalSince1970))
        model.dataChanged()
        model.engine.windowSampleProvider = { now in
            Sample(timestamp: now, appBundleID: "com.apple.Safari", appName: "Safari", windowTitle: nil, url: nil)
        }
        model.engine.start()
        return model
    }

    /// A borderless window far off every screen, ordered front without activating
    /// anything: the controls and app icons only draw for real when hosted in one.
    @MainActor static func snapshot<V: View>(_ view: V, size: CGSize, scale: CGFloat, settle: Duration = .milliseconds(500), to url: URL) async throws {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: settle)
        try capture(host, window: window, size: size, scale: scale, to: url)
    }

    @MainActor static func capture(_ host: NSView, window: NSWindow, size: CGSize, scale: CGFloat, to url: URL) throws {
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    /// The popover with each tip, in the order they come: the hover tip, then
    /// (once the hover opened) the recategorize tip, then (once closed) the review tip.
    @MainActor private static func tipFrames(_ model: AppModel, in dir: URL) async throws {
        for (index, kind) in ContextualTips.Kind.allCases.enumerated() {
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 340, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.ignoresMouseEvents = true
            let host = NSHostingView(rootView: MenuBarDashboardView(model: model).background(Design.floor))
            window.contentView = host
            window.orderFrontRegardless()
            try await Task.sleep(for: .seconds(2.5))
            let size = CGSize(width: 340, height: host.fittingSize.height)
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(600))
            guard model.tips.eligible.contains(kind) else {
                print("tip \(kind): eligible \(model.tips.eligible) status \(ContextualTips.tip(kind).status) rows \(HoverTip.rowsShown) item \(RecategorizeTip.itemShown) due \(ReviewTip.due)")
                window.orderOut(nil); throw CocoaError(.fileReadUnknown) }
            try capture(host, window: window, size: size, scale: 2, to: dir.appendingPathComponent("tip-\(index + 1).png"))
            window.orderOut(nil)
            model.tips.close(kind)
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// The popover under each tour step. One window, so the spotlight moves as it would.
    @MainActor private static func tourFrames(_ model: AppModel, in dir: URL) async throws {
        model.menuTour.armed = true
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 340, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: MenuBarDashboardView(model: model).background(Design.floor))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // The day loads, then the tour starts half a second after the popover appears.
        try await Task.sleep(for: .seconds(2.5))
        let size = CGSize(width: 340, height: host.fittingSize.height)
        window.setContentSize(size)
        try await Task.sleep(for: .milliseconds(600))
        guard model.menuTour.current != nil else { throw CocoaError(.fileReadUnknown) }
        for step in 1...model.menuTour.steps.count {
            try capture(host, window: window, size: size, scale: 2, to: dir.appendingPathComponent("tour-\(step).png"))
            model.menuTour.next()
            try await Task.sleep(for: .milliseconds(500))
        }
        model.menuTour.end()
    }
}

/// `--onboarding-tips-check`: the demo's path, offscreen. The popover is hosted the way the
/// demo hosts it (a fresh `NSHostingController` per open), the tour runs and is clicked
/// through, the popover is torn down and opened again, and each reopen must show the next
/// tip: hover, then recategorize, then review. Exits 0 when it does, 1 when it does not.
/// `busy` as an extra argument runs it on a full day's data (one process per scenario: TipKit's
/// datastore is the process's).
public enum OnboardingTipsCheck {
    @MainActor public static func run() {
        OnboardingFrames.configureTips()
        MenuTour.keepsHoverTip = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        Task { @MainActor in
            var failed = false
            do {
                let busy = CommandLine.arguments.contains("busy")
                print("-- \(busy ? "a busy day" : "an early day")")
                let model = try OnboardingFrames.liveModel(busyDay: busy)
                func check(_ ok: Bool, _ text: String) { print((ok ? "ok   " : "FAIL ") + text); if !ok { failed = true } }

                // Open 1: the tour.
                model.menuTour.armed = true
                var popover = try await open(model, wait: 3)
                print(model.tips.debugLine())
                check(model.menuTour.current != nil, "the tour started")
                // The user's path: each step, the hover step with a pane opening, the last step by clicking the open button.
                var steps = 0
                while let step = model.menuTour.current {
                    steps += 1
                    if step == .row { model.tips.drillOpened(quiet: model.menuTour.current != nil) }
                    if step == .open { model.noteMainWindowOpened(); model.menuTour.end() } else { model.menuTour.next() }
                    try await Task.sleep(for: .milliseconds(300))
                }
                check(steps >= 2, "the tour ran \(steps) steps")
                close(popover)

                // Reopens: one tip each, in order; closing one lets the next through.
                for kind in ContextualTips.Kind.allCases {
                    popover = try await open(model, wait: 3)
                    print(model.tips.debugLine())
                    let shown = model.tips.current(present: model.tips.traced.present, quiet: model.tips.traced.quiet)
                    check(shown == kind, "reopen shows \(kind): \(String(describing: shown))")
                    if let host = popover.contentView {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tips-check-\(kind).png")
                        let size = host.bounds.size
                        try OnboardingFrames.capture(host, window: popover, size: size, scale: 2, to: url)
                        print("     frame \(url.path)")
                    }
                    close(popover)
                    model.tips.close(kind)
                    try await Task.sleep(for: .milliseconds(300))
                }
            } catch { print("FAIL \(error)"); failed = true }
            exit(failed ? 1 : 0)
        }
        app.run()
    }

    /// The popover as the demo builds it, in a window far off every screen.
    @MainActor private static func open(_ model: AppModel, wait: Double) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 340, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.ignoresMouseEvents = true
        let controller = NSHostingController(rootView: MenuBarDashboardView(model: model).dynamicTypeSize(...DynamicTypeSize.xxLarge))
        controller.sizingOptions = .preferredContentSize
        window.contentViewController = controller
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(wait))
        return window
    }

    @MainActor private static func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentViewController = nil
    }
}

/// A made-up screen for the flight frames: a menu bar with the icon, the welcome
/// card fading out where the trail starts.
private struct FlightScene: View {
    static let size = CGSize(width: 1440, height: 900)
    static let start = CGPoint(x: 720, y: 450 - 285 + 64), end = CGPoint(x: 1300, y: 12)
    var t: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Design.floor
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Design.surface)
                .frame(width: OnboardingView.size.width, height: OnboardingView.size.height)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
                .offset(x: 720 - OnboardingView.size.width / 2, y: 450 - OnboardingView.size.height / 2)
                .opacity(max(0, 1 - t / 0.2))
            Rectangle().fill(.white.opacity(0.7)).frame(height: 24)
            ForEach([60.0, 140, 210, 1150, 1210, 1240], id: \.self) { x in
                Capsule().fill(Design.ink2.opacity(0.5)).frame(width: 26, height: 7).offset(x: x, y: 8.5)
            }
            Image(systemName: "hourglass").font(.system(size: 13)).foregroundStyle(Design.ink)
                .position(x: Self.end.x, y: Self.end.y)
            FlightView(t: t, start: Self.start, end: Self.end)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// `--onboarding-demo`: the whole first run on fixture data, to try by hand: the
/// card in an ordinary window, the flight to a status item of its own, the popover
/// with its tour. Simulated permissions, no login item, an in-memory store.
/// Cmd+R, or right-click the status item, replays; the popover's power button quits.
public enum OnboardingDemo {
    @MainActor private final class Host: NSObject, NSApplicationDelegate, NSPopoverDelegate {
        let model: AppModel
        let window: NSWindow
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()

        init(model: AppModel) {
            self.model = model
            window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            super.init()
            window.title = "TimeSink"
            window.isReleasedWhenClosed = false
            popover.behavior = .transient
            popover.delegate = self
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "TimeSink")
                button.target = self
                button.action = #selector(clicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            model.statusButtonFrame = { [weak self] in
                guard let button = self?.item.button, let window = button.window else { return nil }
                return window.convertToScreen(button.convert(button.bounds, to: nil))
            }
            model.popoverShortcut.action = { [weak self] in self?.openPopover() }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
        func popoverDidClose(_ notification: Notification) { model.menuTour.end() }

        @objc func clicked() {
            if NSApp.currentEvent?.type == .rightMouseUp {
                let menu = NSMenu()
                let replay = NSMenuItem(title: "Replay", action: #selector(replay), keyEquivalent: "r")
                replay.target = self
                menu.addItem(replay)
                menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
                item.menu = menu
                item.button?.performClick(nil)
                item.menu = nil
            } else if popover.isShown { popover.performClose(nil) } else { openPopover() }
        }

        func openPopover() {
            guard let button = item.button else { return }
            // Built afresh on every open, as the menu bar's popover is.
            let controller = NSHostingController(rootView: MenuBarDashboardView(model: model).dynamicTypeSize(...DynamicTypeSize.xxLarge))
            controller.sizingOptions = .preferredContentSize
            popover.contentViewController = controller
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Once the popover has settled: why a tip shows, or why not.
            Task { @MainActor [model] in
                try? await Task.sleep(for: .seconds(1.5))
                print(model.tips.debugLine())
            }
        }

        /// A new process: TipKit's datastore cannot be reset after it is configured.
        @objc func replay() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = Array(CommandLine.arguments.dropFirst())
            try? process.run()
            NSApp.terminate(nil)
        }

        func show() {
            popover.performClose(nil)
            model.menuTour.end()
            window.contentView = NSHostingView(rootView: OnboardingView(model: model, demo: true, onContinue: { [weak self] from, _ in
                self?.window.orderOut(nil)
                self?.model.finishOnboarding(from: from, launchAtLogin: false)
            }))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @MainActor private static var host: Host?

    @MainActor public static func run() {
        OnboardingFrames.configureTips()
        MenuTour.keepsHoverTip = true
        let app = NSApplication.shared
        do { host = Host(model: try OnboardingFrames.liveModel()) } catch { print("Demo failed: \(error)"); exit(1) }
        app.delegate = host
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu(), replay = NSMenuItem(title: "Replay", action: #selector(Host.replay), keyEquivalent: "r")
        replay.target = host
        appMenu.addItem(replay)
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        app.mainMenu = menu
        host?.show()
        app.run()
    }
}
#endif
