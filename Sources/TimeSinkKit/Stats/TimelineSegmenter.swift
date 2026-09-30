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
    /// A stretch inside the segment spent on another row than the dominant
    /// one -- a brief switch folded into the block.
    struct Excursion: Sendable, Equatable {
        let start: Date
        var seconds: TimeInterval
        var keySeconds: Int
        let categoryID: String
        let row: ActivitySelection
        let label: String
    }
    /// Every stretch away from the dominant row, in time order.
    let excursions: [Excursion]

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
/// 3. The shortest piece under `resolution` joins the neighbour it most
///    resembles (same leading row, then same leading category, then the
///    longer one), until every piece reaches the resolution. Brief switches
///    fold into the task around them; a stretch of back-and-forth becomes
///    one mixed segment, labelled by whichever row holds the most time.
/// 4. Neighbours with the same leading key merge.
///
/// `forDrawing` is for timelines drawn to scale: gaps under half the
/// resolution are closed, so one task reads as one block, and a stretch of
/// recording still too short to see is left out instead of drawn as a
/// hairline. Lists keep every recorded second and leave it off.
///
/// O(n log n) in the number of spans, so it can rerun on every zoom step.
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
                         forDrawing: Bool = false,
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
            let category: String
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
        let bridge = forDrawing ? max(bridge, resolution / 2) : bridge
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
                current.append(Run(start: start, end: max(span.end, start), key: entryKey,
                                   category: entries[index].identity.selection.categoryID, entries: [index]))
            }
            coveredUntil = max(coveredUntil, span.end)
        }
        if !current.isEmpty { islands.append(current) }

        func extent(_ runs: [Run]) -> TimeInterval {
            guard let first = runs.first, let last = runs.last else { return 0 }
            return last.end.timeIntervalSince(first.start)
        }
        if forDrawing { islands.removeAll { extent($0) < resolution } }

        func longest(_ seconds: [String: TimeInterval]) -> String {
            seconds.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
        }
        func leadingKey(_ runs: [Run]) -> String {
            longest(runs.reduce(into: [:]) { $0[$1.key, default: 0] += $1.duration })
        }

        // 3: shortest piece first, into the neighbour it most resembles.
        func smoothed(_ island: [Run]) -> [[Run]] {
            struct Piece {
                var runs: [Run]
                var seconds: [String: TimeInterval]
                var categorySeconds: [String: TimeInterval]
                var previous: Int?
                var next: Int?
                var version = 0
                var alive = true
                var extent: TimeInterval { runs[runs.count - 1].end.timeIntervalSince(runs[0].start) }
            }
            var pieces = island.indices.map { index in
                Piece(runs: [island[index]], seconds: [island[index].key: island[index].duration],
                      categorySeconds: [island[index].category: island[index].duration],
                      previous: index > 0 ? index - 1 : nil, next: index + 1 < island.count ? index + 1 : nil)
            }
            // A binary min-heap of (extent, piece, version); stale entries are skipped.
            var heap: [(extent: TimeInterval, index: Int, version: Int)] = []
            func before(_ a: (extent: TimeInterval, index: Int, version: Int), _ b: (extent: TimeInterval, index: Int, version: Int)) -> Bool {
                a.extent == b.extent ? a.index < b.index : a.extent < b.extent
            }
            func push(_ index: Int) {
                heap.append((pieces[index].extent, index, pieces[index].version))
                var child = heap.count - 1
                while child > 0, before(heap[child], heap[(child - 1) / 2]) {
                    heap.swapAt(child, (child - 1) / 2)
                    child = (child - 1) / 2
                }
            }
            func pop() -> (extent: TimeInterval, index: Int, version: Int)? {
                guard !heap.isEmpty else { return nil }
                heap.swapAt(0, heap.count - 1)
                let top = heap.removeLast()
                var parent = 0
                while true {
                    var smallest = parent
                    for child in [2 * parent + 1, 2 * parent + 2] where child < heap.count && before(heap[child], heap[smallest]) {
                        smallest = child
                    }
                    guard smallest != parent else { return top }
                    heap.swapAt(parent, smallest)
                    parent = smallest
                }
            }
            func resemblance(_ a: Piece, _ b: Piece) -> Int {
                if longest(a.seconds) == longest(b.seconds) { return 2 }
                return longest(a.categorySeconds) == longest(b.categorySeconds) ? 1 : 0
            }

            pieces.indices.forEach(push)
            while let top = pop() {
                let piece = pieces[top.index]
                guard piece.alive, piece.version == top.version else { continue }
                guard piece.extent < resolution, piece.previous != nil || piece.next != nil else { break }
                let target: Int = {
                    guard let previous = piece.previous else { return piece.next! }
                    guard let next = piece.next else { return previous }
                    let (a, b) = (resemblance(piece, pieces[previous]), resemblance(piece, pieces[next]))
                    if a != b { return a > b ? previous : next }
                    return pieces[next].extent > pieces[previous].extent ? next : previous
                }()
                if target == piece.previous {
                    pieces[target].runs += piece.runs
                    pieces[target].next = piece.next
                    if let next = piece.next { pieces[next].previous = target }
                } else {
                    pieces[target].runs = piece.runs + pieces[target].runs
                    pieces[target].previous = piece.previous
                    if let previous = piece.previous { pieces[previous].next = target }
                }
                pieces[target].seconds.merge(piece.seconds, uniquingKeysWith: +)
                pieces[target].categorySeconds.merge(piece.categorySeconds, uniquingKeysWith: +)
                pieces[target].version += 1
                pieces[top.index].alive = false
                push(target)
            }
            var blocks: [[Run]] = []
            var cursor = pieces.firstIndex { $0.alive && $0.previous == nil }
            while let index = cursor {
                blocks.append(pieces[index].runs)
                cursor = pieces[index].next
            }
            return blocks
        }

        var segments: [TimelineSegment] = []
        for island in islands {
            let blocks = smoothed(island)

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
                var visits: [(entry: Entry, row: ActivitySelection)] = []
                for run in block {
                    for index in run.entries {
                        let entry = entries[index]
                        visits.append((entry, entry.identity.selection.row))
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
                let sortedParts = parts.values.sorted { $0.seconds == $1.seconds ? $0.label < $1.label : $0.seconds > $1.seconds }
                let home = sortedParts[0].selection
                var excursions: [TimelineSegment.Excursion] = []
                var previous: ActivitySelection?
                for visit in visits {
                    defer { previous = visit.row }
                    guard visit.row != home else { continue }
                    let span = visit.entry.item.span
                    if previous == visit.row, var last = excursions.popLast() {
                        last.seconds += span.duration
                        last.keySeconds += span.keySeconds
                        excursions.append(last)
                    } else {
                        excursions.append(.init(start: span.start, seconds: span.duration, keySeconds: span.keySeconds,
                                                categoryID: visit.entry.item.categoryID, row: visit.row,
                                                label: visit.entry.identity.rowLabel))
                    }
                }
                segments.append(TimelineSegment(
                    start: start, end: max(end, start.addingTimeInterval(0.001)),
                    parts: sortedParts, spanCount: spanCount, switches: switches, firstStarts: firstStarts,
                    recorded: recorded, matchedSeconds: matched, excursions: excursions))
            }
        }
        return segments
    }

    /// The duration a mark `points` tall/wide represents at `pointsPerHour`.
    static func resolution(points: CGFloat, pointsPerHour: CGFloat) -> TimeInterval {
        TimeInterval(points / max(pointsPerHour, 1)) * 3600
    }
}
