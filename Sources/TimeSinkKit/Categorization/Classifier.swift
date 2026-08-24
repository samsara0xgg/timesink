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
/// 1. `domain` has a `domainMap` entry with `source == "user"`.
/// 2. `url` is non-nil: scan `context.urlRules` in order, first `matches` wins
///    (the array is expected to already be sorted by the caller -- see
///    `CategoryResolver.refresh()`).
/// 3. `domain` has a seed-sourced entry reachable by walking suffixes of the
///    domain (dropping leftmost labels down to a minimum of 2 labels).
/// 4. `url == nil` (non-browser activity): `appMap[appBundleID]`.
/// 5. `domain` has a `domainMap` entry with `source == "llm"` (exact match
///    only).
/// 6. `"uncategorized"`.
public enum Classifier {
    public static func categoryID(
        appBundleID: String,
        url: String?,
        domain: String?,
        context: ClassificationContext
    ) -> String {
        if let domain, let entry = context.domainMap[domain], entry.source == "user" {
            return entry.categoryID
        }

        if let url {
            for rule in context.urlRules where matches(rule, url: url) {
                return rule.categoryID
            }
        }

        if let domain, let categoryID = seedSuffixMatch(domain: domain, context: context) {
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

    /// Walks `domain`'s suffixes from most-specific to least-specific,
    /// stopping once fewer than 2 labels remain (e.g. `mail.google.com` ->
    /// `google.com`, then stops -- `com` alone is never tried). Returns the
    /// category of the first suffix with a seed-sourced `domainMap` entry.
    private static func seedSuffixMatch(domain: String, context: ClassificationContext) -> String? {
        var labels = domain.split(separator: ".").map(String.init)
        while labels.count >= 2 {
            let candidate = labels.joined(separator: ".")
            if let entry = context.domainMap[candidate], entry.source == "seed" {
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
