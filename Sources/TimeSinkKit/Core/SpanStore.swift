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

    // MARK: - Cloud sync (migration v8)

    /// A row that lives on another device, as the cloud hands it back.
    public struct RemoteSpan: Sendable {
        public let span: Span
        public let deviceID: String
        public let originID: Int64
        public let seq: String

        public init(span: Span, deviceID: String, originID: Int64, seq: String) {
            self.span = span
            self.deviceID = deviceID
            self.originID = originID
            self.seq = seq
        }
    }

    /// This device's rows the cloud has not acknowledged, oldest first.
    /// `openID` is the engine's current row: its `end` is still moving, so
    /// it goes up once it has closed.
    public func unsynced(excluding openID: Int64?, limit: Int) throws -> [Span] {
        try writer.read { db in
            try Span.fetchAll(
                db,
                sql: "SELECT * FROM span WHERE remoteSeq IS NULL AND deviceID IS NULL AND id != ? ORDER BY id LIMIT ?",
                arguments: [openID ?? -1, limit]
            )
        }
    }

    public func unsyncedCount() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM span WHERE remoteSeq IS NULL AND deviceID IS NULL") ?? 0
        }
    }

    public func markSynced(_ acks: [(id: Int64, seq: String)]) throws {
        try writer.write { db in
            for ack in acks {
                try db.execute(sql: "UPDATE span SET remoteSeq = ? WHERE id = ?", arguments: [ack.seq, ack.id])
            }
        }
    }

    /// Other devices' rows. `span_on_device_origin` drops one already here,
    /// so a re-pull is harmless. Returns how many were new.
    @discardableResult
    public func insertRemote(_ rows: [RemoteSpan]) throws -> Int {
        try writer.write { db in
            var inserted = 0
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO span \
                        (start, end, appBundleID, appName, title, url, domain, document, deviceID, originID, remoteSeq) \
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [row.span.start, row.span.end, row.span.appBundleID, row.span.appName,
                                row.span.title, row.span.url, row.span.domain, row.span.document,
                                row.deviceID, row.originID, row.seq]
                )
                inserted += db.changesCount
            }
            return inserted
        }
    }

    /// Forgets that this device's rows were ever uploaded (account change,
    /// account deletion). Other devices' rows are untouched.
    public func clearSyncState() throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE span SET remoteSeq = NULL WHERE deviceID IS NULL")
            try db.execute(sql: "DELETE FROM syncLog")
        }
    }

    /// This device's rows the cloud has acknowledged, and rows pulled from
    /// other devices.
    public func syncTotals() throws -> (uploaded: Int, downloaded: Int) {
        try writer.read { db in
            let up = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM span WHERE deviceID IS NULL AND remoteSeq IS NOT NULL") ?? 0
            let down = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM span WHERE deviceID IS NOT NULL") ?? 0
            return (up, down)
        }
    }

    // MARK: - Sync history (migration v9)

    public struct SyncHour: Sendable, Equatable {
        public let hour: Date
        public let pushed: Int
        public let pulled: Int
        public let failures: Int
        public let lastError: String?
    }

    public static let syncLogDays = 30

    /// Adds one pass to its local hour. A clean pass that moved nothing
    /// leaves no row: a pass runs every minute and nearly all of them
    /// carry a few rows, so the hour, not the pass, is the unit worth reading.
    public func recordSyncPass(at date: Date, pushed: Int, pulled: Int, error: String?) throws {
        guard pushed > 0 || pulled > 0 || error != nil else { return }
        let hour = Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO syncLog (hour, pushed, pulled, failures, lastError) VALUES (?, ?, ?, ?, ?) \
                    ON CONFLICT(hour) DO UPDATE SET pushed = pushed + excluded.pushed, \
                    pulled = pulled + excluded.pulled, failures = failures + excluded.failures, \
                    lastError = COALESCE(excluded.lastError, lastError)
                    """,
                arguments: [hour, pushed, pulled, error == nil ? 0 : 1, error]
            )
            try db.execute(sql: "DELETE FROM syncLog WHERE hour < ?",
                           arguments: [date.addingTimeInterval(-Double(Self.syncLogDays) * 86_400)])
        }
    }

    /// Newest hour first.
    public func syncLog() throws -> [SyncHour] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM syncLog ORDER BY hour DESC").map {
                SyncHour(hour: $0["hour"], pushed: $0["pushed"], pulled: $0["pulled"],
                         failures: $0["failures"], lastError: $0["lastError"])
            }
        }
    }
}
