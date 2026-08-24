import Foundation

/// A date-range selection driven by an "anchor" day: `kind` picks the window
/// shape (a single day, or the 7/30 whole days ending on the anchor's day),
/// `anchor` picks which day it ends on. `shift` moves the anchor by the
/// window's own size (1/7/30 days) and never moves it past today.
public struct DateRangeSelection: Equatable {
    public enum Kind: String, CaseIterable {
        case day, last7, last30
    }

    public var kind: Kind
    public var anchor: Date

    public init(kind: Kind, anchor: Date) {
        self.kind = kind
        self.anchor = anchor
    }

    public static func today() -> DateRangeSelection {
        DateRangeSelection(kind: .day, anchor: Date())
    }

    /// Number of whole days the window spans, ending on `anchor`'s day.
    private var windowDays: Int {
        switch kind {
        case .day: return 1
        case .last7: return 7
        case .last30: return 30
        }
    }

    public var interval: DateInterval {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: anchor)
        let end = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let start = cal.date(byAdding: .day, value: -(windowDays - 1), to: dayStart) ?? dayStart
        return DateInterval(start: start, end: end)
    }

    public var label: String {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(anchor)
        switch kind {
        case .day:
            if isToday { return "今天" }
            if cal.isDateInYesterday(anchor) { return "昨天" }
            return Self.monthDay(anchor, calendar: cal)
        case .last7:
            if isToday { return "近 7 天" }
            return "至 \(Self.monthDay(anchor, calendar: cal)) 的 7 天"
        case .last30:
            if isToday { return "近 30 天" }
            return "至 \(Self.monthDay(anchor, calendar: cal)) 的 30 天"
        }
    }

    /// Moves the anchor by one window's worth of days (1/7/30), clamped so it
    /// never lands past today.
    public mutating func shift(_ direction: Int) {
        let cal = Calendar.current
        let now = Date()
        guard let candidate = cal.date(byAdding: .day, value: direction * windowDays, to: anchor) else { return }
        if cal.startOfDay(for: candidate) > cal.startOfDay(for: now) {
            anchor = now
        } else {
            anchor = candidate
        }
    }

    private static func monthDay(_ date: Date, calendar: Calendar) -> String {
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return "\(month)月\(day)日"
    }
}
