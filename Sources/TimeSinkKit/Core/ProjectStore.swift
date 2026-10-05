import Foundation
import GRDB
import os

/// A project the person works on: named by them, or accepted from a
/// suggestion. Jev is asked which one a window belongs to (`JevPrompt`).
public struct UserProject: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"
    /// The id Jev sees and answers with. Never "none".
    public var id: String
    public var name: String
    public var description: String
    public var sortOrder: Int
    /// "user" or "suggested".
    public var source: String
    public var archived: Bool
    public var createdAt: Date
    /// Its colour: a slot 0..<8 of the project palette. nil only for a row made before v20 (read as the name's proposal).
    public var colorIndex: Int?
}

public final class ProjectStore: Sendable {
    let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Jev is asked about every project in every request, so the list stays short.
    public static let maxProjects = 20

    public enum ProjectError: Error, Equatable {
        case emptyName, duplicate, limitReached, notFound, sameProject
    }

    /// Not archived, in the order the person keeps them.
    public func list() throws -> [UserProject] {
        try writer.read { db in
            try UserProject.fetchAll(db, sql: "SELECT * FROM project WHERE archived = 0 ORDER BY sortOrder, createdAt, id")
        }
    }

    /// Adds a project after the last one. A name an archived project had
    /// brings that one back, with the new description.
    @discardableResult
    public func add(name: String, description: String = "", source: String = "user") throws -> UserProject {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        return try writer.write { db in
            let order = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM project") ?? -1) + 1
            if var old = try UserProject.fetchOne(db, sql: "SELECT * FROM project WHERE name = ?", arguments: [name]) {
                guard old.archived else { throw ProjectError.duplicate }
                old.archived = false
                old.name = name
                old.description = description
                old.sortOrder = order
                // Back from the archive: keep its colour unless a live project has taken it meanwhile.
                let taken = try Self.liveColors(db)
                if let color = old.colorIndex, !taken.contains(color) {} else { old.colorIndex = ProjectPalette.slot(for: name, taken: taken) }
                try old.update(db)
                return old
            }
            let live = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project WHERE archived = 0") ?? 0
            guard live < Self.maxProjects else { throw ProjectError.limitReached }
            let project = UserProject(id: "p-" + UUID().uuidString.lowercased().prefix(8), name: name, description: description,
                                      sortOrder: order, source: source, archived: false, createdAt: Date(),
                                      colorIndex: ProjectPalette.slot(for: name, taken: try Self.liveColors(db)))
            try project.insert(db)
            return project
        }
    }

    /// The colours the live (not archived) projects wear.
    static func liveColors(_ db: Database) throws -> Set<Int> {
        Set(try Int.fetchAll(db, sql: "SELECT colorIndex FROM project WHERE archived = 0 AND colorIndex IS NOT NULL"))
    }

    /// Gives the project one of the palette's colours. Two projects may share one: that is the person's choice.
    public func setColor(id: String, index: Int) throws {
        guard (0..<ProjectPalette.slots).contains(index) else { return }
        try writer.write { db in
            guard try UserProject.exists(db, key: id) else { throw ProjectError.notFound }
            try db.execute(sql: "UPDATE project SET colorIndex = ? WHERE id = ?", arguments: [index, id])
        }
    }

    /// Renames and/or re-describes. Your own assignments of sessions follow the new name.
    public func update(id: String, name: String, description: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        try writer.write { db in
            guard var project = try UserProject.fetchOne(db, key: id) else { throw ProjectError.notFound }
            if let other = try UserProject.fetchOne(db, sql: "SELECT * FROM project WHERE name = ?", arguments: [name]), other.id != id {
                throw ProjectError.duplicate
            }
            let old = project.name
            project.name = name
            project.description = description
            try project.update(db)
            try db.execute(sql: "UPDATE sessionName SET project = ? WHERE project = ? COLLATE NOCASE", arguments: [name, old])
        }
    }

    /// Takes the project out of the list and out of Jev's questions. Its
    /// verdicts and your assignments stay in the database.
    public func archive(_ id: String) throws {
        try writer.write { db in
            guard try UserProject.exists(db, key: id) else { throw ProjectError.notFound }
            try db.execute(sql: "UPDATE project SET archived = 1 WHERE id = ?", arguments: [id])
        }
    }

    /// Moves everything labelled `id` onto `target` and removes `id`: your
    /// session assignments (kept by name) and Jev's verdicts (kept by id).
    public func merge(_ id: String, into target: String) throws {
        guard id != target else { throw ProjectError.sameProject }
        try writer.write { db in
            guard let from = try UserProject.fetchOne(db, key: id), let to = try UserProject.fetchOne(db, key: target) else {
                throw ProjectError.notFound
            }
            try db.execute(sql: "UPDATE sessionName SET project = ? WHERE project = ? COLLATE NOCASE", arguments: [to.name, from.name])
            try db.execute(sql: "UPDATE jevProjectVerdict SET projectID = ? WHERE projectID = ?", arguments: [to.id, from.id])
            try db.execute(sql: "UPDATE jevProjectVerdict SET runnerUp = ? WHERE runnerUp = ?", arguments: [to.id, from.id])
            try db.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [id])
        }
    }
}

extension CategoryStore {
    /// The projects live in the same database.
    public var projects: ProjectStore { ProjectStore(writer) }
}

/// A one-time starting list of projects, read from
/// `~/Library/Application Support/TimeSink/project-seed.json` at launch:
/// `{"projects":[{"name":"...","description":"..."}]}`. It applies only while
/// there are no projects and it has not applied before; a missing or broken
/// file is ignored. The projects come in as 'suggested', and Jev's normal
/// pass then fills in the last two weeks.
public enum ProjectSeed {
    static let flag = "projectSeedApplied"

    public static var defaultURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("TimeSink/project-seed.json")
    }

    /// True when it added projects.
    @discardableResult
    public static func applyIfNeeded(store: ProjectStore, settings: SettingsStore, file: URL? = defaultURL) -> Bool {
        struct Seed: Decodable {
            struct Item: Decodable { let name: String; let description: String? }
            let projects: [Item]
        }
        guard settings.get(flag) == nil, let file, let data = try? Data(contentsOf: file),
              (try? store.list().isEmpty) == true else { return false }
        guard let seed = try? JSONDecoder().decode(Seed.self, from: data) else {
            Logger(subsystem: "com.alllllenshi.TimeSink", category: "projects").error("project-seed.json could not be read")
            return false
        }
        var added = false
        for item in seed.projects.prefix(ProjectStore.maxProjects) {
            if (try? store.add(name: item.name, description: item.description ?? "", source: "suggested")) != nil { added = true }
        }
        settings.set(flag, "true")
        return added
    }
}
