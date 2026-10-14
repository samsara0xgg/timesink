import ApplicationServices
import Foundation

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
    /// Deep enough for both apps' shells (ChatGPT's web area sits at 8,
    /// Claude's inner one at 9) with headroom for a layout change, shallow
    /// enough that a miss costs a handful of reads rather than a tree walk.
    static let maxDepth = 14
    /// Longest any one AX read may block. A messaging timeout belongs to the
    /// element it is set on, so the app element's does not cover the window
    /// or its children: each element gets its own before it is read, or a
    /// hung web view holds a read for the system default of about 6 s.
    static let readTimeout: TimeInterval = 0.25
    /// The whole walk's budget. Measured walks take under 10 ms (see
    /// `TrackerEngine.offActorChatSession`); one that is still going after
    /// this is stuck behind a busy app and gives up with what it has.
    static let walkBudget: TimeInterval = 0.3

    public init() {}

    /// The conversation name, or nil when the app is not showing one --
    /// including when the web area's title is just the app's own name, which
    /// is what Claude reports while a modal (Settings) owns the route.
    public func session(pid: pid_t, appName: String) -> String? {
        let deadline = Date().addingTimeInterval(Self.walkBudget)
        let appRef = AXUIElementCreateApplication(pid)
        // Same budget as `WindowSampler`: this runs on the 1s tick's thread.
        guard Self.limit(appRef, until: deadline) else { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else { return nil }

        var found: String?
        webAreaTitles(win as! AXUIElement, depth: 0, until: deadline) { title in
            if !title.isEmpty, title != appName { found = title }
        }
        return found
    }

    /// Caps `element`'s reads at `readTimeout`, or at what is left of the
    /// walk when that is less. False once the budget is spent: the caller
    /// stops there. (A timeout of 0 would mean "the default", hence the
    /// floor.)
    private static func limit(_ element: AXUIElement, until deadline: Date) -> Bool {
        let left = deadline.timeIntervalSinceNow
        guard left > 0.01 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(readTimeout, left)))
        return true
    }

    private func webAreaTitles(_ element: AXUIElement, depth: Int, until deadline: Date, onTitle: (String) -> Void) {
        guard depth <= Self.maxDepth, Self.limit(element, until: deadline) else { return }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return }
        if role as? String == "AXWebArea" {
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
               let text = title as? String {
                onTitle(text)
            }
            return  // never descend into a transcript
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { webAreaTitles(child, depth: depth + 1, until: deadline, onTitle: onTitle) }
    }
}
