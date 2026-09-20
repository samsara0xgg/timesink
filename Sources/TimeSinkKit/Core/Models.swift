import Foundation

public struct Sample: Equatable, Sendable {
    public var timestamp: Date
    public var appBundleID: String
    public var appName: String
    public var windowTitle: String?
    public var url: String?
    /// CGWindowID of the focused window (process + window identity for the
    /// screen collector); nil when it could not be resolved.
    public var windowID: UInt32?
    public init(timestamp: Date, appBundleID: String, appName: String,
                windowTitle: String?, url: String?, windowID: UInt32? = nil) {
        self.timestamp = timestamp; self.appBundleID = appBundleID
        self.appName = appName; self.windowTitle = windowTitle; self.url = url
        self.windowID = windowID
    }
}

public struct Span: Equatable, Sendable, Codable {
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
