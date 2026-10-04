import Foundation

/// Candidate projects found from the last two weeks of records, with local
/// signals only: nothing leaves the machine and nothing is added by itself.
/// The person accepts, edits or ignores each one.
public enum ProjectSuggester {
    /// How far back the signals are read.
    public static let lookbackDays = 14
    /// Recommendations wait for this much to go on...
    static let minDays = 3
    static let minRecorded: TimeInterval = 8 * 3600
    /// ...and a day with at least this much recorded counts as a day with data.
    static let dayWithData: TimeInterval = 30 * 60
    /// A candidate needs this much time, on this many different days.
    static let minSeconds: TimeInterval = 3600
    static let minCandidateDays = 2
    static let maxCandidates = 8

    /// Where a name was seen.
    public enum Source: Int, Comparable, CaseIterable, Sendable {
        case claudeCode, terminal, github, folder
        public static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .claudeCode: String(localized: "Claude Code 窗口")
            case .terminal: String(localized: "终端和编辑器")
            case .github: String(localized: "GitHub")
            case .folder: String(localized: "文件夹")
            }
        }
    }

    public struct Candidate: Equatable, Identifiable, Sendable {
        public var name: String
        public var seconds: TimeInterval
        public var days: Int
        public var sources: [Source]
        public var id: String { SessionProjectResolver.normalized(name) }

        /// "Seen in Claude Code windows and the terminal, 12h over 6 days".
        public var summary: String {
            let where_ = sources.map(\.label).joined(separator: String(localized: "、"))
            return String(localized: "出现在\(where_)，共 \(Format.duration(seconds))，分布在 \(days) 天")
        }
    }

    public struct Gate: Equatable, Sendable {
        /// Days with at least 30 minutes recorded.
        public var days: Int
        public var recorded: TimeInterval
        public var isOpen: Bool { days >= ProjectSuggester.minDays && recorded >= ProjectSuggester.minRecorded }
    }

    public struct Result: Equatable, Sendable {
        public var gate: Gate
        /// Empty while the gate is closed.
        public var candidates: [Candidate]
        /// The one Today offers unprompted: seen on at least three different days.
        public var todoCandidate: Candidate? { candidates.first { $0.days >= ProjectSuggester.todoDays } }
    }
    static let todoDays = 3

    /// Words and apps that are never a project.
    static let generic: Set<String> = [
        "claude", "claudecode", "chatgpt", "ghostty", "terminal", "iterm", "iterm2", "electron", "googlechrome", "chrome", "safari",
        "firefox", "arc", "newtab", "untitled", "home", "desktop", "documents", "downloads", "projects", "project", "code",
        "xcode", "finder", "cursor", "vscode", "visualstudiocode", "github", "gitlab", "codex", "gemini", "tmp", "src", "users",
    ]

    /// `spans`: the last `lookbackDays` days of records. `existing`: names
    /// already projects, which are not offered again.
    public static func suggest(_ spans: [Span], existing: [String] = [], calendar: Calendar = .current) -> Result {
        let gate = gate(spans, calendar: calendar)
        guard gate.isOpen else { return Result(gate: gate, candidates: []) }
        return Result(gate: gate, candidates: candidates(spans, existing: existing, calendar: calendar))
    }

    static func gate(_ spans: [Span], calendar: Calendar) -> Gate {
        var perDay: [Date: TimeInterval] = [:]
        for span in spans { perDay[calendar.startOfDay(for: span.start), default: 0] += span.duration }
        return Gate(days: perDay.values.filter { $0 >= dayWithData }.count, recorded: perDay.values.reduce(0, +))
    }

    static func candidates(_ spans: [Span], existing: [String], calendar: Calendar) -> [Candidate] {
        struct Tally {
            var names: [String: TimeInterval] = [:]
            var seconds: TimeInterval = 0
            var days = Set<Date>()
            var sources = Set<Source>()
        }
        var tallies: [String: Tally] = [:]
        let apps = Set(spans.map { SessionProjectResolver.normalized($0.appName) })
        let skip = generic.union(apps).union(existing.map(SessionProjectResolver.normalized))
        for span in spans where span.duration > 0 {
            // A name counts once per span, however many signals gave it.
            var found: [String: Source] = [:]
            for (name, source) in names(in: span) {
                let key = SessionProjectResolver.normalized(name)
                guard key.count >= 2, !skip.contains(key), found[key] == nil else { continue }
                found[key] = source
                tallies[key, default: Tally()].names[name, default: 0] += span.duration
            }
            for (key, source) in found {
                tallies[key]!.seconds += span.duration
                tallies[key]!.days.insert(calendar.startOfDay(for: span.start))
                tallies[key]!.sources.insert(source)
            }
        }
        return tallies.values
            .filter { $0.seconds >= minSeconds && $0.days.count >= minCandidateDays }
            .map { tally in
                // Spelled the way it was seen most.
                let name = tally.names.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
                return Candidate(name: name, seconds: tally.seconds, days: tally.days.count, sources: tally.sources.sorted())
            }
            .sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
            .prefix(maxCandidates).map { $0 }
    }

    private static let claudeTitle = try! NSRegularExpression(pattern: #"^\W*(.+?)\s+[-–—]\s+Claude Code$"#)

    /// Every name the span's own fields point at, with where it came from.
    static func names(in span: Span) -> [(String, Source)] {
        var out: [(String, Source)] = []
        if let title = span.title, let m = claudeTitle.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let r = Range(m.range(at: 1), in: title) {
            out.append((String(title[r]), .claudeCode))
        }
        if let document = span.document, let path = DocumentIdentity.path(of: document) {
            let home = DocumentIdentity.homePath
            let parts = path.hasPrefix(home + "/") ? path.dropFirst(home.count + 1).split(separator: "/").map(String.init) : []
            // ~/Projects/<name>/...: a terminal's folder or an editor's file.
            if parts.count >= 2, parts[0].lowercased() == "projects" {
                out.append((parts[1], .terminal))
            } else if parts.count > 2 {
                // A folder with something under it that the segmenter would call a project.
                if let key = SessionSegmenter.projectKey(span) { out.append((key.label, .folder)) }
            }
        } else if let domain = span.domain, span.url != nil, ["github.com", "gitlab.com"].contains(domain),
                  let key = SessionSegmenter.projectKey(span) {
            out.append((key.label, .github))
        }
        return out
    }
}
