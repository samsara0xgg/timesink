import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import os

public enum CloudAuthError: Error {
    case notConfigured
    case cancelled
    case badCallback
    case noRefreshToken
    case http(Int, String)
}

/// Cognito Hosted UI sign-in (OAuth 2 authorization code + PKCE, through
/// `ASWebAuthenticationSession`) and token custody. The refresh token is the
/// only thing persisted, in the Keychain; the access token lives in memory
/// and is renewed when within a minute of expiry. "Signed in" means a
/// refresh token exists.
@MainActor
public final class CloudAuth {
    public static let refreshTokenAccount = "cloud.refreshToken"

    private let settings: SettingsStore
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "cloud.auth")
    private let anchor = Anchor()
    private var accessToken: String?
    private var accessExpiry: Date = .distantPast

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var isSignedIn: Bool {
        Keychain.get(account: Self.refreshTokenAccount) != nil
    }

    /// Opens the hosted sign-in page and, on success, stores the refresh
    /// token and the account's email. Returns the account's stable id
    /// (`sub`) so the caller can tell a different account from the last one.
    @discardableResult
    public func signIn() async throws -> String {
        guard CloudConfig.isConfigured else { throw CloudAuthError.notConfigured }
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(bytes: 16)

        var components = URLComponents(url: CloudConfig.authDomain.appendingPathComponent("oauth2/authorize"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: CloudConfig.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email"),
            .init(name: "redirect_uri", value: CloudConfig.redirectURI),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let callback = try await present(components.url!)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw CloudAuthError.badCallback
        }

        let tokens = try await token(form: [
            "grant_type": "authorization_code",
            "client_id": CloudConfig.clientID,
            "code": code,
            "redirect_uri": CloudConfig.redirectURI,
            "code_verifier": verifier,
        ])
        guard let refresh = tokens.refresh_token else { throw CloudAuthError.noRefreshToken }
        try Keychain.set(refresh, account: Self.refreshTokenAccount)
        remember(tokens)
        let claims = Self.claims(of: tokens.id_token ?? tokens.access_token)
        settings.setCloudEmail(claims["email"] as? String)
        return claims["sub"] as? String ?? ""
    }

    /// Revokes the refresh token (best effort) and forgets everything local.
    public func signOut() async {
        if let refresh = Keychain.get(account: Self.refreshTokenAccount) {
            _ = try? await post(path: "oauth2/revoke", form: ["token": refresh, "client_id": CloudConfig.clientID])
        }
        forget()
    }

    /// A usable access token, renewed through the refresh token when
    /// needed. nil when signed out -- including when the refresh token was
    /// just rejected (expired or revoked), which is treated as a sign-out.
    public func validAccessToken() async throws -> String? {
        if let accessToken, accessExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = Keychain.get(account: Self.refreshTokenAccount) else { return nil }
        do {
            let tokens = try await token(form: [
                "grant_type": "refresh_token",
                "client_id": CloudConfig.clientID,
                "refresh_token": refresh,
            ])
            remember(tokens)
            return tokens.access_token
        } catch CloudAuthError.http(400, let body) {
            logger.error("refresh rejected, signing out: \(body, privacy: .public)")
            forget()
            return nil
        }
    }

    // MARK: - Tokens

    private struct TokenResponse: Decodable {
        var access_token: String
        var id_token: String?
        var refresh_token: String?
        var expires_in: Double
    }

    private func remember(_ tokens: TokenResponse) {
        accessToken = tokens.access_token
        accessExpiry = Date().addingTimeInterval(tokens.expires_in)
    }

    private func forget() {
        Keychain.delete(account: Self.refreshTokenAccount)
        accessToken = nil
        accessExpiry = .distantPast
        settings.setCloudEmail(nil)
    }

    private func token(form: [String: String]) async throws -> TokenResponse {
        let data = try await post(path: "oauth2/token", form: form)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func post(path: String, form: [String: String]) async throws -> Data {
        var request = URLRequest(url: CloudConfig.authDomain.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CloudAuthError.http(status, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    // MARK: - Browser session

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "timesink") { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? CloudAuthError.cancelled)
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    // MARK: - Encoding helpers

    /// The JWT's payload as a dictionary; empty on any malformed input.
    static func claims(of jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func randomURLSafe(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return base64URL(Data(buffer))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}
