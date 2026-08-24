import SwiftUI
import GRDB
import os

public struct TimeSinkApp: App {
    let model: AppModel

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

        let model = AppModel(
            categoryStore: categoryStore,
            spanStore: spanStore,
            settings: settingsStore,
            resolver: resolver,
            engine: engine
        )
        self.model = model

        engine.start()
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label(model.menuTitle, systemImage: "hourglass")
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
            Button("退出") {
                model.engine.stop()
                NSApp.terminate(nil)
            }
        }
        .padding()
    }
}
