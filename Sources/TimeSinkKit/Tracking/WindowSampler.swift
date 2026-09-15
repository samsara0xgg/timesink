import AppKit
import ApplicationServices

/// Split across the actor boundary on purpose. `frontmostApp()` is
/// `@MainActor` because `NSWorkspace` is AppKit and is not documented
/// thread-safe; `sample(at:app:)` is `nonisolated` so `TrackerEngine.tickAsync`
/// can run the two `AXUIElementCopyAttributeValue` calls -- synchronous Mach
/// IPC into the frontmost app, each able to burn its full 0.25s timeout -- off
/// the main actor, where on it they stalled the menu bar once per second
/// behind any beachballing app. Only the IPC leaves the actor; the AppKit read
/// stays on it.
///
/// `Sendable` without `@unchecked` because there is genuinely no stored
/// state: every call creates its own `AXUIElement`s and drops them.
public final class WindowSampler: Sendable {
    /// Frontmost-app identity, read on the main actor and handed across to the
    /// off-actor half so that half never touches AppKit.
    public struct FrontmostApp: Sendable {
        public let bundleID: String
        public let name: String
        public let pid: pid_t
    }

    public init() {}

    @MainActor
    public func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return nil }
        return FrontmostApp(bundleID: bundleID,
                            name: app.localizedName ?? bundleID,
                            pid: app.processIdentifier)
    }

    public func sample(at date: Date = Date(), app: FrontmostApp) -> Sample {
        Sample(timestamp: date, appBundleID: app.bundleID, appName: app.name,
               windowTitle: focusedWindowTitle(pid: app.pid), url: nil)
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
