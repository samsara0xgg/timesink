import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// F1: names a session from its window titles, file and repo names and app
/// names, on this Mac only. On macOS 26 with Apple Intelligence the
/// on-device model names it; otherwise the title held longest does. A
/// guess too unsure gives no name, and the session lists its apps.
///
/// An actor, so one naming runs at a time and never on the main thread.
public actor SessionNamer {
    /// Below this the model's name is not shown.
    static let modelFloor = 0.5
    /// The fallback title must have held this share of the session.
    static let titleFloor = 0.15
    /// Some title or document must have held this share for a model name.
    static let evidenceFloor = 0.2

    /// The share of the session held by its leading title or document.
    static func evidence(_ session: WorkSession) -> Double {
        guard session.recorded > 0 else { return 0 }
        return max(session.titles.first?.seconds ?? 0, session.documents.first?.seconds ?? 0) / session.recorded
    }

    public init() {}

    public static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    public func name(_ raw: WorkSession, useModel: Bool = true) async -> SessionLabel {
        let session = Self.cleaned(raw)
        #if canImport(FoundationModels)
        if useModel, #available(macOS 26, *), Self.modelAvailable,
           let guess = try? await Self.modelGuess(session) {
            let name = guess.name.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
            let project = guess.project.trimmingCharacters(in: .whitespacesAndNewlines)
            // The model is sure more often than it should be: a session
            // with no title or document holding a fair share of it has no
            // one task to name.
            let confidence = Self.evidence(session) >= Self.evidenceFloor ? guess.confidence : min(guess.confidence, 0.4)
            let sure = confidence >= Self.modelFloor && Self.saysSomething(name, in: session)
            return SessionLabel(key: session.nameKey, name: sure ? String(name.prefix(40)) : nil,
                                project: project.isEmpty ? nil : String(project.prefix(40)),
                                confidence: confidence, source: .model)
        }
        #endif
        return Self.titleFallback(session)
    }

    static let separators = [" - ", " — ", " – ", " | ", " · ", " • "]
    /// Words that name no task on their own.
    static let vague: Set<String> = ["review", "reviews", "reviewing", "development", "develop", "coding", "code", "work", "working",
                                     "browsing", "research", "chat", "chatting", "task", "tasks", "session", "project", "debugging",
                                     "and", "of", "the", "a", "on", "in", "for", "with", "开发", "工作", "浏览", "聊天", "审查", "任务"] // l10n: data

    /// Title parts that say nothing about the task: app names, and a part
    /// repeated across most titles (" - Claude Code", " — Google Chrome").
    static func boilerplate(_ session: WorkSession) -> Set<String> {
        var common = Set(session.apps.map { $0.name.lowercased() })
        let texts = (session.titles + session.documents).map(\.title)
        var counts: [String: Int] = [:]
        for text in texts {
            for part in Set(parts(text)) { counts[part, default: 0] += 1 }
        }
        for (part, count) in counts where count >= 3 && Double(count) >= Double(texts.count) * 0.3 { common.insert(part) }
        return common
    }

    static func parts(_ text: String) -> [String] {
        var pieces = [text]
        for separator in separators { pieces = pieces.flatMap { $0.components(separatedBy: separator) } }
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }

    /// Titles and documents with boilerplate parts removed, equal ones merged.
    public static func cleaned(_ session: WorkSession) -> WorkSession {
        let common = boilerplate(session)
        func clean(_ list: [WorkSession.Title]) -> [WorkSession.Title] {
            var merged: [String: WorkSession.Title] = [:]
            var order: [String] = []
            for item in list {
                var pieces = [item.title]
                for separator in separators { pieces = pieces.flatMap { $0.components(separatedBy: separator) } }
                let kept = pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !common.contains($0.lowercased()) }
                guard !kept.isEmpty else { continue }
                let text = kept.joined(separator: " - ")
                if merged[text] == nil { order.append(text); merged[text] = .init(appName: item.appName, title: text, seconds: 0) }
                merged[text]!.seconds += item.seconds
            }
            return order.compactMap { merged[$0] }.sorted { $0.seconds > $1.seconds }
        }
        var session = session
        session.titles = clean(session.titles)
        session.documents = clean(session.documents)
        return session
    }

    /// False for a name that is only app names, boilerplate and vague words
    /// ("Claude Code review").
    static func saysSomething(_ name: String, in session: WorkSession) -> Bool {
        var rest = name.lowercased()
        for part in boilerplate(session).sorted(by: { $0.count > $1.count }) { rest = rest.replacingOccurrences(of: part, with: " ") }
        let words = rest.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !vague.contains($0) }
        return !words.isEmpty
    }

    /// The title held longest, when it held enough of the session.
    public static func titleFallback(_ session: WorkSession) -> SessionLabel {
        guard let top = session.titles.first, session.recorded > 0 else {
            return SessionLabel(key: session.nameKey, name: nil, project: session.projectLabel, confidence: 0, source: .none)
        }
        let share = top.seconds / session.recorded
        let name = top.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionLabel(key: session.nameKey, name: share >= titleFloor && !name.isEmpty ? String(name.prefix(60)) : nil,
                            project: session.projectLabel, confidence: share, source: share >= titleFloor ? .title : .none)
    }

    /// Only titles, file and repo names and app names go in.
    public static func prompt(_ session: WorkSession) -> String {
        func minutes(_ seconds: TimeInterval) -> String { "\(max(1, Int((seconds / 60).rounded()))) min" }
        var lines = ["Total: \(minutes(session.recorded))",
                     "Apps: " + session.apps.prefix(6).map { "\($0.name) (\(minutes($0.seconds)))" }.joined(separator: ", ")]
        if let project = session.projectLabel { lines.append("Main folder or repo: \(project)") }
        if !session.documents.isEmpty {
            lines.append("Conversations, files and folders, longest first:")
            lines += session.documents.map { "- \($0.title) (in \($0.appName), \(minutes($0.seconds)))" }
        }
        lines.append("Window titles, longest first:")
        lines += session.titles.map { "- \($0.title) (in \($0.appName), \(minutes($0.seconds)))" }
        return lines.joined(separator: "\n")
    }

    static var language: String {
        // The language the app's own interface is showing.
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "Simplified Chinese, at most 12 characters" : "English, at most 5 words"
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    @Generable struct Guess {
        @Guide(description: "A short name for the task this work was for, like a to-do item. Not an app name.")
        var name: String
        @Guide(description: "The project, repo or document it belongs to, or an empty string when unclear.")
        var project: String
        @Guide(description: "How sure you are that the name describes the task, from 0 to 1.", .range(0...1))
        var confidence: Double
    }

    @available(macOS 26, *)
    static func modelGuess(_ session: WorkSession) async throws -> Guess {
        let instructions = """
        You name a stretch of work someone did on their Mac, from the apps and window titles they had in front. \
        Write the name in \(language). Take it from the conversations, files and window titles that held the most time; \
        never answer with only an app name, and do not invent details. \
        If no single task held most of the time, or the titles are unrelated to each other, give a confidence below 0.5.
        """
        let model = LanguageModelSession(instructions: instructions)
        return try await model.respond(to: prompt(session), generating: Guess.self,
                                       options: GenerationOptions(temperature: 0.2)).content
    }
    #endif
}
