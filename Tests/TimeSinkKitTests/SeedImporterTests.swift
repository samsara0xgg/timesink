import XCTest
@testable import TimeSinkKit

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

    func testCuratedImportOverwritesSeedButNotUser() throws {
        let db = try AppDatabase.openInMemory()
        let store = CategoryStore(db)
        try store.importSeedDomains([("a.com", "entertainment"), ("b.com", "entertainment")])
        try store.setUserDomain("b.com", categoryID: "learning")

        try store.importCuratedDomains([("a.com", "softwareDev"), ("b.com", "softwareDev"),
                                        ("c.com", "softwareDev")])
        let map = try store.domainMap()
        XCTAssertEqual(map["a.com"], DomainEntry(categoryID: "softwareDev", source: "curated"))
        XCTAssertEqual(map["b.com"], DomainEntry(categoryID: "learning", source: "user"))
        XCTAssertEqual(map["c.com"], DomainEntry(categoryID: "softwareDev", source: "curated"))
    }
}
