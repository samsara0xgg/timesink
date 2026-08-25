@preconcurrency import ApplicationServices
import AppKit

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
        case -600: return .unavailable("Chrome 未运行")
        case -1744: return .notDetermined
        default: return .denied
        }
    }

    @MainActor public static func accessibilityState(prompt: Bool) -> PermissionState {
        accessibilityGranted(prompt: prompt) ? .granted : .denied
    }
    @MainActor public static func chromeAutomationState(ask: Bool) -> PermissionState {
        chromeState(from: chromeAutomationStatus(ask: ask))
    }
}
