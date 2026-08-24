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
