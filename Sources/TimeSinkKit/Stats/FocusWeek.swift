import Foundation

/// F4: one week of the focus log, bucketed by the day each session started.
struct FocusWeek: Equatable {
    let interval: DateInterval
    /// The week's seven days, first weekday first.
    let days: [Date]
    /// Focused seconds on each of `days`.
    let perDay: [TimeInterval]
    /// Newest first; only the sessions that started in the week.
    let sessions: [FocusSession]

    var total: TimeInterval { perDay.reduce(0, +) }
    var longest: TimeInterval { sessions.map(Self.length).max() ?? 0 }

    private static func length(_ session: FocusSession) -> TimeInterval { session.end.timeIntervalSince(session.start) }

    /// The week `weeksBack` weeks before the one containing `now`.
    static func interval(weeksBack: Int, now: Date, calendar: Calendar) -> DateInterval {
        let date = calendar.date(byAdding: .weekOfYear, value: -weeksBack, to: now) ?? now
        return calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86400)
    }

    /// How many weeks back the week of `earliest` is, so the arrows stop there.
    static func weeksBack(of earliest: Date?, now: Date, calendar: Calendar) -> Int {
        guard let earliest else { return 0 }
        let first = interval(weeksBack: 0, now: earliest, calendar: calendar).start
        let current = interval(weeksBack: 0, now: now, calendar: calendar).start
        return max(0, calendar.dateComponents([.weekOfYear], from: first, to: current).weekOfYear ?? 0)
    }

    static func make(_ all: [FocusSession], in interval: DateInterval, calendar: Calendar) -> FocusWeek {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        let inWeek = all.filter { interval.contains($0.start) }.sorted { $0.start > $1.start }
        let perDay = days.map { day in inWeek.filter { calendar.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + length($1) } }
        return FocusWeek(interval: interval, days: days, perDay: perDay, sessions: inWeek)
    }
}
