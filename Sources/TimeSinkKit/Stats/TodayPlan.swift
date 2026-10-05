import Foundation

/// Which colour a project wears. A project's colour is stored with it
/// (`UserProject.colorIndex`); the hash of its name only proposes the first
/// colour when the project is made, so the same project keeps its colour
/// everywhere and from day to day.
enum ProjectPalette {
    /// Colour slots; the design reserves one more for time with no project.
    static let slots = 8

    /// FNV-1a over the lowercased name. Swift's own `hashValue` changes on
    /// every launch, which would repaint every project each morning.
    static func preferredSlot(_ name: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return Int(hash % UInt64(slots))
    }

    /// The colour for a new project: its preferred slot if no live project
    /// uses it, else the first free one; all taken, the preferred slot.
    static func slot(for name: String, taken: Set<Int>) -> Int {
        let preferred = preferredSlot(name)
        if !taken.contains(preferred) { return preferred }
        return (0..<slots).first { !taken.contains($0) } ?? preferred
    }

    /// Stored colours by `SessionProjectResolver.normalized` name, for the views that colour by project.
    static func lookup(_ projects: [UserProject]) -> [String: Int] {
        Dictionary(projects.compactMap { project in
            (SessionProjectResolver.normalized(project.name), project.colorIndex ?? preferredSlot(project.name))
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// A session with no project of its own takes the project of a neighbour
/// doing the same kind of work close by. It is a guess, and the design shows
/// it as one until the person confirms it.
enum ProjectGuess {
    struct Resolved: Equatable {
        var project: String?
        var guessed: Bool
    }

    /// How far apart two sessions may be and still read as one stretch of work.
    static let reach: TimeInterval = 30 * 60

    /// `sessions` by start; `explicit[i]` is the project session `i` has
    /// from its own titles or from the person.
    static func resolve(_ sessions: [WorkSession], explicit: [String?]) -> [Resolved] {
        var result = explicit.map { Resolved(project: $0, guessed: false) }
        func joins(_ a: Int, _ b: Int) -> Bool {
            let (first, second) = a < b ? (a, b) : (b, a)
            return sessions[a].categoryID == sessions[b].categoryID
                && sessions[second].start.timeIntervalSince(sessions[first].end) <= reach
        }
        // Forward, then backward, so a run of unknowns takes the project
        // from whichever end has one.
        for index in sessions.indices.dropFirst() where result[index].project == nil {
            if let project = result[index - 1].project, joins(index - 1, index) { result[index] = Resolved(project: project, guessed: true) }
        }
        for index in sessions.indices.dropLast().reversed() where result[index].project == nil {
            if let project = result[index + 1].project, joins(index, index + 1) { result[index] = Resolved(project: project, guessed: true) }
        }
        return result
    }
}

/// A stretch of the day with nothing recorded.
struct DayGap: Equatable, Identifiable {
    var interval: DateInterval
    /// Still going: you are away right now.
    var ongoing: Bool
    var id: Date { interval.start }
}

/// The day, laid out for the Today page: every number the cards show,
/// worked out once off the view's body.
struct TodayPlan {
    struct Row: Identifiable {
        let session: WorkSession
        var id: Date { session.start }
        var project: String?
        var guessed: Bool
        /// Colour slot of the project; nil for no project.
        var slot: Int?
        /// No project, and Jev has not judged most of its windows yet: the block waits for an answer.
        var projectPending = false
        var interruptions: Int
        var switches: Int
        /// Continues from the day before: it starts as the day does.
        var carriesOver: Bool
    }

    struct Project: Identifiable {
        var name: String?
        var slot: Int?
        var seconds: TimeInterval
        var sessions: [Date]
        var guessedCount: Int
        var interruptions: Int
        /// Time since midnight that continued from the day before.
        var carriedSeconds: TimeInterval
        var id: String { name ?? "" }
    }

    struct CategoryRow: Identifiable {
        var id: String
        var name: String
        var colorHex: String
        var seconds: TimeInterval
        var engaged: Bool
    }

    enum Todo: Identifiable {
        case fill(DateInterval)
        case confirm(count: Int, projects: [String])
        case classify(seconds: TimeInterval, names: [String])
        case focus(lastDay: Date?, lastMinutes: Int?)
        /// A name that keeps turning up and is not a project yet.
        case newProject(name: String)
        var id: String {
            switch self {
            case .newProject(let name): return "project|\(name)"
            case .fill(let gap): return "fill|\(gap.start.timeIntervalSince1970)"
            case .confirm: return "confirm"
            case .classify: return "classify"
            case .focus: return "focus"
            }
        }
    }

    var day: DateInterval
    var now: Date
    var isToday: Bool
    var total: TimeInterval
    var engaged: TimeInterval
    var pulse: Int?
    var rows: [Row]
    var projects: [Project]
    var gaps: [DayGap]
    var axis: DateInterval
    /// Interruptions only, not peeks or pass-throughs.
    var interruptions: [SwitchEpisode]
    var categories: [CategoryRow]
    var todos: [Todo]
    var firstRecord: Date?
    /// What the person said about stretches away.
    var notes: [AwayNote]

    var hasRecords: Bool { total > 0 }
    var guessedRows: [Row] { rows.filter(\.guessed) }
    /// The session in progress, or the last one of the day.
    var current: Row? { rows.last }
    /// Whether `current` is still going: it ended within the session cut.
    var currentIsLive: Bool {
        guard isToday, let last = rows.last else { return false }
        return now.timeIntervalSince(last.session.end) <= 120
    }
    /// The row with the most interruptions, when more than one session ran.
    var messiest: Row? {
        guard rows.count > 1, let row = rows.max(by: { $0.interruptions < $1.interruptions }), row.interruptions > 0 else { return nil }
        return row
    }
    var carriedOver: Row? { rows.first(where: \.carriesOver) }

    // MARK: Helpers (pure)

    /// Gaps between sessions, and, today, the stretch since the last one.
    static func gaps(_ sessions: [WorkSession], now: Date, isToday: Bool,
                     minimum: TimeInterval = 300, trailingMinimum: TimeInterval = SessionSegmenter.defaultThreshold) -> [DayGap] {
        var result: [DayGap] = []
        for (previous, next) in zip(sessions, sessions.dropFirst()) where next.start.timeIntervalSince(previous.end) >= minimum {
            result.append(DayGap(interval: DateInterval(start: previous.end, end: next.start), ongoing: false))
        }
        if isToday, let last = sessions.last, now.timeIntervalSince(last.end) >= trailingMinimum {
            result.append(DayGap(interval: DateInterval(start: last.end, end: now), ongoing: true))
        }
        return result
    }

    /// What the timeline spans: from eight, or the hour of the first session
    /// if that is earlier, to midnight. A session that carries over from the
    /// day before does not pull the axis back to midnight; it is named
    /// above the chart instead.
    static func axis(_ sessions: [WorkSession], day: DateInterval, calendar: Calendar = .current) -> DateInterval {
        let eight = calendar.date(byAdding: .hour, value: 8, to: day.start) ?? day.start.addingTimeInterval(8 * 3600)
        var start = eight
        if let first = sessions.first(where: { $0.start.timeIntervalSince(day.start) >= 60 }), first.start < eight {
            start = calendar.dateInterval(of: .hour, for: first.start)?.start ?? first.start
        }
        return DateInterval(start: start, end: day.end)
    }

    /// Times the window in front changed, among the records of `interval`.
    static func switches(in interval: DateInterval, items: [CategorizedSpan]) -> Int {
        var count = 0
        var last: String?
        for item in items where item.span.end > interval.start && item.span.start < interval.end {
            let key = item.span.appBundleID + "\u{1F}" + (item.span.domain ?? "")
            if let last, last != key { count += 1 }
            last = key
        }
        return count
    }

    /// Whether a note names (most of) the gap already.
    static func isNoted(_ gap: DateInterval, by notes: [AwayNote]) -> Bool {
        notes.contains { note in
            let overlap = min(note.end, gap.end).timeIntervalSince(max(note.start, gap.start))
            return overlap >= gap.duration / 2
        }
    }

    // MARK: Build

    /// `explicit[i]` is session `i`'s own project, if it has one.
    static func build(overview: DayOverview, sessions: [WorkSession], explicit: [String?],
                      episodes: [SwitchEpisode], notes: [AwayNote], categories categoryByID: [String: Category],
                      lastFocus: (day: Date, minutes: Int)?, hasFocusToday: Bool,
                      isToday: Bool, newProject: String? = nil, colors: [String: Int] = [:], calendar: Calendar = .current) -> TodayPlan {
        let resolved = ProjectGuess.resolve(sessions, explicit: explicit)
        let interruptions = episodes.filter { $0.kind == .interruption }
        // A project's colour is the one stored with it; a name that is not one of the projects (a session you
        // named by hand) falls back to the colour its name proposes.
        func slot(_ name: String) -> Int { colors[SessionProjectResolver.normalized(name)] ?? ProjectPalette.preferredSlot(name) }

        let rows = zip(sessions, resolved).map { session, project in
            Row(session: session, project: project.project, guessed: project.guessed,
                slot: project.project.map(slot),
                projectPending: project.project == nil && session.projectPending,
                interruptions: interruptions.filter { $0.start >= session.start && $0.start < session.end }.count,
                switches: switches(in: DateInterval(start: session.start, end: max(session.end, session.start.addingTimeInterval(1))), items: overview.items),
                carriesOver: session.start.timeIntervalSince(overview.day.start) < 60)
        }

        var byProject: [String?: Project] = [:]
        for row in rows {
            var project = byProject[row.project] ?? Project(name: row.project, slot: row.slot, seconds: 0, sessions: [], guessedCount: 0, interruptions: 0, carriedSeconds: 0)
            project.seconds += row.session.recorded
            project.sessions.append(row.session.start)
            project.interruptions += row.interruptions
            if row.guessed { project.guessedCount += 1 }
            if row.carriesOver { project.carriedSeconds += row.session.recorded }
            byProject[row.project] = project
        }
        let projects = byProject.values.sorted {
            // No project last; otherwise most time first.
            if ($0.name == nil) != ($1.name == nil) { return $0.name != nil }
            return $0.seconds == $1.seconds ? ($0.name ?? "") < ($1.name ?? "") : $0.seconds > $1.seconds
        }

        let gaps = gaps(sessions, now: overview.now, isToday: isToday)
        let categories = overview.categories.map {
            CategoryRow(id: $0.id, name: $0.name, colorHex: $0.colorHex, seconds: $0.seconds, engaged: (categoryByID[$0.id]?.productivity ?? 0) >= 1)
        }
        let byCategory = Dictionary(overview.categories.map { ($0.id, $0.seconds) }) { a, _ in a }

        var todos: [Todo] = []
        if let gap = gaps.filter({ !$0.ongoing && $0.interval.duration >= 1800 && !isNoted($0.interval, by: notes) })
            .max(by: { $0.interval.duration < $1.interval.duration }) {
            todos.append(.fill(gap.interval))
        }
        let guessed = rows.filter(\.guessed)
        if !guessed.isEmpty {
            todos.append(.confirm(count: guessed.count, projects: Array(Set(guessed.compactMap(\.project))).sorted()))
        }
        var unknown: [String: TimeInterval] = [:]
        for item in overview.items where item.categoryID == "uncategorized" {
            unknown[item.span.domain ?? item.span.appName, default: 0] += item.span.duration
        }
        let unknownSeconds = unknown.values.reduce(0, +)
        if unknownSeconds >= 60 {
            todos.append(.classify(seconds: unknownSeconds,
                                   names: unknown.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3).map(\.key)))
        }
        if isToday, !hasFocusToday { todos.append(.focus(lastDay: lastFocus?.day, lastMinutes: lastFocus?.minutes)) }

        var plan = TodayPlan(day: overview.day, now: overview.now, isToday: isToday, total: overview.total, engaged: overview.engaged,
                         pulse: Aggregator.pulse(durationByCategory: byCategory, categories: categoryByID),
                         rows: rows, projects: projects, gaps: gaps, axis: axis(sessions, day: overview.day, calendar: calendar),
                         interruptions: interruptions, categories: categories, todos: todos, firstRecord: overview.firstRecord, notes: notes)
        if isToday { plan.setNewProject(newProject) }
        return plan
    }

    /// The "new project" todo: replaced, or removed for nil. It sits before the focus todo, and
    /// arrives after the rest of the plan when the suggestions take longer than the page.
    mutating func setNewProject(_ name: String?) {
        todos.removeAll { if case .newProject = $0 { return true } else { return false } }
        guard let name else { return }
        let at = todos.firstIndex { if case .focus = $0 { return true } else { return false } } ?? todos.endIndex
        todos.insert(.newProject(name: name), at: at)
    }
}
