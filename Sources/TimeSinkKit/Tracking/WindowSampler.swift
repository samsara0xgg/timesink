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
        /// Public so `tsprobe` can ask what the tracker would record for an
        /// app without that app having to be frontmost.
        public init(bundleID: String, name: String, pid: pid_t) {
            self.bundleID = bundleID; self.name = name; self.pid = pid
        }
    }

    /// Apps whose window document is a shell working directory rather than
    /// a file. When the shell in front reports nothing more specific than
    /// the home directory -- which is what Ghostty answers under Zellij,
    /// because Zellij does not pass the inner shell's OSC 7 through
    /// (measured 2026-09-22) -- the window title is the multiplexer's
    /// session name and the only identity on offer, so it stands in.
    /// Editors are deliberately absent: their title is already the file
    /// name, so the same fallback would just duplicate it.
    static let terminalBundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp",
    ]

    public init() {}

    @MainActor
    public func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              // Preview and perf builds (com.alllllenshi.TimeSink.preview) are TimeSink too, not the user's work.
              !bundleID.hasPrefix("com.alllllenshi.TimeSink.") else { return nil }
        return FrontmostApp(bundleID: bundleID,
                            name: app.localizedName ?? bundleID,
                            pid: app.processIdentifier)
    }

    public func sample(at date: Date = Date(), app: FrontmostApp) -> Sample {
        let focused = focusedWindow(pid: app.pid)
        return Sample(timestamp: date, appBundleID: app.bundleID, appName: app.name,
                      windowTitle: focused.title, url: nil, windowID: focused.id,
                      document: document(for: app, focused: focused))
    }

    /// A document worth recording, or nil.
    ///
    /// From the window itself only a filesystem path counts. A browser
    /// publishes its front tab's address as `kAXURL` -- `https://…`, and
    /// also `chrome://newtab/` and friends, which on 2026-09-22 leaked
    /// through an http-only guard and lagged the real tab, filing google.com
    /// spans under "chrome://newtab/". The tab is already `url`/`domain`, so
    /// rather than enumerate schemes, anything that is not a path is dropped.
    ///
    /// Suppressed entirely for the apps the screen collector refuses to look
    /// at (password managers): a document is window content like any other,
    /// and the two lists must not drift apart.
    private func document(for app: FrontmostApp, focused: FocusedWindow) -> String? {
        guard !ScreenCollector.excludedBundleIDs.contains(app.bundleID) else { return nil }
        if let document = focused.document,
           DocumentIdentity.path(of: document) != nil,
           !DocumentIdentity.isHome(document) {
            return document
        }
        return Self.terminalBundleIDs.contains(app.bundleID) ? focused.title : nil
    }

    public struct FocusedWindow: Sendable {
        public let title: String?
        public let id: UInt32?
        public let document: String?
    }

    /// Title, CGWindowID and document of `pid`'s focused window, from one AX read.
    /// The ID comes from `_AXUIElementGetWindow` (private but stable, what
    /// window managers use); when AX has no focused window, the largest
    /// on-screen layer-0 window of the process stands in, which skips the
    /// tiny helper windows some apps keep in front.
    public func focusedWindow(pid: pid_t) -> FocusedWindow {
        let appRef = AXUIElementCreateApplication(pid)
        // AX attribute reads are synchronous Mach IPC into the target app; the
        // default messaging timeout is ~6s, so a beachballing frontmost app
        // would stall every 1s tick. 250ms is ample for a healthy app.
        AXUIElementSetMessagingTimeout(appRef, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else {
            return FocusedWindow(title: nil, id: Self.largestWindowID(pid: pid), document: nil)
        }
        let winElement = win as! AXUIElement
        AXUIElementSetMessagingTimeout(winElement, 0.25)
        var title: CFTypeRef?
        let titleString = AXUIElementCopyAttributeValue(winElement, kAXTitleAttribute as CFString, &title) == .success
            ? title as? String : nil
        var id: CGWindowID = 0
        let idValue: UInt32? = _AXUIElementGetWindow(winElement, &id) == .success && id != 0 ? id : nil
        return FocusedWindow(title: titleString, id: idValue ?? Self.largestWindowID(pid: pid),
                             document: documentAttribute(winElement))
    }

    /// `kAXDocument` (a terminal's working directory, an editor's file),
    /// falling back to `kAXURL` for the windows that publish one instead.
    /// Empty strings -- what the AI chat apps answer -- fold to nil, so the
    /// caller never has to distinguish "no document" from "blank document".
    /// A third AX read on the tick's path, measured at 0.1ms against a
    /// healthy app and bounded by the same 0.25s timeout as the other two.
    private func documentAttribute(_ window: AXUIElement) -> String? {
        for name in [kAXDocumentAttribute, kAXURLAttribute] as [String] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, name as CFString, &value) == .success else { continue }
            if let text = value as? String, !text.isEmpty { return text }
            if let url = value as? NSURL, let text = url.absoluteString, !text.isEmpty { return text }
        }
        return nil
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
