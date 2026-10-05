import Foundation

/// Which project a session belongs to when more than one source has a say.
/// Priority: your own assignment, then what Jev made of the session's
/// windows, then the repo or folder the segmenter found.
enum SessionProjectResolver {
    /// A project must hold this share of the session's time on windows judged to be in some project...
    static let minShareOfProjectTime = 0.5
    /// ...and this share of everything the session recorded...
    static let minShareOfRecorded = 0.25
    /// ...with this time-weighted mean probability.
    static let minProbability = 0.6
    /// A session is waiting for Jev when at least this share of it is on windows with no verdict yet.
    static let pendingShare = 0.5

    /// The project Jev's verdicts name for the session's spans, or nil when no
    /// project is clear enough ("unsure" counts as no project). Windows judged
    /// 'none' (a chat, an untitled assistant window) are left out of the
    /// comparison between projects, so they cannot dilute it; they still count
    /// in what the session recorded. `items` are the session's spans, already clipped.
    static func jevProjectID(of items: [CategorizedSpan], verdict: (Span) -> ProjectVerdict?) -> String? {
        var seconds: [String: TimeInterval] = [:], weighted: [String: Double] = [:]
        var recorded: TimeInterval = 0, inProjects: TimeInterval = 0
        for item in items {
            let length = item.span.duration
            recorded += length
            guard let v = verdict(item.span), !v.projectID.isEmpty, v.projectID != JevPrompt.noProject else { continue }
            seconds[v.projectID, default: 0] += length
            weighted[v.projectID, default: 0] += length * v.prob
            inProjects += length
        }
        guard recorded > 0, inProjects > 0,
              let top = seconds.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
              top.value >= inProjects * minShareOfProjectTime, top.value >= recorded * minShareOfRecorded,
              weighted[top.key, default: 0] / top.value >= minProbability
        else { return nil }
        return top.key
    }

    /// Whether the session is mostly on windows Jev has not judged for a project yet.
    static func isPending(_ items: [CategorizedSpan], verdict: (Span) -> ProjectVerdict?) -> Bool {
        var recorded: TimeInterval = 0, unjudged: TimeInterval = 0
        for item in items {
            recorded += item.span.duration
            if verdict(item.span) == nil { unjudged += item.span.duration }
        }
        return recorded > 0 && unjudged >= recorded * pendingShare
    }

    /// A user project's name for a rule-derived label, ignoring case, spaces
    /// and punctuation: the repo `jarvis` is the project "Jarvis", `time-sink` is "Time Sink".
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// `override`: the person's own assignment. `jev`: the name of the
    /// project Jev chose. `ruleLabel`: the repo or folder label.
    static func resolve(override: String?, jev: String?, ruleLabel: String?, userNames: [String]) -> String? {
        if let override, !override.isEmpty { return override }
        if let jev { return jev }
        guard let ruleLabel else { return nil }
        let key = normalized(ruleLabel)
        return userNames.first { normalized($0) == key } ?? ruleLabel
    }
}
