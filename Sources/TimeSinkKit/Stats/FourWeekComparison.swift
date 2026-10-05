import Foundation

/// The last 28 days read as four weeks, oldest first, whatever range the
/// page shows: the last two weeks against the two before, and the leading
/// categories week by week. Built from the per-day, per-category totals
/// only, so nothing of the spans is kept.
struct FourWeekComparison: Sendable, Equatable {
    struct Row: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let colorHex: String
        /// Seconds in each of the four weeks, oldest first.
        let weeks: [TimeInterval]
        var total: TimeInterval { weeks.reduce(0, +) }
        /// The latest week against the one before it, in whole minutes.
        var delta: TimeInterval { Format.minuteDelta(weeks[3], weeks[2]) }
    }

    enum Headline: Sendable, Equatable {
        case same
        /// `delta` is signed (last two weeks minus the two before); `category`
        /// is the one that moved most in the same direction, if any.
        case changed(delta: TimeInterval, category: String?)
    }

    static let days = 28
    static let leading = 6
    /// A difference under this reads as "about the same".
    static let sameBelow: TimeInterval = 5 * 60

    let rows: [Row]
    /// Nil when the two weeks before have nothing recorded to compare with.
    let headline: Headline?

    init(daily: [(bucketStart: Date, categoryID: String, seconds: TimeInterval)], today: Date,
         categories: [String: Category], calendar: Calendar) {
        let todayStart = calendar.startOfDay(for: today)
        var weeks: [String: [TimeInterval]] = [:]
        var recent = 0.0, before = 0.0
        for entry in daily {
            let ago = calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.bucketStart), to: todayStart).day ?? -1
            guard (0..<Self.days).contains(ago) else { continue }
            weeks[entry.categoryID, default: [0, 0, 0, 0]][3 - ago / 7] += entry.seconds
            if ago < 14 { recent += entry.seconds } else { before += entry.seconds }
        }
        func name(_ id: String) -> String { categories[id]?.name ?? String(localized: "未分类") }
        let unsorted: [Row] = weeks.map { id, seconds in
            Row(id: id, name: name(id), colorHex: categories[id]?.colorHex ?? "#98989D", weeks: seconds)
        }
        let sorted = unsorted.sorted { (a: Row, b: Row) -> Bool in a.total == b.total ? a.id < b.id : a.total > b.total }
        rows = Array(sorted.prefix(Self.leading))

        guard before >= 60 else { headline = nil; return }
        let delta = Format.minuteDelta(recent, before)
        guard abs(delta) >= Self.sameBelow else { headline = .same; return }
        // The category that moved most the same way the total did.
        let mover = weeks.compactMap { id, seconds -> (id: String, change: TimeInterval)? in
            let change = Format.minuteDelta(seconds[2] + seconds[3], seconds[0] + seconds[1])
            return change * delta > 0 ? (id, change) : nil
        }.max { abs($0.change) == abs($1.change) ? $0.id > $1.id : abs($0.change) < abs($1.change) }
        headline = .changed(delta: delta, category: mover.map { name($0.id) })
    }
}
