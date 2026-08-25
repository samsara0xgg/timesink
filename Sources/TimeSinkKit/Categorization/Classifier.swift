import Foundation

/// Snapshot of the classification tables (domain overrides, app defaults, URL
/// rules, title rules) that `Classifier` reads from. Built and refreshed by
/// `CategoryResolver`; kept as a plain Sendable value so it can be captured
/// freely.
///
/// `titleRules` (like `urlRules`) is expected pre-sorted by the caller (see
/// `CategoryResolver.refresh()`: scoped rows first, then `priority`
/// descending, then `id` descending) and pre-filtered to `enabled == true`
/// -- the classification chain does not re-sort or re-check `enabled`.
public struct ClassificationContext: Sendable {
    public var domainMap: [String: DomainEntry]
    public var appMap: [String: DomainEntry]
    public var urlRules: [URLRule]
    public var titleRules: [TitleRule]

    /// `titleRules` compiled once at construction time so the hot
    /// classification path never re-parses a `|`-keyword list or
    /// recompiles an `NSRegularExpression` per call -- measured +36%
    /// (7394ms -> 10035ms per 50k spans) before this precompilation, with
    /// `re:` recompilation alone accounting for 463ms/50k vs 55ms
    /// precompiled (Task 4 fix report F2).
    let compiledTitleRules: [CompiledTitleRule]

    public init(domainMap: [String: DomainEntry], appMap: [String: DomainEntry], urlRules: [URLRule],
                titleRules: [TitleRule] = []) {
        self.domainMap = domainMap
        self.appMap = appMap
        self.urlRules = urlRules
        self.titleRules = titleRules
        self.compiledTitleRules = titleRules.map(CompiledTitleRule.init)
    }
}

/// A `TitleRule` compiled once at `ClassificationContext` construction:
/// `|`-keyword lists are lowercased/trimmed/empty-filtered ahead of time,
/// and a `re:`-prefixed pattern's `NSRegularExpression` is built once
/// instead of per classification call. Keyword extraction shares
/// `Classifier.titleKeywords(from:)` with the pure `titleMatches(pattern:
/// title:)` function so the two paths agree (see
/// `testCompiledTitleRuleAgreesWithTitleMatches`).
struct CompiledTitleRule: Sendable {
    let source: String
    let scopeKey: String
    let categoryID: String
    private let isRegexPattern: Bool
    private let regex: NSRegularExpression?
    private let keywords: [String]

    init(_ rule: TitleRule) {
        source = rule.source
        scopeKey = rule.scopeKey
        categoryID = rule.categoryID
        if rule.pattern.hasPrefix("re:") {
            isRegexPattern = true
            let body = String(rule.pattern.dropFirst(3))
            // F4: an empty (or unparseable) regex must never match every
            // title -- `try?` plus the empty-body guard both fold to `nil`.
            regex = body.isEmpty ? nil : try? NSRegularExpression(pattern: body, options: [.caseInsensitive])
            keywords = []
        } else {
            isRegexPattern = false
            regex = nil
            keywords = Classifier.titleKeywords(from: rule.pattern)
        }
    }

    /// `loweredTitle` is `title.lowercased()`, hoisted once per
    /// `Classifier.categoryID` call by the caller rather than recomputed
    /// per rule.
    func matches(title: String, loweredTitle: String) -> Bool {
        if isRegexPattern {
            guard let regex else { return false }
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            return regex.firstMatch(in: title, options: [], range: range) != nil
        }
        return keywords.contains { loweredTitle.contains($0) }
    }
}

/// Pure, stateless priority resolution: given one activity's identifying
/// fields and a `ClassificationContext` snapshot, decides which category it
/// belongs to.
///
/// Priority order (first hit wins):
/// 1. `title` matches a user-sourced `titleRule` in scope (`context.titleRules`
///    / `context.compiledTitleRules` is expected pre-sorted scoped-first by
///    the caller -- see `CategoryResolver.refresh()`) -- the most specific
///    expression of user intent, so it outranks even the user's own domain
///    override.
/// 2. `domain` has a user-sourced entry reachable by walking suffixes of the
///    domain (dropping leftmost labels down to a minimum of 2 labels) -- an
///    explicit user correction beats every remaining automatic tier.
/// 3. `url` is non-nil: scan `context.urlRules` where `source == "user"` in
///    order, first `matches` wins (the array is expected to already be
///    sorted by the caller -- see `CategoryResolver.refresh()`).
/// 4. `title` matches a non-user-sourced (builtin) `titleRule` in scope.
/// 5. `url` is non-nil: scan `context.urlRules` where `source != "user"` in
///    order, first `matches` wins (same pre-sorted array as tier 3, the
///    non-user remainder).
/// 6. `domain` has a curated-sourced entry reachable by the same suffix walk.
/// 7. `domain` has a seed-sourced entry reachable by the same suffix walk.
/// 8. `url == nil` (non-browser activity): `appMap[appBundleID]`.
/// 9. `domain` has a `domainMap` entry with `source == "llm"` (exact match
///    only).
/// 10. `"uncategorized"`.
public enum Classifier {
    public static func categoryID(
        appBundleID: String,
        url: String?,
        domain: String?,
        title: String?,
        context: ClassificationContext
    ) -> String {
        let scopeKey = domain ?? appBundleID
        // Hoisted once per call (not per rule) and reused by tier 4 below --
        // stays nil for a nil/empty title, keeping that path zero-cost.
        var loweredTitle: String?

        // 1. user title rules -- top tier: more specific than a domain
        //    override, so it outranks it even though it's checked first.
        if let title, !title.isEmpty {
            let lowered = title.lowercased()
            loweredTitle = lowered
            for r in context.compiledTitleRules where r.source == "user"
                && scopeMatches(ruleScopeKey: r.scopeKey, scopeKey: scopeKey)
                && r.matches(title: title, loweredTitle: lowered) {
                return r.categoryID
            }
        }

        // 2. user domain override -- suffix-aware, so correcting youtube.com
        //    also covers m.youtube.com.
        if let domain, let categoryID = suffixMatch(domain: domain, source: "user", context: context) {
            return categoryID
        }

        // 3. user URL rules (array is user-first sorted by the caller; the
        //    original single loop splits into two source-filtered passes so
        //    builtin title seeds can slot in between).
        if let url {
            for rule in context.urlRules where rule.source == "user" && matches(rule, url: url) {
                return rule.categoryID
            }
        }

        // 4. builtin title seeds.
        if let title, let loweredTitle {
            for r in context.compiledTitleRules where r.source != "user"
                && scopeMatches(ruleScopeKey: r.scopeKey, scopeKey: scopeKey)
                && r.matches(title: title, loweredTitle: loweredTitle) {
                return r.categoryID
            }
        }

        // 5. builtin URL rules.
        if let url {
            for rule in context.urlRules where rule.source != "user" && matches(rule, url: url) {
                return rule.categoryID
            }
        }

        // 6. curated overlay outranks the WhoTracks.me seed: the upstream data
        //    has zero coverage of the dev/writing ecosystem and systematic
        //    mislabels that the overlay corrects.
        if let domain, let categoryID = suffixMatch(domain: domain, source: "curated", context: context) {
            return categoryID
        }

        if let domain, let categoryID = suffixMatch(domain: domain, source: "seed", context: context) {
            return categoryID
        }

        if url == nil, let entry = context.appMap[appBundleID] {
            return entry.categoryID
        }

        if let domain, let entry = context.domainMap[domain], entry.source == "llm" {
            return entry.categoryID
        }

        return "uncategorized"
    }

    /// Exact match first (this is what lets single-label domains like
    /// `localhost` match at all), then walks suffixes dropping leftmost
    /// labels down to a minimum of 2 (`com` alone is never tried).
    private static func suffixMatch(domain: String, source: String, context: ClassificationContext) -> String? {
        if let entry = context.domainMap[domain], entry.source == source {
            return entry.categoryID
        }
        var labels = domain.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return nil }
        labels.removeFirst()
        while labels.count >= 2 {
            let candidate = labels.joined(separator: ".")
            if let entry = context.domainMap[candidate], entry.source == source {
                return entry.categoryID
            }
            labels.removeFirst()
        }
        return nil
    }

    /// A `re:`-prefixed pattern is matched as a case-insensitive regular
    /// expression (prefix stripped); any other pattern is a case-insensitive
    /// substring match.
    public static func matches(_ rule: URLRule, url: String) -> Bool {
        matches(pattern: rule.pattern, in: url)
    }

    /// `re:`-prefixed pattern -> case-insensitive regular expression (prefix
    /// stripped); any other pattern -> case-insensitive substring match.
    public static func matches(pattern: String, in text: String) -> Bool {
        if pattern.hasPrefix("re:") {
            let regex = String(pattern.dropFirst(3))
            return text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return text.range(of: pattern, options: [.caseInsensitive]) != nil
    }

    /// `re:`-prefixed pattern -> whole-string regular expression (case
    /// insensitive), matched unanchored -- except a pattern that is exactly
    /// `"re:"` (empty body) never matches anything, rather than compiling to
    /// the empty regex that matches every title (F4; deliberately narrower
    /// than `matches(pattern:in:)`, whose URL-rule-facing empty-regex
    /// behavior is left as-is). Any other pattern is split on `|` into
    /// `titleKeywords(from:)`; any keyword that case-insensitively
    /// substring-matches `title` is a hit. This pure function and
    /// `CompiledTitleRule.matches(title:loweredTitle:)` implement the same
    /// semantics via the shared `titleKeywords(from:)` helper -- see
    /// `testCompiledTitleRuleAgreesWithTitleMatches`.
    public static func titleMatches(pattern: String, title: String) -> Bool {
        if pattern.hasPrefix("re:") {
            let body = String(pattern.dropFirst(3))
            guard !body.isEmpty else { return false }
            return title.range(of: body, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let loweredTitle = title.lowercased()
        return titleKeywords(from: pattern).contains { loweredTitle.contains($0) }
    }

    /// Splits a `|`-joined keyword pattern into lowercased, whitespace-trimmed,
    /// non-empty keywords (F3: a bare or whitespace-only keyword -- e.g. the
    /// trailing piece of `"lecture| "` -- must never survive to match every
    /// title that contains a space). Shared by `titleMatches` and
    /// `CompiledTitleRule` so both paths agree.
    static func titleKeywords(from pattern: String) -> [String] {
        pattern.split(separator: "|").compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed.lowercased()
        }
    }

    /// A `titleRule`'s scope matches when it's global (`scopeKey.isEmpty`) or
    /// exactly equal to the span's scope key (`domain ?? appBundleID`).
    public static func scopeMatches(_ rule: TitleRule, scopeKey: String) -> Bool {
        scopeMatches(ruleScopeKey: rule.scopeKey, scopeKey: scopeKey)
    }

    static func scopeMatches(ruleScopeKey: String, scopeKey: String) -> Bool {
        ruleScopeKey.isEmpty || ruleScopeKey == scopeKey
    }
}
