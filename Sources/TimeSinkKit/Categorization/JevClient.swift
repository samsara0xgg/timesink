import CryptoKit
import Foundation

/// One HTTP round trip; a seam so tests never touch the network.
public protocol JevTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (data: Data, status: Int, retryAfter: String?)
}

/// `post` sends the request as built, so a GET (the key check) goes through it too.
public struct URLSessionJevTransport: JevTransport {
    public init() {}

    public func post(_ request: URLRequest) async throws -> (data: Data, status: Int, retryAfter: String?) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Retry-After"))
    }
}

public enum JevError: LocalizedError, Equatable {
    case http(Int)
    /// HTTP 429; seconds to wait before asking again.
    case rateLimited(retryAfter: Int)
    /// A 2xx reply with no usable answer; `cost` is what its usage said the request cost anyway.
    case badAnswer(cost: Double)
    case unknownCategory(String)

    /// The key, the account, the model id or the address is the problem: asking again changes nothing.
    var stopsTheRun: Bool {
        if case .http(let code) = self { return [400, 401, 402, 403, 404].contains(code) }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .http(let code) where code == 401 || code == 403: String(localized: "API Key 无效或没有权限（HTTP \(code)）。")
        case .http(let code) where code == 402: String(localized: "账户余额不足（HTTP 402）。")
        case .http(let code) where code == 400 || code == 404: String(localized: "模型名或地址不对（HTTP \(code)），请检查高级设置。")
        case .http(let code): String(localized: "服务返回 HTTP \(code)。")
        case .rateLimited(let secs): String(localized: "请求太频繁（HTTP 429），\(secs) 秒后重试。")
        case .badAnswer: String(localized: "服务没有返回分类。")
        case .unknownCategory(let value): String(localized: "服务返回了不认识的分类：\(value)")
        }
    }
}

/// What kind of trouble stopped a run, as the settings screen tells them apart.
public enum JevProblem: Equatable, Sendable {
    /// HTTP 401/403: the key is wrong or was revoked.
    case invalidKey
    /// HTTP 402: the OpenRouter account has no credits left.
    case noCredits
    /// HTTP 400/404: the model id or the address is wrong.
    case badModelOrEndpoint
    /// HTTP 5xx, a timeout or no connection.
    case unavailable

    /// nil for an error that says nothing about the service (a malformed answer, a 429).
    public init?(_ error: any Error) {
        if let jevError = error as? JevError, case .http(let code) = jevError {
            switch code {
            case 401, 403: self = .invalidKey
            case 402: self = .noCredits
            case 400, 404: self = .badModelOrEndpoint
            case 500...599: self = .unavailable
            default: return nil
            }
        } else if error is URLError {
            self = .unavailable
        } else {
            return nil
        }
    }

    /// One line for the settings screen.
    public var message: String {
        switch self {
        case .invalidKey: String(localized: "API 密钥无效或已被撤销，请检查后重新保存")
        case .noCredits: String(localized: "OpenRouter 账户余额不足，充值后会自动继续")
        case .badModelOrEndpoint: String(localized: "模型名或地址不对，请检查高级设置")
        case .unavailable: String(localized: "服务暂时连不上，稍后自动重试")
        }
    }
}

/// What is sent about a window: these six fields, plus `screenText` only when
/// the owner switched it on. Never a screenshot.
struct JevState: Sendable {
    var app: String
    var bundleID: String
    var domain: String
    var url: String
    var title: String
    var document: String
    /// OCR text of a screenshot; nil unless "send screenshot text" is on.
    var screenText: String? = nil
    /// Few-shot examples of the user's own choices; only on low-confidence re-asks.
    var examples: [JevExample]? = nil
}

/// One thing the user settled before: a confirmed or corrected screen, a rule of theirs, or a seed row.
struct JevExample: Equatable, Sendable {
    var bundleID: String
    var app: String
    var domain: String
    var title: String
    var document: String
    /// Category display name.
    var category: String

    static let cap = 20

    /// Only what the user settled for the same website (any browser), or for a
    /// window with no website, the same app: another app's or site's window
    /// titles never ride along. In the order given (most recent first), up to 20.
    static func select(from all: [JevExample], bundleID: String, domain: String) -> [JevExample] {
        let near = all.filter { domain.isEmpty ? $0.bundleID == bundleID && $0.domain.isEmpty : $0.domain == domain }
        return Array(near.prefix(cap))
    }
}

public struct JevAnswer: Equatable, Sendable {
    public var choice: String
    public var probabilities: [String: Double]
    public var confidence: Double
    public var inputTokens: Int
    /// USD.
    public var cost: Double
    /// The project answer, when the request asked the project question.
    public var projectChoice: String? = nil
    public var projectProbabilities: [String: Double]? = nil
    public var projectConfidence: Double? = nil
}

/// The category list as Jev sees it, and a version that changes when what it
/// would answer could.
public enum JevPrompt {
    public static let instructions = "这段电脑使用时间属于哪个活动类别？根据应用、网址、窗口标题判断。"  // l10n: data
    public static let instructionsWithScreenText = "这段电脑使用时间属于哪个活动类别？根据应用、网址、窗口标题和屏幕上的文字判断。"  // l10n: data
    static let exampleListKey = "用户以前确认过的例子"  // l10n: data
    static let exampleCategoryKey = "用户定的分类"  // l10n: data
    static let examplesNote = "用户以前确认过的例子代表他的分类习惯，类似的内容按同样方式分。"  // l10n: data
    static let screenTextLimit = 1_200

    private static let emailRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    /// API keys and tokens: OpenAI/OpenRouter/Anthropic-style `sk-…`, Stripe,
    /// GitHub, Slack and Google keys, AWS access key ids, JWTs, then any run of
    /// 32+ hex digits, or of 32+ letters and digits that mixes upper case, lower
    /// case and digits (a random key). Runs with dashes, dots or slashes in them
    /// are file names and paths and stay.
    private static let tokenPatterns: [String] = [
        #"\bsk-[A-Za-z0-9_-]{16,}"#,
        #"\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}"#,
        #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#,
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"\bAIza[0-9A-Za-z_-]{35}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        #"(?=[0-9A-Fa-f]*[0-9])(?=[0-9A-Fa-f]*[A-Fa-f])[0-9A-Fa-f]{32,}"#,
        #"(?=[A-Za-z0-9]*[0-9])(?=[A-Za-z0-9]*[a-z])(?=[A-Za-z0-9]*[A-Z])[A-Za-z0-9]{32,}"#,
    ]
    private static let tokenRegexes: [NSRegularExpression] = tokenPatterns.map { try! NSRegularExpression(pattern: $0) }
    /// Phone, card and account numbers: 6+ digits with spaces, dashes, dots
    /// or parentheses between them, and a leading "+".
    private static let digitRunRegex = try! NSRegularExpression(pattern: #"\+?\(?\d(?:[ .()-]{0,2}\d){5,}\)?"#)

    /// What leaves the machine of a screenshot's text, and of a title, document
    /// name or URL: no emails, no API keys or tokens, no runs of 6+ digits
    /// (phone and card numbers), at most 1,200 characters.
    public static func redact(_ text: String) -> String {
        var out = text
        for regex in [emailRegex] + tokenRegexes + [digitRunRegex] {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return String(out.prefix(screenTextLimit))
    }

    /// What leaves the machine of a URL: its scheme, host and path. Never the
    /// query string or fragment, where sign-in codes, reset tokens and magic
    /// links live, nor a user name or password.
    public static func strippedURL(_ url: String) -> String {
        if var parts = URLComponents(string: url), parts.scheme != nil {
            parts.query = nil
            parts.fragment = nil
            parts.user = nil
            parts.password = nil
            if let clean = parts.string { return clean }
        }
        guard let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return url }
        return String(url[..<cut])
    }

    /// `uncategorized` is never offered. Descriptions are what teach Jev a
    /// category, so each criterion is "name：description".
    public static func criteria(_ categories: [Category]) -> [(id: String, text: String)] {
        categories.filter { $0.id != "uncategorized" }.sorted { $0.sortOrder < $1.sortOrder }.map {
            ($0.id, $0.description.isEmpty ? $0.name : "\($0.name)：\($0.description)")  // l10n: data
        }
    }

    /// Stable across launches: a hash of ids, names and descriptions in order.
    public static func version(_ categories: [Category]) -> String {
        let text = criteria(categories).map { "\($0.id)\u{1F}\($0.text)" }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static let projectInstructions = "这段电脑使用时间属于哪个项目？不属于任何一个就选 none。"  // l10n: data
    /// The id of "belongs to no project", which Jev can always pick.
    public static let noProject = "none"
    static let noProjectText = "不属于以上任何项目"  // l10n: data

    /// One entry per project, "name：description", then "none". The ids are the
    /// projects' own, so a rename changes the text and not the answer's meaning.
    public static func projectCriteria(_ projects: [UserProject]) -> [(id: String, text: String)] {
        projects.filter { !$0.archived }.sorted { $0.sortOrder < $1.sortOrder }.map {
            ($0.id, $0.description.isEmpty ? $0.name : "\($0.name)：\($0.description)")  // l10n: data
        } + [(noProject, noProjectText)]
    }

    /// Stable across launches, like `version`; changes when the project list or a name or description does.
    public static func projectVersion(_ projects: [UserProject]) -> String {
        let text = projectCriteria(projects).map { "\($0.id)\u{1F}\($0.text)" }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The fields sent per window, for the screen that asks the user to turn it on.
    public static var sentFields: [String] {
        [String(localized: "应用名称"), String(localized: "应用标识"), String(localized: "网站域名"),
         String(localized: "网址，只到路径为止，不含 ? 和 # 之后的部分（最多 300 字）"), String(localized: "窗口标题（最多 300 字）"),
         String(localized: "文档或对话名（最多 300 字）"),
         String(localized: "你的分类名称和描述"), String(localized: "你的项目名称和描述")]
    }
}

public struct JevClient: Sendable {
    public static let defaultEndpoint = "https://openrouter.ai/api/alpha/decisions"
    /// The model that is asked unless the owner typed another; never upgraded by an app update.
    public static let defaultModel = "typesafe/jev-1.13"
    static let fieldLimit = 300

    let endpoint: URL
    let apiKey: String
    let transport: any JevTransport
    let model: String

    public init(endpoint: URL, apiKey: String, model: String = JevClient.defaultModel, transport: any JevTransport = URLSessionJevTransport()) {
        self.model = model
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
    }

    /// Hand-assembled so the criteria keep their order, which a Foundation
    /// dictionary would not.
    /// `projects`: `JevPrompt.projectCriteria`, or empty to ask the category question alone. Empty
    /// `criteria` (with projects) asks the project question alone, for a window whose category is settled.
    static func body(state: JevState, criteria: [(id: String, text: String)], projects: [(id: String, text: String)] = [],
                     model: String = JevClient.defaultModel) -> Data {
        func q(_ s: String) -> String { (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\"" }
        // Redacted before it is cut, so a cut never leaves half an email or token behind.
        func cut(_ s: String) -> String { String(JevPrompt.redact(s).prefix(fieldLimit)) }
        let list = criteria.map { "\(q($0.id)):\(q($0.text))" }.joined(separator: ",")
        let screen = state.screenText.map(JevPrompt.redact)
        let examples = (state.examples ?? []).isEmpty ? nil : state.examples
        func item(_ e: JevExample) -> String {
            let pairs: [(String, String)] = [("app", e.app), ("domain", e.domain), ("title", String(JevPrompt.redact(e.title).prefix(80))),
                         ("document", String(JevPrompt.redact(e.document).prefix(60))),
                         (JevPrompt.exampleCategoryKey, e.category)]
            return "{" + pairs.map { "\(q($0.0)):\(q($0.1))" }.joined(separator: ",") + "}"
        }
        let exampleJSON = examples.map { ",\(q(JevPrompt.exampleListKey)):[" + $0.map(item).joined(separator: ",") + "]" } ?? ""
        let instructions = (screen == nil ? JevPrompt.instructions : JevPrompt.instructionsWithScreenText) + (examples == nil ? "" : JevPrompt.examplesNote)
        let projectJSON = projects.isEmpty ? "" : (criteria.isEmpty ? "" : ",") + "\"project\":{\"type\":\"choice\",\"instructions\":\(q(JevPrompt.projectInstructions)),"
            + "\"criteria\":{\(projects.map { "\(q($0.id)):\(q($0.text))" }.joined(separator: ","))}}"
        let categoryJSON = "\"category\":{\"type\":\"choice\",\"instructions\":\(q(instructions)),\"criteria\":{\(list)}}"
        let json = """
            {"model":\(q(model)),"state":{"app":\(q(state.app)),"bundle_id":\(q(state.bundleID)),"domain":\(q(state.domain)),\
            "url":\(q(cut(JevPrompt.strippedURL(state.url)))),"window_title":\(q(cut(state.title))),"document":\(q(cut(state.document)))\
            \(screen.map { ",\"screen_text\":\(q($0))" } ?? "")\(exampleJSON)},\
            "questions":{\(criteria.isEmpty ? "" : categoryJSON)\(projectJSON)}}
            """
        return Data(json.utf8)
    }

    func decide(_ state: JevState, criteria: [(id: String, text: String)], projects: [(id: String, text: String)] = []) async throws -> JevAnswer {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TimeSink", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = Self.body(state: state, criteria: criteria, projects: projects, model: model)
        let (data, status, retryAfter) = try await transport.post(request)
        if status == 429 { throw JevError.rateLimited(retryAfter: min(max(retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 30, 1), 300)) }
        guard (200..<300).contains(status) else { throw JevError.http(status) }
        return try Self.parse(data, expectCategory: !criteria.isEmpty)
    }

    static func parse(_ data: Data, expectCategory: Bool = true) throws -> JevAnswer {
        struct Answer: Decodable { let choice: String; let probabilities: [String: Double]?; let confidence: Double? }
        struct Usage: Decodable { let input_tokens: Int?; let cost: Double? }
        /// Only the bill, for a reply whose answers did not parse: it was charged all the same.
        struct Billed: Decodable { let usage: Usage? }
        /// A malformed answer reads as missing, so a bad project answer never costs the category.
        struct Lenient: Decodable {
            let value: Answer?
            init(from decoder: any Decoder) throws { value = try? Answer(from: decoder) }
        }
        struct Reply: Decodable { let answers: [String: Lenient]; let usage: Usage? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw JevError.badAnswer(cost: (try? JSONDecoder().decode(Billed.self, from: data))?.usage?.cost ?? 0)
        }
        let project = reply.answers["project"]?.value
        guard let answer = reply.answers["category"]?.value ?? (expectCategory ? nil : project) else {
            throw JevError.badAnswer(cost: reply.usage?.cost ?? 0)
        }
        if !expectCategory {
            // The project question alone: no category came back, and none was asked.
            return JevAnswer(choice: "", probabilities: [:], confidence: 0, inputTokens: reply.usage?.input_tokens ?? 0, cost: reply.usage?.cost ?? 0,
                             projectChoice: project?.choice, projectProbabilities: project.map { $0.probabilities ?? [:] },
                             projectConfidence: project.map { $0.confidence ?? 0 })
        }
        return JevAnswer(choice: answer.choice, probabilities: answer.probabilities ?? [:], confidence: answer.confidence ?? 0,
                         inputTokens: reply.usage?.input_tokens ?? 0, cost: reply.usage?.cost ?? 0,
                         projectChoice: project?.choice, projectProbabilities: project.map { $0.probabilities ?? [:] },
                         projectConfidence: project.map { $0.confidence ?? 0 })
    }
}

/// What OpenRouter says about a key: `GET /api/v1/key`, which costs nothing.
public struct JevKeyInfo: Equatable, Sendable {
    /// USD spent with the key so far.
    public var usage: Double
    /// The key's credit limit in USD; nil when it has none.
    public var limit: Double?
    public var limitRemaining: Double?
    public var isFreeTier: Bool
}

extension JevClient {
    /// `https://openrouter.ai/api/v1/key` for the default endpoint: the same host
    /// as `endpoint`, whatever path the decisions call uses.
    static func keyURL(endpoint: String) -> URL? {
        guard var parts = URLComponents(string: endpoint), parts.scheme != nil, parts.host != nil else { return nil }
        parts.path = "/api/v1/key"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// Asks OpenRouter whether `apiKey` works and what it has spent. Throws
    /// `JevError.http` for a refusal (401/403: invalid key) and the
    /// transport's error when the service cannot be reached.
    public static func checkKey(endpoint: String, apiKey: String,
                                transport: any JevTransport = URLSessionJevTransport()) async throws -> JevKeyInfo {
        guard let url = keyURL(endpoint: endpoint) else { throw JevError.http(404) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, status, _) = try await transport.post(request)
        guard (200..<300).contains(status) else { throw JevError.http(status) }
        guard let info = parseKeyInfo(data) else { throw JevError.badAnswer(cost: 0) }
        return info
    }

    static func parseKeyInfo(_ data: Data) -> JevKeyInfo? {
        struct Body: Decodable { let usage: Double?; let limit: Double?; let limit_remaining: Double?; let is_free_tier: Bool? }
        struct Reply: Decodable { let data: Body }
        guard let body = (try? JSONDecoder().decode(Reply.self, from: data))?.data else { return nil }
        return JevKeyInfo(usage: body.usage ?? 0, limit: body.limit, limitRemaining: body.limit_remaining, isFreeTier: body.is_free_tier ?? false)
    }
}
