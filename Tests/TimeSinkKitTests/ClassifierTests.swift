import XCTest
@testable import TimeSinkKit

final class ClassifierTests: XCTestCase {
    func ctx(domains: [String: DomainEntry] = [:], apps: [String: DomainEntry] = [:],
             rules: [URLRule] = []) -> ClassificationContext {
        ClassificationContext(domainMap: domains, appMap: apps, urlRules: rules)
    }
    func rule(_ p: String, _ c: String, priority: Int = 100, source: String = "builtin") -> URLRule {
        URLRule(id: nil, pattern: p, categoryID: c, priority: priority, source: source)
    }

    func testUserDomainBeatsRuleAndSeed() {
        let c = ctx(domains: ["github.com": .init(categoryID: "learning", source: "user")],
                    rules: [rule("github.com", "softwareDev")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.google.Chrome",
            url: "https://github.com/a", domain: "github.com", title: nil, context: c), "learning")
    }
    func testURLRuleBeatsSeed() {
        let c = ctx(domains: ["youtube.com": .init(categoryID: "entertainment", source: "seed")],
                    rules: [rule("youtube.com/watch", "entertainment", priority: 200)])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.google.Chrome",
            url: "https://youtube.com/watch?v=1", domain: "youtube.com", title: nil, context: c), "entertainment")
    }
    func testSeedSuffixWalk() {
        let c = ctx(domains: ["google.com": .init(categoryID: "utilities", source: "seed")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.google.Chrome",
            url: "https://photos.google.com/x", domain: "photos.google.com", title: nil, context: c), "utilities")
    }
    func testAppDefaultOnlyWithoutURL() {
        let c = ctx(domains: ["unknown.io": .init(categoryID: "news", source: "seed")],
                    apps: ["com.google.Chrome": .init(categoryID: "misc", source: "builtin")])
        // 有 URL 但域名未收录 → 不落到 app 默认, 而是 uncategorized
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.google.Chrome",
            url: "https://nowhere.xyz/", domain: "nowhere.xyz", title: nil, context: c), "uncategorized")
        // 无 URL → app 默认
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.google.Chrome",
            url: nil, domain: nil, title: "Window", context: c), "misc")
        // 有 URL 但不是网站（新标签页、本地文件）→ 同样按应用
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.google.Chrome",
            url: "chrome://newtab/", domain: nil, title: "Window", context: c), "misc")
    }
    func testLLMCacheLowestAmongDomainLayers() {
        let c = ctx(domains: ["x.dev": .init(categoryID: "softwareDev", source: "llm")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.google.Chrome",
            url: "https://x.dev/", domain: "x.dev", title: nil, context: c), "softwareDev")
    }
    func testRegexRule() {
        let c = ctx(rules: [rule("re:youtube\\.com/(watch|shorts)", "entertainment")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b", url: "https://youtube.com/shorts/abc",
            domain: "youtube.com", title: nil, context: c), "entertainment")
    }

    func testUserOverrideCoversSubdomains() {
        // 修正 youtube.com 后，m.youtube.com 也要命中用户层，
        // 且优先于任何 URL 规则和种子
        let c = ctx(
            domains: ["youtube.com": DomainEntry(categoryID: "learning", source: "user"),
                      "m.youtube.com": DomainEntry(categoryID: "entertainment", source: "seed")],
            rules: [rule("youtube.com", "entertainment", priority: 200)]
        )
        XCTAssertEqual(
            Classifier.categoryID(appBundleID: "com.google.Chrome",
                                  url: "https://m.youtube.com/watch?v=x",
                                  domain: "m.youtube.com", title: nil, context: c),
            "learning")
    }

    func testCuratedBeatsSeedButNotURLRules() {
        let c = ctx(
            domains: ["vercel.com": DomainEntry(categoryID: "softwareDev", source: "curated"),
                      "example.com": DomainEntry(categoryID: "entertainment", source: "seed")],
            rules: [rule("vercel.com/pricing", "business", priority: 100)]
        )
        // curated 后缀命中
        XCTAssertEqual(
            Classifier.categoryID(appBundleID: "b", url: "https://app.vercel.com/x",
                                  domain: "app.vercel.com", title: nil, context: c),
            "softwareDev")
        // URL 规则仍优先于 curated
        XCTAssertEqual(
            Classifier.categoryID(appBundleID: "b", url: "https://vercel.com/pricing",
                                  domain: "vercel.com", title: nil, context: c),
            "business")
    }

    func testSingleLabelDomainMatchesExactly() {
        // localhost 只有一个 label，旧的 >=2 后缀循环永远走不进去
        let c = ctx(domains: ["localhost": DomainEntry(categoryID: "softwareDev", source: "curated")])
        XCTAssertEqual(
            Classifier.categoryID(appBundleID: "b", url: "http://localhost:3000/",
                                  domain: "localhost", title: nil, context: c),
            "softwareDev")
    }
}

/// Pins `CompiledURLRule` against the pure `Classifier.matches(pattern:in:)`
/// it replaced on the hot path, the same way
/// `testCompiledTitleRuleAgreesWithTitleMatches` pins the title pair. The
/// compiled path trades ICU case folding for lowercased `contains` (4.3x on
/// real data), so these cases exist to catch that trade changing an answer.
final class CompiledURLRuleTests: XCTestCase {
    private func rule(_ pattern: String) -> URLRule {
        URLRule(id: nil, pattern: pattern, categoryID: "learning", priority: 0, source: "builtin")
    }

    func testCompiledURLRuleAgreesWithMatches() {
        let cases: [(pattern: String, url: String)] = [
            ("youtube.com", "https://www.youtube.com/watch?v=1"),
            ("YouTube.com", "https://www.youtube.com/watch?v=1"),
            ("youtube.com", "https://vimeo.com/1"),
            ("/docs/", "https://swift.org/DOCS/guide"),
            ("", "https://example.com"),
            (#"re:^https://\w+\.github\.io"#, "https://alice.github.io/blog"),
            (#"re:^https://\w+\.github\.io"#, "https://github.io/blog"),
            ("re:", "https://example.com"),
            ("中文", "https://example.com/中文/page"),
        ]
        for c in cases {
            let compiled = CompiledURLRule(rule(c.pattern))
            XCTAssertEqual(
                Classifier.matches(pattern: c.pattern, in: c.url),
                compiled.matches(url: c.url, loweredURL: c.url.lowercased()),
                "compiled/pure disagreement for pattern \(c.pattern) url \(c.url)")
        }
    }
}

/// `CategoryResolver`'s per-tuple memo (perf: ~8x fewer `Classifier` calls on
/// real data). The memo is keyed on the four fields classification reads and
/// cleared only by `refresh()`, so the one way it can go wrong is serving a
/// stale answer after the rules underneath it changed.
@MainActor
final class CategoryResolverMemoTests: XCTestCase {
    private func makeResolver() throws -> (CategoryResolver, CategoryStore) {
        let db = try AppDatabase.openInMemory()
        let store = CategoryStore(db)
        return (CategoryResolver(categoryStore: store), store)
    }

    private func span(domain: String) -> Span {
        Span(start: Date(), end: Date().addingTimeInterval(60),
             appBundleID: "com.google.Chrome", appName: "Chrome",
             title: nil, url: "https://\(domain)/x", domain: domain)
    }

    // The load-bearing one: a memo that isn't cleared on `refresh()` keeps
    // serving "uncategorized" here forever, so a user reassigning a domain
    // would silently not take effect.
    func testMemoIsInvalidatedByRefresh() throws {
        let (resolver, store) = try makeResolver()
        let probe = span(domain: "memo-test.example")

        XCTAssertEqual(resolver.categoryID(for: probe), "uncategorized")

        try store.setUserDomain("memo-test.example", categoryID: "learning")
        resolver.refresh()

        XCTAssertEqual(resolver.categoryID(for: probe), "learning")
    }

    /// The complement of `testMemoIsInvalidatedByRefresh`: a metadata-only
    /// edit must NOT pay the invalidation. `refreshCategories()` has to pick
    /// up the new category row while leaving the memo populated and every
    /// classification answer unchanged -- if it ever starts clearing the memo,
    /// a colour change costs a full reclassification pass (measured at ~600 ms
    /// against ~14 ms warm on the live database) and this is the only thing
    /// that would notice.
    func testRefreshCategoriesKeepsMemoAndClassification() throws {
        let (resolver, store) = try makeResolver()
        try store.setUserDomain("meta-test.example", categoryID: "learning")
        resolver.refresh()

        let probe = span(domain: "meta-test.example")
        XCTAssertEqual(resolver.categoryID(for: probe), "learning")
        let populated = resolver.memoEntryCount
        XCTAssertGreaterThan(populated, 0)

        guard var learning = resolver.categoriesByID["learning"] else {
            return XCTFail("learning category missing")
        }
        learning.name = "重命名"
        learning.colorHex = "#123456"
        learning.productivity = -2
        try store.updateCategory(learning)

        resolver.refreshCategories()

        XCTAssertEqual(resolver.categoriesByID["learning"]?.name, "重命名")
        XCTAssertEqual(resolver.categoriesByID["learning"]?.colorHex, "#123456")
        XCTAssertEqual(resolver.categoriesByID["learning"]?.productivity, -2)
        XCTAssertEqual(resolver.memoEntryCount, populated, "metadata edit must not wipe the memo")
        XCTAssertEqual(resolver.categoryID(for: probe), "learning")
    }

    // The memo is a cache on a hot path, so its one hard obligation is the
    // memory bound: never more than `memoCap` entries, however many distinct
    // tuples get classified. (Which eviction policy is used is a perf
    // tradeoff measured in `memoCap`'s doc comment, not a correctness one --
    // this deliberately does not pin it.)
    func testMemoNeverExceedsCap() throws {
        let (resolver, _) = try makeResolver()
        let cap = CategoryResolver.memoCapForTesting

        for i in 0..<(cap + 100) {
            _ = resolver.categoryID(for: span(domain: "d\(i).example"))
        }

        XCTAssertLessThanOrEqual(resolver.memoEntryCount, cap)
    }

    // A hit must return what a cold call returns, and must not bleed across
    // distinct inputs (a key that dropped a field would collapse these two).
    func testMemoHitAgreesWithColdCallAndDoesNotBleedAcrossInputs() throws {
        let (resolver, store) = try makeResolver()
        try store.setUserDomain("a.example", categoryID: "learning")
        try store.setUserDomain("b.example", categoryID: "business")
        resolver.refresh()

        let a = span(domain: "a.example")
        let b = span(domain: "b.example")
        XCTAssertEqual(resolver.categoryID(for: a), "learning")   // cold
        XCTAssertEqual(resolver.categoryID(for: b), "business")   // cold
        XCTAssertEqual(resolver.categoryID(for: a), "learning")   // memo hit
        XCTAssertEqual(resolver.categoryID(for: b), "business")   // memo hit
    }
}
