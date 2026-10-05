import Foundation

/// Recorded time per project over a stretch of days, worked out off the main
/// actor from a snapshot of everything the answer depends on.
enum ProjectHours {
    /// What the answer depends on. Equal keys give equal answers, so a result is reused while the key holds.
    struct Key: Equatable, Sendable {
        /// `AppModel.dataEditVersion`: your edits and Jev's new verdicts, not the tracker's own writes.
        var edits: Int
        /// Bumped when the project list is re-read.
        var projects: Int
        /// A hash of your session-to-project assignments.
        var assignments: Int
        var splits: Int
        var threshold: TimeInterval
        var day: Date
    }

    /// Everything the pass reads, copied so the pass never touches the main actor.
    struct Input: Sendable {
        var days: [DateInterval]
        var classification: CategoryResolver.Snapshot
        var threshold: TimeInterval
        var verdicts: [VerdictKey: ProjectVerdict]?
        var overrides: [String: SessionNameRow]
        var names: [String: String]
        var userNames: [String]
        var splits: [Date]
        var joins: [Date]
    }

    /// Seconds by `SessionProjectResolver.normalized(project name)`; sessions without a project are left out.
    static func seconds(spans: [Span], input: Input) -> [String: TimeInterval] {
        var classification = input.classification
        var result: [String: TimeInterval] = [:]
        for day in input.days {
            let items = spans.compactMap { span -> CategorizedSpan? in
                guard span.end > day.start, span.start < day.end else { return nil }
                var clipped = span
                clipped.start = max(span.start, day.start)
                clipped.end = min(span.end, day.end)
                return CategorizedSpan(span: clipped, categoryID: classification.categoryID(for: span))
            }
            let sessions = SessionSegmenter.sessions(items, threshold: input.threshold,
                                                     splits: input.splits.filter { day.contains($0) }, joins: input.joins.filter { day.contains($0) },
                                                     projectVerdicts: input.verdicts)
            for session in sessions {
                let project = SessionProjectResolver.resolve(override: input.overrides[session.signature]?.project,
                                                             jev: session.jevProjectID.flatMap { input.names[$0] },
                                                             ruleLabel: session.projectLabel, userNames: input.userNames)
                if let project { result[SessionProjectResolver.normalized(project), default: 0] += session.recorded }
            }
        }
        return result
    }
}
