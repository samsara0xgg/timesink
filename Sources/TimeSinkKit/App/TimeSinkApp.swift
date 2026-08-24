import SwiftUI
import GRDB
import os
import AppKit

public struct TimeSinkApp: App {
    let model: AppModel
    /// True only when running as the installed bundle (`swift run` bare
    /// execution has no bundle identifier) and Accessibility isn't yet
    /// granted — gates whether the onboarding sheet opens at launch.
    let needsOnboarding: Bool

    @Environment(\.openWindow) private var openWindow
    @State private var showOnboarding: Bool
    @NSApplicationDelegateAdaptor(TimeSinkAppDelegate.self) private var appDelegate

    public init() {
        // A second launch (e.g. installed app + `swift run` dev build with the
        // same bundle id, or a double-open) would run a second 1s sampler into
        // the same database and double-count every span -- hand off to the
        // existing instance instead.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != .current }
            if let existing = others.first {
                existing.activate()
                exit(0)
            }
        }

        NSApplication.shared.setActivationPolicy(.accessory)

        let db: any DatabaseWriter
        do {
            db = try AppDatabase.open(at: try AppDatabase.defaultURL())
        } catch {
            Logger(subsystem: "com.alllllenshi.TimeSink", category: "app")
                .fault("failed to open database: \(String(describing: error))")
            fatalError("cannot open TimeSink database: \(error)")
        }

        let spanStore = SpanStore(db)
        let settingsStore = SettingsStore(db)
        let categoryStore = CategoryStore(db)
        SeedImporter.importIfNeeded(categoryStore: categoryStore, settings: settingsStore)

        let resolver = CategoryResolver(categoryStore: categoryStore)
        let engine = TrackerEngine(spanStore: spanStore, settings: settingsStore)
        engine.llmCoordinator = LLMCoordinator(
            categoryStore: categoryStore, settings: settingsStore, resolver: resolver, service: nil
        )

        let model = AppModel(
            categoryStore: categoryStore,
            spanStore: spanStore,
            settings: settingsStore,
            resolver: resolver,
            engine: engine
        )
        self.model = model

        let needsOnboarding = Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink"
            && !Permissions.accessibilityGranted(prompt: false)
        self.needsOnboarding = needsOnboarding
        _showOnboarding = State(initialValue: needsOnboarding)

        engine.start()
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuBarDashboardView(model: model)
        } label: {
            Label(model.menuTitle, systemImage: "hourglass")
                .onAppear {
                    // The menu bar label renders as soon as the app launches
                    // (before any window is shown), so this is a reliable
                    // launch hook for force-opening the main window when
                    // onboarding is needed.
                    appDelegate.engine = model.engine
                    if needsOnboarding {
                        openWindow(id: "main")
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Window("TimeSink", id: "main") {
            MainWindowView(model: model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The menu-bar 退出 button is the only in-app quit path that stops the
/// engine; logout, shutdown, and Cmd-Q would otherwise skip `stop()` and
/// drop up to 30s of the in-progress span (spans younger than 30s vanish
/// entirely -- they are first written at their first heartbeat). Routing
/// every termination through the delegate closes that daily loss path.
final class TimeSinkAppDelegate: NSObject, NSApplicationDelegate {
    var engine: TrackerEngine?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { engine?.stop() }
        return .terminateNow
    }
}
