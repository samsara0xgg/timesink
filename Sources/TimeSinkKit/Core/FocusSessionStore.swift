import Foundation
import GRDB

public final class FocusSessionStore: Sendable {
    let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Starts (and immediately persists) a focus session. `end` == `start`
    /// at creation and is advanced by `heartbeat` as the session runs.
    @discardableResult
    public func start(at date: Date, plannedSeconds: Int) throws -> FocusSession {
        var session = FocusSession(start: date, end: date, plannedSeconds: plannedSeconds)
        try writer.write { db in
            try session.insert(db)
        }
        return session
    }

    public func updatePlannedSeconds(id: Int64, seconds: Int) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE focusSession SET plannedSeconds = ? WHERE id = ?", arguments: [seconds, id])
        }
    }

    /// Advances `end`, and the block counts when given, so a session the
    /// app never got to finish (a crash, a forced quit) keeps what it blocked.
    public func heartbeat(id: Int64, end: Date, appBlocks: Int? = nil, siteBlocks: Int? = nil) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE focusSession SET end = ?, appBlocks = COALESCE(?, appBlocks), \
                    siteBlocks = COALESCE(?, siteBlocks) WHERE id = ?
                    """,
                arguments: [end, appBlocks, siteBlocks, id]
            )
        }
    }

    public func finish(id: Int64, end: Date, appBlocks: Int, siteBlocks: Int, completed: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE focusSession SET end = ?, appBlocks = ?, siteBlocks = ?, completed = ? WHERE id = ?",
                arguments: [end, appBlocks, siteBlocks, completed, id]
            )
        }
    }

    public func sessions(overlapping interval: DateInterval) throws -> [FocusSession] {
        try writer.read { db in
            try FocusSession.fetchAll(
                db,
                sql: "SELECT * FROM focusSession WHERE start < ? AND end > ? ORDER BY start",
                arguments: [interval.end, interval.start]
            )
        }
    }

    public func session(id: Int64) throws -> FocusSession? {
        try writer.read { db in try FocusSession.fetchOne(db, key: id) }
    }

    /// When the first focus session started, to know how far back the history goes.
    public func earliestStart() throws -> Date? {
        try writer.read { db in try Date.fetchOne(db, sql: "SELECT MIN(start) FROM focusSession") }
    }
}
