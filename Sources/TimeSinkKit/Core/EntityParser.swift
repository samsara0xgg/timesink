import Foundation

/// Parses a span's URL into a coarser display-level "entity" grouping key —
/// e.g. a github/gitlab owner/repo(/subgroup), or a youtube channel — for
/// the Activities list's row grouping only. This is purely cosmetic: a
/// category reassignment on an entity row still writes a domain-level
/// override (see `ActivitiesModel.ActivityRow.reassignKey`), never this
/// finer-grained key.
public enum EntityParser {
    /// First-path-segment denylist for github.com: these are site-level
    /// sections (settings, auth flows, org/marketplace pages, trending
    /// feeds, account/billing pages, etc.), not an owner's username, so e.g.
    /// `/settings/emails` or `/trending/swift` must not be mistaken for a
    /// 2-segment owner/repo path. Matched case-insensitively.
    static let reservedGitHubPaths: Set<String> = [
        "settings", "login", "apps", "orgs", "notifications", "pulls", "issues",
        "marketplace", "sponsors", "explore", "topics", "codespaces", "new",
        "about", "features", "search",
        "trending", "collections", "stars", "dashboard", "account", "security",
        "pricing", "signup", "logout", "organizations", "sessions",
    ]

    /// First-path-segment denylist for gitlab.com — a different site
    /// structure than github's, so a separate set (see `entity`'s gitlab
    /// branch). `"-"` covers a bare `/-/…` route hanging directly off the
    /// domain root (defense in depth: the `/-/`-strip below already empties
    /// `segments` for that case, but this keeps the intent explicit rather
    /// than relying solely on the segment-count guard).
    private static let gitlabReservedPaths: Set<String> = [
        "dashboard", "users", "groups", "projects", "help", "admin", "explore", "-",
    ]

    /// `/c/…` and `/user/…` are both legacy vanity-URL forms for the same
    /// kind of channel identity, so they share one key namespace; `/channel/…`
    /// (a distinct, stable channel-ID namespace) is intentionally not merged
    /// into it.
    private static let youTubeMergedHandlePrefixes: Set<String> = ["c", "user"]

    /// `nil` unless `urlString`'s path resolves to a recognized entity on
    /// `domain`:
    /// - **github.com**: `/owner/repo` — >= 2 path segments, first segment
    ///   not in `reservedGitHubPaths`.
    /// - **gitlab.com**: path truncated at a `/-/` segment (GitLab's own
    ///   project-chrome separator, e.g. `/-/issues`, `/-/merge_requests`),
    ///   then >= 2 remaining segments with the first not in a
    ///   gitlab-specific reserved set. The full remaining segment chain
    ///   becomes the key/label (not just the first two), so subgroup
    ///   projects (`group/subgroup/projA` vs `.../projB`) stay distinct
    ///   rather than collapsing onto a shared 2-segment prefix.
    /// - **youtube.com** (or any `*.youtube.com` subdomain, e.g.
    ///   `m.youtube.com`/`music.youtube.com`): `/@handle` (handle must be
    ///   non-empty), `/channel/…`, or `/c/…` / `/user/…` (merged — see
    ///   `youTubeMergedHandlePrefixes`). `/watch` carries no channel
    ///   information, so it deliberately stays `nil` rather than being faked.
    ///
    /// Path segments are split on the URL's *percent-encoded* path (so an
    /// escaped slash inside a single segment, e.g. `owner%2Frepo`, can't
    /// masquerade as two segments) and only percent-decoded afterward, for
    /// display in the label. Entity keys are lowercased for case-insensitive
    /// dedup (`O/R` and `o/r` collapse to one row); labels keep the original
    /// casing.
    public static func entity(urlString: String, domain: String) -> (key: String, label: String)? {
        // Most spans are on other sites; don't parse their URLs at all.
        guard domain == "github.com" || domain == "gitlab.com" || domain == "youtube.com" || domain.hasSuffix(".youtube.com"),
              let components = URLComponents(string: urlString) else { return nil }
        let parts = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }

        if domain == "github.com" {
            guard parts.count >= 2, !reservedGitHubPaths.contains(parts[0].lowercased()) else { return nil }
            let owner = parts[0]
            let repo = parts[1]
            return (key: "\(domain)/\(owner)/\(repo)".lowercased(), label: "\(domain) / \(owner) / \(repo)")
        }

        if domain == "gitlab.com" {
            var segments = parts
            if let dashIndex = segments.firstIndex(of: "-") {
                segments = Array(segments[..<dashIndex])
            }
            guard segments.count >= 2, !gitlabReservedPaths.contains(segments[0].lowercased()) else { return nil }
            let key = "\(domain)/" + segments.joined(separator: "/")
            let label = "\(domain) / " + segments.joined(separator: " / ")
            return (key: key.lowercased(), label: label)
        }

        if domain == "youtube.com" || domain.hasSuffix(".youtube.com") {
            guard let first = parts.first else { return nil }

            if first.hasPrefix("@") {
                guard first.count > 1 else { return nil }
                return (key: "\(domain)/\(first)".lowercased(), label: "\(domain) / \(first)")
            }

            let lowered = first.lowercased()
            guard parts.count >= 2 else { return nil }
            let handle = parts[1]
            if lowered == "channel" {
                return (key: "\(domain)/channel/\(handle)".lowercased(), label: "\(domain) / \(handle)")
            }
            if youTubeMergedHandlePrefixes.contains(lowered) {
                return (key: "\(domain)/c/\(handle)".lowercased(), label: "\(domain) / \(handle)")
            }
            return nil
        }

        return nil
    }
}
