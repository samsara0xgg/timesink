import SwiftUI
import GRDB
import os

public struct TimeSinkApp: App {
    let engine: TrackerEngine

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
        let engine = TrackerEngine(spanStore: spanStore, settings: settingsStore)
        engine.start()
        self.engine = engine
    }

    public var body: some Scene {
        MenuBarExtra("TimeSink", systemImage: "hourglass") {
            Text("TimeSink 运行中")
            Text(engine.latestSample?.appName ?? "未采样")
            Divider()
            Button("退出") {
                engine.stop()
                NSApp.terminate(nil)
            }
        }
    }
}
