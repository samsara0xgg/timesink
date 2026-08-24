import AppKit
import ApplicationServices

@MainActor
public final class WindowSampler {
    public init() {}

    public func sample(at date: Date = Date()) -> Sample? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return nil }
        return Sample(timestamp: date, appBundleID: bundleID,
                      appName: app.localizedName ?? bundleID,
                      windowTitle: focusedWindowTitle(pid: app.processIdentifier),
                      url: nil)
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}
