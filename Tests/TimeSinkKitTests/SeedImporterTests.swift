import XCTest
@testable import TimeSinkKit

@MainActor
final class SeedImporterTests: XCTestCase {
    func testParseSkipsCommentsAndBadRows() {
        let csv = "# version: 1\ngithub.com,softwareDev\nbad-line\nx.com,socialMedia\n"
        let pairs = SeedImporter.parseCSV(csv)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].domain, "github.com")
    }
    func testBundledResourceLoads() {
        let url = Bundle.module.url(forResource: "seed_domains", withExtension: "csv")
        XCTAssertNotNil(url)
    }

    func testCuratedImportOverwritesSeedAndLLMButNotUser() throws {
        let db = try AppDatabase.openInMemory()
        let store = CategoryStore(db)
        try store.importSeedDomains([("a.com", "entertainment"), ("b.com", "entertainment")])
        try store.setUserDomain("b.com", categoryID: "learning")
        // An llm row is an opportunistic machine guess for a domain the
        // deterministic chain (including curated) left uncategorized; the
        // curated overlay must still be able to claim it once it ships
        // coverage for that domain, or the curated tier would be permanently
        // unreachable for exactly the domains it targets.
        try store.insertLLMDomain("d.com", categoryID: "entertainment")

        try store.importCuratedDomains([("a.com", "softwareDev"), ("b.com", "softwareDev"),
                                        ("c.com", "softwareDev"), ("d.com", "softwareDev")])
        let map = try store.domainMap()
        XCTAssertEqual(map["a.com"], DomainEntry(categoryID: "softwareDev", source: "curated"))
        XCTAssertEqual(map["b.com"], DomainEntry(categoryID: "learning", source: "user"))
        XCTAssertEqual(map["c.com"], DomainEntry(categoryID: "softwareDev", source: "curated"))
        XCTAssertEqual(map["d.com"], DomainEntry(categoryID: "softwareDev", source: "curated"))
    }

    func testRemovingUserMappingRestoresShippedDefault() throws {
        let db = try AppDatabase.openInMemory()
        let store = CategoryStore(db)
        for domain in ["figma.com", "youtube.com", "nothing-shipped.invalid"] { try store.setUserDomain(domain, categoryID: "learning") }
        try store.setUserApp("com.apple.dt.Xcode", categoryID: "entertainment")
        try store.setRuleEnabled(key: "app:com.apple.dt.Xcode", enabled: false)

        for key in ["domain:figma.com", "domain:youtube.com", "domain:nothing-shipped.invalid", "app:com.apple.dt.Xcode"] {
            try store.removeUserMapping(key: key)
        }
        let domains = try store.domainMap()
        XCTAssertEqual(domains["figma.com"], DomainEntry(categoryID: "writing", source: "curated"))
        XCTAssertEqual(domains["youtube.com"], DomainEntry(categoryID: "entertainment", source: "seed"))
        XCTAssertNil(domains["nothing-shipped.invalid"])
        XCTAssertEqual(try store.appMap()["com.apple.dt.Xcode"], DomainEntry(categoryID: "softwareDev", source: "builtin"))
        XCTAssertTrue(try store.disabledRules().isEmpty)
    }

    func testOverlayImportsIndependentlyOfMainSeedVersion() throws {
        // Regression: the overlay import must not be nested inside the main
        // seed's early return -- an install that's already at the bundled
        // seedVersion (the common case after the first launch) must still
        // pick up a curated-overlay version bump.
        let db = try AppDatabase.openInMemory()
        let store = CategoryStore(db)
        let settings = SettingsStore(db)
        settings.set("seedVersion", "999")

        SeedImporter.importIfNeeded(categoryStore: store, settings: settings)

        let map = try store.domainMap()
        XCTAssertEqual(map["localhost"], DomainEntry(categoryID: "softwareDev", source: "curated"))
        XCTAssertEqual(settings.get("curatedSeedVersion"), "1")
    }
}
