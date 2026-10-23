import XCTest
@testable import TimeSinkKit

/// A hand-built stand-in for the accessibility tree: no live app, no transcript text.
private struct Fake: ChatAXNode {
    var role: String?
    var subrole: String?
    var title: String?
    var url: String?
    var label: String?
    var domClasses: [String] = []
    var children: [Fake] = []
}

private func web(title: String?, url: String = "https://claude.ai/chat/x", _ kids: [Fake] = []) -> Fake {
    Fake(role: "AXWebArea", title: title, url: url, children: kids)
}
private func window(_ kids: [Fake]) -> Fake { Fake(role: "AXWindow", children: kids) }
private func bar(button: String?, siblings: [Fake] = []) -> [Fake] {
    let btn = Fake(role: "AXButton", title: button, domClasses: ["x", "cursor-text"])
    let noise = Fake(role: "AXGroup", children: [Fake(role: "AXStaticText")])
    return [Fake(role: "AXGroup", children: [noise] + [Fake(role: "AXGroup", children: [btn] + siblings)])]
}
/// web area > ... > dframe-root > AXLandmarkMain > top bar
private func claudePage(title: String?, button: String?, siblings: [Fake] = []) -> Fake {
    let main = Fake(role: "AXGroup", subrole: "AXLandmarkMain", children: bar(button: button, siblings: siblings))
    let root = Fake(role: "AXGroup", domClasses: ["dframe-root"], children: [Fake(role: "AXGroup"), main])
    let wrapper = Fake(role: "AXGroup", children: [root])
    return window([web(title: "", url: "file:///Applications/Claude.app/shell.html"),
                   web(title: title, [wrapper])])
}
private let link = Fake(role: "AXLink", label: "My Project")
private let popup = Fake(role: "AXPopUpButton", title: "Popup Project")

final class ChatContextReaderTests: XCTestCase {
    private func read(_ w: Fake) -> ChatReading { ChatContextReader.read(window: w, appName: "Claude") }

    func testTitleComesFromWebAreaAndProjectFromLink() {
        let r = read(claudePage(title: "Chat name", button: "Button name", siblings: [link]))
        XCTAssertEqual(r, ChatReading(document: "Chat name", context: "My Project"))
    }
    func testButtonTitleStandsInWhenWebAreaTitleIsEmptyOrTheAppName() {
        for title in [nil, "", "Claude"] {
            XCTAssertEqual(read(claudePage(title: title, button: "Button name", siblings: [popup])),
                           ChatReading(document: "Button name", context: "Popup Project"))
        }
    }
    func testNoProjectSiblingGivesNilContext() {
        XCTAssertEqual(read(claudePage(title: "Chat", button: "B", siblings: [Fake(role: "AXLink", label: "")])),
                       ChatReading(document: "Chat", context: nil))
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
        var page = claudePage(title: "", button: "Button name", siblings: [link])
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
