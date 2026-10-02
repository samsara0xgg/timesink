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

    public var key: VerdictKey { VerdictKey(appBundleID: appBundleID, domain: domain, title: title, document: document) }
    public var isUser: Bool { source == "user" }
}

/// What the classifier keeps per automatic verdict.
public struct JevVerdictEntry: Equatable, Sendable {
    public var categoryID: String
    public var prob: Double
}

/// A distinct window content that has no usable verdict yet, with what the
/// request needs.
struct JevCombo: Sendable {
    let key: VerdictKey
    let appName: String
    let url: String
    let seconds: Double
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
                INSERT INTO jevVerdict (appBundleID, domain, title, document, categoryID, prob, runnerUp, runnerUpProb, promptVersion, at, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'jev')
                ON CONFLICT(appBundleID, domain, title, document) DO UPDATE SET
                    categoryID = excluded.categoryID, prob = excluded.prob, runnerUp = excluded.runnerUp,
                    runnerUpProb = excluded.runnerUpProb, promptVersion = excluded.promptVersion, at = excluded.at
                WHERE jevVerdict.source = 'jev'
                """, arguments: [v.appBundleID, v.domain, v.title, v.document, v.categoryID, v.prob, v.runnerUp,
                                 v.runnerUpProb, v.promptVersion, v.at])
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

    /// Window contents seen since `since` that Jev has no current answer for,
    /// longest first: none for a user verdict, one made under the current
    /// prompt, or one a local hard rule decides without it.
    func pendingCombos(since: Date, promptVersion: String) throws -> [JevCombo] {
        try writer.read { db in
            let current = Set(try Row.fetchAll(db, sql: "SELECT appBundleID, domain, title, document, promptVersion, source FROM jevVerdict").compactMap { row -> VerdictKey? in
                let source: String = row["source"], version: String = row["promptVersion"]
                guard source == "user" || version == promptVersion else { return nil }
                return VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])
            })
            let rows = try Row.fetchAll(db, sql: """
                SELECT appBundleID, MAX(appName) AS appName, COALESCE(domain, '') AS domain, COALESCE(title, '') AS title,
                       COALESCE(document, '') AS document, MAX(COALESCE(url, '')) AS url,
                       SUM(julianday("end") - julianday(start)) * 86400 AS seconds
                FROM span WHERE "end" > ? GROUP BY appBundleID, COALESCE(domain, ''), COALESCE(title, ''), COALESCE(document, '')
                ORDER BY seconds DESC
                """, arguments: [since])
            return rows.compactMap { row in
                let key = VerdictKey(appBundleID: row["appBundleID"], domain: row["domain"], title: row["title"], document: row["document"])
                let url: String = row["url"]
                guard !current.contains(key),
                      // Without the url: a span's own url varies inside one combo, so a hit that only the
                      // url gives would leave the other spans of it with no verdict.
                      JevRules.match(appBundleID: key.appBundleID, domain: key.domain, url: nil, title: key.title, document: key.document) == nil
                else { return nil }
                return JevCombo(key: key, appName: row["appName"], url: url, seconds: row["seconds"])
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
