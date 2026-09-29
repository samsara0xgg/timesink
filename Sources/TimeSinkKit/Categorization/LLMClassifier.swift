import Foundation
import os

/// Anything that can turn a domain (+ optional page title) into one of the
/// 11 assignable taxonomy category ids. `Sendable` so it can cross into the
/// unstructured `Task` that `LLMCoordinator` fires.
public protocol DomainClassifying: Sendable {
    func classify(domain: String, title: String?) async throws -> String
}

/// Errors thrown while calling or parsing an OpenAI-compatible chat
/// completion; the settings pane's connection test shows their text.
enum LLMClassifierError: LocalizedError {
    case emptyChoices
    case invalidCategory(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .emptyChoices: String(localized: "服务没有返回分类。")
        case .invalidCategory(let value): String(localized: "服务返回了不认识的分类：\(value)")
        case .http(let code) where code == 401 || code == 403: String(localized: "API Key 无效或没有权限（HTTP \(code)）。")
        case .http(let code): String(localized: "服务返回 HTTP \(code)，请检查 Endpoint 和模型名。")
        }
    }
}

/// Calls an OpenAI-compatible `/chat/completions` endpoint with a fixed
/// SYSTEM prompt and temperature-0 sampling, asking for exactly one
/// taxonomy category id back.
public struct OpenAIDomainClassifier: DomainClassifying {
    private let endpoint: URL
    private let apiKey: String
    private let model: String

    /// Verbatim per the task brief; the 11 assignable category ids
    /// (everything in Taxonomy.categories except "uncategorized").
    static let systemPrompt =
        "Classify the website domain into exactly one category id from: softwareDev, learning, writing, business, utilities, communication, news, shopping, socialMedia, entertainment, misc. Respond with only the category id."

    /// The 11 assignable category ids -- deliberately excludes "uncategorized",
    /// which is never a valid classification result.
    static let validCategoryIDs: Set<String> = [
        "softwareDev", "learning", "writing", "business", "utilities",
        "communication", "news", "shopping", "socialMedia", "entertainment", "misc",
    ]

    public init(endpoint: URL, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }

    public func classify(domain: String, title: String?) async throws -> String {
        var request = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0,
            "max_tokens": 10,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": "domain: \(domain)"],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        // An error body would otherwise surface as a JSON decoding failure.
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw LLMClassifierError.http(status)
        }
        return try Self.parse(response: data)
    }

    /// Extracts `choices[0].message.content`, trims whitespace/newlines, and
    /// throws unless the result is one of the 11 assignable category ids.
    /// A separate static method so it's testable without any network call.
    public static func parse(response: Data) throws -> String {
        struct Message: Decodable { let content: String }
        struct Choice: Decodable { let message: Message }
        struct ChatCompletion: Decodable { let choices: [Choice] }

        let completion = try JSONDecoder().decode(ChatCompletion.self, from: response)
        guard let content = completion.choices.first?.message.content else {
            throw LLMClassifierError.emptyChoices
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validCategoryIDs.contains(trimmed) else {
            throw LLMClassifierError.invalidCategory(trimmed)
        }
        return trimmed
    }
}

/// Fires off-session, best-effort LLM classification for spans the
/// deterministic classifier (`Classifier`, via `CategoryResolver`) left
/// "uncategorized". Gated on: LLM enabled, the span has a domain, the
/// resolver currently classifies it as "uncategorized", and this domain
/// hasn't already been attempted this session (success or failure -- a
/// failed attempt is never retried within the same run).
@MainActor
public final class LLMCoordinator {
    /// Keychain account under which the API key is stored (service
    /// `com.alllllenshi.TimeSink`, set by `Keychain`). Shared with the
    /// Settings LLM pane so both read/write the same item.
    public static let apiKeyAccount = "llmAPIKey"

    private let categoryStore: CategoryStore
    private let settings: SettingsStore
    private let resolver: CategoryResolver
    private var service: (any DomainClassifying)?

    /// Domains classification has already been attempted for this session,
    /// win or lose. Never persisted -- resets on app relaunch.
    private var attemptedDomains: Set<String> = []
    public var onSuggestion: (() -> Void)?

    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "llmCoordinator")

    public init(categoryStore: CategoryStore, settings: SettingsStore, resolver: CategoryResolver, service: (any DomainClassifying)?) {
        self.categoryStore = categoryStore
        self.settings = settings
        self.resolver = resolver
        self.service = service
    }

    public func noteSpanClosed(_ span: Span) {
        guard settings.llmEnabled else { return }
        guard let domain = span.domain else { return }
        guard resolver.categoryID(for: span) == "uncategorized" else { return }
        guard (try? categoryStore.suggestions().contains { $0.key == domain && $0.kind == "domain" }) != true else { return }
        guard !attemptedDomains.contains(domain) else { return }
        guard let classifier = resolveService() else { return }

        attemptedDomains.insert(domain)

        Task { @MainActor in
            do {
                let categoryID = try await classifier.classify(domain: domain, title: nil)
                guard settings.llmEnabled else { return }
                try categoryStore.suggestDomain(domain, categoryID: categoryID)
                onSuggestion?()
            } catch {
                logger.error("classify failed for \(domain, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Drops the memoized service so the next `noteSpanClosed` rebuilds it
    /// from current settings + Keychain. Call this whenever the API key,
    /// endpoint, or model changes -- otherwise the stale classifier (old
    /// key/endpoint/model) keeps being reused for the rest of the session
    /// even after the Settings pane's own "测试" button (which builds its
    /// own throwaway classifier from the current field values) reports
    /// success.
    public func invalidateService() {
        service = nil
    }

    /// Returns the injected service if one exists; otherwise lazily builds
    /// one from current settings + the Keychain-stored API key. Returns nil
    /// (and touches nothing else) if no key is present yet.
    private func resolveService() -> (any DomainClassifying)? {
        if let service { return service }
        guard let key = Keychain.get(account: Self.apiKeyAccount), !key.isEmpty else { return nil }
        guard let endpointURL = URL(string: settings.llmEndpoint) else { return nil }
        let built = OpenAIDomainClassifier(endpoint: endpointURL, apiKey: key, model: settings.llmModel)
        service = built
        return built
    }
}
