import Foundation
import GRDB

/// One stretch of a call (a call app held the microphone), local only.
public struct CallSpan: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "callSpan"
    public var id: Int64?
    public var start: Date
    public var end: Date
    public var appBundleID: String
    public var appName: String

    public init(id: Int64? = nil, start: Date, end: Date, appBundleID: String, appName: String) {
        self.id = id; self.start = start; self.end = end
        self.appBundleID = appBundleID; self.appName = appName
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// The call as a calendar event, so `MeetingTagger` counts it like one.
    var asMeetingEvent: CalendarEvent {
        CalendarEvent(id: "call-\(id ?? 0)-\(start.timeIntervalSince1970)", title: appName, start: start, end: end,
                      isAllDay: false, attendeeCount: 2, isDeclined: false, calendarTitle: "", colorHex: "#98989D")
    }
}

public final class CallSpanStore: Sendable {
    let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) { self.writer = writer }

    @discardableResult
    public func open(at date: Date, bundleID: String, appName: String) throws -> CallSpan {
        var span = CallSpan(start: date, end: date, appBundleID: bundleID, appName: appName)
        try writer.write { db in try span.insert(db) }
        return span
    }

    public func extend(id: Int64, end: Date) throws {
        try writer.write { db in try db.execute(sql: "UPDATE callSpan SET end = ? WHERE id = ?", arguments: [end, id]) }
    }

    /// The row of `bundleID` that ended last, if any.
    public func latest(bundleID: String) throws -> CallSpan? {
        try writer.read { db in
            try CallSpan.fetchOne(db, sql: "SELECT * FROM callSpan WHERE appBundleID = ? ORDER BY \"end\" DESC LIMIT 1",
                                  arguments: [bundleID])
        }
    }

    public func spans(overlapping interval: DateInterval) throws -> [CallSpan] {
        try writer.read { db in
            try CallSpan.fetchAll(db, sql: "SELECT * FROM callSpan WHERE start < ? AND end > ? ORDER BY start",
                                  arguments: [interval.end, interval.start])
        }
    }
}
