import Foundation

public enum CloudError: LocalizedError {
    case signedOut
    case http(Int, String)
    /// 429: this account's per-minute or per-day allowance is spent
    /// (handler.py), or the API's shared cap. `retryAfter` is the server's
    /// Retry-After in seconds, 0 when it sent none.
    case rateLimited(retryAfter: Int)

    public var errorDescription: String? {
        switch self {
        case .signedOut: String(localized: "需要重新登录")
        case .http(let status, _): String(localized: "服务器返回 \(status)")
        case .rateLimited(let seconds): String(localized: "请求太频繁（HTTP 429），\(max(seconds, 1)) 秒后重试。")
        }
    }
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
/// (`after` while `more`, `since` on the next pass): the last row the server
/// read, this device's own included, so it moves even on a page with no
/// `spans`. nil when the account has nothing yet. `skipped` counts rows that
/// could not be read and were left out rather than failing the page.
public struct PullPage: Sendable {
    public let spans: [SpanStore.RemoteSpan]
    public let cursor: String?
    public let more: Bool
    public let skipped: Int
    public init(spans: [SpanStore.RemoteSpan], cursor: String?, more: Bool, skipped: Int = 0) {
        self.spans = spans
        self.cursor = cursor
        self.more = more
        self.skipped = skipped
    }
}

/// The three calls `SyncEngine` makes. `HTTPCloud` is the real one; tests
/// substitute an in-memory fake.
public protocol SpanCloud: Sendable {
    /// `spans` are this device's rows; each one's `id` is its originId.
    func push(deviceID: String, spans: [Span]) async throws -> [SpanAck]
    /// `since` widens by the server's overlap; `after` pages exactly.
    func pull(since: String?, after: String?, excludingDevice: String) async throws -> PullPage
    /// Accepted (202) once every device is signed out and turned away; the
    /// server empties the account in the background.
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
    /// The same without the fraction, which the server also accepts.
    static let isoWhole = Date.ISO8601FormatStyle()

    /// The server's per-field caps (handler.py LIMITS), in Unicode scalars
    /// as Python's len() counts them. The server cuts a longer value too;
    /// cutting here keeps the request small. The local row keeps its full
    /// value; only the wire copy is cut.
    struct FieldLimits {
        static let appBundleID = 255
        static let appName = 255
        static let title = 1024
        static let url = 2048
        static let domain = 255
        static let document = 2048
    }

    static func cut(_ s: String, to limit: Int) -> String {
        let scalars = s.unicodeScalars
        guard scalars.count > limit else { return s }
        return String(String.UnicodeScalarView(scalars.prefix(limit)))
    }

    static func wire(_ span: Span) -> WireSpan? {
        guard let id = span.id else { return nil }
        let title: String? = span.title.map { Self.cut($0, to: FieldLimits.title) }
        let url: String? = span.url.map { Self.cut($0, to: FieldLimits.url) }
        let domain: String? = span.domain.map { Self.cut($0, to: FieldLimits.domain) }
        let document: String? = span.document.map { Self.cut($0, to: FieldLimits.document) }
        return WireSpan(originId: id, start: iso.format(span.start), end: iso.format(span.end),
                        appBundleID: cut(span.appBundleID, to: FieldLimits.appBundleID),
                        appName: cut(span.appName, to: FieldLimits.appName),
                        title: title, url: url, domain: domain, document: document)
    }

    public func push(deviceID: String, spans: [Span]) async throws -> [SpanAck] {
        struct Body: Encodable { var deviceId: String; var spans: [WireSpan] }
        // `acked` also lists rows the server refused for impossible times
        // (end before start); they can never be stored, so they count as
        // done rather than being resent on every pass.
        struct Reply: Decodable { struct Ack: Decodable { var originId: Int64; var seq: String }; var acked: [Ack] }
        let wire = spans.compactMap(Self.wire)
        let data = try await send("POST", path: "spans", body: try JSONEncoder().encode(Body(deviceId: deviceID, spans: wire)))
        return try JSONDecoder().decode(Reply.self, from: data).acked.map { SpanAck(originID: $0.originId, seq: $0.seq) }
    }

    public func pull(since: String?, after: String?, excludingDevice: String) async throws -> PullPage {
        var query = [URLQueryItem(name: "deviceId", value: excludingDevice)]
        if let after { query.append(.init(name: "after", value: after)) }
        else if let since { query.append(.init(name: "since", value: since)) }
        let data = try await send("GET", path: "spans", query: query)
        return try Self.page(from: data)
    }

    /// A row that fails to decode decodes as nil instead of failing its
    /// whole page.
    struct LossyWireSpan: Decodable {
        let wire: WireSpan?
        init(from decoder: any Decoder) throws {
            wire = try? WireSpan(from: decoder)
        }
    }

    /// Reads a pull reply row by row. One unreadable row -- a missing
    /// field, a time this build cannot parse, an end before its start --
    /// is skipped and counted; the page and its cursor still count, so a
    /// bad row can never pin the pull in place.
    static func page(from data: Data) throws -> PullPage {
        struct Reply: Decodable { var spans: [LossyWireSpan]; var cursor: String?; var more: Bool }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        var rows: [SpanStore.RemoteSpan] = []
        rows.reserveCapacity(reply.spans.count)
        for lossy in reply.spans {
            if let wire = lossy.wire, let row = remote(wire) { rows.append(row) }
        }
        return PullPage(spans: rows, cursor: reply.cursor, more: reply.more, skipped: reply.spans.count - rows.count)
    }

    static func remote(_ w: WireSpan) -> SpanStore.RemoteSpan? {
        guard let start = instant(w.start), let end = instant(w.end), start <= end,
              let device = w.deviceId, !device.isEmpty, let seq = w.seq, !seq.isEmpty else { return nil }
        let span = Span(start: start, end: end, appBundleID: w.appBundleID, appName: w.appName, title: w.title,
                        url: w.url, domain: w.domain, document: w.document)
        return SpanStore.RemoteSpan(span: span, deviceID: device, originID: w.originId, seq: seq)
    }

    static func instant(_ s: String) -> Date? {
        if let date = try? iso.parse(s) { return date }
        return try? isoWhole.parse(s)
    }

    /// Retry-After as seconds; 0 when absent or not a number of seconds
    /// (the HTTP-date form is not something this API sends).
    static func retryAfter(_ header: String?) -> Int {
        guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return 0 }
        return seconds
    }

    public func deleteAccount() async throws {
        // 202: the server signs every device out and turns them away, then
        // empties the account in the background. Any 2xx is success.
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
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 429 {
            throw CloudError.rateLimited(retryAfter: Self.retryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(status) else {
            throw CloudError.http(status, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
