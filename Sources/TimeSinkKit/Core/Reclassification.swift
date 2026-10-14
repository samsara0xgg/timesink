import Foundation
import GRDB

/// A local reversible classification edit. Captures the previous row inside
/// the same transaction as the write so undo restores provenance as well.
struct ReclassificationEdit: Sendable {
    enum Scope: String, CaseIterable { case segment, activity, title }
    let scope: Scope
    /// The span id (segment), the domain or bundle ID (activity), or the
    /// normalized pattern (title).
    let key: String
    /// The span's domain or bundle ID: a title rule's scope. Equal to `key`
    /// for an activity edit.
    let activityKey: String
    let categoryID: String
    let isDomain: Bool
    let previousCategory: String?
    let previousSource: String?
    let previousDate: Date?
    let previousTitleRule: TitleRule?
    let createdAt: Date
}

extension CategoryStore {
    func segmentOverrides() throws -> [Int64: String] {
        try writer.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT spanID, categoryID FROM spanCategoryOverride")
                .map { ( $0["spanID"] as Int64, $0["categoryID"] as String ) })
        }
    }

    func reclassify(span: Span, scope: ReclassificationEdit.Scope, categoryID: String, pattern: String = "") throws -> ReclassificationEdit {
        let edit = try writer.write { db in
            try CategoryStore.write(span: span, scope: scope, categoryID: categoryID, pattern: pattern, db: db)
        }
        NotificationCenter.default.post(name: .userRecategorized, object: nil)
        return edit
    }

    /// Segment overrides for every saved span in `spans` not already in
    /// `categoryID`, in one transaction: all of them or, on an error, none.
    func reclassifySegments(_ spans: [Span], categoryID: String) throws -> [ReclassificationEdit] {
        let edits = try writer.write { db -> [ReclassificationEdit] in
            var edits: [ReclassificationEdit] = []
            var seen = Set<Int64>()
            for span in spans {
                // Clipped pieces of one row share its id: one override each.
                guard let id = span.id, seen.insert(id).inserted else { continue }
                edits.append(try CategoryStore.write(span: span, scope: .segment, categoryID: categoryID, pattern: "", db: db))
            }
            return edits
        }
        if !edits.isEmpty { NotificationCenter.default.post(name: .userRecategorized, object: nil) }
        return edits
    }

    private static func write(span: Span, scope: ReclassificationEdit.Scope, categoryID: String, pattern: String, db: Database) throws -> ReclassificationEdit {
        let activityKey = span.domain ?? span.appBundleID
        var key = activityKey
        switch scope {
        case .segment:
            guard let id = span.id else { throw ReclassificationError.unsavedSpan }
            key = String(id)
        case .activity:
            break
        case .title:
            guard let normalized = TitleRuleInput.normalizedPattern(pattern) else { throw ReclassificationError.invalidPattern }
            key = normalized
        }
        return try write(scope: scope, key: key, activityKey: activityKey, isDomain: span.domain != nil, categoryID: categoryID, db: db)
    }

    /// The write itself, from what an edit records: `redoReclassifications`
    /// replays an undone edit through here without its span.
    private static func write(scope: ReclassificationEdit.Scope, key: String, activityKey: String, isDomain: Bool,
                              categoryID: String, db: Database) throws -> ReclassificationEdit {
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        var previous: Row?
        var previousRule: TitleRule?
        switch scope {
        case .segment:
            previous = try Row.fetchOne(db, sql: "SELECT categoryID FROM spanCategoryOverride WHERE spanID = ?", arguments: [key])
            try db.execute(sql: "INSERT INTO spanCategoryOverride(spanID, categoryID) VALUES (?, ?) ON CONFLICT(spanID) DO UPDATE SET categoryID = excluded.categoryID", arguments: [key, categoryID])
        case .activity:
            if isDomain {
                previous = try Row.fetchOne(db, sql: "SELECT * FROM domainCategory WHERE domain = ?", arguments: [key])
                try db.execute(sql: "INSERT INTO domainCategory(domain, categoryID, source, updatedAt) VALUES (?, ?, 'user', ?) ON CONFLICT(domain) DO UPDATE SET categoryID = excluded.categoryID, source = 'user', updatedAt = excluded.updatedAt", arguments: [key, categoryID, now])
            } else {
                previous = try Row.fetchOne(db, sql: "SELECT * FROM appCategory WHERE bundleID = ?", arguments: [key])
                try db.execute(sql: "INSERT INTO appCategory(bundleID, categoryID, source) VALUES (?, ?, 'user') ON CONFLICT(bundleID) DO UPDATE SET categoryID = excluded.categoryID, source = 'user'", arguments: [key, categoryID])
            }
        case .title:
            previousRule = try TitleRule.fetchOne(db, sql: "SELECT * FROM titleRule WHERE pattern = ? AND scopeKey = ?", arguments: [key, activityKey])
            guard previousRule?.source != "builtin" else { throw ReclassificationError.builtinRule }
            try db.execute(sql: "INSERT INTO titleRule(pattern, scopeKey, categoryID, priority, source, enabled, createdAt) VALUES (?, ?, ?, COALESCE((SELECT MAX(priority) FROM titleRule WHERE source = 'user' AND scopeKey = ?), 0) + 100, 'user', 1, ?) ON CONFLICT(pattern, scopeKey) DO UPDATE SET categoryID = excluded.categoryID, enabled = 1, createdAt = excluded.createdAt", arguments: [key, activityKey, categoryID, activityKey, now])
        }
        return ReclassificationEdit(scope: scope, key: key, activityKey: activityKey, categoryID: categoryID, isDomain: isDomain,
            previousCategory: previous?["categoryID"], previousSource: previous?.hasColumn("source") == true ? previous?["source"] : nil,
            previousDate: previous?.hasColumn("updatedAt") == true ? previous?["updatedAt"] : nil,
            previousTitleRule: previousRule, createdAt: now)
    }

    /// Undoes a run of edits, the last one first, in one transaction. One
    /// that can no longer be undone (changed again since) is left alone and
    /// the first such error is rethrown; any other error undoes nothing.
    func undoReclassifications(_ edits: [ReclassificationEdit]) throws {
        let failure = try writer.write { db -> ReclassificationError? in
            var first: ReclassificationError?
            for edit in edits.reversed() {
                do { try CategoryStore.undo(edit, activityKey: edit.activityKey, db: db) }
                catch let error as ReclassificationError { first = first ?? error }
            }
            return first
        }
        if let failure { throw failure }
    }

    func undoReclassification(_ edit: ReclassificationEdit) throws {
        try undoReclassifications([edit])
    }

    /// `activityKey` is ignored: the edit carries its own (kept for callers
    /// written before it did).
    func undoReclassification(_ edit: ReclassificationEdit, activityKey: String) throws {
        try undoReclassification(edit)
    }

    /// Applies undone edits again (redo), the first one first, in one
    /// transaction, and returns the new edits to undo them by. Throws
    /// `changedSinceEdit`, writing nothing, when any was changed again after
    /// the undo.
    func redoReclassifications(_ edits: [ReclassificationEdit]) throws -> [ReclassificationEdit] {
        try writer.write { db -> [ReclassificationEdit] in
            var redone: [ReclassificationEdit] = []
            for edit in edits {
                guard try CategoryStore.restored(edit, db: db) else { throw ReclassificationError.changedSinceEdit }
                redone.append(try CategoryStore.write(scope: edit.scope, key: edit.key, activityKey: edit.activityKey, isDomain: edit.isDomain,
                                             categoryID: edit.categoryID, db: db))
            }
            return redone
        }
    }

    /// Whether what `edit` replaced is still what is there: its undo is the
    /// last word on it.
    private static func restored(_ edit: ReclassificationEdit, db: Database) throws -> Bool {
        switch edit.scope {
        case .segment:
            let current = try String.fetchOne(db, sql: "SELECT categoryID FROM spanCategoryOverride WHERE spanID = ?", arguments: [edit.key])
            return current == edit.previousCategory
        case .activity:
            let sql = edit.isDomain ? "SELECT categoryID FROM domainCategory WHERE domain = ?" : "SELECT categoryID FROM appCategory WHERE bundleID = ?"
            let current = try String.fetchOne(db, sql: sql, arguments: [edit.key])
            return current == edit.previousCategory
        case .title:
            let current = try TitleRule.fetchOne(db, sql: "SELECT * FROM titleRule WHERE pattern = ? AND scopeKey = ?", arguments: [edit.key, edit.activityKey])
            return current?.categoryID == edit.previousTitleRule?.categoryID
        }
    }

    private static func undo(_ edit: ReclassificationEdit, activityKey: String, db: Database) throws {
        switch edit.scope {
        case .segment:
            let current = try String.fetchOne(db, sql: "SELECT categoryID FROM spanCategoryOverride WHERE spanID = ?", arguments: [edit.key])
            guard current == edit.categoryID else { throw ReclassificationError.changedSinceEdit }
            if let previous = edit.previousCategory {
                try db.execute(sql: "UPDATE spanCategoryOverride SET categoryID = ? WHERE spanID = ?", arguments: [previous, edit.key])
            } else { try db.execute(sql: "DELETE FROM spanCategoryOverride WHERE spanID = ?", arguments: [edit.key]) }
        case .activity:
            let table = edit.isDomain ? "domainCategory" : "appCategory"
            let column = edit.isDomain ? "domain" : "bundleID"
            let current = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE \(column) = ?", arguments: [edit.key])
            guard let current, current["categoryID"] as String == edit.categoryID, current["source"] as String == "user" else { throw ReclassificationError.changedSinceEdit }
            if edit.isDomain, abs((current["updatedAt"] as Date).timeIntervalSince(edit.createdAt)) > 0.0001 { throw ReclassificationError.changedSinceEdit }
            if let previous = edit.previousCategory {
                try db.execute(sql: "UPDATE \(table) SET categoryID = ?, source = ? WHERE \(column) = ?", arguments: [previous, edit.previousSource ?? "user", edit.key])
                if edit.isDomain { try db.execute(sql: "UPDATE domainCategory SET updatedAt = ? WHERE domain = ?", arguments: [edit.previousDate ?? edit.createdAt, edit.key]) }
            } else { try db.execute(sql: "DELETE FROM \(table) WHERE \(column) = ?", arguments: [edit.key]) }
        case .title:
            let current = try TitleRule.fetchOne(db, sql: "SELECT * FROM titleRule WHERE pattern = ? AND scopeKey = ?", arguments: [edit.key, activityKey])
            guard let current, current.categoryID == edit.categoryID, abs(current.createdAt.timeIntervalSince(edit.createdAt)) < 0.0001 else { throw ReclassificationError.changedSinceEdit }
            if let previous = edit.previousTitleRule { try previous.update(db) }
            else { try db.execute(sql: "DELETE FROM titleRule WHERE id = ?", arguments: [current.id]) }
        }
    }
}

enum ReclassificationError: LocalizedError {
    case unsavedSpan, invalidPattern, builtinRule, changedSinceEdit
    var errorDescription: String? {
        switch self {
        case .unsavedSpan: String(localized: "这段活动还未保存，请稍后重试。")
        case .invalidPattern: String(localized: "请输入至少两个字的有效标题关键词。")
        case .builtinRule: String(localized: "这个条件已有内置规则，请在分类与规则中编辑。")
        case .changedSinceEdit: String(localized: "分类已再次更改，不能撤销覆盖较新的修改。")
        }
    }
}
