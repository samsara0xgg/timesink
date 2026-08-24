import SwiftUI
import GRDB
import os

public struct TimeSinkApp: App {
    let model: AppModel
    /// True only when running as the installed bundle (`swift run` bare
    /// execution has no bundle identifier) and Accessibility isn't yet
    /// granted — gates whether the onboarding sheet opens at launch.
    let needsOnboarding: Bool

    @Environment(\.openWindow) private var openWindow
    @State private var showOnboarding: Bool

    public init() {
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
            MenuBarContent(model: model)
        } label: {
            Label(model.menuTitle, systemImage: "hourglass")
                .onAppear {
                    // The menu bar label renders as soon as the app launches
                    // (before any window is shown), so this is a reliable
                    // launch hook for force-opening the main window when
                    // onboarding is needed.
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

/// MenuBarExtra dropdown content (`.menuBarExtraStyle(.window)` lets this be
/// arbitrary SwiftUI, not just a plain Menu).
private struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.menuTitle)
                .font(.largeTitle)
            Text("今日总时长 \(model.todayTotalTitle)")
            Text("生产力分 \(model.todayPulseTitle)")
            Divider()
            Button("打开 TimeSink") {
                openWindow(id: "main")
            }
            SettingsLink {
                Text("设置…")
            }
            Button("退出") {
                model.engine.stop()
                NSApp.terminate(nil)
            }
        }
        .padding()
    }
}
