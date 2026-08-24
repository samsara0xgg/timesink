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
        // AX attribute reads are synchronous Mach IPC into the target app; the
        // default messaging timeout is ~6s, so a beachballing frontmost app
        // would stall every 1s tick. 250ms is ample for a healthy app.
        AXUIElementSetMessagingTimeout(appRef, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else { return nil }
        let winElement = win as! AXUIElement
        AXUIElementSetMessagingTimeout(winElement, 0.25)
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}
