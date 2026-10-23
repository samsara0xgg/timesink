import Foundation
import GRDB

/// Why a database write or open failed, from the SQLite result code only.
public enum StorageFailure: Equatable, Sendable {
    case full, corrupt, notADatabase, readOnly, cantOpen, ioError, other

    public static func classify(_ error: Error) -> StorageFailure {
        guard let error = error as? DatabaseError else { return .other }
        switch error.resultCode {
        case .SQLITE_FULL: return .full
        case .SQLITE_CORRUPT: return .corrupt
        case .SQLITE_NOTADB: return .notADatabase
        case .SQLITE_READONLY: return .readOnly
        case .SQLITE_CANTOPEN: return .cantOpen
        case .SQLITE_IOERR: return .ioError
        default: return .other
        }
    }

    /// Short reason shown beside a write that keeps failing.
    public var reason: String {
        switch self {
        case .full: String(localized: "磁盘满")
        case .corrupt, .notADatabase: String(localized: "数据库损坏")
        case .readOnly: String(localized: "数据库只读")
        case .cantOpen, .ioError, .other: String(localized: "写入失败")
        }
    }

    /// The class named in the alert when the database cannot be opened.
    public var openReason: String {
        switch self {
        case .full: String(localized: "磁盘满")
        case .corrupt, .notADatabase: String(localized: "数据库损坏")
        case .readOnly: String(localized: "数据库只读")
        case .cantOpen: String(localized: "无法读取数据库文件")
        case .ioError: String(localized: "磁盘读写出错")
        case .other: String(localized: "未知错误")
        }
    }
}

/// What the launch alert says when the database will not open; the caller shows it.
public enum DatabaseOpenFailure {
    public static func message(for error: Error) -> (title: String, detail: String) {
        let reason = StorageFailure.classify(error).openReason
        return (String(localized: "TimeSink 打不开数据库"),
                String(localized: "原因：\(reason)\n\n\(error.localizedDescription)"))
    }
}
