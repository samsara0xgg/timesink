import Foundation
import TimeSinkKit

/// `tsprobe jev-live --db <copy.sqlite> [--days 30] [--keychain-service <name>] [--cap 1.0]`
///
/// Runs the real Jev pipeline headlessly on a COPY of the database: migrates
/// it, backfills verdicts for the last `--days` days through the worker, then
/// prints hours per category and what the run cost. The key is read in this
/// process from the named Keychain item and never printed. It refuses the
/// live database.
@MainActor
func runJevLive(_ args: [String]) async {
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    guard let path = value("--db") else {
        print("usage: tsprobe jev-live --db <copy.sqlite> [--days 30] [--keychain-service <name>] [--cap 1.0]")
        exit(64)
    }
    let days = value("--days").flatMap(Int.init) ?? 30
    let cap = value("--cap").flatMap(Double.init) ?? 1.0
    let service = value("--keychain-service") ?? "jarvis-eval-openrouter"

    let live = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TimeSink").path
    guard !URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(live) else {
        print("refusing to run on the live database; pass a copy"); exit(65)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-w"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let key = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, !key.isEmpty else { print("no key in keychain item \(service)"); exit(66) }

    let db = try! AppDatabase.open(at: URL(fileURLWithPath: path))
    let categories = CategoryStore(db)
    let settings = SettingsStore(db)
    settings.setJevEnabled(true)
    settings.setJevMonthlyCap(cap)
    let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!

    let worker = JevWorker(categoryStore: categories, settings: settings, apiKey: { key })
    let run = await worker.run(since: since)

    let resolver = CategoryResolver(categoryStore: categories)
    resolver.jevEnabled = true
    let spans = try! SpanStore(db).spans(overlapping: DateInterval(start: since, end: Date())).filter { $0.start >= since }
    var seconds: [String: Double] = [:]
    for item in resolver.categorized(spans) { seconds[item.categoryID, default: 0] += item.span.duration }
    let total = seconds.values.reduce(0, +)
    print("id\tname\thours\t%")
    for (id, s) in seconds.sorted(by: { $0.value > $1.value }) {
        let name = resolver.categoriesByID[id]?.name ?? id
        print(String(format: "%@\t%@\t%.2f\t%.1f", id, name, s / 3600, s / max(total, 1) * 100))
    }
    let low = (try? categories.lowConfidenceVerdicts(in: DateInterval(start: since, end: Date()), below: 0.6)) ?? []
    print(String(format: "total hours %.2f | hours with prob<0.6: %.2f (%d combos)", total / 3600, low.reduce(0) { $0 + $1.seconds } / 3600, low.count))
    print(String(format: "calls %d saved %d failed %d | cost $%.5f | input tokens %d | median latency %.2fs | stopped by cap: %@",
                 run.calls, run.saved, run.failed, run.costUSD, run.inputTokens, run.medianLatency ?? 0, run.stoppedByCap ? "yes" : "no"))
    if let error = run.error { print("last error:", error) }
}
