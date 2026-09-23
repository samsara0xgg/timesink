import Foundation
import UserNotifications
import os

/// Where a tapped notification should route the user inside the app.
/// Encoded into `userInfo["route"]` and decoded by
/// `TimeSinkAppDelegate.userNotificationCenter(_:didReceive:)`.
public enum NotificationRoute: String, Sendable {
    case settingsBudget   // 预算通知 → 设置·预算
    case statsToday       // 每日小结 → 统计·今天
    case activitiesToday  // 专注结束 → 活动·今天
}

@MainActor
public protocol Notifying: AnyObject {
    func requestAuthorization() async -> Bool
    func authorizationState() async -> PermissionState
    /// id 用于同类覆盖（如 "budget.entertainment"）；route 编入 userInfo["route"]。
    func post(id: String, title: String, body: String, route: NotificationRoute?)
}

/// Real implementation backed by `UNUserNotificationCenter`. Never touches
/// the center in stored-property initializers -- only lazily inside method
/// bodies -- because a bundle-less process (`swift test` / `swift run`
/// without the installed app bundle) throws an uncatchable ObjC exception
/// the moment `UNUserNotificationCenter.current()` is resolved. Callers must
/// only construct this via `NotifierFactory.make()`, which gates on the
/// bundle identifier first.
@MainActor
public final class SystemNotifier: Notifying {
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "notifier")

    public init() {}

    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("requestAuthorization failed: \(String(describing: error))")
            return false
        }
    }

    public func authorizationState() async -> PermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable(String(localized: "未知通知权限状态"))
        }
    }

    public func post(id: String, title: String, body: String, route: NotificationRoute?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let route {
            content.userInfo = ["route": route.rawValue]
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.error("post(\(id, privacy: .public)) failed: \(String(describing: error))")
            }
        }
    }
}

/// Used whenever there's no installed app bundle (`swift test`, `swift run`
/// dev execution) so nothing ever touches `UNUserNotificationCenter`.
@MainActor
public final class NoopNotifier: Notifying {
    public init() {}
    public func requestAuthorization() async -> Bool { false }
    public func authorizationState() async -> PermissionState { .denied }
    public func post(id: String, title: String, body: String, route: NotificationRoute?) {}
}

public enum NotifierFactory {
    /// This bundle-identifier check is the crash gate, not a style choice:
    /// `UNUserNotificationCenter.current()` throws an uncatchable ObjC
    /// exception outside an installed app bundle.
    @MainActor
    public static func make() -> any Notifying {
        Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink" ? SystemNotifier() : NoopNotifier()
    }
}

/// `UNUserNotificationCenterDelegate` conformance for `TimeSinkAppDelegate`
/// (declared in `App/TimeSinkApp.swift`) lives here rather than there so
/// `import UserNotifications` stays confined to this single crash-gate file.
extension TimeSinkAppDelegate: UNUserNotificationCenterDelegate {
    /// Registers `self` as the notification center delegate. Bundle-gated
    /// for the same reason as `NotifierFactory.make()` -- touching
    /// `UNUserNotificationCenter.current()` outside an installed app bundle
    /// crashes.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink" else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Shows the banner even while the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Called on a background thread -- hops to the main actor before
    /// calling `route(_:)` rather than `MainActor.assumeIsolated`, which
    /// would be a false assertion here. `route(_:)` delivers immediately if
    /// `onRoute` is set, or buffers into `pendingRoute` if this notification
    /// tap cold-launched the app ahead of SwiftUI's post-launch wiring.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let raw = response.notification.request.content.userInfo["route"] as? String,
              let route = NotificationRoute(rawValue: raw) else { return }
        Task { @MainActor in
            self.route(route)
        }
    }
}
