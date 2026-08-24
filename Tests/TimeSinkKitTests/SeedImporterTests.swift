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
}
