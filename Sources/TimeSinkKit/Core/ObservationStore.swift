import Foundation
import GRDB

/// Persists tracker state reasons and front-window captures (migration v5).
public final class ObservationStore: Sendable {
    let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func logState(_ kind: String, at: Date = Date()) {
        var event = StateEvent(at: at, kind: kind)
        _ = try? writer.write { db in try event.insert(db) }
    }

    @discardableResult
    public func insert(_ capture: Capture) throws -> Capture {
        var capture = capture
        try writer.write { db in try capture.insert(db) }
        return capture
    }

    public func extend(id: Int64, lastSeenAt: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE capture SET lastSeenAt = ? WHERE id = ?", arguments: [lastSeenAt, id])
        }
    }

    /// Forgets image paths older than `cutoff`; rows and text stay.
    public func forgetImage(id: Int64) throws {
        try writer.write { try $0.execute(sql: "UPDATE capture SET imagePath = NULL WHERE id = ?", arguments: [id]) }
    }

    public func forgetImages(before cutoff: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE capture SET imagePath = NULL WHERE at < ? AND imagePath IS NOT NULL",
                           arguments: [cutoff])
        }
    }

    public func captures(overlapping interval: DateInterval) throws -> [Capture] {
        try writer.read { db in
            try Capture.fetchAll(db, sql: "SELECT * FROM capture WHERE at < ? AND lastSeenAt > ? ORDER BY at",
                                 arguments: [interval.end, interval.start])
        }
    }

    public func insert(_ note: AwayNote) throws {
        var note = note
        try writer.write { db in try note.insert(db) }
    }

    public func awayNotes(overlapping interval: DateInterval) throws -> [AwayNote] {
        try writer.read { db in
            try AwayNote.fetchAll(db, sql: "SELECT * FROM awayNote WHERE start < ? AND \"end\" > ? ORDER BY start",
                                  arguments: [interval.end, interval.start])
        }
    }

    public func stateEvents(in interval: DateInterval) throws -> [StateEvent] {
        try writer.read { db in
            try StateEvent.fetchAll(db, sql: "SELECT * FROM stateEvent WHERE at >= ? AND at < ? ORDER BY at",
                                    arguments: [interval.start, interval.end])
        }
    }

    /// One closed health window; a write failure is logged by the caller's
    /// silence, never by dropping ticks.
    public func record(_ health: CaptureHealth) {
        var row = health
        _ = try? writer.write { db in try row.insert(db) }
    }

    public func health(overlapping interval: DateInterval) throws -> [CaptureHealth] {
        try writer.read { db in
            try CaptureHealth.fetchAll(
                db, sql: "SELECT * FROM captureHealth WHERE windowStart < ? AND windowEnd > ? ORDER BY windowStart",
                arguments: [interval.end, interval.start])
        }
    }

    public struct Summary: Equatable, Sendable {
        public let count: Int
        public let latestAt: Date?
    }

    public func summary(since: Date) -> Summary {
        (try? writer.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, MAX(at) AS latest FROM capture WHERE at >= ?",
                                       arguments: [since])
            return Summary(count: row?["n"] ?? 0, latestAt: row?["latest"])
        }) ?? Summary(count: 0, latestAt: nil)
    }
}
