import Foundation

/// Which project a session belongs to when more than one source has a say.
/// Priority: your own assignment, then what Jev made of the session's
/// windows, then the repo or folder the segmenter found.
enum SessionProjectResolver {
    /// Jev's project must hold this share of the session's recorded time...
    static let minShare = 0.5
    /// ...and its time-weighted mean probability must reach this.
    static let minProbability = 0.6

    /// The project Jev's verdicts name for the session's spans, or nil when
    /// no project is clear enough ("unsure" counts as no project). Verdicts
    /// of '', 'none' and archived projects never reach `verdict`.
    /// `items` are the session's spans, already clipped to it.
    static func jevProjectID(of items: [CategorizedSpan], verdict: (Span) -> ProjectVerdict?) -> String? {
        var seconds: [String: TimeInterval] = [:], weighted: [String: Double] = [:]
        var recorded: TimeInterval = 0
        for item in items {
            let length = item.span.duration
            recorded += length
            guard let v = verdict(item.span), !v.projectID.isEmpty, v.projectID != JevPrompt.noProject else { continue }
            seconds[v.projectID, default: 0] += length
            weighted[v.projectID, default: 0] += length * v.prob
        }
        guard recorded > 0,
              let top = seconds.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
              top.value >= recorded * minShare, weighted[top.key, default: 0] / top.value >= minProbability
        else { return nil }
        return top.key
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
