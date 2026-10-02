import Foundation

/// Rules that decide a window locally, ahead of any Jev verdict: where the
/// answer is already known for the owner's own apps, job hunting and the
/// system's own corners, Jev is neither asked nor paid. Ported from the
/// validated prototype.
public enum JevRules {
    public enum Reason: Equatable, Sendable {
        /// The job keyword or portal that matched.
        case job(String)
        case ownApp
        /// A chat app with no conversation open.
        case assistantIdle
        case blankTab
        case tool
        case cloudConsole
        /// The owner's own local or deployed projects.
        case ownSite
    }

    public struct Hit: Equatable, Sendable {
        public let categoryID: String
        public let reason: Reason
    }

    /// "resume" is left out for terminals: there it means "continue".
    private static let jobTerms = [
        #"\bCL\b"#, "cover.?letter", "resume", "简历", "求职", "co-?op", #"\bJD\b"#, "岗位", "实习", "internship", "面试",  // l10n: data
        "myworkdayjobs", "learninginmotion", "sapsf", "bamboohr", "icims", "ashbyhq", "greenhouse", "teamtailor",
        #"lever\.co"#, #"webflow\.jobs"#, #"gate\.aon"#, "linkedin",
        #"\bBCT\b"#, #"\bBCI\b"#, #"\bRBC\b"#, "quadreal", "seymour", "goverlytics", "klue",
    ]
    private static let jobRegex = try! NSRegularExpression(pattern: jobTerms.joined(separator: "|"), options: .caseInsensitive)
    private static let jobRegexWithoutResume = try! NSRegularExpression(
        pattern: jobTerms.filter { $0 != "resume" }.joined(separator: "|"), options: .caseInsensitive)

    private static let terminals: Set<String> = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp"]
    private static let ownApps: Set<String> = [
        "com.nousresearch.hermes", "com.github.Electron", "dev.fullscreenflow.prototype", "com.allen.guard-mode",
        "com.alllllenshi.brb", "com.alllllenshi.typlus", "local.allen.caption-translator",
    ]
    private static let assistants: Set<String> = ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"]
    private static let assistantIdleTitles: Set<String> = ["", "ChatGPT", "Claude", "Codex", "Select files", "Save"]
    private static let blankTabTitles: Set<String> = ["", "New Tab", "新标签页"]  // l10n: data
    private static let tools: Set<String> = [
        "app.vibeisland.macos", "app.openisland.OpenIsland", "now.typeless.desktop", "com.meta.endo", "com.fobwifi.mac",
        "com.zzd.XnipHelper", "com.macpaw.zh.CleanMyMac4", "com.macpaw.zh.CleanMyMac4.Menu", "com.bjango.istatmenus",
        "com.bjango.istatmenus.status", "com.ccswitch.desktop", "cc.dreamskin.menubar", "com.hegenberg.KeyboardCleanTool",
    ]
    private static let consoleHosts = ["console.aws.amazon.com", "signin.aws.amazon.com"]

    private static let ownSiteHosts = ["localhost", "127.0.0.1", "vercel.app"]

    /// The job keyword rule alone. It outranks the user's app rule.
    public static func job(appBundleID: String, domain: String?, url: String?, title: String?, document: String?) -> Hit? {
        let domain = domain ?? "", url = url ?? "", title = title ?? "", document = document ?? ""
        let haystack = "\(domain) \(title) \(document) \(url)"
        let regex = terminals.contains(appBundleID) || title.contains("Claude Code") ? jobRegexWithoutResume : jobRegex
        guard let hit = regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)),
              let range = Range(hit.range, in: haystack) else { return nil }
        return Hit(categoryID: "jobSearch", reason: .job(String(haystack[range])))
    }

    public static func match(appBundleID: String, domain: String?, url: String?, title: String?, document: String?) -> Hit? {
        let domain = domain ?? "", url = url ?? "", title = title ?? "", document = document ?? ""
        if let hit = job(appBundleID: appBundleID, domain: domain, url: url, title: title, document: document) { return hit }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if appBundleID == "com.google.Chrome", blankTabTitles.contains(trimmed), domain.isEmpty {
            return Hit(categoryID: "utilities", reason: .blankTab)
        }
        if tools.contains(appBundleID) { return Hit(categoryID: "utilities", reason: .tool) }
        if assistants.contains(appBundleID), assistantIdleTitles.contains(trimmed), document.isEmpty {
            return Hit(categoryID: "softwareDev", reason: .assistantIdle)
        }
        let lowered = appBundleID.lowercased()
        if ownApps.contains(appBundleID) || lowered.contains("jarvis") || lowered.contains("timesink") || title.contains("Malibu Workshop") {
            return Hit(categoryID: "softwareDev", reason: .ownApp)
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
