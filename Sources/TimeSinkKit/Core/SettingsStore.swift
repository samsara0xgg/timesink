import Foundation
import GRDB
import os

public final class SettingsStore: Sendable {
    let writer: any DatabaseWriter

    private static let idleThresholdKey = "idleThreshold"
    private static let jevEnabledKey = "jevEnabled"
    private static let jevEndpointKey = "jevEndpoint"
    private static let jevModelKey = "jevModel"
    private static let jevScreenTextKey = "jevScreenText"
    private static let jevMonthlyCapKey = "jevMonthlyCapUSD"
    private static let budgetWarnPercentKey = "budgetWarnPercent"
    private static let dailySummaryEnabledKey = "dailySummaryEnabled"
    private static let dailySummaryHourKey = "dailySummaryHour"
    private static let lastSummaryDayKey = "lastSummaryDay"
    private static let menuBarTextEnabledKey = "menuBarTextEnabled"
    private static let focusDurationMinutesKey = "focusDurationMinutes"
    private static let focusAppBlockEnabledKey = "focusAppBlockEnabled"
    private static let focusSiteBlockEnabledKey = "focusSiteBlockEnabled"
    private static let focusBlockedAppsKey = "focusBlockedApps"
    private static let focusBlockedCategoriesKey = "focusBlockedCategories"
    private static let calendarOverlayEnabledKey = "calendarOverlayEnabled"
    private static let screenCapturePausedKey = "screenCapturePaused"

    private static let defaultIdleThreshold: TimeInterval = 180
    private static let defaultJevMonthlyCap = 1.0
    private static let defaultBudgetWarnPercent = 20
    private static let defaultDailySummaryEnabled = false
    private static let defaultDailySummaryHour = 19
    private static let defaultMenuBarTextEnabled = true
    private static let defaultFocusDurationMinutes = 25
    private static let defaultFocusAppBlockEnabled = true
    private static let defaultFocusSiteBlockEnabled = true
    private static let defaultCalendarOverlayEnabled = false

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Settings are read several times a second on the main actor (the
    /// tracker's tick, SwiftUI bodies) and written rarely, only through this
    /// store, so reads are served from memory after the first.
    private let cache = OSAllocatedUnfairLock(initialState: [String: String?]())

    /// Reads a raw setting value. Swallows any error and returns nil (not fatal).
    public func get(_ key: String) -> String? {
        if let hit = cache.withLock({ $0[key] }) { return hit }
        do {
            let value = try writer.read { db in try SettingRow.fetchOne(db, key: key)?.value }
            cache.withLock { $0[key] = .some(value) }
            return value
        } catch {
            return nil
        }
    }

    /// Writes a raw setting value. Swallows any error.
    public func set(_ key: String, _ value: String) {
        do {
            try writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO setting (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value]
                )
            }
            cache.withLock { $0[key] = .some(value) }
        } catch {
            cache.withLock { _ = $0.removeValue(forKey: key) }
        }
    }

    public var idleThreshold: TimeInterval {
        self.get(Self.idleThresholdKey).flatMap(TimeInterval.init) ?? Self.defaultIdleThreshold
    }

    public func setIdleThreshold(_ v: TimeInterval) {
        set(Self.idleThresholdKey, String(v))
    }

    /// Off by default: until the user says so, no window title leaves the machine.
    public var jevEnabled: Bool {
        self.get(Self.jevEnabledKey) == "true"
    }

    public func setJevEnabled(_ v: Bool) {
        set(Self.jevEnabledKey, v ? "true" : "false")
    }

    /// Off by default and independent of `jevEnabled`: the OCR text of
    /// screenshots is sent only when this is on (and Jev itself is).
    public var jevScreenText: Bool {
        self.get(Self.jevScreenTextKey) == "true"
    }

    public func setJevScreenText(_ v: Bool) {
        set(Self.jevScreenTextKey, v ? "true" : "false")
    }

    public var jevEndpoint: String {
        self.get(Self.jevEndpointKey) ?? JevClient.defaultEndpoint
    }

    public func setJevEndpoint(_ v: String) {
        set(Self.jevEndpointKey, v)
    }

    /// The pinned Jev model id; changed only by hand.
    public var jevModel: String {
        let v = self.get(Self.jevModelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return v.isEmpty ? JevClient.defaultModel : v
    }

    public func setJevModel(_ v: String) {
        set(Self.jevModelKey, v.trimmingCharacters(in: .whitespaces))
    }

    /// What Jev may cost in a calendar month, in USD; its worker stops there.
    public var jevMonthlyCap: Double {
        self.get(Self.jevMonthlyCapKey).flatMap(Double.init) ?? Self.defaultJevMonthlyCap
    }

    public func setJevMonthlyCap(_ v: Double) {
        set(Self.jevMonthlyCapKey, String(v))
    }

    /// USD spent on Jev in the calendar month of `date`.
    public func jevSpend(in date: Date = Date()) -> Double {
        self.get(Self.jevSpendKey(date)).flatMap(Double.init) ?? 0
    }

    public func addJevSpend(_ usd: Double, on date: Date = Date()) {
        set(Self.jevSpendKey(date), String(jevSpend(in: date) + usd))
    }

    private static func jevSpendKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "jevSpend.%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public var budgetWarnPercent: Int {
        self.get(Self.budgetWarnPercentKey).flatMap(Int.init) ?? Self.defaultBudgetWarnPercent
    }

    public func setBudgetWarnPercent(_ v: Int) {
        set(Self.budgetWarnPercentKey, String(v))
    }

    public var dailySummaryEnabled: Bool {
        self.get(Self.dailySummaryEnabledKey).flatMap { $0 == "true" } ?? Self.defaultDailySummaryEnabled
    }

    public func setDailySummaryEnabled(_ v: Bool) {
        set(Self.dailySummaryEnabledKey, v ? "true" : "false")
    }

    public var dailySummaryHour: Int {
        self.get(Self.dailySummaryHourKey).flatMap(Int.init) ?? Self.defaultDailySummaryHour
    }

    public func setDailySummaryHour(_ v: Int) {
        set(Self.dailySummaryHourKey, String(v))
    }

    /// nil until the first daily summary is ever sent, or after an explicit
    /// clear (an empty stored value round-trips back to nil).
    public var lastSummaryDay: String? {
        let v = self.get(Self.lastSummaryDayKey)
        return (v?.isEmpty ?? true) ? nil : v
    }

    public func setLastSummaryDay(_ v: String?) {
        set(Self.lastSummaryDayKey, v ?? "")
    }

    public var menuBarTextEnabled: Bool {
        self.get(Self.menuBarTextEnabledKey).flatMap { $0 == "true" } ?? Self.defaultMenuBarTextEnabled
    }

    public func setMenuBarTextEnabled(_ v: Bool) {
        set(Self.menuBarTextEnabledKey, v ? "true" : "false")
    }

    public var focusDurationMinutes: Int {
        self.get(Self.focusDurationMinutesKey).flatMap(Int.init) ?? Self.defaultFocusDurationMinutes
    }

    public func setFocusDurationMinutes(_ v: Int) {
        set(Self.focusDurationMinutesKey, String(v))
    }

    public var focusAppBlockEnabled: Bool {
        self.get(Self.focusAppBlockEnabledKey).flatMap { $0 == "true" } ?? Self.defaultFocusAppBlockEnabled
    }

    public func setFocusAppBlockEnabled(_ v: Bool) {
        set(Self.focusAppBlockEnabledKey, v ? "true" : "false")
    }

    public var focusSiteBlockEnabled: Bool {
        self.get(Self.focusSiteBlockEnabledKey).flatMap { $0 == "true" } ?? Self.defaultFocusSiteBlockEnabled
    }

    public func setFocusSiteBlockEnabled(_ v: Bool) {
        set(Self.focusSiteBlockEnabledKey, v ? "true" : "false")
    }

    public var focusBlockedApps: [String] {
        (self.get(Self.focusBlockedAppsKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    public func setFocusBlockedApps(_ values: [String]) {
        set(Self.focusBlockedAppsKey, values.joined(separator: ","))
    }

    public var focusBlockedCategories: [String] {
        (self.get(Self.focusBlockedCategoriesKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    public func setFocusBlockedCategories(_ values: [String]) {
        set(Self.focusBlockedCategoriesKey, values.joined(separator: ","))
    }

    public var calendarOverlayEnabled: Bool {
        self.get(Self.calendarOverlayEnabledKey).flatMap { $0 == "true" } ?? Self.defaultCalendarOverlayEnabled
    }

    public func setCalendarOverlayEnabled(_ v: Bool) {
        set(Self.calendarOverlayEnabledKey, v ? "true" : "false")
    }

    public var screenCapturePaused: Bool {
        self.get(Self.screenCapturePausedKey) == "true"
    }

    public func setScreenCapturePaused(_ v: Bool) {
        set(Self.screenCapturePausedKey, v ? "true" : "false")
    }

    // MARK: - Cloud (docs/superpowers/specs/2026-09-22-timesink-cloud-design.md)

    private static let cloudDeviceIDKey = "cloud.deviceID"
    private static let cloudSyncEnabledKey = "cloud.syncEnabled"
    private static let cloudPullCursorKey = "cloud.pullCursor"
    private static let cloudEmailKey = "cloud.email"
    private static let cloudUserSubKey = "cloud.userSub"
    private static let cloudLastSyncAtKey = "cloud.lastSyncAt"

    /// This database's identity towards the cloud, minted on first use. It
    /// lives in the database on purpose: a fresh database is a new device,
    /// and the old one's rows come back to it as another device's.
    public var cloudDeviceID: String {
        if let v = self.get(Self.cloudDeviceIDKey), !v.isEmpty { return v }
        let v = UUID().uuidString.lowercased()
        set(Self.cloudDeviceIDKey, v)
        return v
    }

    /// Off by default: nothing leaves the machine until the user says so.
    public var cloudSyncEnabled: Bool {
        self.get(Self.cloudSyncEnabledKey) == "true"
    }

    public func setCloudSyncEnabled(_ v: Bool) {
        set(Self.cloudSyncEnabledKey, v ? "true" : "false")
    }

    public var cloudPullCursor: String? { nonEmpty(Self.cloudPullCursorKey) }
    public func setCloudPullCursor(_ v: String?) { set(Self.cloudPullCursorKey, v ?? "") }

    public var cloudEmail: String? { nonEmpty(Self.cloudEmailKey) }
    public func setCloudEmail(_ v: String?) { set(Self.cloudEmailKey, v ?? "") }

    public var cloudUserSub: String? { nonEmpty(Self.cloudUserSubKey) }
    public func setCloudUserSub(_ v: String?) { set(Self.cloudUserSubKey, v ?? "") }

    public var cloudLastSyncAt: Date? {
        nonEmpty(Self.cloudLastSyncAtKey).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    public func setCloudLastSyncAt(_ v: Date?) {
        set(Self.cloudLastSyncAtKey, v.map { String($0.timeIntervalSince1970) } ?? "")
    }

    /// Same empty-means-nil round trip `lastSummaryDay` uses.
    private func nonEmpty(_ key: String) -> String? {
        let v = self.get(key)
        return (v?.isEmpty ?? true) ? nil : v
    }
}
