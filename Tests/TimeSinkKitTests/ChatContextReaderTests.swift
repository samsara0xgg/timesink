import XCTest
@testable import TimeSinkKit

/// A hand-built stand-in for the accessibility tree: no live app, no transcript text.
private struct Fake: ChatAXNode {
    var role: String?
    var subrole: String?
    var title: String?
    var url: String?
    var domClasses: [String] = []
    var children: [Fake] = []
}

private func web(title: String?, url: String = "https://claude.ai/chat/x", _ kids: [Fake] = []) -> Fake {
    Fake(role: "AXWebArea", title: title, url: url, children: kids)
}
private func window(_ kids: [Fake]) -> Fake { Fake(role: "AXWindow", children: kids) }
private func bar(button: String?) -> [Fake] {
    let btn = Fake(role: "AXButton", title: button, domClasses: ["x", "cursor-text"])
    let noise = Fake(role: "AXGroup", children: [Fake(role: "AXStaticText")])
    return [Fake(role: "AXGroup", children: [noise] + [Fake(role: "AXGroup", children: [btn])])]
}
/// web area > ... > dframe-root > AXLandmarkMain > top bar
private func claudePage(title: String?, button: String?) -> Fake {
    let main = Fake(role: "AXGroup", subrole: "AXLandmarkMain", children: bar(button: button))
    let root = Fake(role: "AXGroup", domClasses: ["dframe-root"], children: [Fake(role: "AXGroup"), main])
    let wrapper = Fake(role: "AXGroup", children: [root])
    return window([web(title: "", url: "file:///Applications/Claude.app/shell.html"),
                   web(title: title, [wrapper])])
}

final class ChatContextReaderTests: XCTestCase {
    private func read(_ w: Fake) -> ChatReading { ChatContextReader.read(window: w, appName: "Claude") }

    func testTitleComesFromWebArea() {
        XCTAssertEqual(read(claudePage(title: "Chat name", button: "Button name")), ChatReading(document: "Chat name"))
    }
    func testButtonTitleStandsInWhenWebAreaTitleIsEmptyOrTheAppName() {
        for title in [nil, "", "Claude"] {
            XCTAssertEqual(read(claudePage(title: title, button: "Button name")), ChatReading(document: "Button name"))
        }
    }
    func testBuiltInBrowserPageGivesItsURL() {
        let page = window([web(title: "", url: "file:///Applications/Claude.app/shell.html"),
                           web(title: "Careers | Indeed.com", url: "https://www.indeed.com/cmp/x")])
        XCTAssertEqual(read(page), ChatReading(document: "Careers | Indeed.com", url: "https://www.indeed.com/cmp/x"))
        // A claude.ai page keeps the conversation name and no url.
        XCTAssertEqual(read(window([web(title: "Chat")])).url, nil)
    }
    func testEmptyButtonKeepsTodaysNil() {
        XCTAssertEqual(read(claudePage(title: "", button: nil)), ChatReading())
    }
    func testMissingNodesGiveTodaysResult() {
        // An unforced Electron tree: the web area has no children at all.
        XCTAssertEqual(read(window([web(title: "Chat")])), ChatReading(document: "Chat"))
        XCTAssertEqual(read(window([web(title: "Claude")])), ChatReading())
        // dframe-root without a main landmark.
        let root = Fake(role: "AXGroup", domClasses: ["dframe-root"], children: [Fake(role: "AXGroup")])
        XCTAssertEqual(read(window([web(title: "Chat", [root])])), ChatReading(document: "Chat"))
        // A main landmark without the button.
        let main = Fake(role: "AXGroup", subrole: "AXLandmarkMain", children: [Fake(role: "AXButton")])
        let root2 = Fake(role: "AXGroup", domClasses: ["dframe-root"], children: [main])
        XCTAssertEqual(read(window([web(title: "", [root2])])), ChatReading())
        XCTAssertEqual(read(window([])), ChatReading())
    }
    func testOnlyAClaudeWebAreaIsSearched() {
        var page = claudePage(title: "", button: "Button name")
        page.children[1].url = "https://chatgpt.com/c/1"
        XCTAssertEqual(read(page), ChatReading())
    }
    func testButtonMustBeAButtonWithTheClass() {
        let impostor = Fake(role: "AXStaticText", title: "nope", domClasses: ["cursor-text"])
        let main = Fake(role: "AXGroup", subrole: "AXLandmarkMain", children: [impostor])
        let root = Fake(role: "AXGroup", domClasses: ["dframe-root"], children: [main])
        XCTAssertEqual(read(window([web(title: "", [root])])), ChatReading())
    }
    func testSearchStopsAtTheNodeBudget() {
        // dframe-root buried below more nodes than the budget allows is not found.
        var node = Fake(role: "AXGroup", domClasses: ["dframe-root"])
        for _ in 0..<ChatContextReader.maxDescentDepth { node = Fake(role: "AXGroup", children: [node]) }
        XCTAssertEqual(read(window([web(title: "Chat", [node])])), ChatReading(document: "Chat"))
        let wide = Fake(role: "AXGroup", children: (0..<ChatContextReader.maxDescent).map { _ in Fake(role: "AXGroup") }
                        + [Fake(role: "AXGroup", domClasses: ["dframe-root"])])
        XCTAssertEqual(read(window([web(title: "Chat", [wide])])), ChatReading(document: "Chat"))
    }
}

/// A node that counts every read it is asked for and reports the budget spent after `limit` of them.
private final class Reads: @unchecked Sendable { var count = 0; let limit: Int; init(limit: Int) { self.limit = limit } }
private struct Counted: ChatAXNode {
    let reads: Reads
    var depth = 0
    var isRoot = false
    var expired: Bool { reads.count >= reads.limit }
    private func touch() { reads.count += 1 }
    var role: String? { touch(); return depth == 0 ? "AXWebArea" : "AXGroup" }
    var subrole: String? { touch(); return nil }
    var title: String? { touch(); return "Chat" }
    var url: String? { touch(); return depth == 0 ? "https://claude.ai/chat/x" : nil }
    var domClasses: [String] { touch(); return [] }
    var children: [Counted] { touch(); return (0..<5).map { _ in Counted(reads: reads, depth: depth + 1) } }
}

final class ChatContextBudgetTests: XCTestCase {
    func testNoReadsAfterTheBudgetIsSpent() {
        let reads = Reads(limit: 40)
        _ = ChatContextReader.read(window: Counted(reads: reads, depth: 1), appName: "Claude")
        // The window is not a web area, so the search walks it; it must stop near the limit, not at the 5^n tree's end.
        XCTAssertLessThanOrEqual(reads.count, 40 + 10)
    }

    func testAMissIsNotSearchedAgainUntilTheTitleChanges() {
        var miss: ChatContextReader.Miss?
        func page(_ title: String) -> Fake { window([web(title: title, [Fake(role: "AXGroup", children: [Fake(role: "AXGroup")])])]) }
        _ = ChatContextReader.read(window: page("A"), appName: "Claude", miss: &miss)
        XCTAssertEqual(miss, ChatContextReader.Miss(title: "A"))
        // Same page again: skipped, even though a good page would now be found.
        let good = claudePage(title: "A", button: "B")
        XCTAssertEqual(ChatContextReader.read(window: good, appName: "Claude", miss: &miss), ChatReading(document: "A"))
        // A new title searches again, finds the bar and forgets the miss.
        let found = ChatContextReader.read(window: claudePage(title: "C", button: "B"), appName: "Claude", miss: &miss)
        XCTAssertEqual(found, ChatReading(document: "C"))
        XCTAssertNil(miss)
    }
}
