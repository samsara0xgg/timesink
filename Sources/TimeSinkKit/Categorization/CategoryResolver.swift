import Foundation
import os

/// A span paired with its resolved category.
public struct CategorizedSpan: Sendable {
    public var span: Span
    public var categoryID: String

    public init(span: Span, categoryID: String) {
        self.span = span
        self.categoryID = categoryID
    }
}

/// Loads the classification tables from `CategoryStore` and answers
/// per-span/per-activity category lookups via `Classifier`.
///
/// `refresh()` re-reads `domainMap`, `appMap`, `urlRules`, `titleRules` and
/// `allCategories` from the store and rebuilds the in-memory
/// `ClassificationContext`. `urlRules()` returns rows in unspecified order, so
/// `refresh()` sorts them: `source == "user"` rows first, then by `priority`
/// descending, then by `pattern` length descending. `titleRules()` rows are
/// filtered to `enabled` and sorted: scoped rows first, then by `priority`
/// descending, then by `id` descending. If the DB read fails, the previous
/// context is kept as-is and the failure is logged.
@MainActor
public final class CategoryResolver {
    private let categoryStore: CategoryStore
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "categoryResolver")

    public private(set) var categoriesByID: [String: Category] = [:]
    private var context = ClassificationContext(domainMap: [:], appMap: [:], urlRules: [], titleRules: [])

    public init(categoryStore: CategoryStore) {
        self.categoryStore = categoryStore
        refresh()
    }

    public func refresh() {
        do {
            let categories = try categoryStore.allCategories()
            let domainMap = try categoryStore.domainMap()
            let appMap = try categoryStore.appMap()
            let sortedRules = try categoryStore.urlRules().sorted { lhs, rhs in
                let lhsUser = lhs.source == "user"
                let rhsUser = rhs.source == "user"
                if lhsUser != rhsUser { return lhsUser }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.pattern.count > rhs.pattern.count
            }
            let titleRules = try categoryStore.titleRules().filter(\.enabled).sorted { lhs, rhs in
                let lhsScoped = !lhs.scopeKey.isEmpty, rhsScoped = !rhs.scopeKey.isEmpty
                if lhsScoped != rhsScoped { return lhsScoped }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return (lhs.id ?? 0) > (rhs.id ?? 0)    // 新规则优先（交互稿语义）
            }

            categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
            context = ClassificationContext(domainMap: domainMap, appMap: appMap, urlRules: sortedRules,
                                             titleRules: titleRules)
        } catch {
            logger.error("CategoryResolver.refresh failed, keeping previous context: \(String(describing: error), privacy: .public)")
        }
    }

    public func categoryID(for span: Span) -> String {
        Classifier.categoryID(
            appBundleID: span.appBundleID,
            url: span.url,
            domain: span.domain,
            title: span.title,
            context: context
        )
    }

    public func categorized(_ spans: [Span]) -> [CategorizedSpan] {
        spans.map { CategorizedSpan(span: $0, categoryID: categoryID(for: $0)) }
    }
}
