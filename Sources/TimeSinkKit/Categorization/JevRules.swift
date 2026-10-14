import Foundation

/// Rules that decide a window locally, ahead of any Jev verdict: where the
/// answer is the same for everyone (job boards, local development, the
/// system's own corners), Jev is neither asked nor paid. Nothing here is
/// about one person's own apps or sites: those are the user's own rules.
public enum JevRules {
    public enum Reason: Equatable, Sendable {
        /// The job keyword or job site that matched.
        case job(String)
        /// A chat app with no conversation open.
        case assistantIdle
        case blankTab
        case tool
        case cloudConsole
        /// A page served from this Mac (localhost): local development.
        case ownSite
    }

    public struct Hit: Equatable, Sendable {
        public let categoryID: String
        public let reason: Reason
    }

    /// Words that only ever mean job hunting, looked for in the window title
    /// and the document name, never in a URL (where `?resume=1` means
    /// something else). "resume" counts only as a word of its own, and not
    /// for terminals or Claude Code, where it means "continue".
    private static let jobTerms = ["cover.?letter", "简历", "求职", "岗位", "实习", #"\binternships?\b"#, "面试"]  // l10n: data
    private static let resumeTerm = #"\br[eé]sum[eé]s?\b"#
    private static let jobRegex = try! NSRegularExpression(pattern: (jobTerms + [resumeTerm]).joined(separator: "|"), options: .caseInsensitive)
    private static let jobRegexWithoutResume = try! NSRegularExpression(pattern: jobTerms.joined(separator: "|"), options: .caseInsensitive)

    /// Job boards and application portals, matched on the site's host (it or
    /// a subdomain of it) and, for a site that is more than a job board, on
    /// the path its job pages live under. Recruiters' own consoles are other
    /// hosts (hire.lever.co, app.greenhouse.io) and are not here.
    private static let jobSites: [(host: String, path: String?)] = [
        ("jobs.lever.co", nil), ("boards.greenhouse.io", nil), ("job-boards.greenhouse.io", nil),
        ("myworkdayjobs.com", nil), ("jobs.ashbyhq.com", nil), ("icims.com", nil), ("teamtailor.com", nil),
        ("bamboohr.com", "/careers"), ("linkedin.com", "/jobs"),
    ]

    private static let terminals: Set<String> = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp"]
    private static let assistants: Set<String> = ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"]
    private static let assistantIdleTitles: Set<String> = ["", "ChatGPT", "Claude", "Codex", "Select files", "Save"]
    private static let blankTabTitles: Set<String> = ["", "New Tab", "新标签页"]  // l10n: data
    private static let tools: Set<String> = [
        "app.vibeisland.macos", "app.openisland.OpenIsland", "now.typeless.desktop", "com.meta.endo", "com.fobwifi.mac",
        "com.zzd.XnipHelper", "com.macpaw.zh.CleanMyMac4", "com.macpaw.zh.CleanMyMac4.Menu", "com.bjango.istatmenus",
        "com.bjango.istatmenus.status", "com.ccswitch.desktop", "cc.dreamskin.menubar", "com.hegenberg.KeyboardCleanTool",
    ]
    private static let consoleHosts = ["console.aws.amazon.com", "signin.aws.amazon.com"]

    private static let ownSiteHosts = ["localhost", "127.0.0.1"]

    /// The job rule alone: a job word in the title or document name, or a job
    /// site. It ranks below every rule of the user's own (see `Classifier`).
    public static func job(appBundleID: String, domain: String?, url: String?, title: String?, document: String?) -> Hit? {
        let title = title ?? "", document = document ?? ""
        let haystack = "\(title) \(document)"
        let regex = terminals.contains(appBundleID) || title.contains("Claude Code") ? jobRegexWithoutResume : jobRegex
        if let hit = regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)),
           let range = Range(hit.range, in: haystack) {
            return Hit(categoryID: "jobSearch", reason: .job(String(haystack[range])))
        }
        guard let site = jobSite(domain: domain, url: url) else { return nil }
        return Hit(categoryID: "jobSearch", reason: .job(site))
    }

    /// The job site `domain` (and, where it matters, `url`'s path) is on; only
    /// the host and the path are read, never the query string.
    static func jobSite(domain: String?, url: String?) -> String? {
        guard let domain = domain?.lowercased(), !domain.isEmpty else { return nil }
        for site in jobSites where domain == site.host || domain.hasSuffix("." + site.host) {
            guard let prefix = site.path else { return site.host }
            let path = url.flatMap { URLComponents(string: $0)?.path.lowercased() } ?? ""
            if path == prefix || path.hasPrefix(prefix + "/") { return site.host + prefix }
        }
        return nil
    }

    /// `job: false` leaves the job rule out: it is Jev's, and only applies when Jev is on.
    public static func match(appBundleID: String, domain: String?, url: String?, title: String?, document: String?, job withJob: Bool = true) -> Hit? {
        let domain = domain ?? "", url = url ?? "", title = title ?? "", document = document ?? ""
        if withJob, let hit = job(appBundleID: appBundleID, domain: domain, url: url, title: title, document: document) { return hit }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if appBundleID == "com.google.Chrome", blankTabTitles.contains(trimmed), domain.isEmpty {
            return Hit(categoryID: "utilities", reason: .blankTab)
        }
        if tools.contains(appBundleID) { return Hit(categoryID: "utilities", reason: .tool) }
        if assistants.contains(appBundleID), assistantIdleTitles.contains(trimmed), document.isEmpty {
            return Hit(categoryID: "softwareDev", reason: .assistantIdle)
        }
        if consoleHosts.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
            return Hit(categoryID: "softwareDev", reason: .cloudConsole)
        }
        if ownSiteHosts.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
            return Hit(categoryID: "softwareDev", reason: .ownSite)
        }
        return nil
    }
}
