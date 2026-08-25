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
            url: nil, domain: nil, title: nil, context: c), "misc")
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
