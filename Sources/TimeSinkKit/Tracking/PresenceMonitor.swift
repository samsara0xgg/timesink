import AppKit
import CoreAudio
import Foundation
import IOKit.pwr_mgt

/// An app the user is on a call in, or watching a video in, whether or not it
/// is frontmost and whether or not a key was touched.
public struct Presence: Equatable, Sendable {
    public enum Kind: String, Sendable { case call, video }
    public var kind: Kind
    public var bundleID: String
    public var appName: String
    /// Something is playing on screen (the app keeps the display awake): only
    /// then does presence count as screen time. A voice-only call is just a lane.
    public var onScreen: Bool

    public init(kind: Kind, bundleID: String, appName: String, onScreen: Bool = true) {
        self.kind = kind; self.bundleID = bundleID; self.appName = appName; self.onScreen = onScreen
    }
}

/// Reads "which app is on a call / playing a video" from CoreAudio's per-process
/// list and IOKit power assertions. The decision is the pure `decide`; the OS
/// reads below it are thin. Device-level "the mic is running" is never used: an
/// always-on voice assistant holds the mic all day, so a call is only a process
/// from the allowlist running input.
public final class PresenceMonitor: @unchecked Sendable {
    struct AudioProcess: Equatable {
        var pid: pid_t
        var bundleID: String
        var input: Bool
        var output: Bool
    }
    struct App: Equatable {
        var pid: pid_t
        var bundleID: String
        var name: String
        /// A Dock app, as against a helper or agent.
        var regular: Bool
    }

    /// Bundle ID prefixes of call apps. Helpers (`us.zoom.CptHost`,
    /// `com.hnc.Discord.helper`) carry the app's prefix.
    static let callPrefixes = ["us.zoom", "com.hnc.Discord", "com.tencent.xinWeChat", "com.apple.FaceTime", "com.microsoft.teams"]
    static let refreshInterval: TimeInterval = 5

    /// The app that owns `bundleID`: the longest running regular app whose bundle ID it is or extends.
    static func root(of bundleID: String, apps: [App]) -> App? {
        apps.filter { $0.regular && (bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".")) }
            .max { $0.bundleID.count < $1.bundleID.count }
    }

    private static func presence(_ kind: Presence.Kind, bundleID: String, apps: [App], onScreen: Set<String>) -> Presence {
        let owner = root(of: bundleID, apps: apps)
        let id = owner?.bundleID ?? bundleID
        return Presence(kind: kind, bundleID: id, appName: owner?.name ?? bundleID, onScreen: onScreen.contains(id))
    }

    /// Call wins over video. Video needs a display-sleep assertion AND audio output from the same
    /// app: music players only hold system-sleep assertions, caffeinate-style tools hold display
    /// assertions without audio.
    static func decide(audio: [AudioProcess], displayAssertionPIDs: [pid_t], apps: [App], ownPID: pid_t) -> Presence? {
        let displayOwners = displayAssertionPIDs.filter { $0 != ownPID }.compactMap { pid -> String? in
            guard let bundleID = apps.first(where: { $0.pid == pid })?.bundleID ?? audio.first(where: { $0.pid == pid })?.bundleID else { return nil }
            return root(of: bundleID, apps: apps)?.bundleID ?? bundleID
        }
        for process in audio where process.input {
            if let prefix = callPrefixes.first(where: { process.bundleID.hasPrefix($0) }) {
                // The running regular app carrying the prefix is the call's app (Zoom's audio comes from a helper).
                let main = apps.first { $0.regular && $0.bundleID.hasPrefix(prefix) }
                return presence(.call, bundleID: main?.bundleID ?? process.bundleID, apps: apps, onScreen: Set(displayOwners))
            }
        }
        let playing = Set(audio.filter(\.output).compactMap { root(of: $0.bundleID, apps: apps)?.bundleID ?? $0.bundleID })
        for owner in displayOwners where playing.contains(owner) {
            return presence(.video, bundleID: owner, apps: apps, onScreen: Set(displayOwners))
        }
        return nil
    }

    private var cached: Presence?
    private var readAt = Date.distantPast
    private let lock = NSLock()

    public init() {}

    /// The current presence, read at most every 5 s.
    public func current(now: Date = Date()) -> Presence? {
        lock.lock(); defer { lock.unlock() }
        guard now.timeIntervalSince(readAt) >= Self.refreshInterval else { return cached }
        readAt = now
        cached = Self.decide(audio: Self.audioProcesses(), displayAssertionPIDs: Self.displayAssertionPIDs(),
                             apps: Self.runningApps(), ownPID: ProcessInfo.processInfo.processIdentifier)
        return cached
    }

    // MARK: OS reads

    private static func runningApps() -> [App] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return App(pid: app.processIdentifier, bundleID: bundleID, name: app.localizedName ?? bundleID,
                       regular: app.activationPolicy == .regular)
        }
    }

    static func displayAssertionPIDs() -> [pid_t] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let byPID = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return byPID.compactMap { pid, assertions in
            assertions.contains { ($0["AssertType"] as? String) == "PreventUserIdleDisplaySleep" } ? pid.int32Value : nil
        }
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as _: T.Type, default zero: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func audioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            guard let pid = property(object, kAudioProcessPropertyPID, as: pid_t.self, default: 0),
                  let bundle = property(object, kAudioProcessPropertyBundleID, as: CFString?.self, default: nil) ?? nil else { return nil }
            return AudioProcess(pid: pid, bundleID: bundle as String,
                                input: (property(object, kAudioProcessPropertyIsRunningInput, as: UInt32.self, default: 0) ?? 0) != 0,
                                output: (property(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self, default: 0) ?? 0) != 0)
        }
    }
}
