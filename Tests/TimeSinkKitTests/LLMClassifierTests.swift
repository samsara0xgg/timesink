import XCTest
@testable import TimeSinkKit

final class LLMClassifierTests: XCTestCase {
    func testParseValidResponse() throws {
        let json = #"{"choices":[{"message":{"content":" softwareDev\n"}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try OpenAIDomainClassifier.parse(response: json), "softwareDev")
    }
    func testParseRejectsUnknownCategory() {
        let json = #"{"choices":[{"message":{"content":"garbage"}}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OpenAIDomainClassifier.parse(response: json))
    }
    func testCoordinatorWritesCache() async throws {
        struct Fake: DomainClassifying {
            func classify(domain: String, title: String?) async throws -> String { "news" }
        }
        let db = try AppDatabase.openInMemory()
        let cs = CategoryStore(db); let ss = SettingsStore(db)
        ss.setLLMEnabled(true)
        let resolver = await CategoryResolver(categoryStore: cs)
        let co = await LLMCoordinator(categoryStore: cs, settings: ss, resolver: resolver, service: Fake())
        let span = Span(start: ts(0), end: ts(60), appBundleID: "com.google.Chrome",
                        appName: "Chrome", title: "t", url: "https://unknown-site.xyz/", domain: "unknown-site.xyz")
        await co.noteSpanClosed(span)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try cs.domainMap()["unknown-site.xyz"],
                       DomainEntry(categoryID: "news", source: "llm"))
    }
}
