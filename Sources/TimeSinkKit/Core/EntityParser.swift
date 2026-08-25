import Foundation

/// Parses a span's URL into a coarser display-level "entity" grouping key —
/// e.g. a github/gitlab owner/repo, or a youtube channel — for the Activities
/// list's row grouping only. This is purely cosmetic: a category
/// reassignment on an entity row still writes a domain-level override (see
/// `ActivitiesModel.ActivityRow.reassignKey`), never this finer-grained key.
public enum EntityParser {
    /// First-path-segment denylist for github.com/gitlab.com: these are
    /// site-level sections (settings, auth flows, org/marketplace pages,
    /// etc.), not an owner's username, so e.g. `/settings/emails` must not
    /// be mistaken for a 2-segment owner/repo path.
    static let reservedGitHubPaths: Set<String> = [
        "settings", "login", "apps", "orgs", "notifications", "pulls", "issues",
        "marketplace", "sponsors", "explore", "topics", "codespaces", "new",
        "about", "features", "search",
    ]

    private static let ownerRepoDomains: Set<String> = ["github.com", "gitlab.com"]
    private static let youTubeChannelPrefixes: Set<String> = ["channel", "c", "user"]

    /// `nil` unless `urlString`'s path resolves to a recognized entity on
    /// `domain`: github/gitlab `/owner/repo` (>= 2 path segments, first
    /// segment not in `reservedGitHubPaths`), or youtube `/@handle`,
    /// `/channel/…`, `/c/…`, `/user/…` — `/watch` carries no channel
    /// information, so it deliberately stays nil rather than being faked.
    public static func entity(urlString: String, domain: String) -> (key: String, label: String)? {
        guard let components = URLComponents(string: urlString) else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if ownerRepoDomains.contains(domain) {
            guard parts.count >= 2, !reservedGitHubPaths.contains(parts[0].lowercased()) else { return nil }
            let owner = parts[0]
            let repo = parts[1]
            return (key: "\(domain)/\(owner)/\(repo)", label: "\(domain) / \(owner) / \(repo)")
        }

        if domain == "youtube.com" {
            guard let first = parts.first else { return nil }
            if first.hasPrefix("@") {
                return (key: "\(domain)/\(first)", label: "\(domain) / \(first)")
            }
            if youTubeChannelPrefixes.contains(first.lowercased()), parts.count >= 2 {
                let handle = parts[1]
                return (key: "\(domain)/\(first)/\(handle)", label: "\(domain) / \(handle)")
            }
            return nil
        }

        return nil
    }
}
