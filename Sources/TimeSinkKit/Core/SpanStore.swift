import Foundation
import GRDB

public final class SpanStore: Sendable {
    let writer: any DatabaseWriter

    /// The exact SQL `spans(overlapping:)` issues (see its comment for why
    /// there's no `ORDER BY`). Hoisted so the EXPLAIN QUERY PLAN regression
    /// test runs this string instead of a hand-copied paraphrase that could
    /// silently drift from what the query actually does.
    static let overlapSQL = "SELECT * FROM span WHERE start < ? AND end > ?"

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func insert(_ span: Span) throws -> Span {
        var span = span
        try writer.write { db in
            try span.insert(db)
        }
        return span
    }

    public func updateEnd(id: Int64, end: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE span SET end = ? WHERE id = ?", arguments: [end, id])
        }
    }

    public func spans(overlapping interval: DateInterval) throws -> [Span] {
        // No ORDER BY here on purpose: with one present, SQLite prefers
        // span_on_start (it both filters `start < ?` and supplies the
        // ordering for free) over the more selective span_on_end for recent
        // windows, making the `end > ?` index dead weight. Sorting the
        // (small, window-bounded) result in Swift keeps callers' ascending
        // contract while letting the planner pick span_on_end.
        let spans = try writer.read { db in
            try Span.fetchAll(
                db,
                sql: Self.overlapSQL,
                arguments: [interval.end, interval.start]
            )
        }
        return spans.sorted { $0.start < $1.start }
    }
}
