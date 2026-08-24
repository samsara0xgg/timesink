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
        guard let chrome: ChromeApplication = SBApplication(bundleIdentifier: "com.google.Chrome"),
              (chrome as? SBApplication)?.isRunning == true,
              let windows = chrome.windows?(), let front = windows.first else { return nil }
        if front.mode == "incognito" {
            return TabInfo(url: nil, title: nil, isIncognito: true)
        }
        let tab = front.activeTab
        return TabInfo(url: tab?.URL, title: tab?.title, isIncognito: false)
    }
}
