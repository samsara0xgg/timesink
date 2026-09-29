import Foundation
import GRDB

public final class CategoryStore: Sendable {
    let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// The database keeps a built-in category's seed (Chinese) name. It is
    /// swapped for the app's language on the way out and back on the way in,
    /// so a name the user never edited follows the language, one they did
    /// edit is left alone, and saving a colour change never stores a
    /// translation.
    public func allCategories() throws -> [Category] {
        try writer.read { db in
            try Category.fetchAll(db, sql: "SELECT * FROM category ORDER BY sortOrder ASC")
        }.map { c in
            var c = c
            if c.name == Taxonomy.seedName(c.id), let local = Taxonomy.localizedName(c.id) { c.name = local }
            return c
        }
    }

    public func updateCategory(_ c: Category) throws {
        var c = c
        if c.name == Taxonomy.localizedName(c.id), let seed = Taxonomy.seedName(c.id) { c.name = seed }
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

    /// Imports the curated overlay. Overwrites seed-, curated-, and
    /// llm-sourced rows, but never a user row: an explicit human correction
    /// must never be clobbered by shipped data, whereas an llm row is just an
    /// opportunistic machine guess that the declared classification priority
    /// already ranks below curated -- leaving it in place would make the
    /// curated tier unreachable for exactly the domains it targets (llm rows
    /// only exist for domains the deterministic chain, including curated,
    /// left uncategorized).
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
                    WHERE domainCategory.source IN ('seed', 'curated', 'llm')
                    """,
                    arguments: [pair.domain, pair.categoryID, now]
                )
            }
        }
    }

    /// All titleRule rows, including disabled -- the settings page needs the
    /// full set to render toggles.
    public func titleRules() throws -> [TitleRule] {
        try writer.read { db in
            try TitleRule.fetchAll(db)
        }
    }

    /// Upserts a user override for (pattern, scopeKey). Unlike
    /// `addUserURLRule`, this must not bare-INSERT: re-saving the same rule
    /// with a different category has to replace the row, not duplicate it.
    ///
    /// If (pattern, scopeKey) collides with an existing *builtin* row, this
    /// is a silent no-op: builtin rows can only ever be disabled via
    /// `setTitleRuleEnabled`, never deleted or reassigned, so a user upsert
    /// must not be able to flip one to source='user' (which would make it
    /// deletable) or silently re-enable a builtin the user had disabled.
    /// There is no re-seed path for a collided builtin row. Callers (the
    /// rules UI) are expected to pre-check for a builtin collision and
    /// message the user instead of relying on this to surface an error.
    /// A new rule ranks above every earlier user rule in its scope ("新规则优
    /// 先"), the same as one saved from the inspector.
    public func upsertUserTitleRule(pattern: String, scopeKey: String, categoryID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO titleRule (pattern, scopeKey, categoryID, priority, source, enabled, createdAt)
                VALUES (?, ?, ?, COALESCE((SELECT MAX(priority) FROM titleRule WHERE source = 'user' AND scopeKey = ?), 0) + 100, 'user', 1, ?)
                ON CONFLICT(pattern, scopeKey) DO UPDATE SET
                    categoryID = excluded.categoryID,
                    source = 'user',
                    enabled = 1
                WHERE titleRule.source = 'user'
                """,
                arguments: [pattern, scopeKey, categoryID, scopeKey, Date()]
            )
        }
    }

    /// Deletes a titleRule row. Callers are responsible for only deleting
    /// user-sourced rows (builtin rows are not meant to be removable here).
    public func deleteTitleRule(id: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM titleRule WHERE id = ?", arguments: [id])
        }
    }

    public func setTitleRuleEnabled(id: Int64, enabled: Bool) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE titleRule SET enabled = ? WHERE id = ?", arguments: [enabled, id])
        }
    }
}
