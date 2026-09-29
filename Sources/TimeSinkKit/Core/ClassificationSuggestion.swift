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
    func suggestDomain(_ domain: String, categoryID: String) throws {
        guard OpenAIDomainClassifier.validCategoryIDs.contains(categoryID) else { return }
        try writer.write { db in
            try db.execute(sql: "INSERT INTO classificationSuggestion(key, kind, categoryID, source, createdAt) VALUES (?, 'domain', ?, 'model', ?) ON CONFLICT(key, kind) DO NOTHING", arguments: [domain, categoryID, Date()])
        }
    }
    func dismissSuggestion(key: String, kind: String) throws {
        try writer.write { try $0.execute(sql: "DELETE FROM classificationSuggestion WHERE key = ? AND kind = ?", arguments: [key, kind]) }
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
    func orderTitleRules(_ ids: [Int64]) throws {
        try writer.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE titleRule SET priority = ? WHERE id = ? AND source = 'user'", arguments: [(ids.count - index) * 100, id])
            }
        }
    }
}
