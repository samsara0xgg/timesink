import Foundation
import AppKit
import TimeSinkKit

let window = WindowSampler()
let chrome = ChromeSampler()
let idle = IdleMonitor()

print("AX granted:", Permissions.accessibilityGranted(prompt: true))
print("Chrome automation:", Permissions.chromeAutomationStatus(ask: true))
print("--- sampling every 1s, Ctrl+C to stop ---")

Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    MainActor.assumeIsolated {
        guard let s = window.sample() else { print("(no frontmost)"); return }
        var line = "\(s.appBundleID) | \(s.windowTitle ?? "-")"
        if s.appBundleID == "com.google.Chrome", let tab = chrome.activeTab() {
            line += " | \(tab.isIncognito ? "(incognito)" : (tab.url ?? "-"))"
        }
        line += " | idle=\(Int(idle.idleSeconds()))s"
        print(line)
    }
}
RunLoop.main.run()
