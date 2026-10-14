import Foundation
import GRDB

/// The four span fields a verdict is about. A missing value and an empty one
/// are the same thing here, as they are in the table.
public struct VerdictKey: Hashable, Sendable {
    public let appBundleID: String
    public let domain: String
    public let title: String
    public let document: String

    public init(appBundleID: String, domain: String?, title: String?, document: String?) {
        self.appBundleID = appBundleID
        self.domain = domain ?? ""
        self.title = title ?? ""
        self.document = document ?? ""
    }

    public init(_ span: Span) {
        self.init(appBundleID: span.appBundleID, domain: span.domain, title: span.title, document: span.document)
    }
}

/// A row of `jevVerdict`. `source == "user"` is a correction or confirmation
/// by the user; it is never re-asked and wins over everything automatic.
/// `source == "seed"` is an example only: resolution ignores it.
public struct JevVerdict: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "jevVerdict"
    public var appBundleID: String
    public var domain: String
    public var title: String
    public var document: String
    public var categoryID: String
    public var prob: Double
    public var runnerUp: String
    public var runnerUpProb: Double
    public var promptVersion: String
    public var at: Date
    public var source: String
    /// 0: not asked with screen text, 1: this verdict used it, 2: asked again (examples, with or without screen text), the screen text was not used.
    public var screenText: Int = 0
    /// The model id that gave an automatic verdict.
    public var model: String = ""
    public var key: VerdictKey { VerdictKey(appBundleID: appBundleID, domain: domain, title: title, document: document) }
    public var isUser: Bool { source == "user" }
    /// Written by hand from outside; only ever an example for Jev, never a verdict.
    public var isSeed: Bool { source == "seed" }
}

/// What the classifier keeps per automatic verdict.
public struct JevVerdictEntry: Equatable, Sendable {
    public var categoryID: String
    public var prob: Double
    /// The verdict was made from screenshot text.
    public var usedScreenText = false
}

/// Where the first 200 characters of a screen's text, the key of a per-screen
/// verdict, end. Counted in Unicode scalars, as SQLite's substr counts.
func captureKey(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.prefix(200))) }

/// A bare-title AI-app screen waiting for its verdict.
struct JevCapture: Sendable {
    let key: String
    let text: String
    let appName: String
    let bundleID: String
    let title: String
}

/// A distinct window content that has no usable verdict yet, with what the
/// request needs.
struct JevCombo: Sendable {
    let key: VerdictKey
    let appName: String
    let url: String
    let seconds: Double
    /// The category is settled (a rule, the user's, or Jev's under the current prompt):
    /// only the project is wanted.
    var projectOnly = false
}

/// Which project a window content belongs to, as Jev answered.
public struct ProjectVerdict: Equatable, Sendable {
    public var projectID: String
    public var prob: Double
}

/// A verdict Jev was unsure about, with the time it covers.
public struct LowConfidenceVerdict: Identifiable, Equatable, Sendable {
    public var key: VerdictKey
    public var appName: String
    public var categoryID: String
    public var prob: Double
    public var runnerUp: String
    public var runnerUpProb: Double
    public var seconds: TimeInterval
    public var id: VerdictKey { key }
}

/// Which question a `jevAttempt` row is about: its `kind` ("category",
/// "project" or "capture") and `key`, the question's fields in a stable
/// encoding.
public struct JevAttemptKey: Hashable, Sendable {
    public let kind: String
    public let key: String

    public static func category(_ key: VerdictKey) -> JevAttemptKey { JevAttemptKey(kind: "category", key: encode(key)) }
    public static func project(_ key: VerdictKey) -> JevAttemptKey { JevAttemptKey(kind: "project", key: encode(key)) }
    /// `textKey`: `captureKey(_:)` of the screen's text.
    public static func capture(_ textKey: String) -> JevAttemptKey { JevAttemptKey(kind: "capture", key: textKey) }

    /// The four fields joined by the unit separator, which no title or name contains.
    static func encode(_ key: VerdictKey) -> String {
        [key.appBundleID, key.domain, key.title, key.document].joined(separator: "\u{1F}")
    }
}

/// How often one question came back with nothing usable (a category that
/// was not offered, a reply that did not parse, a timeout), and when it was
/// last asked. Such a question waits longer after each try instead of being
/// asked on every run, and is no longer asked after `maxAttempts`.
struct JevAttempt: Equatable, Sendable {
    var attempts: Int
    var lastTried: Date

    static let maxAttempts = 6
    /// 3 minutes, doubled per attempt, at most a day.
    static let baseDelay: TimeInterval = 180
    static let maxDelay: TimeInterval = 86_400

    /// When the question may be asked again; nil once it has failed `maxAttempts` times.
    static func nextTry(attempts: Int, lastTried: Date) -> Date? {
        guard attempts < maxAttempts else { return nil }
        let delay = min(baseDelay * Double(1 << min(max(attempts, 0), 30)), maxDelay)
        return lastTried.addingTimeInterval(delay)
    }

    /// True for a question never tried and failed, or whose wait is over.
    static func isDue(_ attempt: JevAttempt?, now: Date) -> Bool {
        guard let attempt else { return true }
        guard let next = nextTry(attempts: attempt.attempts, lastTried: attempt.lastTried) else { return false }
        return now >= next
    }
}

extension CategoryStore {
    func verdicts() throws -> [JevVerdict] {
        try writer.read { try JevVerdict.fetchAll($0) }
    }

    /// Writes a Jev answer, but never over a user's own.
    func saveVerdict(_ v: JevVerdict) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO jevVerdict (appBundleID, domain, title, document, categoryID, prob, runnerUp, runnerUpProb, promptVersion, at, source, screenText, model)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'jev', ?, ?)
                ON CONFLICT(appBundleID, domain, title, document) DO UPDATE SET
                    categoryID = excluded.categoryID, prob = excluded.prob, runnerUp = excluded.runnerUp,
                    runnerUpProb = excluded.runnerUpProb, promptVersion = excluded.promptVersion, at = excluded.at,
                    screenText = excluded.screenText, model = excluded.model
                WHERE jevVerdict.source = 'jev'
                """, arguments: [v.appBundleID, v.domain, v.title, v.document, v.categoryID, v.prob, v.runnerUp,
                                 v.runnerUpProb, v.promptVersion, v.at, v.screenText, v.model])
            try Self.clearAttempt(.category(v.key), db)
        }
    }

    /// Writes the project a window content belongs to (`ProjectVerdict.none`-style 'none' included).
    func saveProjectVerdict(_ key: VerdictKey, projectID: String, prob: Double, runnerUp: String, promptVersion: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO jevProjectVerdict (appBundleID, domain, title, document, projectID, prob, runnerUp, promptVersion, at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [key.appBundleID, key.domain, key.title, key.document, projectID, prob, runnerUp, promptVersion, Date()])
            try Self.clearAttempt(.project(key), db)
        }
    }

    /// Every window content that has a project answer, 'none' included: a window with no entry has not been judged.
    func projectVerdicts() throws -> [VerdictKey: ProjectVerdict] {
        try writer.read { db in
            var out: [VerdictKey: ProjectVerdict] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT appBundleID, domain, title, document, projectID, prob FROM jevProjectVerdict") {
                out[VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])] =
                    ProjectVerdict(projectID: row["projectID"], prob: row["prob"])
            }
            return out
        }
    }

    /// Chat, music and feed apps and sites that are never a project; decided here, without a model call.
    static let neverProjectCategories: Set<String> = ["entertainment", "socialMedia", "news"]
    static let neverProjectApps: Set<String> = [
        "com.tencent.xinWeChat", "com.apple.MobileSMS", "com.apple.Music", "com.apple.TV", "com.tencent.qq", "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp", "com.hnc.Discord", "com.spotify.client",
    ]

    /// Window contents seen on this Mac since `since` that have no project answer for `version`, the longest first: `ask`
    /// for the model, `none` for the ones that are never a project (a chat app, an entertainment or feed
    /// category by app, site or verdict). `excluding`: contents the category request already carries the question for.
    func pendingProjectCombos(since: Date, version: String, excluding: Set<VerdictKey> = []) throws -> (ask: [JevCombo], none: [VerdictKey]) {
        try writer.read { db in
            let done = Set(try Row.fetchAll(db, sql: "SELECT appBundleID, domain, title, document FROM jevProjectVerdict WHERE promptVersion = ?", arguments: [version]).map {
                VerdictKey(appBundleID: $0["appBundleID"], domain: $0["domain"], title: $0["title"], document: $0["document"])
            })
            let byApp = Dictionary(try Row.fetchAll(db, sql: "SELECT bundleID, categoryID FROM appCategory").map { ($0["bundleID"] as String, $0["categoryID"] as String) },
                                   uniquingKeysWith: { a, _ in a })
            let byDomain = Dictionary(try Row.fetchAll(db, sql: "SELECT domain, categoryID FROM domainCategory").map { ($0["domain"] as String, $0["categoryID"] as String) },
                                      uniquingKeysWith: { a, _ in a })
            let decided = Dictionary(try Row.fetchAll(db, sql: "SELECT appBundleID, domain, title, document, categoryID FROM jevVerdict WHERE source <> 'seed'").map {
                (VerdictKey(appBundleID: $0["appBundleID"], domain: $0["domain"], title: $0["title"], document: $0["document"]), $0["categoryID"] as String)
            }, uniquingKeysWith: { a, _ in a })
            let rows = try Row.fetchAll(db, sql: """
                SELECT appBundleID, MAX(appName) AS appName, COALESCE(domain, '') AS domain, COALESCE(title, '') AS title,
                       COALESCE(document, '') AS document, MAX(COALESCE(url, '')) AS url,
                       SUM(julianday("end") - julianday(start)) * 86400 AS seconds
                FROM span WHERE "end" > ? AND deviceID IS NULL
                GROUP BY appBundleID, COALESCE(domain, ''), COALESCE(title, ''), COALESCE(document, '')
                ORDER BY seconds DESC
                """, arguments: [since])
            var ask: [JevCombo] = [], none: [VerdictKey] = []
            for row in rows {
                let key = VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])
                guard !done.contains(key), !excluding.contains(key) else { continue }
                let category = decided[key] ?? byDomain[key.domain] ?? byApp[key.appBundleID]
                if Self.neverProjectApps.contains(key.appBundleID) || category.map(Self.neverProjectCategories.contains) == true {
                    none.append(key)
                } else {
                    ask.append(JevCombo(key: key, appName: row["appName"], url: row["url"], seconds: row["seconds"], projectOnly: true))
                }
            }
            return (ask, none)
        }
    }

    // MARK: - Unusable answers

    /// Every question that came back unusable and has not been answered since.
    func jevAttempts() throws -> [JevAttemptKey: JevAttempt] {
        try writer.read { db in
            var out: [JevAttemptKey: JevAttempt] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT kind, key, attempts, lastTried FROM jevAttempt") {
                out[JevAttemptKey(kind: row["kind"], key: row["key"])] = JevAttempt(attempts: row["attempts"], lastTried: row["lastTried"])
            }
            return out
        }
    }

    /// Counts one more unusable answer (or timeout) for `key`, tried at `date`.
    func recordJevAttempt(_ key: JevAttemptKey, at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO jevAttempt (kind, key, attempts, lastTried) VALUES (?, ?, 1, ?)
                ON CONFLICT(kind, key) DO UPDATE SET attempts = jevAttempt.attempts + 1, lastTried = excluded.lastTried
                """, arguments: [key.kind, key.key, date])
        }
    }

    /// An answer was saved: the question no longer waits.
    static func clearAttempt(_ key: JevAttemptKey, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM jevAttempt WHERE kind = ? AND key = ?", arguments: [key.kind, key.key])
    }

    /// A re-ask with screen text that did not beat the verdict: keep it, do not ask again.
    func markScreenAsked(_ key: VerdictKey) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE jevVerdict SET screenText = 2 WHERE appBundleID = ? AND domain = ? AND title = ? AND document = ? AND source = 'jev'",
                           arguments: [key.appBundleID, key.domain, key.title, key.document])
        }
    }

    /// Jev verdicts of the current prompt under `threshold` that were never asked
    /// again and were seen on this Mac, each with the latest capture text (over 40
    /// characters, if any) of one of its spans. Lowest probability first.
    func lowConfidenceRetries(since: Date, promptVersion: String, below threshold: Double) throws -> [(verdict: JevVerdict, appName: String, url: String, text: String?)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT v.*, s.appName AS spanApp, COALESCE(s.url, '') AS spanURL, c.text AS captureText, MAX(c.at) AS latest
                FROM jevVerdict v
                JOIN span s ON s.appBundleID = v.appBundleID AND COALESCE(s.domain, '') = v.domain
                           AND COALESCE(s.title, '') = v.title AND COALESCE(s.document, '') = v.document
                LEFT JOIN capture c ON c.spanID = s.id AND length(c.text) > 40
                WHERE v.source = 'jev' AND v.prob < ? AND v.screenText = 0 AND v.promptVersion = ?
                  AND s."end" > ? AND s.deviceID IS NULL
                GROUP BY v.appBundleID, v.domain, v.title, v.document
                ORDER BY v.prob
                """, arguments: [threshold, promptVersion, since]).map { row in
                (try JevVerdict(row: row), row["spanApp"], row["spanURL"], row["captureText"])
            }
        }
    }

    /// What the user has settled, most recent first: their verdicts, the seed rows, then
    /// their own title, url, domain and app rules, named by category display name.
    func jevExamples() throws -> [JevExample] {
        try writer.read { db in
            let names = Dictionary(uniqueKeysWithValues: try Category.fetchAll(db).map { ($0.id, $0.name) })
            let apps = Dictionary(try Row.fetchAll(db, sql: "SELECT appBundleID, MAX(appName) AS n FROM span GROUP BY appBundleID").map { ($0["appBundleID"] as String, $0["n"] as String) },
                                  uniquingKeysWith: { a, _ in a })
            var dated: [(Date, JevExample)] = []
            func add(_ at: Date, bundle: String = "", domain: String = "", title: String = "", document: String = "", category: String) {
                guard let name = names[category] else { return }
                dated.append((at, JevExample(bundleID: bundle, app: apps[bundle] ?? bundle, domain: domain, title: String(title.prefix(80)),
                                             document: String(document.prefix(60)), category: name)))
            }
            for v in try JevVerdict.fetchAll(db, sql: "SELECT * FROM jevVerdict WHERE source IN ('user', 'seed') ORDER BY at DESC") {
                add(v.at, bundle: v.appBundleID, domain: v.domain, title: v.title, document: v.document, category: v.categoryID)
            }
            for r in try TitleRule.fetchAll(db) where r.source == "user" && r.enabled { add(r.createdAt, title: r.pattern, category: r.categoryID) }
            for r in try URLRule.fetchAll(db).sorted(by: { $0.pattern < $1.pattern }) where r.source == "user" { add(.distantPast, title: r.pattern, category: r.categoryID) }
            for r in try DomainCategoryRow.fetchAll(db).sorted(by: { $0.domain < $1.domain }) where r.source == "user" { add(.distantPast, domain: r.domain, category: r.categoryID) }
            for r in try AppCategoryRow.fetchAll(db).sorted(by: { $0.bundleID < $1.bundleID }) where r.source == "user" { add(.distantPast, bundle: r.bundleID, category: r.categoryID) }
            // Stable among equal dates, so a run with the same data sends the same examples.
            return dated.enumerated().sorted { ($0.element.0, $1.offset) > ($1.element.0, $0.offset) }.map(\.element.1)
        }
    }

    // MARK: - Per-screen verdicts (bare-title AI apps)

    func saveCaptureVerdict(key: String, categoryID: String, prob: Double, runnerUp: String, runnerUpProb: Double, promptVersion: String, model: String = "") throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO jevCaptureVerdict (textKey, categoryID, prob, runnerUp, runnerUpProb, promptVersion, at, model)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [key, categoryID, prob, runnerUp, runnerUpProb, promptVersion, Date(), model])
            try Self.clearAttempt(.capture(key), db)
        }
    }

    /// Screens of bare-title AI-app spans seen since `since` that have no
    /// verdict of the current prompt, one per distinct text key, newest first.
    /// A screen never asked is wanted if seen since `since`; one with an answer from an
    /// older prompt only if seen since `staleSince`.
    func pendingCaptures(since: Date, staleSince: Date? = nil, promptVersion: String) throws -> [JevCapture] {
        let staleSince = min(staleSince ?? since, since)
        return try writer.read { db in
            let versions = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT textKey, promptVersion FROM jevCaptureVerdict").map { ($0["textKey"] as String, $0["promptVersion"] as String) })
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.text AS text, c.appName AS appName, s.appBundleID AS bundleID, COALESCE(s.title, '') AS title, s."end" AS spanEnd,
                       COALESCE(s.document, '') AS document, COALESCE(s.domain, '') AS domain
                FROM capture c JOIN span s ON s.id = c.spanID
                WHERE s."end" > ? AND s.deviceID IS NULL AND length(c.text) > 40 ORDER BY c.at DESC
                """, arguments: [staleSince])
            var seen = Set<String>()
            return rows.compactMap { row in
                let text: String = row["text"], key = captureKey(text)
                guard JevRules.match(appBundleID: row["bundleID"], domain: row["domain"], url: nil, title: row["title"], document: row["document"])?.reason == .assistantIdle,
                      versions[key] != promptVersion, versions[key] != nil || (row["spanEnd"] as Date) > since,
                      seen.insert(key).inserted else { return nil }
                return JevCapture(key: key, text: text, appName: row["appName"], bundleID: row["bundleID"], title: row["title"])
            }
        }
    }

    /// Per-screen verdicts and capture attempts are keyed by a screen's first 200
    /// characters, so they hold OCR text. Once a capture is forgotten
    /// (`ObservationStore.forgetCaptures`), its text goes from here too: drops every
    /// capture verdict and capture attempt whose key no capture row still has.
    /// Returns how many rows went.
    @discardableResult
    public func forgetOrphanedCaptureVerdicts() throws -> Int {
        try writer.write { db -> Int in try Self.forgetOrphanedCaptureVerdicts(db) }
    }

    /// The same inside the caller's own write, e.g. right after deleting captures.
    @discardableResult
    public static func forgetOrphanedCaptureVerdicts(_ db: Database) throws -> Int {
        try db.execute(sql: "DELETE FROM jevCaptureVerdict WHERE textKey NOT IN (SELECT substr(text, 1, 200) FROM capture)")
        var gone = db.changesCount
        try db.execute(sql: "DELETE FROM jevAttempt WHERE kind = 'capture' AND key NOT IN (SELECT substr(text, 1, 200) FROM capture)")
        gone += db.changesCount
        return gone
    }

    /// Per span, the verdict of its latest capture since `since` that has one. Bounded by
    /// `capture.at` (indexed) so it reads the recent captures, not every screen ever read.
    func captureVerdictsBySpan(since: Date) throws -> [Int64: JevVerdictEntry] {
        try writer.read { db in
            var out: [Int64: JevVerdictEntry] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT c.spanID AS spanID, v.categoryID AS categoryID, v.prob AS prob
                FROM capture c JOIN jevCaptureVerdict v ON v.textKey = substr(c.text, 1, 200)
                WHERE c.at > ? AND c.spanID IS NOT NULL ORDER BY c.at
                """, arguments: [since]) {
                out[row["spanID"]] = JevVerdictEntry(categoryID: row["categoryID"], prob: row["prob"], usedScreenText: true)
            }
            return out
        }
    }

    /// The user's say on one window content: confirms Jev's category or
    /// changes it. Wins over Jev and over the local hard rules.
    public func setUserVerdict(_ key: VerdictKey, categoryID: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO jevVerdict (appBundleID, domain, title, document, categoryID, prob, runnerUp, runnerUpProb, promptVersion, at, source)
                VALUES (?, ?, ?, ?, ?, 1, '', 0, '', ?, 'user')
                ON CONFLICT(appBundleID, domain, title, document) DO UPDATE SET
                    categoryID = excluded.categoryID, prob = 1, runnerUp = '', runnerUpProb = 0,
                    promptVersion = '', at = excluded.at, source = 'user'
                """, arguments: [key.appBundleID, key.domain, key.title, key.document, categoryID, Date()])
            try Self.clearAttempt(.category(key), db)
        }
        NotificationCenter.default.post(name: .userRecategorized, object: nil)
    }

    /// Takes back a user verdict; Jev is asked again on its next run.
    public func removeUserVerdict(_ key: VerdictKey) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM jevVerdict WHERE appBundleID = ? AND domain = ? AND title = ? AND document = ? AND source = 'user'",
                           arguments: [key.appBundleID, key.domain, key.title, key.document])
        }
    }

    /// Window contents seen on this Mac that Jev has no current answer for: none for a
    /// user verdict, a seed row, one made under the current prompt, one a local hard rule
    /// decides without it, or (with `userRules`) one the user's own title, site, URL or
    /// app rule decides. A combo never asked is wanted if seen since `since`, longest
    /// first; one that has an answer from an older prompt only if seen since
    /// `staleSince` (older ones keep their stored answer), after all the never-asked
    /// ones, most recently seen first.
    func pendingCombos(since: Date, staleSince: Date? = nil, promptVersion: String,
                       userRules: ClassificationContext? = nil) throws -> [JevCombo] {
        let staleSince = min(staleSince ?? since, since)
        return try writer.read { db in
            let all = try Row.fetchAll(db, sql: "SELECT appBundleID, domain, title, document, promptVersion, source FROM jevVerdict")
            let answered = Set(all.map { VerdictKey(appBundleID: $0["appBundleID"], domain: $0["domain"], title: $0["title"], document: $0["document"]) })
            let current = Set(all.compactMap { row -> VerdictKey? in
                let source: String = row["source"], version: String = row["promptVersion"]
                guard source != "jev" || version == promptVersion else { return nil }
                return VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])
            })
            let rows = try Row.fetchAll(db, sql: """
                SELECT appBundleID, MAX(appName) AS appName, COALESCE(domain, '') AS domain, COALESCE(title, '') AS title,
                       COALESCE(document, '') AS document, MAX(COALESCE(url, '')) AS url, COUNT(DISTINCT COALESCE(url, '')) AS urls,
                       SUM(julianday("end") - julianday(start)) * 86400 AS seconds, MAX("end") AS lastEnd
                FROM span WHERE "end" > ? AND deviceID IS NULL
                GROUP BY appBundleID, COALESCE(domain, ''), COALESCE(title, ''), COALESCE(document, '')
                ORDER BY seconds DESC
                """, arguments: [staleSince])
            var fresh: [JevCombo] = []
            var stale: [(combo: JevCombo, lastEnd: Date)] = []
            for row in rows {
                let key = VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])
                let url: String = row["url"]
                let lastEnd: Date = row["lastEnd"]
                guard !current.contains(key), answered.contains(key) || lastEnd > since,
                      // Without the url: a span's own url varies inside one combo, so a hit that only the
                      // url gives would leave the other spans of it with no verdict.
                      JevRules.match(appBundleID: key.appBundleID, domain: key.domain, url: nil, title: key.title, document: key.document) == nil
                else { continue }
                if let userRules {
                    // The url only when every span of the combo has that same one, for the same reason.
                    let urlCount: Int = row["urls"]
                    let decided = Classifier.userRuleCategory(
                        appBundleID: key.appBundleID, url: urlCount == 1 && !url.isEmpty ? url : nil,
                        domain: key.domain.isEmpty ? nil : key.domain, title: key.title.isEmpty ? nil : key.title, context: userRules)
                    if decided != nil { continue }
                }
                let combo = JevCombo(key: key, appName: row["appName"], url: url, seconds: row["seconds"])
                if answered.contains(key) { stale.append((combo, lastEnd)) } else { fresh.append(combo) }
            }
            // A category edit makes every old answer stale at once; what was never answered is asked first.
            stale.sort { (a: (combo: JevCombo, lastEnd: Date), b: (combo: JevCombo, lastEnd: Date)) -> Bool in a.lastEnd > b.lastEnd }
            return fresh + stale.map { $0.combo }
        }
    }

    /// Jev verdicts under `threshold` that cover time in `range`, most hours
    /// first. User verdicts never appear: they are settled.
    public func lowConfidenceVerdicts(in range: DateInterval, below threshold: Double = 0.6) throws -> [LowConfidenceVerdict] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT v.appBundleID, v.domain, v.title, v.document, v.categoryID, v.prob, v.runnerUp, v.runnerUpProb,
                       MAX(s.appName) AS appName,
                       SUM((julianday(MIN(s."end", ?)) - julianday(MAX(s.start, ?))) * 86400) AS seconds
                FROM span s JOIN jevVerdict v
                  ON v.appBundleID = s.appBundleID AND v.domain = COALESCE(s.domain, '')
                 AND v.title = COALESCE(s.title, '') AND v.document = COALESCE(s.document, '')
                WHERE v.source = 'jev' AND v.prob < ? AND s."end" > ? AND s.start < ?
                GROUP BY v.appBundleID, v.domain, v.title, v.document
                ORDER BY seconds DESC
                """, arguments: [range.end, range.start, threshold, range.start, range.end]).map { row in
                LowConfidenceVerdict(
                    key: VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"]),
                    appName: row["appName"], categoryID: row["categoryID"], prob: row["prob"],
                    runnerUp: row["runnerUp"], runnerUpProb: row["runnerUpProb"], seconds: row["seconds"])
            }
        }
    }
}
