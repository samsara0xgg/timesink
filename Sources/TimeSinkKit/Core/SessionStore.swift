import Foundation
import GRDB

/// F1 会话: what you named sessions, where you split them, and the names
/// already worked out (migration v13).
public struct SessionNameRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sessionName"
    public var signature: String
    public var name: String?
    public var project: String?
    public var updatedAt: Date
}

public struct SessionLabel: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sessionLabel"
    public enum Source: String, Codable, Sendable { case model, title, none }
    public var key: String
    /// Nil when the guess was too unsure: the session shows its apps instead.
    public var name: String?
    public var project: String?
    public var confidence: Double
    public var source: Source
    public var createdAt: Date

    public init(key: String, name: String?, project: String?, confidence: Double, source: Source, createdAt: Date = Date()) {
        self.key = key
        self.name = name
        self.project = project
        self.confidence = confidence
        self.source = source
        self.createdAt = createdAt
    }
}

extension ObservationStore {
    public func sessionNames() throws -> [String: SessionNameRow] {
        try writer.read { db in
            Dictionary(try SessionNameRow.fetchAll(db).map { ($0.signature, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// `nil` keeps the stored value; an empty string clears it.
    public func setSessionName(signature: String, name: String? = nil, project: String? = nil) throws {
        try writer.write { db in
            var row = try SessionNameRow.fetchOne(db, key: signature)
                ?? SessionNameRow(signature: signature, name: nil, project: nil, updatedAt: Date())
            if let name { row.name = name.isEmpty ? nil : name }
            if let project { row.project = project.isEmpty ? nil : project }
            row.updatedAt = Date()
            if row.name == nil && row.project == nil { try row.delete(db) } else { try row.save(db) }
        }
    }

    public func sessionSplits(in interval: DateInterval) throws -> [Date] {
        try writer.read { db in
            try Date.fetchAll(db, sql: "SELECT at FROM sessionSplit WHERE at >= ? AND at < ? ORDER BY at",
                              arguments: [interval.start, interval.end])
        }
    }

    public func addSessionSplit(at date: Date) throws {
        try writer.write { db in try db.execute(sql: "INSERT OR IGNORE INTO sessionSplit (at) VALUES (?)", arguments: [date]) }
    }

    public func sessionJoins(in interval: DateInterval) throws -> [Date] {
        try writer.read { db in
            try Date.fetchAll(db, sql: "SELECT at FROM sessionJoin WHERE at >= ? AND at < ? ORDER BY at",
                              arguments: [interval.start, interval.end])
        }
    }

    /// Joins the session starting at `date` onto the one before it. A hand-made
    /// split at the same moment goes, so the two do not fight.
    public func addSessionJoin(at date: Date) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sessionSplit WHERE at = ?", arguments: [date])
            try db.execute(sql: "INSERT OR IGNORE INTO sessionJoin (at) VALUES (?)", arguments: [date])
        }
    }

    public func removeSessionJoin(at date: Date) throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM sessionJoin WHERE at = ?", arguments: [date]) }
    }

    public func sessionLabel(key: String) throws -> SessionLabel? {
        try writer.read { db in try SessionLabel.fetchOne(db, key: key) }
    }

    public func save(_ label: SessionLabel) throws {
        try writer.write { db in try label.save(db) }
    }
}
