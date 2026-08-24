import SwiftUI

public struct TimeSinkApp: App {
    public init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    public var body: some Scene {
        MenuBarExtra("TimeSink", systemImage: "hourglass") {
            Text("TimeSink 运行中")
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        }
    }
}
