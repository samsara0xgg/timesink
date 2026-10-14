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
    /// 2-segment owner/repo path. Matched case-insensitively. `copilot`
    /// keeps a chat (`/copilot/c/<id>`) from reading as repo "c"; `users`
    /// is `/users/<name>/projects/...`.
    static let reservedGitHubPaths: Set<String> = [
        "settings", "login", "apps", "orgs", "notifications", "pulls", "issues",
        "marketplace", "sponsors", "explore", "topics", "codespaces", "new",
        "about", "features", "search",
        "trending", "collections", "stars", "dashboard", "account", "security",
        "pricing", "signup", "logout", "organizations", "sessions",
        "copilot", "github-copilot", "users", "enterprise", "enterprises", "team", "readme",
        "customer-stories", "solutions", "resources", "events", "join", "contact", "site",
        "password_reset", "watching",
    ]

    /// The cloud drives macOS keeps under `~/Library`: inside one, the
    /// drive's own root (`.../com~apple~CloudDocs`, `.../GoogleDrive-…`)
    /// stands in for home.
    private static let cloudDriveRoots: Set<String> = ["Mobile Documents", "CloudStorage"]

    /// The project folder `path` is in, for `SessionSegmenter.projectKey`:
    /// `~/Projects/timesink/Sources/x.swift` gives `timesink`, as does
    /// `~/Projects/timesink` itself; outside home, the third component
    /// (`/opt/x/y/...` gives `y`). nil when there is no folder to name:
    ///
    /// - `~/Library` is the system's and the apps', except the cloud drives
    ///   in it, and `/Volumes/<drive>` is an external drive; each of those
    ///   roots stands in for home, so iCloud's `Mobile Documents` or a
    ///   drive's name is never the project.
    /// - The name must be a folder: a file straight inside a container
    ///   (`~/Desktop/notes.md`, `~/Downloads/x.pdf`) names nothing. A last
    ///   component with an extension is taken for a file unless `isFolder`
    ///   (the document was a folder URL, as a terminal's directory is).
    static func projectFolder(path: String, home: String, isFolder: Bool) -> String? {
        guard path != home else { return nil }
        var parts: [String]
        let index: Int
        if path.hasPrefix(home + "/") {
            parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
            if parts.first == "Library" {
                guard parts.count > 3, cloudDriveRoots.contains(parts[1]) else { return nil }
                parts.removeFirst(3)
            }
            index = 1
        } else {
            parts = path.split(separator: "/").map(String.init)
            if parts.first == "Volumes" {
                guard parts.count > 2 else { return nil }
                parts.removeFirst(2)
                index = 1
            } else {
                index = min(2, parts.count - 1)
            }
        }
        guard parts.count >= 2, index < parts.count else { return nil }
        let name = parts[index]
        guard !name.isEmpty else { return nil }
        let isLast = index == parts.count - 1
        if isLast, !isFolder, !(name as NSString).pathExtension.isEmpty { return nil }
        return name
    }

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
