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
/// One per call, never shared: `eventDidFail` is invoked synchronously, on
/// the calling thread, as the direct result of the synchronous Apple Event
/// send, so a call-local delegate is only ever touched by that one thread,
/// whichever thread it is.
private final class ChromeBlockerDelegate: NSObject, SBApplicationDelegate {
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "chromeBlocker")
    private(set) var didFail = false

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
///
/// Not `@MainActor`, for the same reason as `ChromeSampler`: every method is
/// a synchronous Apple Event round-trip (up to its 1 s timeout against a
/// hung Chrome), which froze the whole UI when sent from the main actor.
/// The `async` variants run off it (a `nonisolated async` function does not
/// inherit its caller's isolation, SE-0338 -- the hop `TrackerEngine`'s
/// off-actor samplers rely on). `Sendable` without `@unchecked` because there
/// is no stored state: each call binds its own `SBApplication` and delegate.
public final class ChromeBlocker: Sendable {
    public init() {}

    /// `setActiveTabURL` off the caller's actor.
    public func setActiveTabURLOffActor(_ urlString: String) async -> Bool {
        setActiveTabURL(urlString)
    }

    /// `activateTab(url:)` off the caller's actor.
    public func activateTabOffActor(url urlString: String) async -> Bool {
        activateTab(url: urlString)
    }

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
    /// F3 回到刚才: brings the tab showing `urlString` to the front of its
    /// window, and that window to the front. Best effort, like
    /// `setActiveTabURL`; false when no tab shows the page any more.
    @discardableResult
    public func activateTab(url urlString: String) -> Bool {
        guard let sb = SBApplication(bundleIdentifier: "com.google.Chrome"),
              sb.isRunning else { return false }
        let delegate = ChromeBlockerDelegate()
        sb.timeout = 60
        sb.delegate = delegate
        // Kept alive across every send, not just to its last mention: a
        // delegate gone mid-call is no delegate, and R-T12f's crash is back.
        return withExtendedLifetime(delegate) { () -> Bool in
            let windows = ((sb as ChromeBlockerApplication).windows?() ?? []).compactMap { $0 as? SBObject }
            for window in windows {
                guard let tabs = window.value(forKey: "tabs") as? SBElementArray,
                      let index = (tabs.value(forKey: "URL") as? [String])?.firstIndex(of: urlString) else { continue }
                window.setValue(index + 1, forKey: "activeTabIndex")
                window.setValue(1, forKey: "index")
                return !delegate.didFail
            }
            return false
        }
    }

    @discardableResult
    public func setActiveTabURL(_ urlString: String) -> Bool {
        guard let sb = SBApplication(bundleIdentifier: "com.google.Chrome"),
              sb.isRunning else { return false }
        let delegate = ChromeBlockerDelegate()
        sb.timeout = 60
        sb.delegate = delegate
        return withExtendedLifetime(delegate) { () -> Bool in
            let chrome = sb as ChromeBlockerApplication
            guard let windows = chrome.windows?(), let front = windows.first,
                  let tab = front.activeTab else { return false }
            tab.setValue(urlString, forKey: "URL")
            return !delegate.didFail
        }
    }
}
