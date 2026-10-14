import Foundation
import GRDB

public final class SpanStore: Sendable {
    let writer: any DatabaseWriter

    /// The exact SQL `spans(overlapping:)` issues (see its comment for why
    /// there's no `ORDER BY`). Hoisted so the EXPLAIN QUERY PLAN regression
    /// test runs this string instead of a hand-copied paraphrase that could
    /// silently drift from what the query actually does.
    ///
    /// `end >= start` leaves out a row a clock set back left inverted: summed,
    /// it would take time away. `updateEnd` and `insert` no longer write one.
    static let overlapSQL = "SELECT * FROM span WHERE start < ? AND end > ? AND end >= start"

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func insert(_ span: Span) throws -> Span {
        var span = span
        // Never an end before the start: the clock can be set back mid-span.
        span.end = max(span.start, span.end)
        try writer.write { db in
            try span.insert(db)
        }
        return span
    }

    public func updateEnd(id: Int64, end: Date, keySeconds: Int = 0) throws {
        try writer.write { db in
            // Never before the row's own start (a clock set back): dates are
            // stored as fixed-width UTC text, so MAX compares them in time order.
            try db.execute(sql: "UPDATE span SET end = MAX(?, start), keySeconds = ? WHERE id = ?",
                           arguments: [end, keySeconds, id])
        }
    }

    /// The window's spans, ascending by start, with another Mac's rows cut
    /// down to what this Mac did not record (`thisMacWins`).
    public func spans(overlapping interval: DateInterval) throws -> [Span] {
        // No ORDER BY here on purpose: with one present, SQLite prefers
        // span_on_start (it both filters `start < ?` and supplies the
        // ordering for free) over the more selective span_on_end for recent
        // windows, making the `end > ?` index dead weight. Sorting the
        // (small, window-bounded) result in Swift keeps callers' ascending
        // contract while letting the planner pick span_on_end.
        let spans = try writer.read { (db: Database) throws -> [Span] in
            let rows = try Self.fetchByDevice(db, sql: Self.overlapSQL, arguments: [interval.end, interval.start])
            return Self.thisMacWins(local: rows.local, remote: rows.remote)
        }
        return spans.sorted { $0.start < $1.start }
    }

    /// `spans(overlapping:)` one row at a time and in no particular order, for
    /// a caller that keeps only part of each span and so never holds the
    /// titles and addresses of the whole window at once. This Mac's rows go
    /// straight through; another Mac's wait until the window is read, when
    /// what ours cover is known (`thisMacWins`) -- only their rows and our
    /// rows' times are held meanwhile.
    public func forEachSpan(overlapping interval: DateInterval, _ body: (Span) throws -> Void) throws {
        try writer.read { db in
            var covered: [Stretch] = []
            var remote: [DeviceRow] = []
            let cursor = try Row.fetchCursor(db, sql: Self.overlapSQL, arguments: [interval.end, interval.start])
            while let row = try cursor.next() {
                let span = try Span(row: row)
                let deviceID: String? = row["deviceID"]
                if let deviceID {
                    remote.append(DeviceRow(span: span, deviceID: deviceID))
                } else {
                    covered.append((start: span.start, end: span.end))
                    try body(span)
                }
            }
            for piece in Self.trimmed(remote, against: covered) { try body(piece) }
        }
    }

    // MARK: - This Mac wins

    /// A row another Mac recorded, pulled in by sync (`deviceID` non-null,
    /// migration v8).
    struct DeviceRow: Sendable {
        let span: Span
        let deviceID: String
    }

    typealias Stretch = (start: Date, end: Date)

    /// Two Macs on one account both record the hours they are both awake
    /// and in use, and sync puts the other Mac's rows in this table beside
    /// this one's. Summed as they are, a day could hold more than 24 hours.
    /// So every loader that totals time keeps this Mac's rows whole and
    /// another Mac's row only where no row of this Mac covers it; between two
    /// other Macs, the one whose id sorts first wins.
    ///
    /// A trimmed row can come back as several pieces, each a copy of it
    /// (same `id`) with its own `start`/`end` -- the same shape a clipped
    /// span already has; only the first keeps the row's key-seconds. Only
    /// the stretch inside the window read is exact: a row of ours outside
    /// the window is not loaded, so a piece can reach past the window's
    /// edge, where every caller clips anyway.
    static func thisMacWins(local: [Span], remote: [DeviceRow]) -> [Span] {
        guard !remote.isEmpty else { return local }
        let covered: [Stretch] = local.map { (start: $0.start, end: $0.end) }
        return local + trimmed(remote, against: covered)
    }

    /// `remote` without what `local` covers, and each other Mac without what
    /// the Macs before it (by id) kept.
    static func trimmed(_ remote: [DeviceRow], against local: [Stretch]) -> [Span] {
        guard !remote.isEmpty else { return [] }
        var covered = union(local)
        var kept: [Span] = []
        let devices: [String] = Set(remote.map { $0.deviceID }).sorted()
        for device in devices {
            var pieces: [Span] = []
            for row in remote where row.deviceID == device {
                pieces += uncovered(row.span, by: covered)
            }
            let added: [Stretch] = pieces.map { (start: $0.start, end: $0.end) }
            covered = union(covered + added)
            kept += pieces
        }
        return kept
    }

    /// Sorted, disjoint cover of `stretches`.
    private static func union(_ stretches: [Stretch]) -> [Stretch] {
        let sorted = stretches.sorted { (a: Stretch, b: Stretch) -> Bool in a.start < b.start }
        var result: [Stretch] = []
        for stretch in sorted {
            if let last = result.last, stretch.start <= last.end {
                result[result.count - 1].end = max(last.end, stretch.end)
            } else {
                result.append(stretch)
            }
        }
        return result
    }

    /// The parts of `span` outside `covered` (sorted and disjoint).
    private static func uncovered(_ span: Span, by covered: [Stretch]) -> [Span] {
        // The first stretch ending after the span starts: in a disjoint,
        // sorted cover the ends ascend with the starts.
        var low = 0, high = covered.count
        while low < high {
            let mid = (low + high) / 2
            if covered[mid].end <= span.start { low = mid + 1 } else { high = mid }
        }
        var pieces: [Span] = []
        var cursor = span.start
        func keep(until end: Date) {
            var piece = span
            piece.start = cursor
            piece.end = end
            if !pieces.isEmpty { piece.keySeconds = 0 }
            pieces.append(piece)
        }
        var index = low
        while index < covered.count, covered[index].start < span.end {
            if covered[index].start > cursor { keep(until: covered[index].start) }
            cursor = max(cursor, covered[index].end)
            index += 1
        }
        if cursor < span.end { keep(until: span.end) }
        return pieces
    }

    /// The rows `sql` reads, split by where they were recorded.
    private static func fetchByDevice(_ db: Database, sql: String,
                                      arguments: StatementArguments) throws -> (local: [Span], remote: [DeviceRow]) {
        var local: [Span] = []
        var remote: [DeviceRow] = []
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try cursor.next() {
            let span = try Span(row: row)
            let deviceID: String? = row["deviceID"]
            if let deviceID {
                remote.append(DeviceRow(span: span, deviceID: deviceID))
            } else {
                local.append(span)
            }
        }
        return (local, remote)
    }

    /// Other Macs' rows overlapping a window, and this Mac's times there:
    /// what `dailyTupleTotals` needs to trim the former against the latter.
    static let remoteOverlapSQL = "SELECT * FROM span WHERE start < ? AND end > ? AND end >= start AND deviceID IS NOT NULL"
    static let localStretchSQL = "SELECT start, \"end\" FROM span WHERE start < ? AND end > ? AND end >= start AND deviceID IS NULL"

    /// Other Macs' rows overlapping `[start, end)`, trimmed against this
    /// Mac's rows there. Nothing more is read when there are none.
    private static func remotePieces(_ db: Database, from start: Date, to end: Date) throws -> [Span] {
        let remote = try fetchByDevice(db, sql: remoteOverlapSQL, arguments: [end, start]).remote
        guard !remote.isEmpty else { return [] }
        var local: [Stretch] = []
        let cursor = try Row.fetchCursor(db, sql: localStretchSQL, arguments: [end, start])
        while let row = try cursor.next() {
            let from: Date = row[0]
            let to: Date = row[1]
            local.append((start: from, end: to))
        }
        return trimmed(remote, against: local)
    }

    // MARK: - Day-bucketed aggregation

    /// One `(day bucket, classification tuple)` total from
    /// `dailyTupleTotals(dayBoundaries:)`: the summed duration of every span
    /// that both starts AND ends inside bucket `dayIndex`, grouped by the
    /// exact five fields `CategoryResolver.categoryID(for:)` reads. A caller
    /// classifies each of these ONCE instead of once per span row.
    public struct DailyTupleTotal: Sendable {
        public let dayIndex: Int
        public let categoryOverride: String?
        public let appBundleID: String
        public let title: String?
        public let url: String?
        public let domain: String?
        /// Part of the classification tuple too: an AI chat app is judged by
        /// its conversation, and a verdict is keyed by it.
        public let document: String?
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
    ///
    /// This Mac's rows only (`deviceID IS NULL`): another Mac's rows have to
    /// be trimmed against these first (`thisMacWins`), which SQL cannot do
    /// per row cheaply, so they take the Swift path with the straddlers.
    /// `document` is grouped as it is: GROUP BY puts NULLs together.
    static let dayTupleTotalsSQL = """
        SELECT appBundleID, title, url, domain, document, override.categoryID AS categoryOverride, \
        SUM(CAST(ROUND((julianday(end) - julianday(start)) * 86400000) AS INTEGER)) AS ms \
        FROM span LEFT JOIN spanCategoryOverride AS override ON override.spanID = span.id \
        WHERE start >= ? AND start < ? AND end <= ? AND end > start AND deviceID IS NULL \
        GROUP BY appBundleID, title, url, domain, document, override.categoryID
        """

    /// The spans a bucket hands forward: they start inside it but run past
    /// its end, so their duration belongs to two or more buckets. Same
    /// span_on_start range scan as `dayTupleTotalsSQL`, and the complement of
    /// its `end <= ?` term, so between them the two queries see every span
    /// starting in the bucket exactly once. This Mac's rows only, like it.
    static let dayStraddlerSQL = "SELECT * FROM span WHERE start >= ? AND start < ? AND end > ? AND deviceID IS NULL"

    /// Aggregates `[dayBoundaries[0], dayBoundaries.last]` into one row per
    /// (bucket, classification tuple), plus the raw spans that cross a bucket
    /// boundary and other Macs' rows trimmed to what this Mac did not record
    /// (`thisMacWins`; there are none unless sync is on).
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
            // zero-width interval: "the spans covering this instant". Other
            // Macs' rows come in below, trimmed.
            var straddlers = try Self.fetchByDevice(db, sql: Self.overlapSQL,
                                                    arguments: [dayBoundaries[0], dayBoundaries[0]]).local
            for index in 0..<(dayBoundaries.count - 1) {
                let dayStart = dayBoundaries[index]
                let dayEnd = dayBoundaries[index + 1]
                let rows = try Row.fetchAll(db, sql: Self.dayTupleTotalsSQL,
                                            arguments: [dayStart, dayEnd, dayEnd])
                for row in rows {
                    let ms: Int64 = row["ms"]
                    totals.append(DailyTupleTotal(dayIndex: index,
                                                  categoryOverride: row["categoryOverride"],
                                                  appBundleID: row["appBundleID"],
                                                  title: row["title"],
                                                  url: row["url"],
                                                  domain: row["domain"],
                                                  document: row["document"],
                                                  seconds: TimeInterval(ms) / 1000))
                }
                straddlers += try Span.fetchAll(db, sql: Self.dayStraddlerSQL,
                                                arguments: [dayStart, dayEnd, dayEnd])
            }
            straddlers += try Self.remotePieces(db, from: dayBoundaries[0], to: dayBoundaries[dayBoundaries.count - 1])
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

    /// Other devices' rows. `span_on_device_origin` matches one already
    /// here: a re-pull of the same content is a no-op, and a row its Mac
    /// changed since (an idle tail trimmed after upload) is updated in
    /// place. Returns how many were new or changed.
    @discardableResult
    public func insertRemote(_ rows: [RemoteSpan]) throws -> Int {
        try writer.write { db in
            var inserted = 0
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO span \
                        (start, end, appBundleID, appName, title, url, domain, document, deviceID, originID, remoteSeq) \
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
                        ON CONFLICT(deviceID, originID) WHERE deviceID IS NOT NULL DO UPDATE SET \
                        start = excluded.start, "end" = excluded."end", title = excluded.title, url = excluded.url, \
                        domain = excluded.domain, document = excluded.document, remoteSeq = excluded.remoteSeq \
                        WHERE span.start IS NOT excluded.start OR span."end" IS NOT excluded."end" \
                        OR span.title IS NOT excluded.title OR span.url IS NOT excluded.url \
                        OR span.domain IS NOT excluded.domain OR span.document IS NOT excluded.document
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
        }
    }
}
