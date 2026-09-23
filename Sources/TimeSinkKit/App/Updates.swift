import AppKit
import Sparkle

/// Sparkle's updater and standard UI. Exists only in a bundle whose
/// Info.plist names a feed (`SUFeedURL`): a `swift run` build has no
/// Info.plist, and a started updater without a feed alerts at launch.
@MainActor
public final class Updates: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    public static func startIfConfigured() -> Updates? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil ? nil : Updates()
    }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    public var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    public func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// "0.2.0 (3)" -- the marketing version and the build number Sparkle
    /// compares against the appcast.
    public static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // The app runs as an accessory (no Dock icon), so a scheduled update
    // alert would open behind whatever app is in front. Sparkle asks
    // background apps to opt in to handling that; bringing the app forward
    // when the alert shows is the whole of our handling.
    public nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    public nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) }
    }
}
