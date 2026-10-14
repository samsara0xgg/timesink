import Foundation
import GRDB

public final class BudgetStore: Sendable {
    let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func budgets() throws -> [Budget] {
        try writer.read { db in
            try Budget.fetchAll(db)
        }
    }

    /// Upserts the daily limit for `categoryID`. A brand-new row is enabled
    /// by default; an existing row's `enabled` flag is left untouched.
    public func setBudget(categoryID: String, dailySeconds: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO budget (categoryID, dailySeconds, enabled)
                VALUES (?, ?, 1)
                ON CONFLICT(categoryID) DO UPDATE SET
                    dailySeconds = excluded.dailySeconds
                """,
                arguments: [categoryID, dailySeconds]
            )
        }
    }

    public func setEnabled(categoryID: String, enabled: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE budget SET enabled = ? WHERE categoryID = ?",
                arguments: [enabled, categoryID]
            )
        }
    }

    /// Deletes the budget row and any budgetAlert rows for `categoryID`, in
    /// one transaction, so a deleted budget can't leave orphaned alert history.
    public func deleteBudget(categoryID: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM budget WHERE categoryID = ?", arguments: [categoryID])
            try db.execute(sql: "DELETE FROM budgetAlert WHERE categoryID = ?", arguments: [categoryID])
        }
    }

    public func alertKinds(categoryID: String, day: String) throws -> Set<String> {
        try writer.read { db in
            let kinds = try String.fetchAll(
                db,
                sql: "SELECT kind FROM budgetAlert WHERE categoryID = ? AND day = ?",
                arguments: [categoryID, day]
            )
            return Set(kinds)
        }
    }

    /// An alert already sent on a day: its kind and the daily limit it went
    /// out under (nil: sent before limits were recorded with it).
    public struct AlertStamp: Equatable, Sendable {
        public let categoryID: String
        public let kind: String
        public let limitSeconds: Int?
    }

    /// Every alert sent on `day`, in one read.
    public func alertStamps(day: String) throws -> [AlertStamp] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT categoryID, kind, limitSeconds FROM budgetAlert WHERE day = ?", arguments: [day])
            return rows.map { (row: Row) -> AlertStamp in
                let categoryID: String = row["categoryID"]
                let kind: String = row["kind"]
                let limitSeconds: Int? = row["limitSeconds"]
                return AlertStamp(categoryID: categoryID, kind: kind, limitSeconds: limitSeconds)
            }
        }
    }

    /// Stamps an alert as sent, under `limitSeconds` (the budget's limit at
    /// the time). Stamping the same kind again on the same day replaces the
    /// limit: a raised limit that fired again.
    public func noteAlert(categoryID: String, day: String, kind: String, limitSeconds: Int? = nil) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO budgetAlert (categoryID, day, kind, limitSeconds) VALUES (?, ?, ?, ?)
                ON CONFLICT(categoryID, day, kind) DO UPDATE SET limitSeconds = excluded.limitSeconds
                """,
                arguments: [categoryID, day, kind, limitSeconds]
            )
        }
    }

    /// `day` strings are all the same "YYYY-MM-DD" local-calendar format, so
    /// lexicographic comparison is chronological comparison.
    public func pruneAlerts(before day: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM budgetAlert WHERE day < ?", arguments: [day])
        }
    }
}
