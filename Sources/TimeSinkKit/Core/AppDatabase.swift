import Foundation
import GRDB

public enum AppDatabase {
    /// Opens (creating if needed) a WAL-mode database pool at `url` and runs migrations.
    public static func open(at url: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: url.path)
        try migrator.migrate(pool)
        return pool
    }

    /// Opens an in-memory database queue and runs migrations. Useful for tests.
    public static func openInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return queue
    }

    /// "timesink.sqlite" only when running as the installed bundle;
    /// bare-executable runs (`swift run`, no bundle identifier) get
    /// "timesink-dev.sqlite" so dev sessions can never pollute real data
    /// even if the single-instance guard is bypassed.
    public static func databaseFileName(bundleIdentifier: String?) -> String {
        bundleIdentifier == "com.alllllenshi.TimeSink" ? "timesink.sqlite" : "timesink-dev.sqlite"
    }

    /// Creates `~/Library/Application Support/TimeSink/` if needed and returns the
    /// path to `timesink.sqlite` (or `timesink-dev.sqlite`, see `databaseFileName`)
    /// inside it.
    public static func defaultURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("TimeSink", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(databaseFileName(bundleIdentifier: Bundle.main.bundleIdentifier))
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "span") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("start", .datetime).notNull().indexed()
                t.column("end", .datetime).notNull()
                t.column("appBundleID", .text).notNull().indexed()
                t.column("appName", .text).notNull()
                t.column("title", .text)
                t.column("url", .text)
                t.column("domain", .text).indexed()
            }

            try db.create(table: "category") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("productivity", .integer).notNull()
                t.column("sortOrder", .integer).notNull()
            }

            try db.create(table: "domainCategory") { t in
                t.column("domain", .text).primaryKey()
                t.column("categoryID", .text).notNull().references("category")
                t.column("source", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "urlRule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pattern", .text).notNull()
                t.column("categoryID", .text).notNull().references("category")
                t.column("priority", .integer).notNull()
                t.column("source", .text).notNull()
            }

            try db.create(table: "appCategory") { t in
                t.column("bundleID", .text).primaryKey()
                t.column("categoryID", .text).notNull().references("category")
                t.column("source", .text).notNull()
            }

            try db.create(table: "setting") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }

            // Seed the fixed taxonomy of 12 categories.
            for category in Taxonomy.categories {
                try category.insert(db)
            }

            // Seed builtin app -> category defaults.
            for app in Taxonomy.builtinApps {
                try db.execute(
                    sql: "INSERT INTO appCategory (bundleID, categoryID, source) VALUES (?, ?, 'builtin')",
                    arguments: [app.bundleID, app.categoryID]
                )
            }

            // Seed builtin URL rules.
            for rule in Taxonomy.builtinURLRules {
                try db.execute(
                    sql: "INSERT INTO urlRule (pattern, categoryID, priority, source) VALUES (?, ?, ?, 'builtin')",
                    arguments: [rule.pattern, rule.categoryID, rule.priority]
                )
            }
        }

        migrator.registerMigration("v2") { db in
            // Social media and communication hosts not covered by v1's
            // builtinURLRules; see Taxonomy.v2URLRules for why these are needed.
            for rule in Taxonomy.v2URLRules {
                try db.execute(
                    sql: "INSERT INTO urlRule (pattern, categoryID, priority, source) VALUES (?, ?, ?, 'builtin')",
                    arguments: [rule.pattern, rule.categoryID, rule.priority]
                )
            }
        }

        migrator.registerMigration("v3") { db in
            // Every stats refresh runs `start < ? AND end > ?`; with only the
            // `start` index a window ending at "now" matches every historical row,
            // so the query is O(total history). `end > ?` is the selective
            // predicate for recent windows. appBundleID/domain were indexed in v1
            // but no query ever filters on them (all grouping happens in memory).
            // SQLite only picks this index once SpanStore.spans(overlapping:) drops
            // its ORDER BY start ASC -- with that clause present the planner keeps
            // using span_on_start for the free ordering, ignoring span_on_end
            // entirely (verified via EXPLAIN QUERY PLAN; see DatabaseTests).
            try db.execute(sql: "CREATE INDEX span_on_end ON span(\"end\")")
            try db.execute(sql: "DROP INDEX IF EXISTS span_on_appBundleID")
            try db.execute(sql: "DROP INDEX IF EXISTS span_on_domain")
        }

        return migrator
    }
}
