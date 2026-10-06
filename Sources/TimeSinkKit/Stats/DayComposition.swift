import Foundation

/// 构成: a day's recorded time cut into five-minute slots, each slot's seconds
/// split by project and by category. Parallel work shows up as slots shared by
/// several projects, which a session-sized block can only grey out.
struct DayComposition: Sendable, Equatable {
    static let slot: TimeInterval = 300
    /// The project key of time that belongs to no project.
    static let noProject = ""

    struct Slot: Sendable, Equatable {
        var project: [String: TimeInterval] = [:]
        var category: [String: TimeInterval] = [:]
        var total: TimeInterval { category.values.reduce(0, +) }

        func parts(_ colors: TimelineColors) -> [String: TimeInterval] { colors == .project ? project : category }
    }

    /// The day's start: slot `i` is `origin + i * slot`.
    let origin: Date
    let slots: [Slot]
    /// Each key's time over the day, most first (no project last).
    let projectTotals: [(id: String, seconds: TimeInterval)]
    let categoryTotals: [(id: String, seconds: TimeInterval)]

    static func == (a: Self, b: Self) -> Bool { a.origin == b.origin && a.slots == b.slots }

    func start(of index: Int) -> Date { origin.addingTimeInterval(Double(index) * Self.slot) }

    func totals(_ colors: TimelineColors) -> [(id: String, seconds: TimeInterval)] { colors == .project ? projectTotals : categoryTotals }

    /// `assigned`: sessions whose project the person set, which wins over Jev. `verdict`: the project
    /// Jev names for a span, nil for none or unsure. A span that crosses a slot's edge is split at it.
    static func make(items: [CategorizedSpan], day: DateInterval, assigned: [(interval: DateInterval, project: String)],
                     verdict: (Span) -> String?) -> DayComposition {
        var slots = [Slot](repeating: Slot(), count: max(1, Int((day.duration / slot).rounded(.up))))
        for item in items {
            let start = max(item.span.start, day.start), end = min(item.span.end, day.end)
            guard end > start else { continue }
            let jev = verdict(item.span)
            let first = Int(start.timeIntervalSince(day.start) / slot)
            let last = min(slots.count - 1, Int(((end.timeIntervalSince(day.start)) / slot).rounded(.up)) - 1)
            guard first <= last else { continue }
            for index in first...last {
                let from = max(start, day.start.addingTimeInterval(Double(index) * slot))
                let to = min(end, day.start.addingTimeInterval(Double(index + 1) * slot))
                let seconds = to.timeIntervalSince(from)
                guard seconds > 0 else { continue }
                let middle = from.addingTimeInterval(seconds / 2)
                let project = assigned.first { $0.interval.start <= middle && middle < $0.interval.end }?.project ?? jev ?? noProject
                slots[index].project[project, default: 0] += seconds
                slots[index].category[item.categoryID, default: 0] += seconds
            }
        }
        func totals(_ part: KeyPath<Slot, [String: TimeInterval]>) -> [(id: String, seconds: TimeInterval)] {
            var sum: [String: TimeInterval] = [:]
            for slot in slots { for (id, seconds) in slot[keyPath: part] { sum[id, default: 0] += seconds } }
            return sum.sorted {
                // No project last; otherwise most time first.
                if ($0.key == noProject) != ($1.key == noProject) { return $1.key == noProject }
                return $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.map { (id: $0.key, seconds: $0.value) }
        }
        return DayComposition(origin: day.start, slots: slots, projectTotals: totals(\.project), categoryTotals: totals(\.category))
    }
}

extension AppModel {
    /// The day's 构成, binned off the main actor. A session you assigned to a project keeps it for every
    /// window in it; the rest take the project Jev named for the window.
    func composition(of items: [CategorizedSpan], day: DateInterval, sessions: [WorkSession]) async -> DayComposition {
        loadSessionOverrides()
        // A project you typed in other letters is still the project of that name.
        let canonical = Dictionary(projects.map { (SessionProjectResolver.normalized($0.name), $0.name) }, uniquingKeysWith: { a, _ in a })
        let assigned = sessions.compactMap { session -> (interval: DateInterval, project: String)? in
            guard let name = sessionOverrides[session.signature]?.project, !name.isEmpty else { return nil }
            return (DateInterval(start: session.start, end: max(session.start, session.end)), canonical[SessionProjectResolver.normalized(name)] ?? name)
        }
        let verdicts = resolver.projectsJudged ? resolver.projectVerdicts : [:]
        let names = projectNames
        return await Task.detached(priority: .userInitiated) {
            DayComposition.make(items: items, day: day, assigned: assigned) { span in
                guard let found = verdicts[VerdictKey(span)], found.projectID != JevPrompt.noProject else { return nil }
                return names[found.projectID]
            }
        }.value
    }
}
