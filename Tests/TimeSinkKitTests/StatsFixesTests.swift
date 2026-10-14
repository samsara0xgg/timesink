import XCTest
import GRDB
@testable import TimeSinkKit

/// Audit round (2026-10-14), the statistics side: what the stores hand the
/// stats (#10 another Mac's time, #12 inverted rows), the daily pulse's
/// classification (#11c), the average and the previous-period cut (#11d),
/// the interruption trend's read (#24) and project detection (#33).
@MainActor
final class StatsFixesTests: XCTestCase {
    private func makeModel() throws -> (AppModel, SpanStore, CategoryStore) {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let settings = SettingsStore(db)
        let model = AppModel(categoryStore: categoryStore, spanStore: spanStore, settings: settings,
                             resolver: CategoryResolver(categoryStore: categoryStore),
                             engine: TrackerEngine(spanStore: spanStore, settings: settings))
        return (model, spanStore, categoryStore)
    }

    private func legacyDailyPulses(_ model: AppModel, days: Int, endingAt: Date) -> [Int?] {
        let lookback = model.rangedSpans(for: DateRangeSelection(kind: .last30, anchor: endingAt))
        return Aggregator.dailyPulses(items: lookback, categories: model.resolver.categoriesByID,
                                      days: days, endingAt: endingAt, calendar: .current)
    }

    // MARK: - #12 inverted rows

    func testTheStoreNeverWritesAnEndBeforeTheStart() throws {
        let store = SpanStore(try AppDatabase.openInMemory())
        let inserted = try store.insert(Span(start: ts(1000), end: ts(990), appBundleID: "a", appName: "A",
                                             title: nil, url: nil, domain: nil))
        XCTAssertEqual(inserted.end, inserted.start)

        let running = try store.insert(Span(start: ts(2000), end: ts(2060), appBundleID: "b", appName: "B",
                                            title: nil, url: nil, domain: nil))
        let runningID = try XCTUnwrap(running.id)
        try store.updateEnd(id: runningID, end: ts(1900))
        let spans = try store.spans(overlapping: DateInterval(start: ts(0), end: ts(5000)))
        let updated = try XCTUnwrap(spans.first(where: { $0.id == runningID }))
        XCTAssertEqual(updated.end, updated.start)
        XCTAssertTrue(spans.allSatisfy { $0.end >= $0.start })
    }

    func testRowsALaterClockLeftInvertedAreIgnored() throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        try store.insert(Span(start: ts(100), end: ts(400), appBundleID: "a", appName: "A", title: nil, url: nil, domain: nil))
        try db.write { db in
            try db.execute(sql: "INSERT INTO span (start, end, appBundleID, appName) VALUES (?, ?, 'x', 'X')",
                           arguments: [ts(300), ts(200)])
        }
        let window = DateInterval(start: ts(0), end: ts(1000))
        let spans = try store.spans(overlapping: window)
        XCTAssertEqual(spans.map(\.appBundleID), ["a"])
        var streamed: [String] = []
        try store.forEachSpan(overlapping: window) { streamed.append($0.appBundleID) }
        XCTAssertEqual(streamed, ["a"])
    }

    // MARK: - #10 this Mac wins

    /// This Mac's row stays whole; another Mac's rows keep only what no row
    /// here covers, and between two other Macs the one whose id sorts first
    /// wins. The whole stretch is counted once: 2.5 hours, not 4.
    func testAnotherMacsTimeKeepsOnlyWhatThisMacDidNotRecord() throws {
        let store = SpanStore(try AppDatabase.openInMemory())
        let base = ts(100_000)
        func span(_ from: Double, _ to: Double, _ app: String) -> Span {
            Span(start: base.addingTimeInterval(from * 60), end: base.addingTimeInterval(to * 60),
                 appBundleID: app, appName: app, title: nil, url: nil, domain: nil)
        }
        try store.insert(span(0, 60, "here"))
        try store.insertRemote([
            SpanStore.RemoteSpan(span: span(30, 120, "b"), deviceID: "B", originID: 1, seq: "1"),
            SpanStore.RemoteSpan(span: span(90, 150, "a"), deviceID: "A", originID: 1, seq: "2"),
            SpanStore.RemoteSpan(span: span(10, 20, "b"), deviceID: "B", originID: 2, seq: "3"),
        ])
        let window = DateInterval(start: base.addingTimeInterval(-3600), end: base.addingTimeInterval(4 * 3600))
        let spans = try store.spans(overlapping: window)
        let pieces: [String] = spans.map { span in
            let from = Int(span.start.timeIntervalSince(base) / 60), to = Int(span.end.timeIntervalSince(base) / 60)
            return "\(span.appBundleID) \(from)-\(to)"
        }
        XCTAssertEqual(pieces, ["here 0-60", "b 60-90", "a 90-150"])
        XCTAssertEqual(Aggregator.totalDuration(spans), 150 * 60)

        var streamed: [Span] = []
        try store.forEachSpan(overlapping: window) { streamed.append($0) }
        XCTAssertEqual(streamed.sorted { $0.start < $1.start }, spans)
    }

    /// The SQL day buckets leave another Mac's rows to the trimmed Swift
    /// path, so the popover's streak still matches the span-by-span path.
    /// The other Mac's Spotify hour under this Mac's Xcode hour is dropped:
    /// (3600 x 100 + 1800 x 0) / 5400 = 67; summed whole it would be 40.
    func testDailyPulsesCountAnotherMacsTimeOnceLikeTheSpanPath() throws {
        let (model, store, _) = try makeModel()
        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        func span(_ from: Double, _ minutes: Double, productive: Bool) -> Span {
            let start = todayStart.addingTimeInterval(from * 60)
            return Span(start: start, end: start.addingTimeInterval(minutes * 60),
                        appBundleID: productive ? "com.apple.dt.Xcode" : "com.spotify.client",
                        appName: productive ? "Xcode" : "Spotify", title: nil, url: nil, domain: nil)
        }
        try store.insert(span(60, 60, productive: true))
        try store.insertRemote([
            SpanStore.RemoteSpan(span: span(60, 60, productive: false), deviceID: "other", originID: 1, seq: "1"),
            SpanStore.RemoteSpan(span: span(120, 30, productive: false), deviceID: "other", originID: 2, seq: "2"),
        ])
        model.dataChanged()

        let new = model.dailyPulses(days: 2, endingAt: now, calendar: .current)
        XCTAssertEqual(new, legacyDailyPulses(model, days: 2, endingAt: now))
        XCTAssertEqual(new.last ?? nil, 67)
    }

    // MARK: - #11c the daily pulse reads the document

    /// A chat app is judged by its conversation: here the user filed this
    /// one under entertainment (0 points). Without `document` the SQL path
    /// classified it as a chat app with nothing open.
    func testDailyPulsesClassifyAChatAppByItsConversation() throws {
        let (model, store, categoryStore) = try makeModel()
        let app = "com.anthropic.claudefordesktop"
        let conversation = "Movie night plans"
        try categoryStore.setUserVerdict(VerdictKey(appBundleID: app, domain: nil, title: "Claude", document: conversation),
                                         categoryID: "entertainment")
        model.resolver.refresh()
        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        try store.insert(Span(start: todayStart.addingTimeInterval(3600), end: todayStart.addingTimeInterval(7200),
                              appBundleID: app, appName: "Claude", title: "Claude", url: nil, domain: nil,
                              document: conversation))
        model.dataChanged()

        let new = model.dailyPulses(days: 1, endingAt: now, calendar: .current)
        XCTAssertEqual(new, legacyDailyPulses(model, days: 1, endingAt: now))
        XCTAssertEqual(new.last ?? nil, 0)
    }

    // MARK: - #11d average and previous-period cut

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// 2026-03-08, 00:00-24:00 in New York, is 23 hours long.
    private func march(_ day: Int, _ hour: Int = 0) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
    }

    func testAverageDividesByFractionalDaysAndADSTDayIsStillOne() {
        // 近 7 天 at noon on its last day: 6.5 days, not 6 or 7.
        XCTAssertEqual(StatsSummary.elapsedDays(from: march(10), to: march(16, 12), calendar: newYork), 6.5, accuracy: 1e-9)
        XCTAssertEqual(StatsSummary.elapsedDays(from: march(2), to: march(9), calendar: newYork), 7, accuracy: 1e-9)
        // Noon on the short day is 11 of its 23 hours in.
        XCTAssertEqual(StatsSummary.elapsedDays(from: march(2), to: march(8, 12), calendar: newYork), 6 + 11.0 / 23, accuracy: 1e-9)
    }

    func testThePreviousPeriodIsCutAtTheSameWallClockTime() {
        // Today is the DST day: 10:00 is nine hours after its midnight, but
        // yesterday is cut at 10:00 too, not at 09:00.
        XCTAssertEqual(StatsSummary.previousCutoff(currentStart: march(8), previousStart: march(7),
                                                   now: march(8, 10), calendar: newYork), march(7, 10))
        // A week holding the DST day against the week before.
        let weekBefore = newYork.date(from: DateComponents(year: 2026, month: 2, day: 23))!
        XCTAssertEqual(StatsSummary.previousCutoff(currentStart: march(2), previousStart: weekBefore,
                                                   now: march(8, 10), calendar: newYork), march(1, 10))
    }

    // MARK: - #24 the interruption trend off the main actor

    /// The worker's one read counts each day as the radar does
    /// (`AppModel.interruptions(for:)`), and the trend shows it.
    func testInterruptionTrendCountsEachDayLikeTheRadar() async throws {
        let (model, store, _) = try makeModel()
        let calendar = Calendar.current
        let today = try XCTUnwrap(calendar.dateInterval(of: .day, for: Date()))
        let yesterday = try XCTUnwrap(calendar.dateInterval(of: .day, for: today.start.addingTimeInterval(-3600)))
        func record(_ day: DateInterval, _ parts: [(seconds: Double, productive: Bool)]) throws {
            var cursor = day.start.addingTimeInterval(10 * 3600)
            for part in parts {
                try store.insert(Span(start: cursor, end: cursor.addingTimeInterval(part.seconds),
                                      appBundleID: part.productive ? "com.apple.dt.Xcode" : "com.spotify.client",
                                      appName: part.productive ? "Xcode" : "Spotify", title: nil, url: nil, domain: nil))
                cursor = cursor.addingTimeInterval(part.seconds)
            }
        }
        try record(yesterday, [(60, true), (30, false), (210, true), (30, false), (60, true)])
        try record(today, [(60, true), (30, false), (60, true)])
        model.dataChanged()

        let counts = try await StatsWorker().interruptionCounts(
            store: store, classification: model.resolver.snapshot(), editVersion: model.dataEditVersion,
            dataVersion: model.dataVersion, days: [yesterday, today],
            productivity: model.resolver.categoriesByID.mapValues(\.productivity),
            distracting: model.resolver.distractingIDs, rule: model.interruptionRule)
        let radarYesterday = await model.interruptions(for: yesterday).interruptions.count
        let radarToday = await model.interruptions(for: today).interruptions.count
        XCTAssertEqual(counts, [radarYesterday, radarToday])
        XCTAssertEqual(counts, [2, 1])

        let stats = StatsModel()
        await stats.loadInterruptionTrend(model: model)
        let trend = try XCTUnwrap(stats.interruptionTrend)
        XCTAssertEqual(trend.count, StatsModel.interruptionTrendDays)
        XCTAssertEqual(trend.suffix(2).map(\.count), [2, 1])
        XCTAssertEqual(trend.last?.day, today.start)
    }

    // MARK: - #33 project detection

    func testAProjectIsAFolderAndNeverAContainerRoot() {
        let home = "/Users/a"
        func folder(_ path: String, isFolder: Bool = false) -> String? {
            EntityParser.projectFolder(path: path, home: home, isFolder: isFolder)
        }
        XCTAssertEqual(folder("/Users/a/Projects/timesink/Sources/x.swift"), "timesink")
        XCTAssertEqual(folder("/Users/a/Projects/timesink"), "timesink")
        XCTAssertEqual(folder("/Users/a/Projects/my.tool", isFolder: true), "my.tool")
        XCTAssertEqual(folder("/Users/a/Documents/Thesis/ch1.tex"), "Thesis")
        // iCloud Drive and the other cloud drives: their own root stands in for home.
        XCTAssertEqual(folder("/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Projects/novel/ch1.md"), "novel")
        XCTAssertNil(folder("/Users/a/Library/Mobile Documents/com~apple~CloudDocs/notes.md"))
        XCTAssertEqual(folder("/Users/a/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/thesis/draft.docx"), "thesis")
        XCTAssertNil(folder("/Users/a/Library/Application Support/Code/User/settings.json"))
        // An external drive: the same, from the drive's root.
        XCTAssertEqual(folder("/Volumes/Work/Projects/site/index.html"), "site")
        XCTAssertNil(folder("/Volumes/Work/Projects"))
        // A file straight inside a container names nothing.
        XCTAssertNil(folder("/Users/a/Desktop/notes.md"))
        XCTAssertNil(folder("/Users/a/Downloads/report.pdf"))
        XCTAssertNil(folder("/Users/a"))
        XCTAssertEqual(folder("/opt/x/y/z"), "y")
    }

    func testProjectKeyOfAnICloudFileAndOfAGitHubCopilotChat() {
        func span(url: String? = nil, domain: String? = nil, document: String? = nil) -> Span {
            Span(start: ts(0), end: ts(60), appBundleID: "a", appName: "a", title: nil, url: url, domain: domain, document: document)
        }
        let home = DocumentIdentity.homePath
        let icloud = "file://\(home)/Library/Mobile%20Documents/com~apple~CloudDocs/Projects/novel/ch1.md"
        XCTAssertEqual(SessionSegmenter.projectKey(span(document: icloud))?.label, "novel")
        XCTAssertNil(SessionSegmenter.projectKey(span(document: "file://\(home)/Desktop/notes.md")))
        XCTAssertNil(SessionSegmenter.projectKey(span(url: "https://github.com/copilot/c/0f3a9", domain: "github.com")))
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/users/octocat/projects/1", domain: "github.com"))
        XCTAssertEqual(SessionSegmenter.projectKey(span(url: "https://github.com/owner/repo", domain: "github.com"))?.key, "repo")
    }
}
