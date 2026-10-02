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
    /// Categories flagged `distracting`: what an interruption can be made of.
    public private(set) var distractingIDs: Set<String> = []
    private var context = ClassificationContext(domainMap: [:], appMap: [:], urlRules: [], titleRules: [])

    /// Whether cached verdicts count. Off, the resolver is what it was
    /// before Jev: rules, then the shipped lists.
    public var jevEnabled = false {
        didSet { if jevEnabled != oldValue { refresh() } }
    }

    /// Whether screenshot verdicts count (the "send screenshot text" switch).
    public var jevScreenText = false {
        didSet { if jevScreenText != oldValue { refresh() } }
    }

    /// The fields `Classifier.categoryID` actually reads. Holds
    /// references to the span's existing strings, so building one is a few
    /// retains -- no copying, no joined-key allocation.
    fileprivate struct MemoKey: Hashable, Sendable {
        let appBundleID: String
        let url: String?
        let domain: String?
        let title: String?
        let document: String?
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
    /// that can change `context` (settings panes, title-rule editor, activity
    /// reassign, LLM fallback) calls `resolver.refresh()` before
    /// `dataChanged()`. `refreshCategories()` deliberately does not clear the
    /// memo: it reloads `categoriesByID` only and never touches `context`, so
    /// no memoized answer can have gone stale. Pinned by
    /// `testMemoIsInvalidatedByRefresh` and
    /// `testRefreshCategoriesKeepsMemoAndClassification`.
    private var memo: [MemoKey: String] = [:]
    private var overrides: [Int64: String] = [:]

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
    nonisolated private static let memoCap = 20_000

    /// Test-visible mirror of `memoCap`, so the cap test can't silently
    /// drift out of sync with the constant it is checking.
    static var memoCapForTesting: Int { memoCap }

    public init(categoryStore: CategoryStore) {
        self.categoryStore = categoryStore
        refresh()
    }

    public func refresh() {
        do {
            let disabled = try categoryStore.disabledRules()
            let categories = try categoryStore.allCategories()
            // Turning off your own correction brings back what shipped for
            // that site or app; turning off a shipped mapping unmaps it.
            let allDomains = try categoryStore.domainMap(), allApps = try categoryStore.appMap()
            var domainMap = allDomains.filter { !disabled.contains("domain:" + $0.key) }
            let offDomains = allDomains.filter { $0.value.source == "user" && disabled.contains("domain:" + $0.key) }
            for (domain, shipped) in SeedImporter.shippedDomains(Set(offDomains.keys)) {
                domainMap[domain] = DomainEntry(categoryID: shipped.categoryID, source: shipped.source)
            }
            var appMap = allApps.filter { !disabled.contains("app:" + $0.key) }
            for (app, entry) in allApps where entry.source == "user" && disabled.contains("app:" + app) {
                if let builtin = Taxonomy.builtinApps.first(where: { $0.bundleID == app }), categoryExists(builtin.categoryID, in: categories) {
                    appMap[app] = DomainEntry(categoryID: builtin.categoryID, source: "builtin")
                }
            }
            let sortedRules = try categoryStore.urlRules().filter { !disabled.contains("url:" + String($0.id ?? 0)) }.sorted { lhs, rhs in
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

            let overrides = try categoryStore.segmentOverrides()
            categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
            distractingIDs = Set(categories.filter(\.distracting).map(\.id))
            self.overrides = overrides
            var user: [VerdictKey: String] = [:], jev: [VerdictKey: JevVerdictEntry] = [:]
            for v in try categoryStore.verdicts() {
                if v.isUser { user[v.key] = v.categoryID } else if jevEnabled { jev[v.key] = JevVerdictEntry(categoryID: v.categoryID, prob: v.prob, usedScreenText: v.screenText == 1) }
            }
            let shots = jevEnabled && jevScreenText ? try categoryStore.captureVerdictsBySpan() : [:]
            context = ClassificationContext(domainMap: domainMap, appMap: appMap, urlRules: sortedRules,
                                             titleRules: titleRules, userVerdicts: user, jevVerdicts: jev, captureVerdicts: shots,
                                             categoryIDs: Set(categories.map(\.id)))
            memo.removeAll(keepingCapacity: true)
        } catch {
            logger.error("CategoryResolver.refresh failed, keeping previous context: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reloads `categoriesByID` alone, leaving `context` and the memo intact.
    ///
    /// For edits that change a category's presentation or productivity but
    /// not how any span classifies: `Classifier` reads only `context`
    /// (domainMap, appMap, urlRules, titleRules), and a `Category`'s name,
    /// colorHex, productivity and sortOrder appear in none of them. Its `id`
    /// is the primary key and cannot be edited, so the (span -> categoryID)
    /// mapping the memo holds is unchanged by definition.
    ///
    /// The distinction is worth a separate entry point because the full
    /// `refresh()` is cheap on its own but wiping the memo is not. Measured
    /// in a release build against the live database (32,128 spans):
    ///
    ///     refresh(), all 5 tables ................  12.11 ms
    ///     allCategories() alone ..................   0.04 ms
    ///     categorized(30d), memo warm ............  14.52 ms
    ///     categorized(30d) right after refresh ... 611.18 ms
    ///
    /// So routing a color or name edit through `refresh()` does not cost 12
    /// ms, it costs ~600 ms on whichever view recomputes next -- a cliff that
    /// reads as "clicking a button is laggy".
    public func refreshCategories() {
        do {
            let categories = try categoryStore.allCategories()
            categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
            distractingIDs = Set(categories.filter(\.distracting).map(\.id))
        } catch {
            logger.error("CategoryResolver.refreshCategories failed, keeping previous: \(String(describing: error), privacy: .public)")
        }
    }

    private func categoryExists(_ id: String, in categories: [Category]) -> Bool { categories.contains { $0.id == id } }

    /// Memo occupancy, for `testMemoNeverExceedsCap` -- the memory bound is
    /// otherwise unobservable from outside.
    var memoEntryCount: Int { memo.count }

    public func categoryID(for span: Span) -> String {
        if let id = span.id, let override = overrides[id] { return override }
        return Self.categoryID(for: span, context: context, memo: &memo)
    }

    /// A worker owns its copy of the memo; no database or main-actor reference
    /// crosses the boundary. Rule edits replace the snapshot before the next run.
    struct Snapshot: Sendable {
        fileprivate let context: ClassificationContext
        fileprivate var memo: [MemoKey: String]
        fileprivate let overrides: [Int64: String]

        mutating func categoryID(for span: Span) -> String {
            if let id = span.id, let override = overrides[id] { return override }
            return CategoryResolver.categoryID(for: span, context: context, memo: &memo)
        }

        /// The rule that won for `span`, as the rules pane keys it.
        func matchingRuleKey(for span: Span) -> String? {
            CategoryResolver.matchingRuleKey(for: span, context: context, overrides: overrides)
        }
    }

    func snapshot() -> Snapshot { Snapshot(context: context, memo: memo, overrides: overrides) }

    nonisolated private static func categoryID(for span: Span, context: ClassificationContext,
                                               memo: inout [MemoKey: String]) -> String {
        // A span with its own screenshot verdict is not the same as another span with the same fields.
        let own = span.id.flatMap { context.captureVerdicts[$0] } != nil
        let key = MemoKey(appBundleID: span.appBundleID, url: span.url,
                          domain: span.domain, title: span.title, document: span.document)
        if !own, let hit = memo[key] { return hit }
        let resolved = Classifier.categoryID(
            appBundleID: span.appBundleID,
            url: span.url,
            domain: span.domain,
            title: span.title,
            document: span.document,
            spanID: own ? span.id : nil,
            context: context
        )
        if own { return resolved }
        if memo.count >= Self.memoCap { memo.removeAll(keepingCapacity: true) }
        memo[key] = resolved
        return resolved
    }

    func previewEdit(span: Span, scope: ReclassificationEdit.Scope, categoryID: String,
                     pattern: String, items: [CategorizedSpan], titleScope: String? = nil, titlePriority: Int = .max) -> [CategorizedSpan] {
        var domains = context.domainMap
        var apps = context.appMap
        var titles = context.titleRules
        // Only spans the new entry can reach are classified again: a 30-day
        // preview otherwise re-classifies thousands of tuples cold per call.
        let reachable: (Span) -> Bool
        switch scope {
        case .segment: return items.filter { $0.span.id == span.id && $0.categoryID != categoryID }
        case .activity:
            if let domain = span.domain {
                domains[domain] = DomainEntry(categoryID: categoryID, source: "user")
                reachable = { $0.domain.map { $0 == domain || $0.hasSuffix("." + domain) } ?? false }
            } else {
                let app = span.appBundleID
                apps[app] = DomainEntry(categoryID: categoryID, source: "user")
                reachable = { $0.appBundleID == app }
            }
        case .title:
            guard let pattern = TitleRuleInput.normalizedPattern(pattern) else { return [] }
            let rule = CompiledTitleRule(TitleRule(pattern: pattern, scopeKey: "", categoryID: "", source: "user"))
            reachable = { $0.title.map { rule.matches(title: $0, loweredTitle: $0.lowercased()) } ?? false }
            let key = titleScope ?? span.domain ?? span.appBundleID
            let old = (try? categoryStore.titleRules())?.first { $0.pattern == pattern && $0.scopeKey == key }
            guard old?.source != "builtin" else { return [] }
            titles.removeAll { $0.pattern == pattern && $0.scopeKey == key }
            titles.append(TitleRule(id: old?.id ?? Int64.max, pattern: pattern, scopeKey: key, categoryID: categoryID, priority: old?.priority ?? titlePriority, source: "user"))
            titles.sort {
                if $0.scopeKey.isEmpty != $1.scopeKey.isEmpty { return !$0.scopeKey.isEmpty }
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return ($0.id ?? 0) > ($1.id ?? 0)
            }
        }
        let preview = ClassificationContext(domainMap: domains, appMap: apps, urlRules: context.urlRules, titleRules: titles,
                                            userVerdicts: context.userVerdicts, jevVerdicts: context.jevVerdicts, captureVerdicts: context.captureVerdicts,
                                            categoryIDs: context.categoryIDs)
        var memo: [MemoKey: String] = [:]
        return items.filter { item in
            guard reachable(item.span) else { return false }
            if let id = item.span.id, overrides[id] != nil { return false }
            return Self.categoryID(for: item.span, context: preview, memo: &memo) != item.categoryID
        }
    }

    /// The winning rule only, matching the classifier's tier order. Segment
    /// corrections are intentionally not credited to an unrelated rule.
    func matchingRuleKey(for span: Span) -> String? {
        Self.matchingRuleKey(for: span, context: context, overrides: overrides)
    }

    nonisolated fileprivate static func matchingRuleKey(for span: Span, context: ClassificationContext, overrides: [Int64: String]) -> String? {
        if let id = span.id, overrides[id] != nil { return nil }
        let verdictKey = VerdictKey(span)
        if let id = context.userVerdicts[verdictKey], context.categoryIDs?.contains(id) ?? true { return nil }
        let scope = span.domain ?? span.appBundleID
        // The compiled rules sit index for index beside the raw ones: the
        // rules pane asks this for every span of the day, and the raw
        // patterns re-split keywords and recompile regexes on every call.
        func title(_ user: Bool) -> String? {
            guard let text = span.title else { return nil }
            let lowered = text.lowercased()
            for (rule, compiled) in zip(context.titleRules, context.compiledTitleRules) where (rule.source == "user") == user
                && Classifier.scopeMatches(ruleScopeKey: rule.scopeKey, scopeKey: scope) && compiled.matches(title: text, loweredTitle: lowered) {
                return rule.id.map { "title:\($0)" }
            }
            return nil
        }
        func domain(_ source: String) -> String? {
            guard let domain = span.domain else { return nil }
            var labels = domain.split(separator: ".")
            while labels.count >= 2 {
                let candidate = labels.joined(separator: ".")
                if context.domainMap[candidate]?.source == source { return "domain:" + candidate }
                labels.removeFirst()
            }
            return nil
        }
        func url(_ user: Bool) -> String? {
            guard let value = span.url else { return nil }
            let lowered = value.lowercased()
            for (rule, compiled) in zip(context.urlRules, context.compiledURLRules) where (rule.source == "user") == user
                && compiled.matches(url: value, loweredURL: lowered) {
                return rule.id.map { "url:\($0)" }
            }
            return nil
        }
        if let key = title(true) ?? domain("user") ?? url(true) { return key }
        if jobHit(for: span, context: context) != nil { return nil }
        if span.domain == nil, context.appMap[span.appBundleID]?.source == "user" { return "app:" + span.appBundleID }
        // A hard rule or a verdict decided it: no list rule gets the credit.
        if automaticReason(for: span, context: context) != nil { return nil }
        if let key = title(false) ?? url(false) ?? domain("curated") ?? domain("seed") { return key }
        if span.domain == nil, context.appMap[span.appBundleID] != nil { return "app:" + span.appBundleID }
        if let domain = span.domain, context.domainMap[domain]?.source == "llm" { return "domain:" + domain }
        return nil
    }

    /// The hard rule, else the cached Jev verdict, that decides `span` once
    /// the user's own rules have passed.
    private enum Automatic { case rule(JevRules.Hit), jev(Double, screenText: Bool) }

    /// The job keyword rule, which outranks the user's app mapping.
    nonisolated private static func jobHit(for span: Span, context: ClassificationContext) -> JevRules.Hit? {
        JevRules.job(appBundleID: span.appBundleID, domain: span.domain, url: span.url, title: span.title, document: span.document)
            .flatMap { context.categoryIDs?.contains($0.categoryID) ?? true ? $0 : nil }
    }
    nonisolated private func jobHit(for span: Span, context: ClassificationContext) -> JevRules.Hit? {
        Self.jobHit(for: span, context: context)
    }

    nonisolated private static func automaticReason(for span: Span, context: ClassificationContext) -> Automatic? {
        func exists(_ id: String) -> Bool { context.categoryIDs?.contains(id) ?? true }
        if let hit = JevRules.match(appBundleID: span.appBundleID, domain: span.domain, url: span.url, title: span.title, document: span.document),
           exists(hit.categoryID) {
            if hit.reason == .assistantIdle, let id = span.id, let shot = context.captureVerdicts[id], exists(shot.categoryID) {
                return .jev(shot.prob, screenText: true)
            }
            return .rule(hit)
        }
        if let v = context.jevVerdicts[VerdictKey(span)], exists(v.categoryID) { return .jev(v.prob, screenText: v.usedScreenText) }
        return nil
    }

    nonisolated private func automaticReason(for span: Span, context: ClassificationContext) -> Automatic? {
        Self.automaticReason(for: span, context: context)
    }

    func explanation(for span: Span) -> String {
        if let id = span.id, overrides[id] != nil { return String(localized: "你单独调整了这条记录，其他活动不受影响。") }
        if let id = context.userVerdicts[VerdictKey(span)], context.categoryIDs?.contains(id) ?? true { return String(localized: "你确认或改过这条内容的分类。") }
        let scope = span.domain ?? span.appBundleID
        func titleReason(user: Bool) -> String? {
            guard let title = span.title else { return nil }
            guard let rule = context.titleRules.first(where: {
                ($0.source == "user") == user && Classifier.scopeMatches(ruleScopeKey: $0.scopeKey, scopeKey: scope)
                    && Classifier.titleMatches(pattern: $0.pattern, title: title)
            }) else { return nil }
            return String(localized: "\(user ? String(localized: "你的") : String(localized: "内置"))标题规则 · \(rule.pattern)")
        }
        func domainReason(_ source: String) -> String? {
            guard let domain = span.domain else { return nil }
            var suffix = domain
            while suffix.split(separator: ".").count >= 2 {
                if let entry = context.domainMap[suffix], entry.source == source { return "\(source == "user" ? String(localized: "你的网站规则") : String(localized: "内置网站分类")) · \(suffix)" }
                guard let dot = suffix.firstIndex(of: ".") else { break }
                suffix = String(suffix[suffix.index(after: dot)...])
            }
            return nil
        }
        func urlReason(user: Bool) -> String? {
            guard let url = span.url, let rule = context.urlRules.first(where: { ($0.source == "user") == user && Classifier.matches(pattern: $0.pattern, in: url) }) else { return nil }
            return String(localized: "\(user ? String(localized: "你的") : String(localized: "内置"))网址规则 · \(rule.pattern)")
        }
        if let reason = titleReason(user: true) ?? domainReason("user") ?? urlReason(user: true) { return reason }
        if let hit = jobHit(for: span, context: context) { return Self.reason(hit) }
        if span.domain == nil, let entry = context.appMap[span.appBundleID], entry.source == "user" { return String(localized: "你的应用分类 · \(span.appName)") }
        switch Self.automaticReason(for: span, context: context) {
        case .rule(let hit): return Self.reason(hit)
        case .jev(let prob, let screenText):
            let p = String(format: "%.2f", prob)
            return screenText ? String(localized: "Jev 判断（含截图文字）· 概率 \(p)") : String(localized: "Jev 判断 · 概率 \(p)")
        case nil: break
        }
        if let reason = titleReason(user: false) ?? urlReason(user: false) ?? domainReason("curated") ?? domainReason("seed") { return reason }
        if span.domain == nil, let entry = context.appMap[span.appBundleID] { return String(localized: "\(entry.source == "user" ? String(localized: "你的") : String(localized: "内置"))应用分类 · \(span.appName)") }
        if let domain = span.domain, context.domainMap[domain]?.source == "llm" { return String(localized: "智能分类 · 根据网站域名识别") }
        return String(localized: "还没有匹配的应用、网站或标题规则。选择分类后可以为以后自动归类。")
    }

    private static func reason(_ hit: JevRules.Hit) -> String {
        switch hit.reason {
        case .job(let word): String(localized: "内置求职规则 · \(word)")
        case .ownApp: String(localized: "内置规则 · 自己的项目")
        case .assistantIdle: String(localized: "内置规则 · 没有打开的对话")
        case .blankTab: String(localized: "内置规则 · 空白标签页")
        case .tool: String(localized: "内置规则 · 系统小工具")
        case .cloudConsole: String(localized: "内置规则 · 云控制台")
        case .ownSite: String(localized: "内置规则 · 自己部署的项目")
        }
    }

    public func categorized(_ spans: [Span]) -> [CategorizedSpan] {
        spans.map { CategorizedSpan(span: $0, categoryID: categoryID(for: $0)) }
    }
}
