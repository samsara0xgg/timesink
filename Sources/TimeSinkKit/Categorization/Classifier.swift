import Foundation

/// Snapshot of the classification tables (domain overrides, app defaults, URL
/// rules) that `Classifier` reads from. Built and refreshed by
/// `CategoryResolver`; kept as a plain Sendable value so it can be captured
/// freely.
public struct ClassificationContext: Sendable {
    public var domainMap: [String: DomainEntry]
    public var appMap: [String: DomainEntry]
    public var urlRules: [URLRule]
    public var titleRules: [TitleRule]

    public init(domainMap: [String: DomainEntry], appMap: [String: DomainEntry], urlRules: [URLRule],
                titleRules: [TitleRule] = []) {
        self.domainMap = domainMap
        self.appMap = appMap
        self.urlRules = urlRules
        self.titleRules = titleRules
    }
}

/// Pure, stateless priority resolution: given one activity's identifying
/// fields and a `ClassificationContext` snapshot, decides which category it
/// belongs to.
///
/// Priority order (first hit wins):
/// 1. `title` matches a user-sourced `titleRule` in scope (`context.titleRules`
///    is expected pre-sorted scoped-first by the caller -- see
///    `CategoryResolver.refresh()`) -- the most specific expression of user
///    intent, so it outranks even the user's own domain override.
/// 2. `domain` has a user-sourced entry reachable by walking suffixes of the
///    domain (dropping leftmost labels down to a minimum of 2 labels) -- an
///    explicit user correction beats every remaining automatic tier.
/// 3. `url` is non-nil: scan `context.urlRules` where `source == "user"` in
///    order, first `matches` wins.
/// 4. `title` matches a non-user-sourced (builtin) `titleRule` in scope.
/// 5. `url` is non-nil: scan `context.urlRules` where `source != "user"` in
///    order, first `matches` wins.
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

        // 0. user title rules -- top tier: more specific than a domain
        //    override, so it outranks it even though it's checked first.
        if let title, !title.isEmpty {
            for r in context.titleRules where r.source == "user"
                && scopeMatches(r, scopeKey: scopeKey) && titleMatches(pattern: r.pattern, title: title) {
                return r.categoryID
            }
        }

        // 1. user domain override -- suffix-aware, so correcting youtube.com
        //    also covers m.youtube.com.
        if let domain, let categoryID = suffixMatch(domain: domain, source: "user", context: context) {
            return categoryID
        }

        // 2. user URL rules (array is user-first sorted by the caller; the
        //    original single loop splits into two source-filtered passes so
        //    builtin title seeds can slot in between).
        if let url {
            for rule in context.urlRules where rule.source == "user" && matches(rule, url: url) {
                return rule.categoryID
            }
        }

        // 3. builtin title seeds.
        if let title, !title.isEmpty {
            for r in context.titleRules where r.source != "user"
                && scopeMatches(r, scopeKey: scopeKey) && titleMatches(pattern: r.pattern, title: title) {
                return r.categoryID
            }
        }

        // 4. builtin URL rules.
        if let url {
            for rule in context.urlRules where rule.source != "user" && matches(rule, url: url) {
                return rule.categoryID
            }
        }

        // 5. curated overlay outranks the WhoTracks.me seed: the upstream data
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

    /// `re:`-prefixed pattern -> whole-string regular expression, matched per
    /// the same regex conventions as `matches(pattern:in:)`. Any other
    /// pattern is split on `|` into keywords; any non-empty keyword that
    /// case-insensitively substring-matches `title` is a hit.
    public static func titleMatches(pattern: String, title: String) -> Bool {
        if pattern.hasPrefix("re:") {
            return matches(pattern: pattern, in: title)
        }
        return pattern.split(separator: "|").contains { keyword in
            !keyword.isEmpty && title.range(of: keyword, options: [.caseInsensitive]) != nil
        }
    }

    /// A `titleRule`'s scope matches when it's global (`scopeKey.isEmpty`) or
    /// exactly equal to the span's scope key (`domain ?? appBundleID`).
    public static func scopeMatches(_ rule: TitleRule, scopeKey: String) -> Bool {
        rule.scopeKey.isEmpty || rule.scopeKey == scopeKey
    }
}
