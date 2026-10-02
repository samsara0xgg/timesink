import Foundation

/// Pure axis helpers so charts are trimmed to their data instead of fixed 0–24 / 0–60 frames.
enum ChartAxis {
    /// Hour totals axis: 4 h steps (at least 0–8 h), widened to keep at most 5 intervals.
    static func hourScale(maxHours: Double) -> (top: Double, step: Double) {
        let step = 4 * max(1, ceil(maxHours / 20 - 1e-9))
        return (max(2 * step, ceil(maxHours / step - 1e-9) * step), step)
    }

    /// Minute axis for hour-of-day bars: 15-minute steps, at least 0–30, so a single
    /// day's chart stays within 0–60. Multi-day sums above an hour use whole-hour steps
    /// (at most 4 intervals).
    static func minuteScale(maxMinutes: Double) -> (top: Double, step: Double) {
        guard maxMinutes > 60 else { return (max(30, ceil(maxMinutes / 15 - 1e-9) * 15), 15) }
        let step = 60 * ceil(maxMinutes / 240 - 1e-9)
        return (ceil(maxMinutes / step - 1e-9) * step, step)
    }

    /// Hours [start, end) that contain data, widened to at least `minSpan` hours; nil when empty.
    static func hourSpan(_ hours: some Sequence<Int>, minSpan: Int = 3) -> Range<Int>? {
        guard let lo = hours.min(), let hi = hours.max() else { return nil }
        let end = min(24, max(hi + 1, lo + minSpan))
        return max(0, min(lo, end - minSpan))..<end
    }

    /// "四 24" (weekday without 周, day of month); today is "今天".
    static func dayLabel(_ day: Date, now: Date, calendar: Calendar, locale: Locale = AppLanguage.locale) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "今天") }
        // In the app's language, not the system's.
        var named = calendar
        named.locale = locale
        let weekday = named.veryShortStandaloneWeekdaySymbols[calendar.component(.weekday, from: day) - 1]
        return "\(weekday) \(calendar.component(.day, from: day))"
    }

    /// Every day when it fits, otherwise every n-th day counted back from the last one,
    /// so the most recent day (usually today) always keeps its label.
    static func labeledDays(_ days: [Date], maxLabels: Int = 10) -> [Date] {
        let stride = max(1, Int(ceil(Double(days.count) / Double(maxLabels))))
        return days.enumerated().filter { (days.count - 1 - $0.offset) % stride == 0 }.map(\.element)
    }

    /// Start of each day in `interval`.
    static func days(in interval: DateInterval, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

/// The language the interface is in (the person's choice in Settings, or the
/// system's), for dates written in words.
public enum AppLanguage {
    public static var locale: Locale { Locale(identifier: Locale.preferredLanguages.first ?? "en") }
}
