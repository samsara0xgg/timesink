import Foundation

/// What counts as an interruption (decided 2026-09-30): switching away alone
/// never does. Leaving a productive window starts an episode that lasts
/// until a productive window is back in front; only the time spent in
/// distracting categories inside it counts, and it becomes an interruption
/// when you stayed there long enough or typed there.
public struct InterruptionRule: Sendable, Equatable, Hashable {
    /// Dwell at which a switch becomes an interruption: 15, 30 or 60 s.
    public var dwell: TimeInterval
    /// Whether two key-seconds in the distracting window also count.
    public var countsTyping: Bool

    public init(dwell: TimeInterval = 15, countsTyping: Bool = true) {
        self.dwell = dwell
        self.countsTyping = countsTyping
    }

    public static let dwellChoices: [TimeInterval] = [15, 30, 60]
    /// Under this, a switch is a ⌘⇥ pass-through: not counted, not drawn.
    public static let pass: TimeInterval = 3
    /// Key-seconds that mean you typed there.
    public static let typedKeySeconds = 2
    /// Returns to the same destination within this count once.
    public static let repeatWindow: TimeInterval = 60
    /// Only these count as candidates. Uncategorized and misc time never
    /// does -- it is listed for sorting instead.
    public static let distractingCategories: Set<String> = ["communication", "socialMedia", "entertainment", "shopping", "news"]
    /// Productivity at which a category is work you can be interrupted from.
    public static let productiveFloor = 1
}

public struct SwitchEpisode: Sendable, Equatable, Identifiable {
    public enum Kind: Int, Sendable, Comparable {
        case pass, peek, interruption
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    public enum Reason: Sendable, Equatable { case typed, stayed }

    /// When the productive window was left.
    public var start: Date
    /// When a productive window came back (or the episode was cut by away
    /// time or the end of the data).
    public var end: Date
    public var dwell: TimeInterval
    public var keySeconds: Int
    /// The distracting window that held the most dwell: its activity row.
    public var destination: String
    public var destinationLabel: String
    public var destinationBundleID: String
    public var destinationCategoryID: String
    /// Category of the productive window that was left.
    public var originCategoryID: String
    public var kind: Kind
    public var reason: Reason?
    /// Visits folded in by the repeat window; 1 for a single visit.
    public var visits: Int
    /// Whether a productive window came back (false when away time or the
    /// end of the data cut it).
    public var returned: Bool

    public var id: Date { start }
}

/// Classifies a day's switch-outs. Pure and O(n) in spans, so it runs
/// wherever the spans already are; callers cache the result per day.
public enum InterruptionClassifier {
    /// A gap longer than this is away time (idle, lock, pause): it ends the
    /// episode and forgets the origin, so coming back to a chat after lunch
    /// is not an interruption of work.
    public static let awayGap: TimeInterval = 30

    public static func episodes(_ items: [CategorizedSpan], productivity: [String: Int],
                                rule: InterruptionRule = InterruptionRule()) -> [SwitchEpisode] {
        struct Open {
            var start: Date
            var end: Date
            var dwell: TimeInterval = 0
            var keySeconds = 0
            var byDestination: [String: (seconds: TimeInterval, label: String, bundleID: String, categoryID: String)] = [:]
        }
        let sorted = items.filter { $0.span.end > $0.span.start }.sorted { $0.span.start < $1.span.start }
        var result: [SwitchEpisode] = []
        var origin: String?
        var open: Open?
        var lastEnd = Date.distantPast

        func finish(returned: Bool) {
            defer { open = nil }
            guard let episode = open, let origin, episode.dwell > 0,
                  let lead = episode.byDestination.max(by: { $0.value.seconds == $1.value.seconds ? $0.key > $1.key : $0.value.seconds < $1.value.seconds })
            else { return }
            let typed = rule.countsTyping && episode.keySeconds >= InterruptionRule.typedKeySeconds
            let kind: SwitchEpisode.Kind = episode.dwell < InterruptionRule.pass ? .pass
                : typed || episode.dwell >= rule.dwell ? .interruption : .peek
            result.append(SwitchEpisode(
                start: episode.start, end: episode.end, dwell: episode.dwell, keySeconds: episode.keySeconds,
                destination: lead.key, destinationLabel: lead.value.label, destinationBundleID: lead.value.bundleID,
                destinationCategoryID: lead.value.categoryID, originCategoryID: origin, kind: kind,
                reason: kind == .interruption ? (typed ? .typed : .stayed) : nil, visits: 1, returned: returned))
        }

        for item in sorted {
            let span = item.span
            if span.start.timeIntervalSince(lastEnd) > awayGap {
                finish(returned: false)
                origin = nil
            }
            lastEnd = max(lastEnd, span.end)
            if (productivity[item.categoryID] ?? 0) >= InterruptionRule.productiveFloor {
                finish(returned: true)
                origin = item.categoryID
                continue
            }
            guard let originCategory = origin else { continue }
            if open == nil { open = Open(start: span.start, end: span.end) }
            open!.end = max(open!.end, span.end)
            guard InterruptionRule.distractingCategories.contains(item.categoryID),
                  item.categoryID != originCategory else { continue }
            let identity = ActivityIdentity(item)
            let key = identity.selection.rowID + "\u{1F}" + (span.title ?? "")
            open!.dwell += span.duration
            open!.keySeconds += span.keySeconds
            let prior = open!.byDestination[key]?.seconds ?? 0
            open!.byDestination[key] = (prior + span.duration, identity.rowLabel, span.appBundleID, item.categoryID)
        }
        finish(returned: false)
        return mergingRepeats(result)
    }

    /// Returns to the same destination within `repeatWindow` of the last
    /// counted visit there count once: the stronger class wins, dwell and
    /// key-seconds add up.
    static func mergingRepeats(_ episodes: [SwitchEpisode]) -> [SwitchEpisode] {
        var merged: [SwitchEpisode] = []
        var lastCounted: [String: Int] = [:]
        for episode in episodes {
            guard episode.kind != .pass else { merged.append(episode); continue }
            if let index = lastCounted[episode.destination],
               episode.start.timeIntervalSince(merged[index].end) <= InterruptionRule.repeatWindow {
                var into = merged[index]
                into.end = max(into.end, episode.end)
                into.dwell += episode.dwell
                into.keySeconds += episode.keySeconds
                into.visits += 1
                into.returned = episode.returned
                if episode.kind > into.kind { into.kind = episode.kind; into.reason = episode.reason }
                else if into.reason == .stayed, episode.reason == .typed { into.reason = .typed }
                merged[index] = into
                continue
            }
            lastCounted[episode.destination] = merged.count
            merged.append(episode)
        }
        return merged
    }
}

/// A day's episodes with the counts every surface reads.
public struct DayInterruptions: Sendable, Equatable {
    public var episodes: [SwitchEpisode]
    /// Focus attempts the focus session blocked, drawn as hollow ticks.
    public var blocked: [Date]

    public init(episodes: [SwitchEpisode] = [], blocked: [Date] = []) {
        self.episodes = episodes
        self.blocked = blocked
    }

    public var interruptions: [SwitchEpisode] { episodes.filter { $0.kind == .interruption } }
    public var peeks: [SwitchEpisode] { episodes.filter { $0.kind == .peek } }
    public var passes: Int { episodes.filter { $0.kind == .pass }.count }

    /// Interruptions by destination, most first.
    public struct Source: Sendable, Equatable, Identifiable {
        public var destination: String
        public var label: String
        public var bundleID: String
        public var categoryID: String
        public var count: Int
        public var typed: Int
        public var seconds: TimeInterval
        public var peeks: Int
        public var id: String { destination }
    }

    public var sources: [Source] {
        var byKey: [String: Source] = [:]
        for episode in interruptions {
            var source = byKey[episode.destination] ?? Source(destination: episode.destination, label: episode.destinationLabel,
                                                              bundleID: episode.destinationBundleID,
                                                              categoryID: episode.destinationCategoryID,
                                                              count: 0, typed: 0, seconds: 0, peeks: 0)
            source.count += 1
            source.seconds += episode.dwell
            if episode.reason == .typed { source.typed += 1 }
            byKey[episode.destination] = source
        }
        for episode in peeks where byKey[episode.destination] != nil { byKey[episode.destination]!.peeks += 1 }
        return byKey.values.sorted { $0.count == $1.count ? $0.seconds > $1.seconds : $0.count > $1.count }
    }

    /// Interruptions per hour of the day.
    public func byHour(calendar: Calendar = .current) -> [Int] {
        var hours = Array(repeating: 0, count: 24)
        for episode in interruptions { hours[calendar.component(.hour, from: episode.start)] += 1 }
        return hours
    }

    /// Longest stretch between `from` and `to` that no interruption and no
    /// away gap broke.
    public func longestUnbroken(activity: [DateInterval]) -> DateInterval? {
        var best: DateInterval?
        for stretch in activity {
            var cursor = stretch.start
            for episode in interruptions where episode.start < stretch.end && episode.end > stretch.start {
                if episode.start > cursor, best.map({ episode.start.timeIntervalSince(cursor) > $0.duration }) ?? true {
                    best = DateInterval(start: cursor, end: episode.start)
                }
                cursor = max(cursor, episode.end)
            }
            if stretch.end > cursor, best.map({ stretch.end.timeIntervalSince(cursor) > $0.duration }) ?? true {
                best = DateInterval(start: cursor, end: stretch.end)
            }
        }
        return best
    }
}
