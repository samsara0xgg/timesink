import Foundation

public struct Sample: Equatable, Sendable {
    public var timestamp: Date
    public var appBundleID: String
    public var appName: String
    public var windowTitle: String?
    public var url: String?
    public init(timestamp: Date, appBundleID: String, appName: String,
                windowTitle: String?, url: String?) {
        self.timestamp = timestamp; self.appBundleID = appBundleID
        self.appName = appName; self.windowTitle = windowTitle; self.url = url
    }
}

public struct Span: Equatable, Sendable {
    public var id: Int64?
    public var start: Date
    public var end: Date
    public var appBundleID: String
    public var appName: String
    public var title: String?
    public var url: String?
    public var domain: String?
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public init(id: Int64? = nil, start: Date, end: Date, appBundleID: String,
                appName: String, title: String?, url: String?, domain: String?) {
        self.id = id; self.start = start; self.end = end
        self.appBundleID = appBundleID; self.appName = appName
        self.title = title; self.url = url; self.domain = domain
    }
}
