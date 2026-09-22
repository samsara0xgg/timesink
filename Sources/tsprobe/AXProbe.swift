import AppKit
import ApplicationServices
import TimeSinkKit

/// `tsprobe ax <bundleID> [maxDepth]`: prints the running app's focused
/// window attribute names, its title/document/url (with per-read timings),
/// and a depth-limited walk of the window subtree listing every
/// `AXStaticText` / `AXHeading` value and every selected `AXRow`.
///
/// Read-only and one-shot: it exists to answer "does this app expose the
/// identity we want, and how expensive is it to read" before any sampler is
/// written against it. Timeouts are deliberately looser than
/// `WindowSampler`'s 0.25s -- a probe wants the answer, not a budget.
enum AXProbe {
    static let interestingRoles: Set<String> = ["AXStaticText", "AXHeading"]

    static func run(bundleID: String, maxDepth: Int, manual: Bool = false,
                    all: Bool = false, nodeBudget: Int = 4000) -> Int32 {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            print("not running: \(bundleID)")
            return 2
        }
        print("app: \(app.localizedName ?? bundleID) pid=\(app.processIdentifier) bundle=\(bundleID)")
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appRef, 2.0)

        // Electron (VS Code, ChatGPT, Claude) ships an empty AX tree -- just
        // the window chrome -- until an assistive client asks for it. Setting
        // `AXManualAccessibility` is Electron's documented opt-in; the tree is
        // then built for the lifetime of that process, which is a real,
        // permanent cost in the target app and the reason this is a flag and
        // not the default.
        if manual {
            let (result, ms) = timed {
                AXUIElementSetAttributeValue(appRef, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            print(String(format: "AXManualAccessibility=true -> %@ (%.1f ms)", "\(result)", ms))
            Thread.sleep(forTimeInterval: 1.5)  // the tree is built asynchronously
        }

        guard let window = focusedWindow(appRef) else {
            print("no focused window and no AXWindows")
            return 3
        }
        AXUIElementSetMessagingTimeout(window, 2.0)

        print("window attributes: \(attributeNames(window).joined(separator: ", "))")
        for name in [kAXTitleAttribute, kAXDocumentAttribute, kAXURLAttribute] as [String] {
            let (value, ms) = timed { describe(copyAttr(window, name)) }
            print(String(format: "  %@ = %@   (%.1f ms)", name, value ?? "nil", ms))
        }

        // The shipping code path, on the live app: what the tracker would
        // actually store as this window's document.
        let (session, sessionMs) = timed {
            ChatSessionSampler().session(pid: app.processIdentifier, appName: app.localizedName ?? bundleID)
        }
        print(String(format: "ChatSessionSampler -> %@   (%.1f ms)", session.map(quote) ?? "nil", sessionMs))
        let frontmost = WindowSampler.FrontmostApp(bundleID: bundleID,
                                                   name: app.localizedName ?? bundleID,
                                                   pid: app.processIdentifier)
        let (sampled, sampleMs) = timed { WindowSampler().sample(app: frontmost) }
        print(String(format: "WindowSampler.sample().document -> %@   (%.1f ms)",
                     sampled.document.map(quote) ?? "nil", sampleMs))

        print("--- subtree walk (maxDepth=\(maxDepth), budget=\(nodeBudget), all=\(all)) ---")
        var visited = 0
        let (_, walkMs) = timed {
            walk(window, path: "AXWindow", depth: 0, maxDepth: maxDepth,
                 budget: nodeBudget, all: all, visited: &visited)
        }
        print(String(format: "--- %d nodes in %.1f ms ---", visited, walkMs))
        return 0
    }

    /// The focused window, or the first of `AXWindows` -- a CLI probe is
    /// never itself frontmost, and some apps answer `AXFocusedWindow` only
    /// while they are.
    private static func focusedWindow(_ appRef: AXUIElement) -> AXUIElement? {
        if let focused = copyAttr(appRef, kAXFocusedWindowAttribute) {
            return (focused as! AXUIElement)
        }
        guard let windows = copyAttr(appRef, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        print("(no AXFocusedWindow; using AXWindows[0] of \(windows.count))")
        return windows.first
    }

    private static func walk(_ element: AXUIElement, path: String, depth: Int,
                             maxDepth: Int, budget: Int, all: Bool, visited: inout Int) {
        guard depth <= maxDepth, visited < budget else { return }
        visited += 1
        let role = str(element, kAXRoleAttribute) ?? "?"

        if all {
            let subrole = str(element, kAXSubroleAttribute).map { "(\($0))" } ?? ""
            let bits = [("title", str(element, kAXTitleAttribute)),
                        ("value", str(element, kAXValueAttribute)),
                        ("desc", str(element, kAXDescriptionAttribute))]
                .compactMap { name, text in
                    (text?.isEmpty == false) ? "\(name)=\(quote(clip(text!)))" : nil
                }
            print("  \(path)/\(role)\(subrole) \(bits.joined(separator: " "))")
        }

        // A web view's own URL is a stabler identity than its title: it
        // survives a generic document.title, and it is what the sampler
        // would key a chat session on if the title turns out to be useless.
        if role == "AXWebArea" {
            let url = describe(copyAttr(element, kAXURLAttribute)) ?? "nil"
            let title = str(element, kAXTitleAttribute).map(quote) ?? "nil"
            print("  \(path)/AXWebArea  title=\(title)  AXURL=\(url)")
        }

        if !all, interestingRoles.contains(role) {
            let text = str(element, kAXValueAttribute) ?? str(element, kAXTitleAttribute)
            if let text, !text.isEmpty { print("  \(path)/\(role) = \(quote(text))") }
        }
        if role == "AXRow", copyAttr(element, kAXSelectedAttribute) as? Bool == true {
            print("  \(path)/\(role) SELECTED = \(quote(rowText(element)))")
        }

        guard let children = copyAttr(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for (index, child) in children.enumerated() {
            walk(child, path: "\(path)/\(role)[\(index)]", depth: depth + 1,
                 maxDepth: maxDepth, budget: budget, all: all, visited: &visited)
        }
    }

    /// A row's own title/description, else the first static text under it --
    /// a sidebar row usually carries its label one level down.
    private static func rowText(_ row: AXUIElement) -> String {
        if let title = str(row, kAXTitleAttribute), !title.isEmpty { return title }
        if let description = str(row, kAXDescriptionAttribute), !description.isEmpty { return description }
        var found: String?
        var budget = 40
        func descend(_ element: AXUIElement) {
            guard found == nil, budget > 0 else { return }
            budget -= 1
            if str(element, kAXRoleAttribute) == "AXStaticText",
               let value = str(element, kAXValueAttribute), !value.isEmpty {
                found = value
                return
            }
            for child in (copyAttr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { descend(child) }
        }
        descend(row)
        return found ?? "-"
    }

    // MARK: - AX helpers

    private static func copyAttr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func str(_ element: AXUIElement, _ name: String) -> String? {
        copyAttr(element, name) as? String
    }

    private static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return ["(unavailable)"] }
        return list
    }

    /// AX values are not all strings: a URL comes back as `NSURL`, and
    /// anything else still deserves to be seen rather than reported as nil.
    private static func describe(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return quote(text) }
        if let url = value as? NSURL { return quote(url.absoluteString ?? "\(url)") }
        return "\(value)"
    }

    private static func quote(_ text: String) -> String { "\"\(text)\"" }

    private static func clip(_ text: String, _ limit: Int = 80) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    private static func timed<T>(_ body: () -> T) -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        return (result, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
}
