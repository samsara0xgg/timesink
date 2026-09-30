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

        migrator.registerMigration("v4") { db in
            try db.create(table: "titleRule") { t in
                t.autoIncrementedPrimaryKey("id")
                // NOCASE: title matching is case-insensitive (大小写不敏感子串命中),
                // so the (pattern, scopeKey) uniqueKey below must dedupe
                // case-insensitively too, or upsertUserTitleRule's ON CONFLICT
                // silently stops firing for patterns differing only in ASCII
                // case. CJK has no case, so Chinese keywords are unaffected.
                t.column("pattern", .text).notNull().collate(.nocase)
                t.column("scopeKey", .text).notNull().defaults(to: "")
                t.column("categoryID", .text).notNull().references("category")
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("source", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["pattern", "scopeKey"])
            }
            try db.create(table: "budget") { t in
                t.column("categoryID", .text).primaryKey().references("category")
                t.column("dailySeconds", .integer).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "budgetAlert") { t in
                t.column("categoryID", .text).notNull()
                t.column("day", .text).notNull()       // 本地日历 "YYYY-MM-DD"，绝不用 UTC Date
                t.column("kind", .text).notNull()      // "warn" | "limit"
                t.primaryKey(["categoryID", "day", "kind"])
            }
            try db.create(table: "focusSession") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("start", .datetime).notNull().indexed()
                t.column("end", .datetime).notNull()
                t.column("plannedSeconds", .integer).notNull()
                t.column("appBlocks", .integer).notNull().defaults(to: 0)
                t.column("siteBlocks", .integer).notNull().defaults(to: 0)
                t.column("completed", .boolean).notNull().defaults(to: false)
            }
            for rule in Taxonomy.builtinTitleRules {
                try db.execute(
                    sql: "INSERT INTO titleRule (pattern, scopeKey, categoryID, priority, source, enabled, createdAt) VALUES (?, '', ?, 0, 'builtin', 1, ?)",
                    arguments: [rule.pattern, rule.categoryID, Date()]
                )
            }
        }

        migrator.registerMigration("v5") { db in
            // Why the tracker stopped or resumed (idle/lock/sleep/pause/
            // start/stop) -- so an empty stretch of spans is explainable.
            try db.create(table: "stateEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .datetime).notNull().indexed()
                t.column("kind", .text).notNull()
            }
            // One row per distinct front-window content; `lastSeenAt` is
            // extended while a re-check finds the content unchanged.
            try db.create(table: "capture") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .datetime).notNull().indexed()
                t.column("lastSeenAt", .datetime).notNull()
                t.column("appBundleID", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("windowID", .integer).notNull()
                t.column("title", .text)
                t.column("spanID", .integer)
                t.column("text", .text).notNull()
                t.column("imagePath", .text)
            }
        }

        migrator.registerMigration("v6") { db in
            // Screen collector health, one row per bounded window: checks
            // and how each ended, so a gap in captures has a stated reason.
            try db.create(table: "captureHealth") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("windowStart", .datetime).notNull().indexed()
                t.column("windowEnd", .datetime).notNull()
                for name in ["checks", "unchanged", "textSame", "inserted", "extended", "ocrRuns",
                             "ocrFailed", "screenshotFailed", "notFront", "permissionDenied", "skippedBusy"] {
                    t.column(name, .integer).notNull().defaults(to: 0)
                }
            }
        }

        migrator.registerMigration("v7") { db in
            // What the front window is on: a terminal's working directory,
            // an editor's file, an AI chat app's conversation name. A new
            // column rather than a reuse of `title`/`url` on purpose --
            // those two are read by name by another process (Jarvis), so
            // changing what they mean would break it silently.
            try db.alter(table: "span") { t in t.add(column: "document", .text) }

            // `builtinApps` is only ever seeded by v1, and SeedImporter's
            // version gate covers the domain CSVs, not appCategory -- so an
            // existing database never sees a later addition to that list
            // unless a migration inserts it. OR IGNORE keeps any row the
            // user has since set for the same bundle ID.
            for app in Taxonomy.v7Apps {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO appCategory (bundleID, categoryID, source) VALUES (?, ?, 'builtin')",
                    arguments: [app.bundleID, app.categoryID]
                )
            }
        }

        migrator.registerMigration("v8") { db in
            // Cloud sync (docs/superpowers/specs/2026-09-22-timesink-cloud-design.md
            // §4). This device's own rows keep deviceID/originID NULL -- their
            // identity is `id`; rows pulled from another device carry that
            // device's id and row number. remoteSeq is the server's sequence
            // once a row is acknowledged, NULL while it still has to go up.
            // `Span`'s Codable shape is untouched: `SELECT *` ignores the
            // extra columns and `insert` leaves them NULL, so the other
            // reader of this table (Jarvis) sees no change.
            try db.alter(table: "span") { t in
                t.add(column: "deviceID", .text)
                t.add(column: "originID", .integer)
                t.add(column: "remoteSeq", .text)
            }
            // A re-pull of a row already here is a no-op, not a duplicate.
            try db.execute(sql: """
                CREATE UNIQUE INDEX span_on_device_origin ON span(deviceID, originID) \
                WHERE deviceID IS NOT NULL
                """)
            // "What still has to go up" without a scan of the whole history.
            try db.execute(sql: """
                CREATE INDEX span_unsynced ON span(id) \
                WHERE remoteSeq IS NULL AND deviceID IS NULL
                """)
        }

        migrator.registerMigration("v9") { db in
            try db.create(table: "spanCategoryOverride") { t in
                t.column("spanID", .integer).primaryKey().references("span", onDelete: .cascade)
                t.column("categoryID", .text).notNull().references("category")
            }
        }

        migrator.registerMigration("v10") { db in
            try db.create(table: "classificationSuggestion") { t in
                t.column("key", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("categoryID", .text).notNull().references("category")
                t.column("source", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["key", "kind"])
            }
            try db.create(table: "disabledClassificationRule") { t in t.column("ruleKey", .text).primaryKey() }
        }

        // The distributed 0.2.1 app already used the generic identifier v9
        // for another feature. A named, additive migration repairs upgrades
        // from that branch and preserves databases that have these tables.
        migrator.registerMigration("refined_20260928_classification_support") { db in
            try db.create(table: "spanCategoryOverride", options: .ifNotExists) { t in
                t.column("spanID", .integer).primaryKey().references("span", onDelete: .cascade)
                t.column("categoryID", .text).notNull().references("category")
            }
            try db.create(table: "classificationSuggestion", options: .ifNotExists) { t in
                t.column("key", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("categoryID", .text).notNull().references("category")
                t.column("source", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["key", "kind"])
            }
            try db.create(table: "disabledClassificationRule", options: .ifNotExists) { t in
                t.column("ruleKey", .text).primaryKey()
            }
        }
        migrator.registerMigration("v11") { db in
            // Key-seconds per span, for telling a glance from an
            // interruption. NOT NULL DEFAULT 0 so an older build that
            // inserts without the column (a rollback) still writes valid
            // rows, and every existing span reads as "no typing".
            try db.alter(table: "span") { t in
                t.add(column: "keySeconds", .integer).notNull().defaults(to: 0)
            }
        }
        return migrator
    }
}
