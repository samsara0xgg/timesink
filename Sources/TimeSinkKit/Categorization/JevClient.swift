import CryptoKit
import Foundation

/// One HTTP round trip; a seam so tests never touch the network.
public protocol JevTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

public struct URLSessionJevTransport: JevTransport {
    public init() {}

    public func post(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum JevError: LocalizedError, Equatable {
    case http(Int)
    case badAnswer
    case unknownCategory(String)

    /// The key or the account is the problem: asking again changes nothing.
    var stopsTheRun: Bool {
        if case .http(let code) = self { return [401, 402, 403].contains(code) }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .http(let code) where code == 401 || code == 403: String(localized: "API Key 无效或没有权限（HTTP \(code)）。")
        case .http(let code) where code == 402: String(localized: "账户余额不足（HTTP 402）。")
        case .http(let code): String(localized: "服务返回 HTTP \(code)。")
        case .badAnswer: String(localized: "服务没有返回分类。")
        case .unknownCategory(let value): String(localized: "服务返回了不认识的分类：\(value)")
        }
    }
}

/// What is sent about a window: exactly these six fields and nothing else.
/// Never screen text, never a screenshot.
struct JevState: Sendable {
    var app: String
    var bundleID: String
    var domain: String
    var url: String
    var title: String
    var document: String
}

public struct JevAnswer: Equatable, Sendable {
    public var choice: String
    public var probabilities: [String: Double]
    public var confidence: Double
    public var inputTokens: Int
    /// USD.
    public var cost: Double
}

/// The category list as Jev sees it, and a version that changes when what it
/// would answer could.
public enum JevPrompt {
    public static let instructions = "这段电脑使用时间属于哪个活动类别？根据应用、网址、窗口标题判断。"  // l10n: data

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

    /// The fields sent per window, for the screen that asks the user to turn it on.
    public static var sentFields: [String] {
        [String(localized: "应用名称"), String(localized: "应用标识"), String(localized: "网站域名"),
         String(localized: "网址（最多 300 字）"), String(localized: "窗口标题（最多 300 字）"), String(localized: "文档或对话名（最多 300 字）"),
         String(localized: "你的分类名称和描述")]
    }
}

public struct JevClient: Sendable {
    public static let defaultEndpoint = "https://openrouter.ai/api/alpha/decisions"
    public static let model = "typesafe/jev-1.13"
    static let fieldLimit = 300

    let endpoint: URL
    let apiKey: String
    let transport: any JevTransport

    public init(endpoint: URL, apiKey: String, transport: any JevTransport = URLSessionJevTransport()) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
    }

    /// Hand-assembled so the criteria keep their order, which a Foundation
    /// dictionary would not.
    static func body(state: JevState, criteria: [(id: String, text: String)]) -> Data {
        func q(_ s: String) -> String { (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\"" }
        func cut(_ s: String) -> String { String(s.prefix(fieldLimit)) }
        let list = criteria.map { "\(q($0.id)):\(q($0.text))" }.joined(separator: ",")
        let json = """
            {"model":\(q(model)),"state":{"app":\(q(state.app)),"bundle_id":\(q(state.bundleID)),"domain":\(q(state.domain)),\
            "url":\(q(cut(state.url))),"window_title":\(q(cut(state.title))),"document":\(q(cut(state.document)))},\
            "questions":{"category":{"type":"choice","instructions":\(q(JevPrompt.instructions)),"criteria":{\(list)}}}}
            """
        return Data(json.utf8)
    }

    func decide(_ state: JevState, criteria: [(id: String, text: String)]) async throws -> JevAnswer {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TimeSink", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = Self.body(state: state, criteria: criteria)
        let (data, status) = try await transport.post(request)
        guard (200..<300).contains(status) else { throw JevError.http(status) }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> JevAnswer {
        struct Answer: Decodable { let choice: String; let probabilities: [String: Double]?; let confidence: Double? }
        struct Usage: Decodable { let input_tokens: Int?; let cost: Double? }
        struct Reply: Decodable { let answers: [String: Answer]; let usage: Usage? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let answer = reply.answers["category"] else {
            throw JevError.badAnswer
        }
        return JevAnswer(choice: answer.choice, probabilities: answer.probabilities ?? [:], confidence: answer.confidence ?? 0,
                         inputTokens: reply.usage?.input_tokens ?? 0, cost: reply.usage?.cost ?? 0)
    }
}
