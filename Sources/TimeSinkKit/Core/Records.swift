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

// MARK: - Internal row types for domainCategory / appCategory / setting tables

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
