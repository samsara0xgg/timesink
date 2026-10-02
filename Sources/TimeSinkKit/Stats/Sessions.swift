import Foundation

/// F1 会话: a stretch of connected work, cut where you left for a while or
/// where what you were doing changed and stayed changed.
public struct WorkSession: Sendable, Equatable, Identifiable {
    public struct App: Sendable, Equatable {
        public var bundleID: String
        public var name: String
        public var seconds: TimeInterval
    }
    public struct Title: Sendable, Equatable {
        public var appName: String
        public var title: String
        public var seconds: TimeInterval
    }

    public var start: Date
    public var end: Date
    public var recorded: TimeInterval
    /// The category holding the most recorded time.
    public var categoryID: String
    /// Repo, folder or site holding the most time, when one holds a fair
    /// share of it (`SessionSegmenter.projectKey`), with a display label.
    public var project: String?
    public var projectLabel: String?
    /// Longest first.
    public var apps: [App]
    /// Window titles by time held, longest first, at most 12: what a name
    /// is based on.
    public var titles: [Title]
    /// Folder, file, repo and conversation names, longest held first, at most 8.
    public var documents: [Title]

    public var id: Date { start }
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// What makes two sessions "the same kind": a rename or a project
    /// assignment is reused for every session with this signature.
    public var signature: String {
        if let project { return "p:" + project }
        return "a:" + apps.prefix(2).map(\.bundleID).sorted().joined(separator: ",") + "|" + categoryID
    }

    /// Changes only when the make-up changes materially (the leading apps,
    /// project or category), so a live session is not renamed on every write.
    public var composition: String {
        signature + "|" + apps.prefix(3).map(\.bundleID).sorted().joined(separator: ",") + "|" + categoryID
    }

    /// The per-session cache key for a name.
    public var nameKey: String { "\(Int(start.timeIntervalSince1970))|\(composition)" }
}

public enum SessionSegmenter {
    /// 设置 › 记录 › 会话: away this long, or a change that lasts this long,
    /// starts a new session.
    public static let defaultThreshold: TimeInterval = 600
    public static let thresholdChoices: [TimeInterval] = [300, 600, 900, 1800]
    /// A stretch shorter than this never counts as a change on its own: it
    /// reads as a glance inside whatever surrounds it.
    static let glance: TimeInterval = 60
    /// A project names the session only when it holds this share of it.
    static let projectShare = 0.3

    /// The repo, folder or site a span belongs to, normalised so the same
    /// project matches across apps: `~/Projects/timesink/Sources/x.swift` in
    /// an editor, `~/Projects/timesink` in a terminal and the
    /// `owner/timesink` page on GitHub all give `timesink`.
    public static func projectKey(_ span: Span) -> (key: String, label: String)? {
        if let document = span.document, let path = DocumentIdentity.path(of: document) {
            let home = DocumentIdentity.homePath
            let relative = path == home ? [] : path.hasPrefix(home + "/")
                ? path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
                : path.split(separator: "/").map(String.init)
            // ~/Projects/timesink/... -> timesink; ~/notes.md -> notes.md;
            // /opt/x/y/... -> y.
            let depth = path.hasPrefix(home + "/") ? 2 : 3
            guard let name = relative.prefix(depth).last, !name.isEmpty else { return nil }
            return (name.lowercased(), name)
        }
        guard let domain = span.domain else { return nil }
        if let url = span.url, let entity = EntityParser.entity(urlString: url, domain: domain) {
            let name = entity.label.split(separator: "/").last.map(String.init) ?? entity.label
            return (name.lowercased(), name)
        }
        return (domain, domain)
    }

    /// `items` sorted by start. `splits`: extra boundaries the user asked for.
    public static func sessions(_ items: [CategorizedSpan], threshold: TimeInterval = defaultThreshold,
                                splits: [Date] = []) -> [WorkSession] {
        let items = items.filter { $0.span.duration > 0 }
        guard !items.isEmpty else { return [] }

        // 1. Away: a gap of `threshold` or more always cuts.
        var chunks: [[CategorizedSpan]] = [[items[0]]]
        var reach = items[0].span.end
        for item in items.dropFirst() {
            if item.span.start.timeIntervalSince(reach) >= threshold { chunks.append([]) }
            chunks[chunks.count - 1].append(item)
            reach = max(reach, item.span.end)
        }

        var sessions: [WorkSession] = []
        for chunk in chunks {
            // 2. A category or project that stays changed for `threshold`.
            let changes = Set(lastingChanges(chunk.map { ($0.span.start, $0.span.end, $0.categoryID) }, threshold: threshold)
                + lastingChanges(chunk.map { ($0.span.start, $0.span.end, projectKey($0.span)?.key) }, threshold: threshold))
            let chunkStart = chunk[0].span.start
            let chunkEnd = chunk.map(\.span.end).max()!
            let userCuts = splits.filter { $0 > chunkStart && $0 < chunkEnd }
            // 3. A piece shorter than the threshold joins the next one (the
            // change it led into), or the previous one at the end.
            var cuts = changes.filter { $0 > chunkStart }.sorted()
            var merged = true
            while merged {
                merged = false
                let edges = [chunkStart] + cuts + [chunkEnd]
                for index in cuts.indices {
                    let before = edges[index + 1].timeIntervalSince(edges[index])
                    let after = edges[index + 2].timeIntervalSince(edges[index + 1])
                    if before < threshold || (index == cuts.count - 1 && after < threshold) {
                        cuts.remove(at: index)
                        merged = true
                        break
                    }
                }
            }
            let edges = [chunkStart] + Set(cuts + userCuts).sorted() + [chunkEnd]
            for (start, end) in zip(edges, edges.dropFirst()) {
                let pieces = chunk.compactMap { item -> CategorizedSpan? in
                    let s = max(item.span.start, start), e = min(item.span.end, end)
                    guard e > s else { return nil }
                    var piece = item
                    piece.span.start = s
                    piece.span.end = e
                    return piece
                }
                if !pieces.isEmpty { sessions.append(session(pieces)) }
            }
        }
        // A stretch under a minute between two absences is too short to name.
        return sessions.filter { $0.recorded >= glance }
    }

    /// Where a key changes and the new one lasts `threshold`. Spans without
    /// a key are transparent; a stretch under `glance` keeps the key before it.
    static func lastingChanges(_ marks: [(start: Date, end: Date, key: String?)], threshold: TimeInterval) -> [Date] {
        var runs: [(start: Date, end: Date, key: String)] = []
        for mark in marks {
            guard let key = mark.key else { continue }
            if let last = runs.last, last.key == key {
                runs[runs.count - 1].end = max(last.end, mark.end)
            } else {
                runs.append((mark.start, mark.end, key))
            }
        }
        // Glances take the key before them, then equal neighbours join.
        var steady: [(start: Date, end: Date, key: String)] = []
        for run in runs {
            let key = run.end.timeIntervalSince(run.start) < glance ? steady.last?.key ?? run.key : run.key
            if let last = steady.last, last.key == key {
                steady[steady.count - 1].end = max(last.end, run.end)
            } else {
                steady.append((run.start, run.end, key))
            }
        }
        guard var current = steady.first?.key else { return [] }
        var changes: [Date] = []
        for run in steady.dropFirst() where run.key != current && run.end.timeIntervalSince(run.start) >= threshold {
            changes.append(run.start)
            current = run.key
        }
        return changes
    }

    static func session(_ pieces: [CategorizedSpan]) -> WorkSession {
        var apps: [String: WorkSession.App] = [:]
        var categories: [String: TimeInterval] = [:]
        var projects: [String: (label: String, seconds: TimeInterval)] = [:]
        var titles: [String: WorkSession.Title] = [:]
        var documents: [String: WorkSession.Title] = [:]
        var recorded: TimeInterval = 0
        for piece in pieces {
            let span = piece.span, seconds = span.duration
            recorded += seconds
            apps[span.appBundleID, default: .init(bundleID: span.appBundleID, name: span.appName, seconds: 0)].seconds += seconds
            categories[piece.categoryID, default: 0] += seconds
            if let project = projectKey(span) {
                projects[project.key, default: (project.label, 0)].seconds += seconds
            }
            // A title that only repeats the app's name says nothing.
            if let title = span.title, !title.isEmpty, title != span.appName {
                titles[span.appName + "\u{1}" + title, default: .init(appName: span.appName, title: title, seconds: 0)].seconds += seconds
            }
            if let document = span.document {
                let name = DocumentIdentity.path(of: document).map { ($0 as NSString).lastPathComponent } ?? document
                documents[span.appName + "\u{1}" + name, default: .init(appName: span.appName, title: name, seconds: 0)].seconds += seconds
            }
        }
        let project = projects.max { $0.value.seconds == $1.value.seconds ? $0.key > $1.key : $0.value.seconds < $1.value.seconds }
            .flatMap { $0.value.seconds >= recorded * projectShare ? $0 : nil }
        return WorkSession(
            start: pieces.map(\.span.start).min()!, end: pieces.map(\.span.end).max()!, recorded: recorded,
            categoryID: categories.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key,
            project: project?.key, projectLabel: project?.value.label,
            apps: apps.values.sorted { $0.seconds == $1.seconds ? $0.bundleID < $1.bundleID : $0.seconds > $1.seconds },
            titles: Array(titles.values.sorted { $0.seconds == $1.seconds ? $0.title < $1.title : $0.seconds > $1.seconds }.prefix(12)),
            documents: Array(documents.values.sorted { $0.seconds == $1.seconds ? $0.title < $1.title : $0.seconds > $1.seconds }.prefix(8)))
    }
}
