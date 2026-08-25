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

    public func noteAlert(categoryID: String, day: String, kind: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO budgetAlert (categoryID, day, kind) VALUES (?, ?, ?)
                ON CONFLICT(categoryID, day, kind) DO NOTHING
                """,
                arguments: [categoryID, day, kind]
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
