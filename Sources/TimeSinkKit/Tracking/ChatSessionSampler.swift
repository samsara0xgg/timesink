import ApplicationServices
import Foundation

/// What a chat app is showing: the conversation name and, for Claude, the
/// project it is filed under. Both nil when the app shows neither.
public struct ChatReading: Equatable, Sendable {
    public var document: String?
    public var context: String?
    public init(document: String? = nil, context: String? = nil) {
        self.document = document; self.context = context
    }
}

/// The few attributes the chat reading needs from an accessibility node.
/// Live code wraps an `AXUIElement`; tests use a plain struct. Every property
/// may be an IPC call, so the reader asks for each at most once per node.
protocol ChatAXNode {
    var role: String? { get }
    var subrole: String? { get }
    var title: String? { get }
    /// `AXURL` as text.
    var url: String? { get }
    /// `AXDescription`.
    var label: String? { get }
    /// `AXDOMClassList`.
    var domClasses: [String] { get }
    var children: [Self] { get }
}

/// Decides the conversation name and project from a chat window's nodes.
///
/// Claude desktop's top bar holds a button (DOM class `cursor-text`) with the
/// conversation name, next to a link or pop-up button naming the project. It
/// sits under `dframe-root` > `AXLandmarkMain` inside the claude.ai web area.
/// That is the same path another tracker reads (reverse-engineered, not
/// measured here), and it is only ever *looked for*: nothing forces the
/// Electron tree open, so when any node on the path is missing the result is
/// exactly what the web-area title alone gave before.
enum ChatContextReader {
    /// Same bound as the original walk; see `ChatSessionSampler.maxDepth`.
    static let maxWindowDepth = 14
    /// Nodes looked at below the claude.ai web area, per target. A transcript
    /// is thousands of nodes; the top bar is near the top of the breadth-first order.
    static let maxDescent = 600
    static let maxDescentDepth = 24
    static let claudeURLPrefix = "https://claude.ai/"

    static func read<N: ChatAXNode>(window: N, appName: String) -> ChatReading {
        var title: String?
        var claudeWeb: N?
        findWebAreas(window, depth: 0) { area in
            if let text = area.title, !text.isEmpty, text != appName { title = text }
            if claudeWeb == nil, area.url?.hasPrefix(claudeURLPrefix) == true { claudeWeb = area }
        }
        var reading = ChatReading(document: title)
        guard let web = claudeWeb,
              let root = firstNode(below: web, where: { $0.domClasses.contains("dframe-root") }),
              let main = root.node.children.first(where: { $0.subrole == "AXLandmarkMain" }),
              let bar = firstNode(below: main, where: { $0.role == "AXButton" && $0.domClasses.contains("cursor-text") })
        else { return reading }
        if title == nil, let name = bar.node.title, !name.isEmpty { reading.document = name }
        reading.context = bar.siblings.lazy.compactMap(project).first
        return reading
    }

    /// A link's description or a pop-up button's title, when not empty.
    private static func project<N: ChatAXNode>(_ node: N) -> String? {
        let text: String?
        switch node.role {
        case "AXLink": text = node.label
        case "AXPopUpButton": text = node.title
        default: text = nil
        }
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every web area under `node`, none descended into: the web areas that
    /// matter are siblings, and a transcript below one is thousands of nodes.
    private static func findWebAreas<N: ChatAXNode>(_ node: N, depth: Int, _ body: (N) -> Void) {
        guard depth <= maxWindowDepth else { return }
        if node.role == "AXWebArea" { body(node); return }
        for child in node.children { findWebAreas(child, depth: depth + 1, body) }
    }

    /// Breadth-first, bounded by depth and node count. Returns the node and
    /// the children of its parent (itself included).
    private static func firstNode<N: ChatAXNode>(
        below start: N, where match: (N) -> Bool
    ) -> (node: N, siblings: [N])? {
        let top = start.children
        var queue = top.map { (node: $0, depth: 1, siblings: top) }
        var head = 0, seen = 0
        while head < queue.count, seen < maxDescent {
            let (node, depth, siblings) = queue[head]
            head += 1; seen += 1
            if match(node) { return (node, siblings) }
            guard depth < maxDescentDepth else { continue }
            let kids = node.children
            queue.append(contentsOf: kids.map { (node: $0, depth: depth + 1, siblings: kids) })
        }
        return nil
    }
}

/// Reads the current conversation out of an AI chat app's web view.
///
/// ChatGPT and Claude are both a web app in a native window, and the native
/// window title is a constant -- "ChatGPT", "Claude" -- so `WindowSampler`
/// alone sees one undifferentiated block. The `AXWebArea` inside carries the
/// page's own title, which is the conversation name (measured 2026-09-22:
/// ChatGPT's window said "ChatGPT" while its web area said
/// "检查今日未完成任务").
///
/// The walk deliberately does NOT descend into a web area: the transcript
/// below one is thousands of nodes, and the web areas that matter are
/// siblings rather than nested -- Claude ships an outer shell web area
/// (`file:///Applications/Claude.app/...`, empty title) next to the inner
/// claude.ai one. The last non-empty title wins for that reason.
///
/// `nonisolated` and `Sendable` for the same reason as `ChromeSampler`:
/// `TrackerEngine` runs it off the main actor, and it keeps no state -- every
/// call builds its own `AXUIElement`s and drops them.
public final class ChatSessionSampler: Sendable {
    /// Kept for the original walk's callers; see `ChatContextReader.maxWindowDepth`.
    static let maxDepth = ChatContextReader.maxWindowDepth
    /// The descent into a claude.ai web area gives up after this long in
    /// total, whatever the node count: a slow app must not stretch the tick.
    static let descentBudget: TimeInterval = 0.2

    public init() {}

    /// The conversation name, or nil when the app is not showing one --
    /// including when the web area's title is just the app's own name, which
    /// is what Claude reports while a modal (Settings) owns the route (then
    /// Claude's top-bar button, when the tree exposes it, supplies the name).
    public func session(pid: pid_t, appName: String) -> String? {
        reading(pid: pid, appName: appName).document
    }

    /// The conversation and, when shown, its project.
    public func reading(pid: pid_t, appName: String) -> ChatReading {
        let appRef = AXUIElementCreateApplication(pid)
        // Same budget as `WindowSampler`: this runs on the 1s tick's thread.
        AXUIElementSetMessagingTimeout(appRef, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else { return ChatReading() }
        let node = LiveChatNode(element: win as! AXUIElement,
                                deadline: Date().addingTimeInterval(Self.descentBudget))
        return ChatContextReader.read(window: node, appName: appName)
    }
}

/// An `AXUIElement` read lazily. Past `deadline` it reports no children, so
/// the breadth-first search stops without the reader knowing about time.
private struct LiveChatNode: ChatAXNode {
    let element: AXUIElement
    let deadline: Date

    private func copy(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    var role: String? { copy(kAXRoleAttribute) as? String }
    var subrole: String? { copy(kAXSubroleAttribute) as? String }
    var title: String? { copy(kAXTitleAttribute) as? String }
    var label: String? { copy(kAXDescriptionAttribute) as? String }
    var url: String? {
        guard let value = copy(kAXURLAttribute) else { return nil }
        return (value as? URL)?.absoluteString ?? value as? String
    }
    var domClasses: [String] { copy("AXDOMClassList") as? [String] ?? [] }
    var children: [LiveChatNode] {
        guard Date() < deadline,
              let list = copy(kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return list.map { LiveChatNode(element: $0, deadline: deadline) }
    }
}
