import ScriptingBridge

@objc fileprivate protocol ChromeTab { @objc optional var URL: String { get }; @objc optional var title: String { get } }
@objc fileprivate protocol ChromeWindow {
    @objc optional var activeTab: ChromeTab { get }
    @objc optional var mode: String { get }
}
@objc fileprivate protocol ChromeApplication { @objc optional func windows() -> [ChromeWindow] }
extension SBObject: ChromeTab, ChromeWindow {}
extension SBApplication: ChromeApplication {}

@MainActor
public final class ChromeSampler {
    public struct TabInfo: Equatable {
        public var url: String?
        public var title: String?
        public var isIncognito: Bool
    }
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
        sb.timeout = 60
        let chrome = sb as ChromeApplication
        guard let windows = chrome.windows?(), let front = windows.first else { return nil }
        if front.mode == "incognito" {
            return TabInfo(url: nil, title: nil, isIncognito: true)
        }
        let tab = front.activeTab
        return TabInfo(url: tab?.URL, title: tab?.title, isIncognito: false)
    }
}
