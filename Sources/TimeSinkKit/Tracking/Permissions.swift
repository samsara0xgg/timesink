@preconcurrency import ApplicationServices
import AppKit
import EventKit
import os

private let permissionsLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "permissions")

public enum Permissions {
    @MainActor
    public static func accessibilityGranted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    @MainActor
    public static func chromeAutomationStatus(ask: Bool) -> OSStatus {
        let bundleID = "com.google.Chrome"
        var addr = AEAddressDesc()
        let data = bundleID.data(using: .utf8)!
        let err = data.withUnsafeBytes { ptr in
            AECreateDesc(typeApplicationBundleID, ptr.baseAddress, data.count, &addr)
        }
        guard err == noErr else { return OSStatus(err) }
        defer { AEDisposeDesc(&addr) }
        return AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, ask)
    }
}

public enum PermissionState: Equatable, Sendable {
    case granted, denied, notDetermined
    case unavailable(String)

    /// True for `.unavailable` regardless of message — lets callers branch
    /// on the case without string-comparing the associated value.
    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

extension Permissions {
    /// 纯映射，可测：AEDeterminePermissionToAutomateTarget 的 OSStatus → 状态。
    /// -1744 = errAEEventWouldRequireUserConsent（从未询问过）。
    public nonisolated static func chromeState(from status: OSStatus) -> PermissionState {
        switch status {
        case noErr: return .granted
        case -600: return .unavailable(String(localized: "Chrome 未运行"))
        case -1744: return .notDetermined
        default: return .denied
        }
    }

    /// Screen Recording, read without prompting; `ScreenCollector` asks once.
    public nonisolated static func screenRecordingState() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    @MainActor public static func accessibilityState(prompt: Bool) -> PermissionState {
        accessibilityGranted(prompt: prompt) ? .granted : .denied
    }
    @MainActor public static func chromeAutomationState(ask: Bool) -> PermissionState {
        chromeState(from: chromeAutomationStatus(ask: ask))
    }

    /// A cheap, non-prompting authorization read -- safe to call anywhere
    /// (unlike `requestCalendarAccess`), same spirit as
    /// `accessibilityState(prompt: false)`.
    @MainActor public static func calendarState() -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable(String(localized: "未知日历权限状态"))
        }
    }

    /// Requests full calendar read/write access, prompting the user if
    /// `.notDetermined`. Bundle-gated -- the crash gate, not a style choice:
    /// `EKEventStore`'s access-request APIs throw an uncatchable ObjC
    /// exception outside an installed app bundle, same failure mode as
    /// `UNUserNotificationCenter.current()` in `Notifier.swift`.
    @MainActor public static func requestCalendarAccess() async -> Bool {
        guard Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink" else { return false }
        do {
            return try await EKEventStore().requestFullAccessToEvents()
        } catch {
            // Spec §11 mandates this log by name: a missing
            // `NSCalendarsFullAccessUsageDescription` in the app bundle makes
            // this call fail silently and PERMANENTLY (calendar overlay,
            // meeting badges and the idle exemption all dead, with no trace
            // in Console). Every other error path in this batch logs the same
            // way, so a silent `return false` here is convention drift too.
            permissionsLogger.error(
                "requestFullAccessToEvents failed (check NSCalendarsFullAccessUsageDescription in Info.plist): \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// The 通知 row's state read (spec §11's fourth permission), kept out of
    /// the permissions pane so it's testable without a view.
    ///
    /// Async because `UNUserNotificationCenter.getNotificationSettings` is
    /// callback-based -- callers cache the result in `@State` from `onAppear`
    /// exactly like the three TCC reads above (spec §11's 通知状态缓存 note),
    /// never polling. Always goes through the injected `Notifying` so
    /// `swift test` / `swift run` (which get `NoopNotifier` via
    /// `NotifierFactory`) never touch the real notification center. A nil
    /// notifier (never injected) reads as `.denied` -- the same conservative
    /// fallback `NoopNotifier` itself returns.
    @MainActor public static func notificationState(_ notifier: (any Notifying)?) async -> PermissionState {
        await notifier?.authorizationState() ?? .denied
    }
}
