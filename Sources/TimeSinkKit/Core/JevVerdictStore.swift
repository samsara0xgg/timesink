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
    /// Which project the window belongs to: '' not asked, 'none' asked and in
    /// no project, else a `UserProject.id`. Jev fills it even on a row whose
    /// category is the user's own.
    public var projectID: String = ""
    public var projectProb: Double = 0
    public var projectRunnerUp: String = ""
    /// The `JevPrompt.projectVersion` it was asked under; '' when not asked.
    public var projectPromptVersion: String = ""

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
    /// The category is settled (the user's, or Jev's under the current prompt):
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

extension CategoryStore {
    func verdicts() throws -> [JevVerdict] {
        try writer.read { try JevVerdict.fetchAll($0) }
    }

    /// Writes a Jev answer, but never over a user's own.
    func saveVerdict(_ v: JevVerdict) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO jevVerdict (appBundleID, domain, title, document, categoryID, prob, runnerUp, runnerUpProb, promptVersion, at, source, screenText, model,
                                        projectID, projectProb, projectRunnerUp, projectPromptVersion)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'jev', ?, ?, ?, ?, ?, ?)
                ON CONFLICT(appBundleID, domain, title, document) DO UPDATE SET
                    categoryID = excluded.categoryID, prob = excluded.prob, runnerUp = excluded.runnerUp,
                    runnerUpProb = excluded.runnerUpProb, promptVersion = excluded.promptVersion, at = excluded.at,
                    screenText = excluded.screenText, model = excluded.model,
                    -- A request without the project question leaves the project answer as it was.
                    projectID = CASE WHEN excluded.projectPromptVersion <> '' THEN excluded.projectID ELSE jevVerdict.projectID END,
                    projectProb = CASE WHEN excluded.projectPromptVersion <> '' THEN excluded.projectProb ELSE jevVerdict.projectProb END,
                    projectRunnerUp = CASE WHEN excluded.projectPromptVersion <> '' THEN excluded.projectRunnerUp ELSE jevVerdict.projectRunnerUp END,
                    projectPromptVersion = CASE WHEN excluded.projectPromptVersion <> '' THEN excluded.projectPromptVersion ELSE jevVerdict.projectPromptVersion END
                WHERE jevVerdict.source = 'jev'
                """, arguments: [v.appBundleID, v.domain, v.title, v.document, v.categoryID, v.prob, v.runnerUp,
                                 v.runnerUpProb, v.promptVersion, v.at, v.screenText, v.model,
                                 v.projectID, v.projectProb, v.projectRunnerUp, v.projectPromptVersion])
        }
    }

    /// Writes Jev's project answer on a row that already has its category
    /// (the user's own included). Seed rows are examples only and get none.
    func saveProjectVerdict(_ key: VerdictKey, projectID: String, prob: Double, runnerUp: String, promptVersion: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE jevVerdict SET projectID = ?, projectProb = ?, projectRunnerUp = ?, projectPromptVersion = ?
                WHERE appBundleID = ? AND domain = ? AND title = ? AND document = ? AND source <> 'seed'
                """, arguments: [projectID, prob, runnerUp, promptVersion, key.appBundleID, key.domain, key.title, key.document])
        }
    }

    /// The project Jev named for each window content, ignoring '' (not asked)
    /// and 'none'. User rows count: the person chose their category, not their project.
    func projectVerdicts() throws -> [VerdictKey: ProjectVerdict] {
        try writer.read { db in
            var out: [VerdictKey: ProjectVerdict] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT appBundleID, domain, title, document, projectID, projectProb FROM jevVerdict WHERE projectID NOT IN ('', 'none') AND source <> 'seed'") {
                out[VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])] =
                    ProjectVerdict(projectID: row["projectID"], prob: row["projectProb"])
            }
            return out
        }
    }

    /// A re-ask with screen text that did not beat the verdict: keep it, do not ask again.
    func markScreenAsked(_ key: VerdictKey) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE jevVerdict SET screenText = 2 WHERE appBundleID = ? AND domain = ? AND title = ? AND document = ? AND source = 'jev'",
                           arguments: [key.appBundleID, key.domain, key.title, key.document])
        }
    }

    /// Jev verdicts of the current prompt under `threshold` that were never asked
    /// again, each with the latest capture text (over 40 characters, if any) of one
    /// of its spans. Lowest probability first.
    func lowConfidenceRetries(since: Date, promptVersion: String, below threshold: Double) throws -> [(verdict: JevVerdict, appName: String, url: String, text: String?)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT v.*, s.appName AS spanApp, COALESCE(s.url, '') AS spanURL, c.text AS captureText, MAX(c.at) AS latest
                FROM jevVerdict v
                JOIN span s ON s.appBundleID = v.appBundleID AND COALESCE(s.domain, '') = v.domain
                           AND COALESCE(s.title, '') = v.title AND COALESCE(s.document, '') = v.document
                LEFT JOIN capture c ON c.spanID = s.id AND length(c.text) > 40
                WHERE v.source = 'jev' AND v.prob < ? AND v.screenText = 0 AND v.promptVersion = ?
                  AND s."end" > ?
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
                WHERE s."end" > ? AND length(c.text) > 40 ORDER BY c.at DESC
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

    /// Per span, the verdict of its latest capture that has one.
    func captureVerdictsBySpan() throws -> [Int64: JevVerdictEntry] {
        try writer.read { db in
            var out: [Int64: JevVerdictEntry] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT c.spanID AS spanID, v.categoryID AS categoryID, v.prob AS prob
                FROM capture c JOIN jevCaptureVerdict v ON v.textKey = substr(c.text, 1, 200)
                WHERE c.spanID IS NOT NULL ORDER BY c.at
                """) {
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
        }
    }

    /// Takes back a user verdict; Jev is asked again on its next run.
    public func removeUserVerdict(_ key: VerdictKey) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM jevVerdict WHERE appBundleID = ? AND domain = ? AND title = ? AND document = ? AND source = 'user'",
                           arguments: [key.appBundleID, key.domain, key.title, key.document])
        }
    }

    /// Window contents Jev has no current answer for, longest first: none for a user
    /// verdict, a seed row, one made under the current prompt, or one a local hard rule
    /// decides without it. A combo never asked is wanted if seen since `since`; one that
    /// has an answer from an older prompt only if seen since `staleSince` (older ones
    /// keep their stored answer).
    ///
    /// With `projectVersion` (projects exist), a combo whose category is settled is also
    /// wanted when its project answer is from another version and it was seen since
    /// `projectSince`; such a combo is `projectOnly`. Seed rows never get one.
    func pendingCombos(since: Date, staleSince: Date? = nil, promptVersion: String,
                       projectVersion: String? = nil, projectSince: Date? = nil) throws -> [JevCombo] {
        let staleSince = min(staleSince ?? since, since)
        return try writer.read { db in
            let all = try Row.fetchAll(db, sql: "SELECT appBundleID, domain, title, document, promptVersion, source, projectPromptVersion FROM jevVerdict")
            let answered = Set(all.map { VerdictKey(appBundleID: $0["appBundleID"], domain: $0["domain"], title: $0["title"], document: $0["document"]) })
            let projectSettled = Set(all.compactMap { row -> VerdictKey? in
                let source: String = row["source"], version: String = row["projectPromptVersion"]
                guard source == "seed" || version == projectVersion else { return nil }
                return VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])
            })
            let current = Set(all.compactMap { row -> VerdictKey? in
                let source: String = row["source"], version: String = row["promptVersion"]
                guard source != "jev" || version == promptVersion else { return nil }
                return VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])
            })
            let rows = try Row.fetchAll(db, sql: """
                SELECT appBundleID, MAX(appName) AS appName, COALESCE(domain, '') AS domain, COALESCE(title, '') AS title,
                       COALESCE(document, '') AS document, MAX(COALESCE(url, '')) AS url,
                       SUM(julianday("end") - julianday(start)) * 86400 AS seconds, MAX("end") AS lastEnd
                FROM span WHERE "end" > ? GROUP BY appBundleID, COALESCE(domain, ''), COALESCE(title, ''), COALESCE(document, '')
                ORDER BY seconds DESC
                """, arguments: [staleSince])
            return rows.compactMap { row -> JevCombo? in
                let key = VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])
                let url: String = row["url"]
                let lastEnd: Date = row["lastEnd"]
                // Without the url: a span's own url varies inside one combo, so a hit that only the
                // url gives would leave the other spans of it with no verdict.
                guard JevRules.match(appBundleID: key.appBundleID, domain: key.domain, url: nil, title: key.title, document: key.document) == nil
                else { return nil }
                if !current.contains(key), answered.contains(key) || lastEnd > since {
                    return JevCombo(key: key, appName: row["appName"], url: url, seconds: row["seconds"])
                }
                guard projectVersion != nil, current.contains(key), !projectSettled.contains(key), lastEnd > (projectSince ?? since)
                else { return nil }
                return JevCombo(key: key, appName: row["appName"], url: url, seconds: row["seconds"], projectOnly: true)
            }
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
