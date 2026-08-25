import ScriptingBridge
import os

@objc fileprivate protocol ChromeBlockerWindow { @objc optional var activeTab: SBObject { get } }
@objc fileprivate protocol ChromeBlockerApplication { @objc optional func windows() -> [ChromeBlockerWindow] }
extension SBObject: ChromeBlockerWindow {}
extension SBApplication: ChromeBlockerApplication {}

/// R-T12f: `SBApplication.h`/`SBObject.h` document that an Apple Event
/// error raises an uncatchable Objective-C exception when the application
/// has no delegate -- assigning one (even a trivial one) is what makes a
/// failed write surface as `eventDidFail` instead of crashing. Records the
/// failure so `setActiveTabURL` can report it via its return value rather
/// than blindly claiming success once the write call itself didn't throw.
/// `@preconcurrency`: `SBApplicationDelegate`'s requirements are declared
/// `nonisolated` (a plain `@objc` protocol, not actor-aware), but
/// `eventDidFail` is only ever invoked synchronously, on the calling
/// thread, as the direct result of the synchronous Apple Event send inside
/// `setActiveTabURL` -- itself always called on the main actor (this whole
/// type is `@MainActor`). There is no genuine cross-actor race here; this
/// silences the compiler's inability to see that synchronous-call
/// invariant.
@MainActor
private final class ChromeBlockerDelegate: NSObject, @preconcurrency SBApplicationDelegate {
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "chromeBlocker")
    private(set) var didFail = false

    func reset() { didFail = false }

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
        didFail = true
        logger.error("Chrome AppleEvent failed: \(String(describing: error))")
        return nil
    }
}

/// Redirects Chrome's frontmost window's active tab, for the focus session's
/// site hard-block. A fully independent `SBApplication` instance from
/// `ChromeSampler`'s -- NEVER shares its throttle/backoff state. A blocking
/// write failing and masquerading as a permission alert (mixing this into
/// `ChromeSampler`'s degraded-flag plumbing) is exactly the bug class A2
/// already fixed; this type must never feed `TrackerEngine`'s
/// `chromeBackoff`.
@MainActor
public final class ChromeBlocker {
    private let delegate = ChromeBlockerDelegate()

    public init() {}

    /// Sets the frontmost Chrome window's active tab URL. Must set
    /// `sb.timeout = 60` before any Apple Event write -- `SBApplication
    /// .timeout` is in 1/60s ticks (60 = 1 real second), not seconds; the
    /// same trap documented at `ChromeSampler.swift:30`. Writes via KVC
    /// (`setValue(_:forKey:)`) on the underlying `SBObject` -- ScriptingBridge
    /// objects are dynamic KVC proxies, and Swift's optional-protocol-
    /// requirement sugar only reliably exposes the getter half of a settable
    /// `@objc optional` property through a protocol existential. Returns
    /// `false` if the window/tab wasn't found OR the delegate observed an
    /// `eventDidFail` for this write (R-T12f) -- otherwise `true`.
    /// ScriptingBridge doesn't surface a stronger success signal than "no
    /// failure event fired", so this is still best-effort, not a guarantee.
    @discardableResult
    public func setActiveTabURL(_ urlString: String) -> Bool {
        guard let sb = SBApplication(bundleIdentifier: "com.google.Chrome"),
              sb.isRunning else { return false }
        sb.timeout = 60
        sb.delegate = delegate
        delegate.reset()
        let chrome = sb as ChromeBlockerApplication
        guard let windows = chrome.windows?(), let front = windows.first,
              let tab = front.activeTab else { return false }
        tab.setValue(urlString, forKey: "URL")
        return !delegate.didFail
    }
}
