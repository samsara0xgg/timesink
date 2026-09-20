import Foundation
import AppKit
import TimeSinkKit

_ = NSApplication.shared  // ScreenCaptureKit needs a window-server connection even from a CLI
let window = WindowSampler()
let chrome = ChromeSampler()
let idle = IdleMonitor()

/// `tsprobe capture`: drives the real collector against the front window
/// for 40s and prints what it stored; images go under /tmp.
if CommandLine.arguments.dropFirst().first == "capture" {
    let dir = URL(fileURLWithPath: "/tmp/tsprobe-captures", isDirectory: true)
    let db = try! AppDatabase.openInMemory()
    let collector = ScreenCollector(store: ObservationStore(db), imagesRoot: dir, paused: false)
    print("Screen Recording:", Permissions.screenRecordingState())
    print("switch to the window you want captured; sampling for 40s (first OCR warms up for ~20s)...")
    let start = Date()
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        MainActor.assumeIsolated {
            let now = Date()
            guard let app = window.frontmostApp() else { return }
            let s = window.sample(at: now, app: app)
            print("\(Int(now.timeIntervalSince(start)))s \(s.appBundleID) window=\(s.windowID.map(String.init) ?? "-")")
            Task { await collector.tick(now: now, sample: s, spanID: nil) }
            if now.timeIntervalSince(start) >= 40 {
                let rows = (try? ObservationStore(db).captures(overlapping: DateInterval(start: start, end: now.addingTimeInterval(1)))) ?? []
                for row in rows {
                    print("--- capture \(row.appName) title=\(row.title ?? "-") image=\(row.imagePath ?? "none")")
                    print(row.text.prefix(600))
                }
                print("captures: \(rows.count) (images under \(dir.path))")
                exit(0)
            }
        }
    }
    RunLoop.main.run()
}

print("AX granted:", Permissions.accessibilityGranted(prompt: true))
print("Chrome automation:", Permissions.chromeAutomationStatus(ask: true))
print("--- sampling every 1s, Ctrl+C to stop ---")

Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    MainActor.assumeIsolated {
        guard let app = window.frontmostApp() else { print("(no frontmost)"); return }
        let s = window.sample(app: app)
        var line = "\(s.appBundleID) | \(s.windowTitle ?? "-") | win=\(s.windowID.map(String.init) ?? "-")"
        if s.appBundleID == "com.google.Chrome", let tab = chrome.activeTab() {
            line += " | \(tab.isIncognito ? "(incognito)" : (tab.url ?? "-"))"
        }
        line += " | idle=\(Int(idle.idleSeconds()))s"
        print(line)
    }
}
RunLoop.main.run()
