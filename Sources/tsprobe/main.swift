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

/// `tsprobe sessions <copy.sqlite> [days] [--names]`: F1 sessions per day
/// and how each would be named. Numbers only unless `--names` (for a look
/// on this Mac, never to be copied anywhere).
if CommandLine.arguments.dropFirst().first == "sessions" {
    let db = try! AppDatabase.open(at: URL(fileURLWithPath: CommandLine.arguments[2]))
    let resolver = CategoryResolver(categoryStore: CategoryStore(db))
    let days = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 3 : 3
    let showNames = CommandLine.arguments.contains("--names")
    let namer = SessionNamer()
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    print("model available:", SessionNamer.modelAvailable)
    let done = DispatchSemaphore(value: 0)
    let dayItems = (0..<days).reversed().map { back in
        let start = calendar.date(byAdding: .day, value: -back, to: today)!
        let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        return (back, start, resolver.categorized(try! SpanStore(db).spans(overlapping: interval)).sorted { $0.span.start < $1.span.start })
    }
    Task.detached {
    for (back, start, items) in dayItems {
        let t0 = Date()
        let sessions = SessionSegmenter.sessions(items)
        let cut = Date().timeIntervalSince(t0) * 1000
        print(String(format: "day -%d spans=%d sessions=%d segment=%.1fms", back, items.count, sessions.count, cut))
        for session in sessions {
            let t1 = Date()
            let label = await namer.name(session)
            let fallback = SessionNamer.titleFallback(session)
            let from: Int = Int(session.start.timeIntervalSince(start) / 60)
            let to: Int = Int(session.end.timeIntervalSince(start) / 60)
            let ms: Double = Date().timeIntervalSince(t1) * 1000
            var line = "  \(from)-\(to) rec=\(Int(session.recorded / 60))min apps=\(session.apps.count) titles=\(session.titles.count)"
            line += " src=\(label.source.rawValue) conf=\(String(format: "%.2f", label.confidence)) named=\(label.name != nil) fallbackNamed=\(fallback.name != nil) name=\(Int(ms))ms"
            if showNames { line += " | " + (label.name ?? "-") + " | " + (label.project ?? "-") + " | fb: " + (fallback.name ?? "-") }
            print(line)
            if CommandLine.arguments.contains("--prompt") { print(SessionNamer.prompt(session)) }
        }
    }
    done.signal()
    }
    done.wait()
    exit(0)
}

/// `tsprobe waterfall <copy.sqlite>`: reconciles the timeline thread's
/// interruption count (all non-productive dwell, grouped by the longest
/// destination, no merge) with the classifier's, one rule at a time, for
/// 9-24/25/28/29. Migrates the file it is given; prints numbers only.
if CommandLine.arguments.dropFirst().first == "waterfall" {
    let db = try! AppDatabase.open(at: URL(fileURLWithPath: CommandLine.arguments[2]))
    let resolver = CategoryResolver(categoryStore: CategoryStore(db))
    let productivity = resolver.categoriesByID.mapValues(\.productivity)
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let breaking: Set<String> = ["idle", "lock", "sleep", "stop", "start", "tracking_pause"]
    struct Ep { var start: Date; var end: Date; var all: TimeInterval = 0; var distracting: TimeInterval = 0
        var byDest: [String: TimeInterval] = [:]; var destCat: [String: String] = [:]; var byDistracting: [String: TimeInterval] = [:] }
    for back in [6, 5, 2, 1] {
        let start = calendar.date(byAdding: .day, value: -back, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let interval = DateInterval(start: start, end: end)
        let items = resolver.categorized(try! SpanStore(db).spans(overlapping: interval))
            .filter { $0.span.end > $0.span.start }.sorted { $0.span.start < $1.span.start }
        let events = ((try? ObservationStore(db).stateEvents(in: interval)) ?? []).filter { breaking.contains($0.kind) }.map(\.at)
        // Timeline-thread episodes, with the choice of key for merges.
        func episodes(useEvents: Bool, titleKey: Bool) -> [Ep] {
            var result: [Ep] = []
            var open: Ep?
            var lastProductiveEnd: Date?
            var lastEnd = Date.distantPast
            func close() { if let e = open { result.append(e) }; open = nil }
            for item in items {
                let span = item.span
                let broken = span.start.timeIntervalSince(lastEnd) > 30
                    || (useEvents && events.contains { $0 >= lastEnd.addingTimeInterval(-1) && $0 <= span.start })
                if broken { close(); lastProductiveEnd = nil }
                lastEnd = max(lastEnd, span.end)
                if (productivity[item.categoryID] ?? 0) >= 1 { close(); lastProductiveEnd = span.end; continue }
                if open == nil {
                    guard lastProductiveEnd != nil else { continue }
                    open = Ep(start: span.start, end: span.end)
                }
                let row = span.domain ?? span.appBundleID
                let key = titleKey ? row + "\u{1F}" + (span.title ?? "") : row
                open!.end = max(open!.end, span.end)
                open!.all += span.duration
                open!.byDest[key, default: 0] += span.duration
                open!.destCat[key] = item.categoryID
                if InterruptionRule.distractingCategories.contains(item.categoryID) {
                    open!.distracting += span.duration
                    open!.byDistracting[key, default: 0] += span.duration
                }
            }
            close()
            return result
        }
        func lead(_ d: [String: TimeInterval]) -> String? { d.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key }
        let base = episodes(useEvents: true, titleKey: false)
        // 1. Timeline method: all non-productive dwell >= 15, group a by longest destination.
        let s1 = base.filter { (e: Ep) -> Bool in
            guard e.all >= 15, let k = lead(e.byDest), let c = e.destCat[k] else { return false }
            return InterruptionRule.distractingCategories.contains(c)
        }.count
        let allGroups = base.filter { $0.all >= 15 }.count
        let leadCats = base.filter { $0.all >= 15 }.compactMap { (e: Ep) -> String? in lead(e.byDest).flatMap { e.destCat[$0] } }
        let groupB = leadCats.filter { $0 == "uncategorized" }.count, groupC = leadCats.filter { $0 == "misc" }.count
        let groupOther = leadCats.count - groupB - groupC - leadCats.filter { InterruptionRule.distractingCategories.contains($0) }.count
        // 2. Only distracting time counts toward the threshold.
        let two = base.filter { $0.distracting >= 15 }
        // 2b. Same, but peeks count as visits for the merge too (as the app does).
        // 3. 60 s merge by destination (app / site).
        // The app merges visits of any class, the stronger class wins.
        func mergedInterruptions(_ eps: [Ep], key: (Ep) -> String) -> Int {
            var groups: [(key: String, end: Date, isInt: Bool)] = []
            var lastIndex: [String: Int] = [:]
            for e in eps where e.distracting >= 3 {
                let k = key(e)
                if let i = lastIndex[k], e.start.timeIntervalSince(groups[i].end) <= 60 {
                    groups[i].end = max(groups[i].end, e.end); groups[i].isInt = groups[i].isInt || e.distracting >= 15
                    // dwell adds up across merged visits
                    continue
                }
                lastIndex[k] = groups.count
                groups.append((k, e.end, e.distracting >= 15))
            }
            return groups.filter(\.isInt).count
        }
        let s3row = mergedInterruptions(base) { (e: Ep) -> String in lead(e.byDistracting)! }
        let titled = episodes(useEvents: true, titleKey: true)
        let s3title = mergedInterruptions(titled) { (e: Ep) -> String in lead(e.byDistracting)! }
        let noEvents = episodes(useEvents: false, titleKey: true)
        let s4 = mergedInterruptions(noEvents) { (e: Ep) -> String in lead(e.byDistracting)! }
        let app = DayInterruptions(episodes: InterruptionClassifier.episodes(items, productivity: productivity,
                                                                            rule: InterruptionRule(dwell: 15, countsTyping: false))).interruptions.count
        print(start.formatted(.iso8601.year().month().day()), "1.timeline", s1, "(all groups", allGroups, "b", groupB, "c", groupC, "other", groupOther, ")",
              "2.distractingDwell", two.count, "3.merge(app/site)", s3row, "3'.merge(window)", s3title,
              "4.gapOnly", s4, "5.app", app)
    }
    exit(0)
}

/// `tsprobe interruptions <copy.sqlite> [days]`: per-day interruption counts
/// at each dwell threshold. Migrates the file it is given, so point it at a
/// copy. Prints numbers only -- no titles or apps.
if CommandLine.arguments.dropFirst().first == "interruptions" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard let path = args.first else { print("usage: tsprobe interruptions <db> [days]"); exit(64) }
    let db = try! AppDatabase.open(at: URL(fileURLWithPath: path))
    let resolver = CategoryResolver(categoryStore: CategoryStore(db))
    let productivity = resolver.categoriesByID.mapValues(\.productivity)
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    for back in stride(from: (args.count > 1 ? Int(args[1]) ?? 7 : 7), through: 0, by: -1) {
        let start = calendar.date(byAdding: .day, value: -back, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let items = resolver.categorized(try! SpanStore(db).spans(overlapping: DateInterval(start: start, end: end)))
        var line = start.formatted(.iso8601.year().month().day())
        for dwell in InterruptionRule.dwellChoices {
            let day = DayInterruptions(episodes: InterruptionClassifier.episodes(items, productivity: productivity,
                                                                                 rule: InterruptionRule(dwell: dwell, countsTyping: false)))
            line += "  \(Int(dwell))s: int \(day.interruptions.count) peek \(day.peeks.count) pass \(day.passes)"
        }
        let typed = DayInterruptions(episodes: InterruptionClassifier.episodes(items, productivity: productivity))
        line += "  | 15s+typing: \(typed.interruptions.count)  keySecondsSum \(items.reduce(0) { $0 + $1.span.keySeconds })"
        print(line)
    }
    exit(0)
}

/// `tsprobe ax <bundleID> [maxDepth]`: one-shot accessibility dump of an
/// app's focused window -- see `AXProbe`. Runs from the command line without
/// the target being frontmost, so it can be pointed at whatever is open.
if CommandLine.arguments.dropFirst().first == "ax" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard let bundleID = args.first else {
        print("usage: tsprobe ax <bundleID> [maxDepth]")
        exit(64)
    }
    print("AX granted:", Permissions.accessibilityGranted(prompt: true))
    exit(AXProbe.run(bundleID: bundleID,
                     maxDepth: args.count > 1 ? (Int(args[1]) ?? 12) : 12,
                     manual: args.contains("manual"),
                     all: args.contains("all")))
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
        if legacy { p.checkInterval = 30; p.titleSettleSeconds = .infinity; p.quietInterval = 30 }
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
    print("sampling the front window for \(Int(seconds))s, check every \(policy.checkInterval)s (\(policy.quietInterval)s with no input), refresh \(collector.refreshInterval)s, legacy=\(legacy) (first OCR warms up for ~20s)...")
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
            let idleSeconds = idle.idleSeconds()
            Task { await collector.tick(now: now, sample: s, spanID: nil, idleSeconds: idleSeconds) }
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
