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

    public func heartbeat(id: Int64, end: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE focusSession SET end = ? WHERE id = ?", arguments: [end, id])
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
                sql: "SELECT * FROM focusSession WHERE start < ? AND end > ?",
                arguments: [interval.end, interval.start]
            )
        }
    }

    /// When the first focus session started, to know how far back the history goes.
    public func earliestStart() throws -> Date? {
        try writer.read { db in try Date.fetchOne(db, sql: "SELECT MIN(start) FROM focusSession") }
    }
}
