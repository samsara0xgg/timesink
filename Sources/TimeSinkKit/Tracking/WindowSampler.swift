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
        let focused = focusedWindow(pid: app.pid)
        return Sample(timestamp: date, appBundleID: app.bundleID, appName: app.name,
                      windowTitle: focused.title, url: nil, windowID: focused.id)
    }

    /// Title and CGWindowID of `pid`'s focused window, from one AX read.
    /// The ID comes from `_AXUIElementGetWindow` (private but stable, what
    /// window managers use); when AX has no focused window, the largest
    /// on-screen layer-0 window of the process stands in, which skips the
    /// tiny helper windows some apps keep in front.
    public func focusedWindow(pid: pid_t) -> (title: String?, id: UInt32?) {
        let appRef = AXUIElementCreateApplication(pid)
        // AX attribute reads are synchronous Mach IPC into the target app; the
        // default messaging timeout is ~6s, so a beachballing frontmost app
        // would stall every 1s tick. 250ms is ample for a healthy app.
        AXUIElementSetMessagingTimeout(appRef, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else { return (nil, Self.largestWindowID(pid: pid)) }
        let winElement = win as! AXUIElement
        AXUIElementSetMessagingTimeout(winElement, 0.25)
        var title: CFTypeRef?
        let titleString = AXUIElementCopyAttributeValue(winElement, kAXTitleAttribute as CFString, &title) == .success
            ? title as? String : nil
        var id: CGWindowID = 0
        let idValue: UInt32? = _AXUIElementGetWindow(winElement, &id) == .success && id != 0 ? id : nil
        return (titleString, idValue ?? Self.largestWindowID(pid: pid))
    }

    static func largestWindowID(pid: pid_t) -> UInt32? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: (id: UInt32, area: CGFloat)?
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let area = bounds.width * bounds.height
            if best == nil || area > best!.area { best = (number, area) }
        }
        return best?.id
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError
