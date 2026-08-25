import Foundation

/// A date-range selection driven by an "anchor" day: `kind` picks the window
/// shape (a single day; the 7/30 whole days ending on the anchor's day; the
/// calendar week/month containing the anchor; or a custom `[customStart,
/// customEnd]` span), `anchor` picks which day it ends on (or, for `.custom`,
/// is kept in sync with `customEnd` for display purposes). `shift` moves the
/// window by its own size and never moves it past today.
public struct DateRangeSelection: Equatable {
    public enum Kind: String, CaseIterable {
        case day, week, month, last7, last30, custom
    }

    public var kind: Kind
    public var anchor: Date
    /// Only read when `kind == .custom`; regularized to `startOfDay` when the
    /// interval is computed.
    public var customStart: Date?
    /// Only read when `kind == .custom`; the interval includes the whole of
    /// this day (`interval.end` is the day after `customEnd`, at midnight).
    public var customEnd: Date?

    public init(kind: Kind, anchor: Date, customStart: Date? = nil, customEnd: Date? = nil) {
        self.kind = kind
        self.anchor = anchor
        self.customStart = customStart
        self.customEnd = customEnd
    }

    public static func today() -> DateRangeSelection {
        DateRangeSelection(kind: .day, anchor: Date())
    }

    /// Pins the first day of the week to Monday (the "Monday=0" convention
    /// used throughout the stats/aggregation code), independent of locale.
    private var mondayCalendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    /// Number of whole days the window spans, ending on `anchor`'s day. Only
    /// meaningful for `.day`/`.last7`/`.last30`.
    private var windowDays: Int {
        switch kind {
        case .day: return 1
        case .last7: return 7
        case .last30: return 30
        case .week, .month, .custom: return 1
        }
    }

    public var interval: DateInterval {
        let cal = Calendar.current
        switch kind {
        case .day, .last7, .last30:
            let dayStart = cal.startOfDay(for: anchor)
            let end = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            let start = cal.date(byAdding: .day, value: -(windowDays - 1), to: dayStart) ?? dayStart
            return DateInterval(start: start, end: end)
        case .week:
            return mondayCalendar.dateInterval(of: .weekOfYear, for: anchor) ?? fallbackDayInterval(cal)
        case .month:
            return cal.dateInterval(of: .month, for: anchor) ?? fallbackDayInterval(cal)
        case .custom:
            let start = cal.startOfDay(for: customStart ?? anchor)
            let endDayStart = cal.startOfDay(for: customEnd ?? anchor)
            let end = cal.date(byAdding: .day, value: 1, to: endDayStart) ?? endDayStart.addingTimeInterval(86400)
            return DateInterval(start: start, end: end)
        }
    }

    /// Single-day fallback for the rare case `Calendar.dateInterval(of:for:)`
    /// returns nil (e.g. an invalid calendar configuration).
    private func fallbackDayInterval(_ cal: Calendar) -> DateInterval {
        let dayStart = cal.startOfDay(for: anchor)
        let end = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        return DateInterval(start: dayStart, end: end)
    }

    /// The immediately preceding period to compare against ("环比"): for
    /// `.week`/`.month` this is the previous calendar week/month (which may
    /// differ in length from the current one); for every other kind it's the
    /// equal-length window immediately before `interval.start`.
    public var previousInterval: DateInterval {
        switch kind {
        case .week:
            let cal = mondayCalendar
            guard let prevAnchor = cal.date(byAdding: .weekOfYear, value: -1, to: anchor),
                  let prevInterval = cal.dateInterval(of: .weekOfYear, for: prevAnchor) else {
                return equalLengthPreceding
            }
            return prevInterval
        case .month:
            let cal = Calendar.current
            guard let prevAnchor = cal.date(byAdding: .month, value: -1, to: anchor),
                  let prevInterval = cal.dateInterval(of: .month, for: prevAnchor) else {
                return equalLengthPreceding
            }
            return prevInterval
        case .day, .last7, .last30, .custom:
            return equalLengthPreceding
        }
    }

    private var equalLengthPreceding: DateInterval {
        let iv = interval
        return DateInterval(start: iv.start.addingTimeInterval(-iv.duration), end: iv.start)
    }

    /// Whether `interval` contains the current moment.
    public var containsNow: Bool {
        interval.contains(Date())
    }

    public var label: String {
        let cal = Calendar.current
        let now = Date()
        switch kind {
        case .day:
            if cal.isDateInToday(anchor) { return "今天" }
            if cal.isDateInYesterday(anchor) { return "昨天" }
            return Self.monthDay(anchor, calendar: cal)
        case .last7:
            if cal.isDateInToday(anchor) { return "近 7 天" }
            return "至 \(Self.monthDay(anchor, calendar: cal)) 的 7 天"
        case .last30:
            if cal.isDateInToday(anchor) { return "近 30 天" }
            return "至 \(Self.monthDay(anchor, calendar: cal)) 的 30 天"
        case .week:
            let mcal = mondayCalendar
            if mcal.isDate(anchor, equalTo: now, toGranularity: .weekOfYear) { return "本周" }
            if let nextWeekAnchor = mcal.date(byAdding: .weekOfYear, value: 1, to: anchor),
               mcal.isDate(nextWeekAnchor, equalTo: now, toGranularity: .weekOfYear) {
                return "上周"
            }
            return "\(Self.monthDay(anchor, calendar: cal)) 那周"
        case .month:
            if cal.isDate(anchor, equalTo: now, toGranularity: .month) { return "本月" }
            return "\(cal.component(.month, from: anchor))月"
        case .custom:
            guard let start = customStart, let end = customEnd else { return "自定义" }
            return "\(Self.monthDay(start, calendar: cal)) – \(Self.monthDay(end, calendar: cal))"
        }
    }

    /// Moves the window by its own size (1/7/30 days, one week, one month, or
    /// the custom range's own day-count), clamped so it never lands past
    /// today.
    public mutating func shift(_ direction: Int) {
        let cal = Calendar.current
        let now = Date()
        switch kind {
        case .day, .last7, .last30:
            guard let candidate = cal.date(byAdding: .day, value: direction * windowDays, to: anchor) else { return }
            anchor = clampToToday(candidate, cal: cal, now: now)
        case .week:
            guard let candidate = cal.date(byAdding: .weekOfYear, value: direction, to: anchor) else { return }
            anchor = clampToToday(candidate, cal: cal, now: now)
        case .month:
            guard let candidate = cal.date(byAdding: .month, value: direction, to: anchor) else { return }
            anchor = clampToToday(candidate, cal: cal, now: now)
        case .custom:
            guard let start = customStart, let end = customEnd else { return }
            let days = customRangeDays(cal: cal)
            guard let candidateStart = cal.date(byAdding: .day, value: direction * days, to: start),
                  let candidateEnd = cal.date(byAdding: .day, value: direction * days, to: end) else { return }
            if cal.startOfDay(for: candidateEnd) > cal.startOfDay(for: now) {
                customEnd = now
                customStart = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now))
            } else {
                customStart = candidateStart
                customEnd = candidateEnd
            }
            anchor = customEnd ?? anchor
        }
    }

    private func clampToToday(_ candidate: Date, cal: Calendar, now: Date) -> Date {
        cal.startOfDay(for: candidate) > cal.startOfDay(for: now) ? now : candidate
    }

    /// Whole-day length of `[customStart, customEnd]`, inclusive.
    private func customRangeDays(cal: Calendar) -> Int {
        guard let start = customStart, let end = customEnd else { return 1 }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0
        return max(1, days + 1)
    }

    private static func monthDay(_ date: Date, calendar: Calendar) -> String {
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return "\(month)月\(day)日"
    }
}
