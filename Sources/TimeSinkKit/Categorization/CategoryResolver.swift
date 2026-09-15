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

    /// The four fields `Classifier.categoryID` actually reads. Holds
    /// references to the span's existing strings, so building one is a few
    /// retains -- no copying, no joined-key allocation.
    private struct MemoKey: Hashable {
        let appBundleID: String
        let url: String?
        let domain: String?
        let title: String?
    }

    /// Memoizes `Classifier.categoryID` per distinct input tuple. The span
    /// table is heavily redundant -- on real data 31,804 rows collapse to
    /// 4,005 distinct (bundleID, url, domain, title) tuples, ~8x, because a
    /// span is closed and reopened on every window-title flicker. Without
    /// this, one wide-range `categorized(_:)` re-runs the same work eight
    /// times over per tuple: a `title.lowercased()` allocation, up to ~100
    /// URL-rule substring scans (51 rules, two source-filtered passes), and
    /// three `suffixMatch` domain split/join walks.
    ///
    /// Correctness rests on one invariant: classification reads *only*
    /// `context`, and `refresh()` is the only thing that ever reassigns it.
    /// So clearing here, and only here, is sufficient -- every mutation path
    /// (settings panes, title-rule editor, activity reassign, LLM fallback)
    /// already calls `resolver.refresh()` before `dataChanged()`.
    /// Pinned by `testMemoIsInvalidatedByRefresh`.
    private var memo: [MemoKey: String] = [:]

    /// Bounds memory: on reaching the cap the memo is cleared wholesale and
    /// starts refilling.
    ///
    /// Distinct tuples grow near-linearly at ~12.6% of row count, so this cap
    /// is passed around 160k rows -- about 3.5 months at the observed 1,465
    /// spans/day. Clearing sounds wasteful there, so all three policies were
    /// measured on a 540k-row / 67k-tuple one-year fixture, classifying the
    /// whole table:
    ///
    ///   no memo at all ............. 39,714 ms
    ///   clear on full (this) ....... 10,413 ms
    ///   stop inserting on full ..... 27,446 ms
    ///
    /// Clearing wins because spans arrive in time order and the same
    /// window/tab repeats in bursts, so the live working set is small and
    /// local. Clearing follows it; refusing new entries freezes the memo on
    /// the oldest, least relevant tuples and throws that locality away.
    ///
    /// ponytail: clear-on-full, not LRU -- LRU bookkeeping on this hot path
    /// would cost more than the ~2.6x it could add back over clearing, and
    /// the cap is unreachable for every range the UI can normally request
    /// (`.last30` on that same one-year fixture touches ~5.5k tuples, well
    /// under). Only a multi-year `.custom` range overflows, and that path is
    /// dominated by other costs anyway -- its 1.9s fetch and 540k-row
    /// materialization are the real ceiling, not the memo policy. The fix
    /// there is aggregating in SQL instead of classifying row by row, not a
    /// smarter cache.
    private static let memoCap = 20_000

    /// Test-visible mirror of `memoCap`, so the cap test can't silently
    /// drift out of sync with the constant it is checking.
    static var memoCapForTesting: Int { memoCap }

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
            memo.removeAll(keepingCapacity: true)
        } catch {
            logger.error("CategoryResolver.refresh failed, keeping previous context: \(String(describing: error), privacy: .public)")
        }
    }

    /// Memo occupancy, for `testMemoNeverExceedsCap` -- the memory bound is
    /// otherwise unobservable from outside.
    var memoEntryCount: Int { memo.count }

    public func categoryID(for span: Span) -> String {
        let key = MemoKey(appBundleID: span.appBundleID, url: span.url,
                          domain: span.domain, title: span.title)
        if let hit = memo[key] { return hit }
        let resolved = Classifier.categoryID(
            appBundleID: span.appBundleID,
            url: span.url,
            domain: span.domain,
            title: span.title,
            context: context
        )
        if memo.count >= Self.memoCap { memo.removeAll(keepingCapacity: true) }
        memo[key] = resolved
        return resolved
    }

    public func categorized(_ spans: [Span]) -> [CategorizedSpan] {
        spans.map { CategorizedSpan(span: $0, categoryID: categoryID(for: $0)) }
    }
}
