import ScriptingBridge

@objc fileprivate protocol ChromeTab { @objc optional var URL: String { get }; @objc optional var title: String { get } }
@objc fileprivate protocol ChromeWindow {
    @objc optional var activeTab: ChromeTab { get }
    @objc optional var mode: String { get }
}
@objc fileprivate protocol ChromeApplication { @objc optional func windows() -> [ChromeWindow] }
extension SBObject: ChromeTab, ChromeWindow {}
extension SBApplication: ChromeApplication {}

/// Deliberately `nonisolated` (no `@MainActor`) so `TrackerEngine` can run
/// `activeTab()` off the main actor -- see `TrackerEngine.tickAsync`. The
/// `windows()` call below is a synchronous Apple Event round-trip and used to
/// block the 1s tick on the main actor. `Sendable` without `@unchecked`
/// because there is no stored state: each call binds a fresh `SBApplication`
/// and never shares an `SBObject` across threads.
public final class ChromeSampler: Sendable {
    public struct TabInfo: Equatable, Sendable {
        public var url: String?
        public var title: String?
        public var isIncognito: Bool
    }
    /// Hoisted out of `activeTab()` (see the rationale there) only so a test
    /// can pin the value: shortening it makes slow replies count as failures
    /// and feed `chromeBackoff`, so it must not drift unnoticed.
    static let timeoutTicks = 15

    public init() {}

    public func activeTab() -> TabInfo? {
        // Bind + configure before any Apple Event is sent: `isRunning` just
        // reads the process list (no AE), but `windows()` below is itself a
        // synchronous AE round-trip -- the riskiest send, made fresh on every
        // tick -- so the timeout must be set before it, not after the guard.
        guard let sb = SBApplication(bundleIdentifier: "com.google.Chrome"),
              sb.isRunning else { return nil }
        // SBApplication.timeout is in ticks (1/60s). Default Apple Event reply
        // timeout is about a minute; a hung Chrome would freeze the app that long.
        // 15 ticks = 0.25s, matching the AX messaging timeout in
        // `WindowSampler`: one tick's total IPC budget is then bounded at
        // ~0.75s (two AX reads + one AE) instead of the old ~1.5s, which is
        // what let a single slow tick overrun the 1s timer interval.
        sb.timeout = Self.timeoutTicks
        let chrome = sb as ChromeApplication
        guard let windows = chrome.windows?(), let front = windows.first else { return nil }
        if front.mode == "incognito" {
            return TabInfo(url: nil, title: nil, isIncognito: true)
        }
        let tab = front.activeTab
        return TabInfo(url: tab?.URL, title: tab?.title, isIncognito: false)
    }
}
