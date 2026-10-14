import Foundation
import GRDB

extension SpanStore {
    /// Export only when the user explicitly chooses a destination. Spreadsheet
    /// formulas are neutralized while quoted newlines and Unicode survive.
    public func exportCSV() throws -> String {
        try exportCSV(categories: nil)
    }

    /// Times are local with their UTC offset (`2026-10-14T09:30:00+08:00`),
    /// so a spreadsheet shows the hour the user lived and still sorts and
    /// converts exactly. With `categories` (the resolver's `snapshot()`,
    /// taken on the main actor) each row also names its category as the app
    /// shows it, by `names` (id → name; an id without one is written as is).
    func exportCSV(categories: CategoryResolver.Snapshot?, names: [String: String] = [:]) throws -> String {
        var resolver = categories
        return try writer.read { db in
            var result = resolver == nil ? String(localized: "开始,结束,应用,应用标识,标题,网址,域名\r\n")
                : String(localized: "开始,结束,应用,应用标识,标题,网址,域名,分类\r\n")
            let format = ISO8601DateFormatter()
            format.timeZone = TimeZone.current
            let cursor = try Span.fetchCursor(db, sql: "SELECT * FROM span ORDER BY start")
            while let span = try cursor.next() {
                var cells: [String] = [format.string(from: span.start), format.string(from: span.end), span.appName, span.appBundleID,
                                       span.title ?? "", span.url ?? "", span.domain ?? ""]
                if let id = resolver?.categoryID(for: span) { cells.append(names[id] ?? id) }
                result += cells.map(Self.csvCell).joined(separator: ",") + "\r\n"
            }
            return "\u{FEFF}" + result
        }
    }
    nonisolated static func csvCell(_ text: String) -> String {
        let guarded = text.first.map { "=+-@\t\r".contains($0) } == true ? "'" + text : text
        return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public func diagnosticSummary() throws -> String {
        try writer.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM span") ?? 0
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            return String(localized: "TimeSink 诊断信息\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n活动条数：\(count)\n数据库版本：\(migrations.joined(separator: ", "))\n\n不含窗口标题、网址、应用清单、截图、识别文字、密钥或账号。\n")
        }
    }
}
