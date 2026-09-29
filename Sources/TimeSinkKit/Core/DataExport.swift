import Foundation
import GRDB

extension SpanStore {
    /// Export only when the user explicitly chooses a destination. Spreadsheet
    /// formulas are neutralized while quoted newlines and Unicode survive.
    public func exportCSV() throws -> String {
        try writer.read { db in
            var result = String(localized: "开始,结束,应用,应用标识,标题,网址,域名\r\n")
            let format = ISO8601DateFormatter()
            let cursor = try Span.fetchCursor(db, sql: "SELECT * FROM span ORDER BY start")
            while let span = try cursor.next() {
                result += [format.string(from: span.start), format.string(from: span.end), span.appName, span.appBundleID, span.title ?? "", span.url ?? "", span.domain ?? ""].map(Self.csvCell).joined(separator: ",") + "\r\n"
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
