import Foundation

extension SettingsStore {
    public var excludedApps: Set<String> {
        guard let raw = get("excludedApps") else { return ScreenCollector.excludedBundleIDs }
        return Set(raw.split(separator: "\n").map(String.init)).union(ScreenCollector.excludedBundleIDs)
    }
    public func setExcludedApps(_ apps: Set<String>) { set("excludedApps", apps.sorted().joined(separator: "\n")) }
    public var excludedDomains: Set<String> {
        Set((get("excludedDomains") ?? "accounts.google.com").split(separator: "\n").map(String.init))
    }
    public func setExcludedDomains(_ domains: Set<String>) { set("excludedDomains", domains.sorted().joined(separator: "\n")) }
    public func excludes(_ sample: Sample) -> Bool {
        if excludedApps.contains(sample.appBundleID) { return true }
        guard let url = sample.url, let domain = DomainParser.domain(from: url) else { return false }
        return excludedDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }
    public var captureRetentionDays: Int { max(1, min(30, Int(get("captureRetentionDays") ?? "7") ?? 7)) }
    public var budgetNotificationsEnabled: Bool { self.get("budgetNotificationsEnabled") != "false" }
    public var focusNotificationsEnabled: Bool { self.get("focusNotificationsEnabled") != "false" }
    public var notificationSound: Bool { self.get("notificationSound") == "true" }
}
