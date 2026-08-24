import Foundation

/// Snapshot of the classification tables (domain overrides, app defaults, URL
/// rules) that `Classifier` reads from. Built and refreshed by
/// `CategoryResolver`; kept as a plain Sendable value so it can be captured
/// freely.
public struct ClassificationContext: Sendable {
    public var domainMap: [String: DomainEntry]
    public var appMap: [String: DomainEntry]
    public var urlRules: [URLRule]

    public init(domainMap: [String: DomainEntry], appMap: [String: DomainEntry], urlRules: [URLRule]) {
        self.domainMap = domainMap
        self.appMap = appMap
        self.urlRules = urlRules
    }
}

/// Pure, stateless priority resolution: given one activity's identifying
/// fields and a `ClassificationContext` snapshot, decides which category it
/// belongs to.
///
/// Priority order (first hit wins):
/// 1. `domain` has a user-sourced entry reachable by walking suffixes of the
///    domain (dropping leftmost labels down to a minimum of 2 labels) -- an
///    explicit user correction beats every automatic tier.
/// 2. `url` is non-nil: scan `context.urlRules` in order, first `matches` wins
///    (the array is expected to already be sorted by the caller -- see
///    `CategoryResolver.refresh()`).
/// 3. `domain` has a curated-sourced entry reachable by the same suffix walk.
/// 4. `domain` has a seed-sourced entry reachable by the same suffix walk.
/// 5. `url == nil` (non-browser activity): `appMap[appBundleID]`.
/// 6. `domain` has a `domainMap` entry with `source == "llm"` (exact match
///    only).
/// 7. `"uncategorized"`.
public enum Classifier {
    public static func categoryID(
        appBundleID: String,
        url: String?,
        domain: String?,
        context: ClassificationContext
    ) -> String {
        // 1. user override -- suffix-aware, so correcting youtube.com also
        //    covers m.youtube.com. Checked before URL rules: an explicit user
        //    correction must beat every automatic tier.
        if let domain, let categoryID = suffixMatch(domain: domain, source: "user", context: context) {
            return categoryID
        }

        if let url {
            for rule in context.urlRules where matches(rule, url: url) {
                return rule.categoryID
            }
        }

        // 2. curated overlay outranks the WhoTracks.me seed: the upstream data
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
        if rule.pattern.hasPrefix("re:") {
            let pattern = String(rule.pattern.dropFirst(3))
            return url.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return url.range(of: rule.pattern, options: [.caseInsensitive]) != nil
    }
}
