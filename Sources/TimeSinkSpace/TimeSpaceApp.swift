import SwiftUI
import AppKit

@main
struct TimeSpaceApp: App {
    @NSApplicationDelegateAdaptor(SpaceAppDelegate.self) private var delegate

    var body: some Scene {
        Window("TimeSink · 时间空间", id: "time-space") {
            TimeSpaceView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 700)
        }
        .defaultSize(width: 1220, height: 850)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class SpaceAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
