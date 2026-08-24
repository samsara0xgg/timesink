import Foundation
import GRDB

public final class SpanStore: Sendable {
    let writer: any DatabaseWriter

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
        try writer.read { db in
            try Span.fetchAll(
                db,
                sql: "SELECT * FROM span WHERE start < ? AND end > ? ORDER BY start ASC",
                arguments: [interval.end, interval.start]
            )
        }
    }
}
