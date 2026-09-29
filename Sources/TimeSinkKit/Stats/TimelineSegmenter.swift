import Foundation

/// One legible stretch of a timeline: a run of raw spans folded together
/// because each of them on its own would be too short to see at the current
/// scale. Every recorded second stays accounted for in `parts`.
struct TimelineSegment: Identifiable, Sendable {
    /// One activity row (document / URL entity / site / app) inside the
    /// segment, with its recorded time.
    struct Part: Identifiable, Sendable {
        /// Row-level selection (`title == nil`), the same key the activity
        /// list groups by.
        let selection: ActivitySelection
        let label: String
        let appBundleID: String
        let appName: String
        var seconds: TimeInterval
        var spanCount: Int
        var matchedSeconds: TimeInterval
        /// The longest raw span of this row inside the segment -- what the
        /// inspector opens when the part is picked.
        var longest: CategorizedSpan
        var id: ActivitySelection { selection }
        var categoryID: String { selection.categoryID }
    }

    let start: Date
    /// Tiled to the next segment's start inside one stretch of continuous
    /// recording, so blocks abut instead of leaving hairline seams.
    let end: Date
    /// Sorted by recorded seconds, longest first. Never empty.
    let parts: [Part]
    let spanCount: Int
    /// How many times the front activity changed inside the segment.
    let switches: Int
    /// First start inside the segment for every title-level selection it
    /// contains -- lets a list row or search hit find its segment and the
    /// exact raw span to inspect.
    let firstStarts: [ActivitySelection: Date]
    let recorded: TimeInterval
    let matchedSeconds: TimeInterval

    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var dominant: Part { parts[0] }
    /// The category holding the most time -- a segment's colour. Can differ
    /// from `dominant`'s when several rows share one category.
    var leadingCategoryID: String {
        var seconds: [String: TimeInterval] = [:]
        for part in parts { seconds[part.categoryID, default: 0] += part.seconds }
        return seconds.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
    }
    /// More than one row, and the leading one holds under 80% of the time.
    var isMixed: Bool { parts.count > 1 && dominant.seconds < recorded * 0.8 }

    func contains(_ selection: ActivitySelection) -> Bool {
        if selection.title == nil { return parts.contains { $0.selection == selection } }
        return firstStarts[selection] != nil
    }

    /// Where to point the inspector for `selection` inside this segment.
    func firstStart(of selection: ActivitySelection) -> Date? {
        if let exact = firstStarts[selection] { return exact }
        guard selection.title == nil else { return nil }
        return firstStarts.filter { $0.key.row == selection }.map(\.value).min()
    }
}

/// A span's display identity, computed once: the title-level selection the
/// activity list uses plus the row label it shows.
struct ActivityIdentity: Sendable {
    let selection: ActivitySelection
    let rowLabel: String

    init(_ item: CategorizedSpan) {
        let span = item.span
        let entity = span.domain.flatMap { domain in
            span.url.flatMap { EntityParser.entity(urlString: $0, domain: domain) }
        }
        let rowID = span.document.map { "\(span.appBundleID)/\($0)" }
            ?? entity?.key ?? span.domain ?? span.appBundleID
        selection = ActivitySelection(categoryID: item.categoryID, rowID: rowID,
                                      title: span.title?.isEmpty == false ? span.title! : String(localized: "(无标题)"))
        rowLabel = span.document.map { "\(span.appName) / \(DocumentIdentity.label(for: $0))" }
            ?? entity?.label ?? span.domain ?? span.appName
    }
}

/// Folds raw spans into `TimelineSegment`s no shorter than a resolution
/// (the duration of the smallest legible mark at the current zoom).
///
/// 1. Spans closer than `bridge` count as continuous; a longer gap is real
///    unrecorded time and is never painted over.
/// 2. Consecutive spans with the same grouping key form runs (titles never
///    split a run).
/// 3. A run at least `resolution` long stands on its own. Shorter runs are
///    gathered into chunks of about `resolution`, labelled by whichever row
///    holds the most time; a leftover sliver joins its neighbour.
/// 4. Neighbours with the same leading key merge.
///
/// Linear in the number of spans, so it can rerun on every zoom step.
enum TimelineSegmenter {
    enum Grouping: Sendable {
        /// Row level: document, URL entity, site or app -- the activity list's rows.
        case activity
        /// Category level: what a single-colour band can distinguish anyway.
        case category
    }

    /// Gaps up to this long are tick jitter or a brief lock, not time away.
    static let defaultBridge: TimeInterval = 30

    static func segments(_ items: [CategorizedSpan], resolution: TimeInterval,
                         bridge: TimeInterval = defaultBridge, grouping: Grouping = .activity,
                         matching: ((CategorizedSpan) -> Bool)? = nil) -> [TimelineSegment] {
        struct Entry {
            let item: CategorizedSpan
            let identity: ActivityIdentity
            let matched: Bool
        }
        struct Run {
            var start: Date
            var end: Date
            let key: String
            var entries: [Int]
            var duration: TimeInterval { end.timeIntervalSince(start) }
        }

        let entries = items.filter { $0.span.end > $0.span.start }
            .sorted { $0.span.start == $1.span.start ? $0.span.end < $1.span.end : $0.span.start < $1.span.start }
            .map { Entry(item: $0, identity: ActivityIdentity($0), matched: matching?($0) ?? false) }
        guard !entries.isEmpty else { return [] }

        func key(_ entry: Entry) -> String {
            switch grouping {
            case .activity: return entry.identity.selection.categoryID + "\u{1F}" + entry.identity.selection.rowID
            case .category: return entry.identity.selection.categoryID
            }
        }

        // 1-2: islands of continuous recording, each a list of runs.
        var islands: [[Run]] = []
        var current: [Run] = []
        var coveredUntil = Date.distantPast
        for index in entries.indices {
            let span = entries[index].item.span
            let entryKey = key(entries[index])
            if !current.isEmpty, span.start.timeIntervalSince(coveredUntil) > bridge {
                islands.append(current)
                current = []
            }
            if var last = current.last, last.key == entryKey {
                last.end = max(last.end, span.end)
                last.entries.append(index)
                current[current.count - 1] = last
            } else {
                // Overlapping spans start where the previous run ends.
                let start = current.last.map { max(span.start, $0.end) } ?? span.start
                current.append(Run(start: start, end: max(span.end, start), key: entryKey, entries: [index]))
            }
            coveredUntil = max(coveredUntil, span.end)
        }
        if !current.isEmpty { islands.append(current) }

        func leadingKey(_ runs: [Run]) -> String {
            var seconds: [String: TimeInterval] = [:]
            for run in runs { seconds[run.key, default: 0] += run.duration }
            return seconds.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
        }

        var segments: [TimelineSegment] = []
        for island in islands {
            // 3: anchors stand alone; slivers gather into chunks.
            var blocks: [[Run]] = []
            var pending: [Run] = []
            func pendingDuration() -> TimeInterval {
                guard let first = pending.first, let last = pending.last else { return 0 }
                return last.end.timeIntervalSince(first.start)
            }
            for run in island {
                if run.duration >= resolution {
                    if !pending.isEmpty {
                        if blocks.isEmpty { blocks.append(pending + [run]) }
                        else { blocks[blocks.count - 1] += pending; blocks.append([run]) }
                        pending = []
                    } else {
                        blocks.append([run])
                    }
                } else {
                    pending.append(run)
                    if pendingDuration() >= resolution {
                        blocks.append(pending)
                        pending = []
                    }
                }
            }
            if !pending.isEmpty {
                if blocks.isEmpty { blocks.append(pending) } else { blocks[blocks.count - 1] += pending }
            }

            // 4: neighbours led by the same key become one.
            var merged: [(runs: [Run], lead: String)] = []
            for block in blocks {
                let lead = leadingKey(block)
                if let last = merged.last, last.lead == lead {
                    merged[merged.count - 1].runs += block
                } else {
                    merged.append((block, lead))
                }
            }

            for (offset, (block, _)) in merged.enumerated() {
                var parts: [ActivitySelection: TimelineSegment.Part] = [:]
                var firstStarts: [ActivitySelection: Date] = [:]
                var spanCount = 0
                var recorded: TimeInterval = 0
                var matched: TimeInterval = 0
                var switches = 0
                var previousRow: ActivitySelection?
                for run in block {
                    for index in run.entries {
                        let entry = entries[index]
                        let seconds = entry.item.span.duration
                        let row = entry.identity.selection.row
                        spanCount += 1
                        recorded += seconds
                        if entry.matched { matched += seconds }
                        if let previousRow, previousRow != row { switches += 1 }
                        previousRow = row
                        if firstStarts[entry.identity.selection] == nil {
                            firstStarts[entry.identity.selection] = entry.item.span.start
                        }
                        if var part = parts[row] {
                            part.seconds += seconds
                            part.spanCount += 1
                            if entry.matched { part.matchedSeconds += seconds }
                            if seconds > part.longest.span.duration { part.longest = entry.item }
                            parts[row] = part
                        } else {
                            parts[row] = TimelineSegment.Part(
                                selection: row, label: entry.identity.rowLabel,
                                appBundleID: entry.item.span.appBundleID, appName: entry.item.span.appName,
                                seconds: seconds, spanCount: 1, matchedSeconds: entry.matched ? seconds : 0,
                                longest: entry.item)
                        }
                    }
                }
                let start = block.first!.start
                let end = offset + 1 < merged.count ? merged[offset + 1].runs.first!.start : block.map(\.end).max()!
                segments.append(TimelineSegment(
                    start: start, end: max(end, start.addingTimeInterval(0.001)),
                    parts: parts.values.sorted { $0.seconds == $1.seconds ? $0.label < $1.label : $0.seconds > $1.seconds },
                    spanCount: spanCount, switches: switches, firstStarts: firstStarts,
                    recorded: recorded, matchedSeconds: matched))
            }
        }
        return segments
    }

    /// The duration a mark `points` tall/wide represents at `pointsPerHour`.
    static func resolution(points: CGFloat, pointsPerHour: CGFloat) -> TimeInterval {
        TimeInterval(points / max(pointsPerHour, 1)) * 3600
    }
}
