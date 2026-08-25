import ScriptingBridge

@objc fileprivate protocol ChromeBlockerTab { @objc optional var URL: String { get } }
@objc fileprivate protocol ChromeBlockerWindow { @objc optional var activeTab: ChromeBlockerTab { get } }
@objc fileprivate protocol ChromeBlockerApplication { @objc optional func windows() -> [ChromeBlockerWindow] }
extension SBObject: ChromeBlockerTab, ChromeBlockerWindow {}
extension SBApplication: ChromeBlockerApplication {}

/// Redirects Chrome's frontmost window's active tab, for the focus session's
/// site hard-block. A fully independent `SBApplication` instance from
/// `ChromeSampler`'s -- NEVER shares its throttle/backoff state. A blocking
/// write failing and masquerading as a permission alert (mixing this into
/// `ChromeSampler`'s degraded-flag plumbing) is exactly the bug class A2
/// already fixed; this type must never feed `TrackerEngine`'s
/// `chromeBackoff`.
@MainActor
public final class ChromeBlocker {
    public init() {}

    /// Sets the frontmost Chrome window's active tab URL. Must set
    /// `sb.timeout = 60` before any Apple Event write -- `SBApplication
    /// .timeout` is in 1/60s ticks (60 = 1 real second), not seconds; the
    /// same trap documented at `ChromeSampler.swift:30`. Writes via KVC
    /// (`setValue(_:forKey:)`) on the underlying `SBObject` rather than a
    /// settable `@objc optional` protocol property -- ScriptingBridge
    /// objects are dynamic KVC proxies, and Swift's optional-protocol-
    /// requirement sugar only reliably exposes the getter half through a
    /// protocol existential. Returns whether the write itself was attempted
    /// successfully (window/tab found) -- ScriptingBridge doesn't surface a
    /// reliable success signal beyond "didn't crash", so this is
    /// best-effort.
    @discardableResult
    public func setActiveTabURL(_ urlString: String) -> Bool {
        guard let sb = SBApplication(bundleIdentifier: "com.google.Chrome"),
              sb.isRunning else { return false }
        sb.timeout = 60
        let chrome = sb as ChromeBlockerApplication
        guard let windows = chrome.windows?(), let front = windows.first,
              let tab = front.activeTab as? SBObject else { return false }
        tab.setValue(urlString, forKey: "URL")
        return true
    }
}
