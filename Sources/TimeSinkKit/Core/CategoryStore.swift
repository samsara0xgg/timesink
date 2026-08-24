import Foundation
import GRDB

public final class CategoryStore: Sendable {
    let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func allCategories() throws -> [Category] {
        try writer.read { db in
            try Category.fetchAll(db, sql: "SELECT * FROM category ORDER BY sortOrder ASC")
        }
    }

    public func updateCategory(_ c: Category) throws {
        try writer.write { db in
            try c.update(db)
        }
    }

    public func domainMap() throws -> [String: DomainEntry] {
        try writer.read { db in
            let rows = try DomainCategoryRow.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0.domain, DomainEntry(categoryID: $0.categoryID, source: $0.source))
            })
        }
    }

    public func appMap() throws -> [String: DomainEntry] {
        try writer.read { db in
            let rows = try AppCategoryRow.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0.bundleID, DomainEntry(categoryID: $0.categoryID, source: $0.source))
            })
        }
    }

    public func urlRules() throws -> [URLRule] {
        try writer.read { db in
            try URLRule.fetchAll(db)
        }
    }

    /// Upserts a user override for `domain`. Always overwrites any existing row.
    public func setUserDomain(_ domain: String, categoryID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO domainCategory (domain, categoryID, source, updatedAt)
                VALUES (?, ?, 'user', ?)
                ON CONFLICT(domain) DO UPDATE SET
                    categoryID = excluded.categoryID,
                    source = excluded.source,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [domain, categoryID, Date()]
            )
        }
    }

    /// Upserts a user override for `bundleID`. Always overwrites any existing row.
    public func setUserApp(_ bundleID: String, categoryID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO appCategory (bundleID, categoryID, source)
                VALUES (?, ?, 'user')
                ON CONFLICT(bundleID) DO UPDATE SET
                    categoryID = excluded.categoryID,
                    source = excluded.source
                """,
                arguments: [bundleID, categoryID]
            )
        }
    }

    public func addUserURLRule(pattern: String, categoryID: String, priority: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO urlRule (pattern, categoryID, priority, source) VALUES (?, ?, ?, 'user')",
                arguments: [pattern, categoryID, priority]
            )
        }
    }

    public func deleteURLRule(id: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM urlRule WHERE id = ?", arguments: [id])
        }
    }

    /// Inserts an LLM-derived domain classification. Never overwrites an existing row.
    public func insertLLMDomain(_ domain: String, categoryID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO domainCategory (domain, categoryID, source, updatedAt)
                VALUES (?, ?, 'llm', ?)
                ON CONFLICT(domain) DO NOTHING
                """,
                arguments: [domain, categoryID, Date()]
            )
        }
    }

    /// Imports seed domain classifications. Never overwrites an existing row.
    public func importSeedDomains(_ pairs: [(domain: String, categoryID: String)]) throws {
        try writer.write { db in
            let now = Date()
            for pair in pairs {
                try db.execute(
                    sql: """
                    INSERT INTO domainCategory (domain, categoryID, source, updatedAt)
                    VALUES (?, ?, 'seed', ?)
                    ON CONFLICT(domain) DO NOTHING
                    """,
                    arguments: [pair.domain, pair.categoryID, now]
                )
            }
        }
    }

    /// Imports the curated overlay. Overwrites seed-sourced rows (the overlay
    /// exists to correct them) and its own previous rows, but never a user or
    /// llm row.
    public func importCuratedDomains(_ pairs: [(domain: String, categoryID: String)]) throws {
        try writer.write { db in
            let now = Date()
            for pair in pairs {
                try db.execute(
                    sql: """
                    INSERT INTO domainCategory (domain, categoryID, source, updatedAt)
                    VALUES (?, ?, 'curated', ?)
                    ON CONFLICT(domain) DO UPDATE SET
                        categoryID = excluded.categoryID,
                        source = 'curated',
                        updatedAt = excluded.updatedAt
                    WHERE domainCategory.source IN ('seed', 'curated')
                    """,
                    arguments: [pair.domain, pair.categoryID, now]
                )
            }
        }
    }
}
