import Foundation
import GRDB

// MARK: - Span GRDB record conformance
// Codable is already declared on Span in Models.swift (Ruling R1a); redeclaring it
// here would be a redundant-conformance error, so this extension adds only the
// GRDB record protocols.

extension Span: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "span"
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Category

public struct Category: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "category"
    public var id: String
    public var name: String
    public var colorHex: String
    public var productivity: Int
    public var sortOrder: Int

    public init(id: String, name: String, colorHex: String, productivity: Int, sortOrder: Int) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.productivity = productivity
        self.sortOrder = sortOrder
    }
}

// MARK: - URLRule

public struct URLRule: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "urlRule"
    public var id: Int64?
    public var pattern: String
    public var categoryID: String
    public var priority: Int
    public var source: String

    public init(id: Int64? = nil, pattern: String, categoryID: String, priority: Int, source: String) {
        self.id = id
        self.pattern = pattern
        self.categoryID = categoryID
        self.priority = priority
        self.source = source
    }
}

// MARK: - DomainEntry (plain value type, not a GRDB record)

public struct DomainEntry: Codable, Equatable, Sendable {
    public var categoryID: String
    public var source: String

    public init(categoryID: String, source: String) {
        self.categoryID = categoryID
        self.source = source
    }
}

// MARK: - TitleRule

public struct TitleRule: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "titleRule"
    public var id: Int64?
    public var pattern: String
    public var scopeKey: String
    public var categoryID: String
    public var priority: Int
    public var source: String
    public var enabled: Bool
    public var createdAt: Date

    public init(id: Int64? = nil, pattern: String, scopeKey: String = "",
                categoryID: String, priority: Int = 0, source: String,
                enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.pattern = pattern
        self.scopeKey = scopeKey
        self.categoryID = categoryID
        self.priority = priority
        self.source = source
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

// MARK: - Budget

public struct Budget: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "budget"
    public var categoryID: String
    public var dailySeconds: Int
    public var enabled: Bool

    public init(categoryID: String, dailySeconds: Int, enabled: Bool = true) {
        self.categoryID = categoryID
        self.dailySeconds = dailySeconds
        self.enabled = enabled
    }
}

// MARK: - FocusSession

public struct FocusSession: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "focusSession"
    public var id: Int64?
    public var start: Date
    public var end: Date
    public var plannedSeconds: Int
    public var appBlocks: Int
    public var siteBlocks: Int
    public var completed: Bool

    public init(id: Int64? = nil, start: Date, end: Date, plannedSeconds: Int,
                appBlocks: Int = 0, siteBlocks: Int = 0, completed: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.plannedSeconds = plannedSeconds
        self.appBlocks = appBlocks
        self.siteBlocks = siteBlocks
        self.completed = completed
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Internal row types for domainCategory / appCategory / setting / budgetAlert tables

struct DomainCategoryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "domainCategory"
    var domain: String
    var categoryID: String
    var source: String
    var updatedAt: Date
}

struct AppCategoryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "appCategory"
    var bundleID: String
    var categoryID: String
    var source: String
}

struct SettingRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setting"
    var key: String
    var value: String
}

struct BudgetAlertRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "budgetAlert"
    var categoryID: String
    var day: String
    var kind: String
}
