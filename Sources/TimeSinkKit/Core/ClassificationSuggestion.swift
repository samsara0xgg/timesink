import Foundation
import GRDB

struct ClassificationSuggestion: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "classificationSuggestion"
    let key: String
    let kind: String
    let categoryID: String
    let source: String
    let createdAt: Date
}

extension CategoryStore {
    func suggestions() throws -> [ClassificationSuggestion] {
        try writer.read { try ClassificationSuggestion.fetchAll($0) }
    }
    func dismissSuggestion(key: String, kind: String) throws {
        try writer.write { try $0.execute(sql: "DELETE FROM classificationSuggestion WHERE key = ? AND kind = ?", arguments: [key, kind]) }
    }
    /// Puts a dismissed suggestion back, for undoing an accept.
    func restoreSuggestion(_ suggestion: ClassificationSuggestion) throws {
        try writer.write { try suggestion.save($0) }
    }
    func disabledRules() throws -> Set<String> {
        try writer.read { Set(try String.fetchAll($0, sql: "SELECT ruleKey FROM disabledClassificationRule")) }
    }
    func setRuleEnabled(key: String, enabled: Bool) throws {
        try writer.write { db in
            if enabled { try db.execute(sql: "DELETE FROM disabledClassificationRule WHERE ruleKey = ?", arguments: [key]) }
            else { try db.execute(sql: "INSERT OR IGNORE INTO disabledClassificationRule(ruleKey) VALUES (?)", arguments: [key]) }
        }
    }
    /// Deletes a user website ("domain:…") or app ("app:…") mapping and puts
    /// back what shipped for it. The user row overwrote the default in
    /// place, so deleting alone would leave the site or app unmapped.
    func removeUserMapping(key: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM disabledClassificationRule WHERE ruleKey = ?", arguments: [key])
            if key.hasPrefix("domain:") {
                let domain = String(key.dropFirst("domain:".count))
                try db.execute(sql: "DELETE FROM domainCategory WHERE domain = ? AND source = 'user'", arguments: [domain])
                if let shipped = SeedImporter.shippedDomain(domain) {
                    try db.execute(sql: "INSERT OR IGNORE INTO domainCategory (domain, categoryID, source, updatedAt) VALUES (?, ?, ?, ?)",
                                   arguments: [domain, shipped.categoryID, shipped.source, Date()])
                }
            } else if key.hasPrefix("app:") {
                let app = String(key.dropFirst("app:".count))
                try db.execute(sql: "DELETE FROM appCategory WHERE bundleID = ? AND source = 'user'", arguments: [app])
                if let builtin = Taxonomy.builtinApps.first(where: { $0.bundleID == app }) {
                    try db.execute(sql: "INSERT OR IGNORE INTO appCategory (bundleID, categoryID, source) VALUES (?, ?, 'builtin')",
                                   arguments: [app, builtin.categoryID])
                }
            }
        }
    }
    func orderTitleRules(_ ids: [Int64]) throws {
        try writer.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE titleRule SET priority = ? WHERE id = ? AND source = 'user'", arguments: [(ids.count - index) * 100, id])
            }
        }
    }
}
