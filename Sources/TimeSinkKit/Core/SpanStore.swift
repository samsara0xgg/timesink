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

    // MARK: - Day-bucketed aggregation

    /// One `(day bucket, classification tuple)` total from
    /// `dailyTupleTotals(dayBoundaries:)`: the summed duration of every span
    /// that both starts AND ends inside bucket `dayIndex`, grouped by the
    /// exact four fields `CategoryResolver.categoryID(for:)` reads. A caller
    /// classifies each of these ONCE instead of once per span row.
    public struct DailyTupleTotal: Sendable {
        public let dayIndex: Int
        public let appBundleID: String
        public let title: String?
        public let url: String?
        public let domain: String?
        public let seconds: TimeInterval
    }

    /// Per-bucket, per-tuple duration sum, for spans wholly inside one
    /// bucket. Hoisted for the EXPLAIN QUERY PLAN test, same reason as
    /// `overlapSQL`; the plan matters more here than there, because the whole
    /// point is that `start >= ? AND start < ?` is a span_on_start RANGE scan
    /// touching only that day's rows. The obvious "overlaps this day"
    /// predicate (`start < dayEnd AND end > dayStart`) is NOT a range on
    /// either index -- it degrades to re-scanning the whole tail of the table
    /// once per day, i.e. O(days^2) rows.
    ///
    /// Durations are summed as whole milliseconds, not as float days:
    /// `julianday()` returns a double whose ulp near 2026 is ~40 microseconds,
    /// so summing raw julianday differences would drift by ~0.1s over a busy
    /// day and could flip a pulse that lands on a .5 rounding boundary.
    /// Dates are stored by GRDB with millisecond precision, so the ROUND
    /// recovers the exact stored value and the SUM is integer-exact.
    static let dayTupleTotalsSQL = """
        SELECT appBundleID, title, url, domain, \
        SUM(CAST(ROUND((julianday(end) - julianday(start)) * 86400000) AS INTEGER)) AS ms \
        FROM span \
        WHERE start >= ? AND start < ? AND end <= ? AND end > start \
        GROUP BY appBundleID, title, url, domain
        """

    /// The spans a bucket hands forward: they start inside it but run past
    /// its end, so their duration belongs to two or more buckets. Same
    /// span_on_start range scan as `dayTupleTotalsSQL`, and the complement of
    /// its `end <= ?` term, so between them the two queries see every span
    /// starting in the bucket exactly once.
    static let dayStraddlerSQL = "SELECT * FROM span WHERE start >= ? AND start < ? AND end > ?"

    /// Aggregates `[dayBoundaries[0], dayBoundaries.last]` into one row per
    /// (bucket, classification tuple), plus the raw spans that cross a bucket
    /// boundary.
    ///
    /// `dayBoundaries` must be ascending and contiguous (bucket `i` is
    /// `[dayBoundaries[i], dayBoundaries[i+1])`); the caller computes them
    /// with `Calendar.current` so day bucketing follows LOCAL midnights and
    /// DST-shortened/-lengthened days, which SQLite's UTC `date()` and its
    /// `'localtime'` modifier both get wrong.
    ///
    /// Boundary-crossing spans are returned whole rather than clipped in SQL
    /// on purpose: they are a handful per window (12 out of 43,362 rows on
    /// the one-year fixture), and splitting them in Swift against the same
    /// `dayBoundaries` array keeps that arithmetic identical to the old
    /// `Aggregator.split` path instead of re-deriving it in SQLite.
    ///
    /// All queries run inside ONE read transaction: the tracker writes spans
    /// continuously, and 60+ separate reads could see a span inserted
    /// mid-loop and count it twice (or a span's `end` extended between two
    /// buckets and count it in neither).
    public func dailyTupleTotals(dayBoundaries: [Date]) throws -> (totals: [DailyTupleTotal], straddlers: [Span]) {
        guard dayBoundaries.count >= 2 else { return ([], []) }
        return try writer.read { db in
            var totals: [DailyTupleTotal] = []
            // Spans already open at the window's start -- they start before
            // bucket 0 and so are invisible to every per-bucket query below.
            // Reuses `overlapSQL` (and so its span_on_end plan) with a
            // zero-width interval: "the spans covering this instant".
            var straddlers = try Span.fetchAll(db, sql: Self.overlapSQL,
                                               arguments: [dayBoundaries[0], dayBoundaries[0]])
            for index in 0..<(dayBoundaries.count - 1) {
                let dayStart = dayBoundaries[index]
                let dayEnd = dayBoundaries[index + 1]
                let rows = try Row.fetchAll(db, sql: Self.dayTupleTotalsSQL,
                                            arguments: [dayStart, dayEnd, dayEnd])
                for row in rows {
                    let ms: Int64 = row["ms"]
                    totals.append(DailyTupleTotal(dayIndex: index,
                                                  appBundleID: row["appBundleID"],
                                                  title: row["title"],
                                                  url: row["url"],
                                                  domain: row["domain"],
                                                  seconds: TimeInterval(ms) / 1000))
                }
                straddlers += try Span.fetchAll(db, sql: Self.dayStraddlerSQL,
                                                arguments: [dayStart, dayEnd, dayEnd])
            }
            return (totals, straddlers)
        }
    }
}
