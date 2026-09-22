import Foundation
import AppKit
import TimeSinkKit

_ = NSApplication.shared  // ScreenCaptureKit needs a window-server connection even from a CLI
let window = WindowSampler()
let chrome = ChromeSampler()
let idle = IdleMonitor()

/// Process CPU seconds (user + system) and peak resident set in MiB.
func processUsage() -> (cpu: Double, peakMiB: Double) {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return (cpu, Double(usage.ru_maxrss) / 1_048_576)
}

/// `tsprobe capture [seconds] [checkInterval] [legacy]`: drives the real
/// collector against whatever is in front for `seconds` (default 40) with
/// the given check interval (default: the shipped policy) and prints what it
/// stored, the health counters, and this process's CPU time and peak memory;
/// images go under /tmp/tsprobe-captures. `legacy` reproduces the fd039ff
/// behaviour (30 s checks, OCR only on a >=10% signature change, no refresh)
/// for before/after comparison. Exits 3 without looking when Screen Recording
/// is not already granted, so a bench never pops the permission dialog.
if CommandLine.arguments.dropFirst().first == "capture" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    let seconds = args.first.flatMap(Double.init) ?? 40
    let legacy = args.contains("legacy")
    let policy: ScreenCapturePolicy = {
        var p = ScreenCapturePolicy()
        if legacy { p.checkInterval = 30; p.titleSettleSeconds = .infinity }
        if args.count > 1, let interval = Double(args[1]) { p.checkInterval = interval }
        return p
    }()
    let dir = URL(fileURLWithPath: "/tmp/tsprobe-captures", isDirectory: true)
    let db = try! AppDatabase.openInMemory()
    let store = ObservationStore(db)
    let collector = legacy
        ? ScreenCollector(store: store, imagesRoot: dir, paused: false, policy: policy,
                          refreshInterval: .infinity, ocrFraction: ScreenSignature.changedFraction)
        : ScreenCollector(store: store, imagesRoot: dir, paused: false, policy: policy)
    let permission = Permissions.screenRecordingState()
    print("Screen Recording:", permission)
    guard "\(permission)".lowercased().contains("granted") else {
        print("not granted; refusing to prompt from a bench")
        exit(3)
    }
    print("sampling the front window for \(Int(seconds))s, check every \(policy.checkInterval)s, refresh \(collector.refreshInterval)s, legacy=\(legacy) (first OCR warms up for ~20s)...")
    let start = Date()
    let usageAtStart = processUsage()
    var transitions = 0
    var lastKey: WindowKey?
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        MainActor.assumeIsolated {
            let now = Date()
            guard let app = window.frontmostApp() else { return }
            let s = window.sample(at: now, app: app)
            if let id = s.windowID {
                let key = WindowKey(bundleID: s.appBundleID, windowID: id)
                if key != lastKey { transitions += 1; lastKey = key }
            }
            Task { await collector.tick(now: now, sample: s, spanID: nil) }
            if now.timeIntervalSince(start) >= seconds {
                let transitions = transitions
                Task {
                    await collector.interrupt()  // closes the health window
                    let usage = processUsage()
                    let rows = (try? store.captures(overlapping: DateInterval(start: start, end: now.addingTimeInterval(1)))) ?? []
                    for row in rows {
                        let seen = Int(row.lastSeenAt.timeIntervalSince(row.at))
                        print("--- capture \(row.appName) at=+\(Int(row.at.timeIntervalSince(start)))s seen=\(seen)s title=\(row.title ?? "-") chars=\(row.text.count) image=\(row.imagePath ?? "none")")
                    }
                    let health = (try? store.health(overlapping: DateInterval(start: start.addingTimeInterval(-1), end: now.addingTimeInterval(1)))) ?? []
                    var totals = CaptureHealth(windowStart: start, windowEnd: now)
                    for h in health {
                        totals.checks += h.checks; totals.unchanged += h.unchanged; totals.textSame += h.textSame
                        totals.inserted += h.inserted; totals.extended += h.extended; totals.ocrRuns += h.ocrRuns
                        totals.ocrFailed += h.ocrFailed; totals.screenshotFailed += h.screenshotFailed
                        totals.notFront += h.notFront; totals.permissionDenied += h.permissionDenied
                        totals.skippedBusy += h.skippedBusy
                    }
                    var imageBytes: UInt64 = 0
                    for row in rows {
                        if let path = row.imagePath,
                           let size = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(path).path)[.size] as? UInt64 {
                            imageBytes += size
                        }
                    }
                    print(String(format: "RESULT seconds=%.0f interval=%.0f window_transitions=%d rows=%d images_kb=%d checks=%d unchanged=%d textSame=%d inserted=%d extended=%d ocr=%d ocrFailed=%d shotFailed=%d notFront=%d denied=%d busy=%d cpu_s=%.2f cpu_pct=%.1f peak_mib=%.0f",
                                 seconds, policy.checkInterval, transitions, rows.count, Int(imageBytes / 1024),
                                 totals.checks, totals.unchanged, totals.textSame, totals.inserted, totals.extended,
                                 totals.ocrRuns, totals.ocrFailed, totals.screenshotFailed, totals.notFront,
                                 totals.permissionDenied, totals.skippedBusy,
                                 usage.cpu - usageAtStart.cpu, (usage.cpu - usageAtStart.cpu) / seconds * 100, usage.peakMiB))
                    exit(0)
                }
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
