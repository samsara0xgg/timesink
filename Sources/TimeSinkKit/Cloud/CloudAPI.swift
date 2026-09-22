import Foundation

public enum CloudError: Error {
    case signedOut
    case http(Int, String)
}

/// The server's receipt for one pushed row.
public struct SpanAck: Equatable, Sendable {
    public let originID: Int64
    public let seq: String
    public init(originID: Int64, seq: String) {
        self.originID = originID
        self.seq = seq
    }
}

/// One page of other devices' rows. `cursor` is what the next call passes
/// (`after` while `more`, `since` on the next pass); nil when the account
/// has nothing yet.
public struct PullPage: Sendable {
    public let spans: [SpanStore.RemoteSpan]
    public let cursor: String?
    public let more: Bool
    public init(spans: [SpanStore.RemoteSpan], cursor: String?, more: Bool) {
        self.spans = spans
        self.cursor = cursor
        self.more = more
    }
}

/// The three calls `SyncEngine` makes. `HTTPCloud` is the real one; tests
/// substitute an in-memory fake.
public protocol SpanCloud: Sendable {
    /// `spans` are this device's rows; each one's `id` is its originId.
    func push(deviceID: String, spans: [Span]) async throws -> [SpanAck]
    /// `since` widens by the server's overlap; `after` pages exactly.
    func pull(since: String?, after: String?, excludingDevice: String) async throws -> PullPage
    func deleteAccount() async throws
}

public typealias AccessTokenProvider = @Sendable () async throws -> String?

/// `SpanCloud` over the HTTP API `cloud/infra` deploys. Every call carries
/// the Cognito access token as a Bearer; a missing one is `signedOut`.
public struct HTTPCloud: SpanCloud {
    private let base: URL
    private let accessToken: AccessTokenProvider

    public init(base: URL, accessToken: @escaping AccessTokenProvider) {
        self.base = base
        self.accessToken = accessToken
    }

    /// Wire shape of one row, shared by push and pull.
    struct WireSpan: Codable {
        var originId: Int64
        var start: String
        var end: String
        var appBundleID: String
        var appName: String
        var title: String?
        var url: String?
        var domain: String?
        var document: String?
        var deviceId: String?
        var seq: String?
    }

    static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public func push(deviceID: String, spans: [Span]) async throws -> [SpanAck] {
        struct Body: Encodable { var deviceId: String; var spans: [WireSpan] }
        struct Reply: Decodable { struct Ack: Decodable { var originId: Int64; var seq: String }; var acked: [Ack] }
        let wire = spans.compactMap { span -> WireSpan? in
            guard let id = span.id else { return nil }
            return WireSpan(originId: id, start: Self.iso.format(span.start), end: Self.iso.format(span.end),
                            appBundleID: span.appBundleID, appName: span.appName, title: span.title,
                            url: span.url, domain: span.domain, document: span.document)
        }
        let data = try await send("POST", path: "spans", body: try JSONEncoder().encode(Body(deviceId: deviceID, spans: wire)))
        return try JSONDecoder().decode(Reply.self, from: data).acked.map { SpanAck(originID: $0.originId, seq: $0.seq) }
    }

    public func pull(since: String?, after: String?, excludingDevice: String) async throws -> PullPage {
        struct Reply: Decodable { var spans: [WireSpan]; var cursor: String?; var more: Bool }
        var query = [URLQueryItem(name: "deviceId", value: excludingDevice)]
        if let after { query.append(.init(name: "after", value: after)) }
        else if let since { query.append(.init(name: "since", value: since)) }
        let data = try await send("GET", path: "spans", query: query)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let rows = try reply.spans.map { w -> SpanStore.RemoteSpan in
            let span = Span(start: try Self.iso.parse(w.start), end: try Self.iso.parse(w.end),
                            appBundleID: w.appBundleID, appName: w.appName, title: w.title,
                            url: w.url, domain: w.domain, document: w.document)
            return SpanStore.RemoteSpan(span: span, deviceID: w.deviceId ?? "", originID: w.originId, seq: w.seq ?? "")
        }
        return PullPage(spans: rows, cursor: reply.cursor, more: reply.more)
    }

    public func deleteAccount() async throws {
        _ = try await send("DELETE", path: "account")
    }

    private func send(_ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard let token = try await accessToken() else { throw CloudError.signedOut }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CloudError.http(status, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
