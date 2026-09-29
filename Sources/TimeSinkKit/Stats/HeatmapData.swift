import Foundation

/// Calendar-hour summaries shared by the heatmap preview and its date drill-down.
struct HeatmapData: Sendable {
    struct Key: Hashable, Identifiable, Sendable {
        let weekday: Int // Monday = 0
        let hour: Int
        var id: Int { weekday * 24 + hour }
        var weekdayLabel: String { [String(localized: "周一"), String(localized: "周二"), String(localized: "周三"), String(localized: "周四"), String(localized: "周五"), String(localized: "周六"), String(localized: "周日")][weekday] }
        /// In the reader's clock (12- or 24-hour) rather than a fixed pattern.
        func timeLabel(_ locale: Locale) -> String {
            let start = Self.date(hour: hour), style = Date.FormatStyle.dateTime.hour().minute().locale(locale)
            return "\(start.formatted(style))–\(start.addingTimeInterval(3600).formatted(style))"
        }
        func label(_ locale: Locale) -> String { "\(weekdayLabel) · \(timeLabel(locale))" }
        static func hourLabel(_ hour: Int, locale: Locale) -> String {
            date(hour: hour).formatted(.dateTime.hour(.defaultDigits(amPM: .narrow)).locale(locale))
        }
        private static func date(hour: Int) -> Date {
            let day = Calendar.current.startOfDay(for: Date())
            return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
    }

    struct Contribution: Identifiable, Sendable {
        let id: String
        let name: String
        let seconds: TimeInterval
        let colorHex: String?
    }

    struct Day: Identifiable, Sendable {
        var id: Date { interval.start }
        let date: Date
        let interval: DateInterval
        let seconds: TimeInterval
        let pulse: Int?
    }

    struct Cell: Identifiable, Sendable {
        var id: Key { key }
        let key: Key
        let seconds: TimeInterval
        let pulse: Int?
        let categories: [Contribution]
        let apps: [Contribution]
        let days: [Day]
        let availableDays: Int
        let recordedDays: Int
        let accessibilitySummary: String
        var averageSeconds: TimeInterval { seconds / Double(max(1, availableDays)) }
        var isLowSample: Bool { seconds > 0 && seconds < 900 }
        var scoreLabel: String {
            seconds == 0 ? String(localized: "无记录") : (isLowSample ? String(localized: "样本不足") : String(localized: "\(pulse ?? 0) 分"))
        }
        init(key: Key, seconds: TimeInterval, pulse: Int?, categories: [Contribution], apps: [Contribution], days: [Day]) {
            self.key = key
            self.seconds = seconds
            self.pulse = pulse
            self.categories = categories
            self.apps = apps
            self.days = days
            availableDays = Set(days.map(\.date)).count
            recordedDays = Set(days.filter { $0.seconds > 0 }.map(\.date)).count
            let score = seconds == 0 ? String(localized: "无记录") : (seconds < 900 ? String(localized: "样本不足") : String(localized: "\(pulse ?? 0) 分"))
            let average = seconds / Double(max(1, availableDays))
            accessibilitySummary = String(localized: "\(score)，累计 \(Format.duration(seconds))，每个\(key.weekdayLabel)平均 \(Format.duration(average))，\(availableDays) 天中有 \(recordedDays) 天记录")
        }
    }

    let window: DateInterval
    let cells: [Cell]
    subscript(_ key: Key) -> Cell { cells[key.id] }
    let suggestedKey: Key
    init(window: DateInterval, cells: [Cell]) {
        self.window = window
        self.cells = cells
        suggestedKey = cells.max { $0.seconds < $1.seconds }?.key ?? Key(weekday: 0, hour: 0)
    }

    private struct Totals {
        var byCategory: [String: TimeInterval] = [:]
        var byApp: [String: TimeInterval] = [:]
        var appNames: [String: String] = [:]
        var seconds: TimeInterval { byCategory.values.reduce(0, +) }
        mutating func add(_ item: CategorizedSpan, seconds: TimeInterval) {
            byCategory[item.categoryID, default: 0] += seconds
            byApp[item.span.appBundleID, default: 0] += seconds
            appNames[item.span.appBundleID] = item.span.appName
        }
    }

    static func build(_ items: [CategorizedSpan], categories: [String: Category],
                      window: DateInterval, now: Date = Date(), calendar: Calendar = .current) -> Self {
        let cutoff = max(window.start, min(now, window.end))
        var byHour: [Date: Totals] = [:]
        var byCell: [Key: Totals] = [:]
        var splitter = Aggregator.BucketSplitter(component: .hour, calendar: calendar)
        for item in items {
            var clipped = item
            clipped.span.start = max(item.span.start, window.start)
            clipped.span.end = min(item.span.end, cutoff)
            guard clipped.span.end > clipped.span.start else { continue }
            for part in splitter.split(clipped.span) {
                let key = Key(weekday: (calendar.component(.weekday, from: part.bucketStart) + 5) % 7,
                              hour: calendar.component(.hour, from: part.bucketStart))
                byHour[part.bucketStart, default: Totals()].add(item, seconds: part.seconds)
                byCell[key, default: Totals()].add(item, seconds: part.seconds)
            }
        }
        var days: [Key: [Day]] = [:]
        var cursor = window.start
        while cursor < cutoff, let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor {
            let key = Key(weekday: (calendar.component(.weekday, from: hour.start) + 5) % 7,
                          hour: calendar.component(.hour, from: hour.start))
            let totals = byHour[hour.start] ?? Totals()
            days[key, default: []].append(Day(date: calendar.startOfDay(for: hour.start),
                interval: DateInterval(start: max(window.start, hour.start), end: min(window.end, hour.end)),
                seconds: totals.seconds, pulse: Aggregator.pulse(durationByCategory: totals.byCategory, categories: categories)))
            cursor = hour.end
        }
        let cells = (0..<168).map { index -> Cell in
            let key = Key(weekday: index / 24, hour: index % 24)
            let totals = byCell[key] ?? Totals()
            let rankedCategories = totals.byCategory.map { id, seconds in
                Contribution(id: id, name: categories[id]?.name ?? id, seconds: seconds, colorHex: categories[id]?.colorHex)
            }.sorted(by: ranked)
            let rankedApps = totals.byApp.map { id, seconds in
                Contribution(id: id, name: totals.appNames[id] ?? id, seconds: seconds, colorHex: nil)
            }.sorted(by: ranked)
            return Cell(key: key, seconds: totals.seconds,
                pulse: Aggregator.pulse(durationByCategory: totals.byCategory, categories: categories),
                categories: rankedCategories, apps: rankedApps,
                days: (days[key] ?? []).sorted { $0.interval.start > $1.interval.start })
        }
        return Self(window: window, cells: cells)
    }

    private static func ranked(_ lhs: Contribution, _ rhs: Contribution) -> Bool {
        lhs.seconds == rhs.seconds ? lhs.id < rhs.id : lhs.seconds > rhs.seconds
    }
}

/// One focus stop for 168 cells. Mouse preview never replaces a pinned selection.
struct HeatmapInteraction {
    var hovered: HeatmapData.Key?
    var cursor: HeatmapData.Key?
    var pinned: HeatmapData.Key?
    func preview(fallback: HeatmapData.Key) -> HeatmapData.Key { pinned ?? hovered ?? cursor ?? fallback }
    mutating func move(horizontal: Int = 0, vertical: Int = 0, fallback: HeatmapData.Key) {
        let current = cursor ?? pinned ?? hovered ?? fallback
        let next = HeatmapData.Key(weekday: min(6, max(0, current.weekday + vertical)),
                                  hour: min(23, max(0, current.hour + horizontal)))
        cursor = next
        hovered = nil
        if pinned != nil { pinned = next }
    }
    mutating func select(_ key: HeatmapData.Key) {
        cursor = key
        pinned = pinned == key ? nil : key
    }
    mutating func dismiss() { pinned = nil; hovered = nil }
}
