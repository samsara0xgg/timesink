import Foundation
import SQLite3

/// Reads the existing capture store without importing the tracker or running migrations.
struct SpaceLibrary: Sendable {
    let date: Date
    let events: [SpaceEvent]
    let error: String?

    static func loadToday(now: Date = Date()) -> SpaceLibrary {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TimeSink", isDirectory: true)
        return load(database: root.appendingPathComponent("timesink.sqlite"), captureRoot: root.appendingPathComponent("captures", isDirectory: true), date: now)
    }

    static func load(database: URL, captureRoot: URL, date: Date) -> SpaceLibrary {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return SpaceLibrary(date: date, events: [], error: "无法读取 TimeSink 的本地记录。请先运行 TimeSink 并采集画面。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let query = """
        SELECT id, at, lastSeenAt, appBundleID, appName, windowID, title, imagePath
        FROM capture WHERE at >= ? AND at < ? ORDER BY at, id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return SpaceLibrary(date: date, events: [], error: "本地截图记录的格式暂不受此预览支持。")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, formatter.string(from: dayStart), -1, transient)
        sqlite3_bind_text(statement, 2, formatter.string(from: dayEnd), -1, transient)
        func string(_ column: Int32) -> String {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: text)
        }
        func parseDate(_ value: String) -> Date? {
            if let date = formatter.date(from: value) { return date }
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let date = formatter.date(from: value)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return date
        }
        struct Group {
            let app: String
            let bundle: String
            let window: Int64
            let title: String
            var snapshots: [SpaceSnapshot]
        }
        var groups: [Group] = []
        var interrupted = false
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            let app = string(4), bundle = string(3)
            if ["SecurityAgent", "loginwindow", "1Password", "Passwords", "Keychain Access"].contains(app) {
                interrupted = true
                continue
            }
            guard let at = parseDate(string(1)), let lastSeen = parseDate(string(2)) else { continue }
            let rawTitle = string(6).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? app : rawTitle
            let relativePath = string(7)
            let candidate = captureRoot.appendingPathComponent(relativePath).standardizedFileURL
            let allowedRoot = captureRoot.standardizedFileURL.path + "/"
            let url: URL? = !relativePath.isEmpty && candidate.path.hasPrefix(allowedRoot)
                && FileManager.default.isReadableFile(atPath: candidate.path) ? candidate : nil
            let snapshot = SpaceSnapshot(id: sqlite3_column_int64(statement, 0), at: at,
                                         lastSeenAt: min(dayEnd, max(at, lastSeen)), url: url)
            let window = sqlite3_column_int64(statement, 5)
            if !interrupted, let last = groups.last, last.bundle == bundle, last.window == window,
               last.title == title, let previous = last.snapshots.last,
               at.timeIntervalSince(previous.lastSeenAt) <= 75 {
                groups[groups.count - 1].snapshots.append(snapshot)
            } else {
                groups.append(Group(app: app, bundle: bundle, window: window, title: title, snapshots: [snapshot]))
            }
            interrupted = false
        }
        guard step == SQLITE_DONE else {
            return SpaceLibrary(date: date, events: [], error: "读取截图时遇到问题，请关闭预览后重试。")
        }
        let events = groups.enumerated().map { index, group in
            SpaceEvent(id: index, start: group.snapshots.first!.at,
                       end: group.snapshots.map(\.lastSeenAt).max()!, app: group.app, bundleID: group.bundle,
                       title: group.title, category: .infer(app: group.app, title: group.title), snapshots: group.snapshots)
        }
        return SpaceLibrary(date: date, events: events, error: nil)
    }
}
