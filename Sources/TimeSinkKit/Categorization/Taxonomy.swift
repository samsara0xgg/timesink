import Foundation

public enum Taxonomy {
    public static let categories: [Category] = [
        Category(id: "softwareDev", name: "软件开发", colorHex: "#3478F6", productivity: 2, sortOrder: 0),
        Category(id: "learning", name: "学习参考", colorHex: "#34C759", productivity: 2, sortOrder: 1),
        Category(id: "writing", name: "写作创作", colorHex: "#30B0C7", productivity: 2, sortOrder: 2),
        Category(id: "business", name: "事务", colorHex: "#5E5CE6", productivity: 1, sortOrder: 3),
        Category(id: "utilities", name: "工具", colorHex: "#8E8E93", productivity: 1, sortOrder: 4),
        Category(id: "communication", name: "沟通", colorHex: "#FF9F0A", productivity: 0, sortOrder: 5),
        Category(id: "news", name: "新闻", colorHex: "#AF52DE", productivity: -1, sortOrder: 6),
        Category(id: "shopping", name: "购物", colorHex: "#FF6482", productivity: -1, sortOrder: 7),
        Category(id: "socialMedia", name: "社交媒体", colorHex: "#FF3B30", productivity: -2, sortOrder: 8),
        Category(id: "entertainment", name: "娱乐", colorHex: "#FFD60A", productivity: -2, sortOrder: 9),
        Category(id: "misc", name: "其他", colorHex: "#98989D", productivity: 0, sortOrder: 10),
        Category(id: "uncategorized", name: "未分类", colorHex: "#C7C7CC", productivity: 0, sortOrder: 11),
    ]

    /// Builtin appCategory seed rows (bundleID -> categoryID), source = "builtin".
    public static let builtinApps: [(bundleID: String, categoryID: String)] = [
        ("com.apple.dt.Xcode", "softwareDev"),
        ("com.microsoft.VSCode", "softwareDev"),
        ("com.apple.Terminal", "softwareDev"),
        ("com.googlecode.iterm2", "softwareDev"),
        ("com.mitchellh.ghostty", "softwareDev"),
        ("com.todesktop.230313mzl4w4u92", "softwareDev"), // Cursor
        ("md.obsidian", "writing"),
        ("com.apple.Notes", "writing"),
        ("notion.id", "writing"),
        ("com.apple.iWork.Pages", "writing"),
        ("com.apple.Preview", "learning"),
        ("com.apple.mail", "communication"),
        ("com.apple.MobileSMS", "communication"),
        ("com.tencent.xinWeChat", "communication"),
        ("us.zoom.xos", "communication"),
        ("com.hnc.Discord", "communication"),
        ("com.spotify.client", "entertainment"),
        ("com.apple.Music", "entertainment"),
        ("com.apple.TV", "entertainment"),
        ("com.valvesoftware.steam", "entertainment"),
        ("com.apple.finder", "utilities"),
        ("com.apple.systempreferences", "utilities"),
        ("com.google.Chrome", "misc"), // Chrome fallback when no URL is available
    ]

    /// Builtin urlRule seed rows (pattern, categoryID, priority), source = "builtin".
    /// Higher priority wins; path-level rules use 200, host-level rules use 100.
    public static let builtinURLRules: [(pattern: String, categoryID: String, priority: Int)] = [
        ("music.youtube.com", "entertainment", 200),
        ("youtube.com/watch", "entertainment", 200),
        ("docs.google.com", "writing", 100),
        ("slides.google.com", "writing", 100),
        ("mail.google.com", "communication", 100),
        ("calendar.google.com", "business", 100),
        ("drive.google.com", "utilities", 100),
        ("meet.google.com", "communication", 100),
        ("scholar.google.com", "learning", 100),
        ("translate.google.com", "learning", 100),
        ("github.com", "softwareDev", 100),
        ("gitlab.com", "softwareDev", 100),
        ("stackoverflow.com", "softwareDev", 100),
        ("leetcode.com", "softwareDev", 100),
        ("localhost", "softwareDev", 100),
        ("127.0.0.1", "softwareDev", 100),
        ("arxiv.org", "learning", 100),
        ("wikipedia.org", "learning", 100),
        ("overleaf.com", "writing", 100),
        ("figma.com", "writing", 100),
        ("chatgpt.com", "learning", 100),
        ("chat.openai.com", "learning", 100),
        ("claude.ai", "learning", 100),
        ("gemini.google.com", "learning", 100),
        ("canvas.", "learning", 100),
        ("brightspace", "learning", 100),
        ("piazza.com", "learning", 100),
        ("crowdmark.com", "learning", 100),
        ("prairielearn", "learning", 100),
        ("chrome://", "utilities", 100),
        ("bilibili.com", "entertainment", 100),
        ("netflix.com", "entertainment", 100),
        ("twitch.tv", "entertainment", 100),
    ]

    /// Additional builtin urlRule rows, seeded by migration v2: social media
    /// and communication hosts not covered by `builtinURLRules`. Without
    /// these, seed-tier domain mappings (which classify e.g. facebook.com as
    /// entertainment, whatsapp.com as entertainment, discord.com as
    /// business) go uncorrected, since seed rows permanently outrank the
    /// future LLM tier. Host-level rules use priority 100, same as the v1
    /// host-level rows.
    public static let v2URLRules: [(pattern: String, categoryID: String, priority: Int)] = [
        ("facebook.com", "socialMedia", 100),
        ("instagram.com", "socialMedia", 100),
        ("tiktok.com", "socialMedia", 100),
        ("twitter.com", "socialMedia", 100),
        (#"re:https?://(www\.)?x\.com"#, "socialMedia", 100),
        ("reddit.com", "socialMedia", 100),
        ("snapchat.com", "socialMedia", 100),
        ("weibo.com", "socialMedia", 100),
        ("pinterest.com", "socialMedia", 100),
        ("linkedin.com", "socialMedia", 100),
        ("whatsapp.com", "communication", 100),
        ("discord.com", "communication", 100),
        ("telegram.org", "communication", 100),
        ("messenger.com", "communication", 100),
        ("slack.com", "communication", 100),
        ("teams.microsoft.com", "communication", 100),
        ("zoom.us", "communication", 100),
        ("outlook.", "communication", 100),
    ]

    /// Builtin titleRule seed rows, seeded by migration v4. Global scope.
    /// Deliberately tiny: a global title substring reclassifies every matching
    /// activity across all apps and sites -- only ship phrases that are
    /// near-unambiguous.
    ///
    /// The first row is `re:`-prefixed rather than a plain `lecture|course`
    /// substring list: bare "course" as a substring false-positives on
    /// natural-language and compound-word titles that have nothing to do
    /// with learning ("Of course I still love you", "Best golf course near
    /// Toronto?", "Concourse (2019)", "CourseView.swift", "discourse",
    /// "racecourse" -- all verified, Task 4 fix report F1). `\bcourse\b`
    /// alone still isn't enough: "course" is a genuine standalone word in
    /// "of course" and "golf course" too, so those two collocations are
    /// excluded with negative lookbehind while "CS540 Course Home" /
    /// "Online Course: Intro to ML" still match.
    public static let builtinTitleRules: [(pattern: String, categoryID: String)] = [
        (#"re:\blecture\b|\b(?<!of )(?<!golf )course\b"#, "learning"),
        ("教程|课程|讲座", "learning"),
        ("pull request|merge request|PR #", "softwareDev"),
    ]
}
