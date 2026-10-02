import GRDB
import XCTest
@testable import TimeSinkKit

@MainActor
final class CategoryUITests: XCTestCase {
    func testAddIsBlockedAtTheCapOnly() {
        XCTAssertNil(CategoryEditing.addBlocker(assignableCount: CategoryStore.maxCategories - 1))
        XCTAssertNotNil(CategoryEditing.addBlocker(assignableCount: CategoryStore.maxCategories))
    }

    func testAddAtTheCapFailsInTheStoreToo() throws {
        let store = CategoryStore(try AppDatabase.openInMemory())
        var count = try store.allCategories().filter { $0.id != "uncategorized" }.count
        while count < CategoryStore.maxCategories { try store.addCategory(name: "c\(count)", colorHex: "#112233"); count += 1 }
        XCTAssertNotNil(CategoryEditing.addBlocker(assignableCount: count))
        XCTAssertThrowsError(try store.addCategory(name: "one more", colorHex: "#112233")) {
            XCTAssertEqual($0 as? CategoryStore.CategoryError, .limitReached)
        }
    }

    func testNameValidation() {
        let a = Category(id: "a", name: "Study", colorHex: "#000000", productivity: 0, sortOrder: 0)
        XCTAssertFalse(CategoryEditing.nameIsValid("  ", among: [a], excluding: nil))
        XCTAssertFalse(CategoryEditing.nameIsValid("study", among: [a], excluding: nil))
        XCTAssertTrue(CategoryEditing.nameIsValid("study", among: [a], excluding: "a"))
        XCTAssertTrue(CategoryEditing.nameIsValid("Games", among: [a], excluding: nil))
    }

    func testToConfirmRowsSortByHoursAndShortenText() {
        let cats = ["a": Category(id: "a", name: "A", colorHex: "#000000", productivity: 0, sortOrder: 0),
                    "b": Category(id: "b", name: "B", colorHex: "#000000", productivity: 0, sortOrder: 1)]
        func v(_ domain: String, _ title: String, cat: String, seconds: Double) -> LowConfidenceVerdict {
            LowConfidenceVerdict(key: VerdictKey(appBundleID: "x.app", domain: domain, title: title, document: ""), appName: "App",
                                 categoryID: cat, prob: 0.5, runnerUp: "b", runnerUpProb: 0.3, seconds: seconds)
        }
        let rows = ToConfirmRow.rows([v("", "short", cat: "a", seconds: 60), v("site.com", String(repeating: "x", count: 100), cat: "a", seconds: 600),
                                      v("gone.com", "t", cat: "missing", seconds: 9999)], categories: cats)
        XCTAssertEqual(rows.map(\.label), ["site.com", "App"])
        XCTAssertEqual(rows[0].detail.count, ToConfirmRow.detailLimit + 1)
        XCTAssertEqual(rows[0].runnerUpName, "B")
    }

    func testCapParsing() {
        XCTAssertEqual(JevSettingsPane.parseCap(" 2.5 "), 2.5)
        XCTAssertNil(JevSettingsPane.parseCap("-1"))
        XCTAssertNil(JevSettingsPane.parseCap("abc"))
    }
}
