import Foundation

/// Outputs of the `TimeSink` CDK stack (`cloud/infra`), pasted here after
/// `npx cdk deploy`. Public values, not secrets: the app client has no
/// secret and proves itself with PKCE.
public enum CloudConfig {
    public static let authDomain = URL(string: "https://timesink-301126926693.auth.us-west-2.amazoncognito.com")!
    public static let clientID = "4p7hbvt021pqj7qa65nul7d6gh"
    public static let apiBase = URL(string: "https://zxnxd85dll.execute-api.us-west-2.amazonaws.com")!
    /// Registered in packaging/Info.plist (CFBundleURLSchemes) and as the
    /// app client's callback URL.
    public static let redirectURI = "timesink://auth"

    /// False until a deployment's outputs replace the placeholders; the
    /// account pane says so instead of offering a sign-in that cannot work.
    public static var isConfigured: Bool { clientID != "REPLACE" }
}
