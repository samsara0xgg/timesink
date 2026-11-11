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
    /// The app is playing audio too. A call opens only with output (so a lone
    /// open mic is not a call) but, once open, continues on input alone: silence
    /// in a voice channel stops the output without ending the call.
    public var output: Bool
    /// When the read this came from was taken; nil when not from a read. Cached reads hand the
    /// same one to several ticks, so "two reads in a row" is two different times here.
    public var sampledAt: Date?

    public init(kind: Kind, bundleID: String, appName: String, onScreen: Bool = true, output: Bool = true, sampledAt: Date? = nil) {
        self.kind = kind; self.bundleID = bundleID; self.appName = appName; self.onScreen = onScreen; self.output = output
        self.sampledAt = sampledAt
    }
}

/// Reads "which app is on a call / playing a video" from CoreAudio's per-process
/// list and IOKit power assertions. The decision is the pure `decide`; the OS
/// reads below it are thin. Device-level "the mic is running" is never used: an
/// always-on voice assistant holds the mic all day, so a call is only a process
/// from the allowlist running input.
public final class PresenceMonitor: @unchecked Sendable {
    struct AudioProcess: Equatable, Sendable {
        var pid: pid_t
        var bundleID: String
        var input: Bool
        var output: Bool
    }
    struct App: Equatable, Sendable {
        var pid: pid_t
        var bundleID: String
        var name: String
        /// A Dock app, as against a helper or agent.
        var regular: Bool
    }

    /// Bundle ID prefixes of call apps. Helpers (`us.zoom.CptHost`,
    /// `com.hnc.Discord.helper`) carry the app's prefix.
    static let callPrefixes = ["us.zoom", "com.hnc.Discord", "com.tencent.xinWeChat", "com.apple.FaceTime", "com.microsoft.teams",
                                  "com.tencent.meeting", "com.tencent.qq"]
    static let refreshInterval: TimeInterval = 5

    /// The app that owns `bundleID`: the longest running regular app whose bundle ID it is or extends.
    static func root(of bundleID: String, apps: [App]) -> App? {
        apps.filter { $0.regular && (bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".")) }
            .max { $0.bundleID.count < $1.bundleID.count }
    }

    private static func presence(_ kind: Presence.Kind, bundleID: String, apps: [App], onScreen: Set<String>, audio: [AudioProcess]) -> Presence {
        let owner = root(of: bundleID, apps: apps)
        let id = owner?.bundleID ?? bundleID
        let output = audio.contains { $0.output && (root(of: $0.bundleID, apps: apps)?.bundleID ?? $0.bundleID) == id }
        return Presence(kind: kind, bundleID: id, appName: owner?.name ?? bundleID, onScreen: onScreen.contains(id), output: output)
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
                var call = presence(.call, bundleID: main?.bundleID ?? process.bundleID, apps: apps, onScreen: Set(displayOwners), audio: audio)
                // Output by the same prefix: Zoom's audio helpers (`us.zoom.CptHost`) are not under `us.zoom.xos.`.
                call.output = audio.contains { $0.output && $0.bundleID.hasPrefix(prefix) }
                return call
            }
        }
        let playing = Set(audio.filter(\.output).compactMap { root(of: $0.bundleID, apps: apps)?.bundleID ?? $0.bundleID })
        for owner in displayOwners where playing.contains(owner) {
            return presence(.video, bundleID: owner, apps: apps, onScreen: Set(displayOwners), audio: audio)
        }
        return nil
    }

    private var cached: Presence?
    private var readAt = Date.distantPast
    private var refreshing = false
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.alllllenshi.TimeSink.presence", qos: .utility)
    // Only accessed on queue. Keep system IPC outside the snapshot lock.
    private var sampledAt = Date.distantPast
    private var sampled: Presence?
    private var audioReader = AudioReader()
    private let readOverride: (@Sendable () -> Presence?)?

    public init() { readOverride = nil }

    init(readPresence: @escaping @Sendable () -> Presence?) { readOverride = readPresence }

    /// Returns once a queued background read has finished (tests).
    func waitForRefresh() { queue.sync {} }

    /// Synchronous read for command-line probes; app ticks use cachedCurrent.
    public func current(now: Date = Date()) -> Presence? {
        queue.sync { refresh(now: now) }
    }

    /// Never waits for CoreAudio. At most one refresh is queued, and the next
    /// tracker tick sees its result. The five-second sampling cadence is unchanged.
    public func cachedCurrent(now: Date = Date()) -> Presence? {
        lock.lock()
        let result = cached
        let elapsed = now.timeIntervalSince(readAt)
        let needsRefresh = !refreshing && (elapsed < 0 || elapsed >= Self.refreshInterval)
        if needsRefresh { refreshing = true }
        lock.unlock()
        if needsRefresh {
            // NSRunningApplication caches dynamic properties on the main run loop.
            // Snapshot them on the caller (the app's main thread); background
            // property reads otherwise repeatedly fetch LaunchServices metadata.
            let apps = readOverride == nil ? Self.runningApps() : nil
            queue.async { [self] in
                _ = refresh(now: now, appSnapshot: apps)
                lock.lock()
                refreshing = false
                lock.unlock()
            }
        }
        return result
    }

    private func refresh(now: Date, appSnapshot: [App]? = nil) -> Presence? {
        let elapsed = now.timeIntervalSince(sampledAt)
        guard elapsed < 0 || elapsed >= Self.refreshInterval else { return sampled }
        if let readOverride {
            sampled = readOverride()
        } else {
            let apps = appSnapshot ?? Self.runningApps()
            let assertions = Self.displayAssertionPIDs()
            let audio = audioReader.read(objects: Self.audioObjects(), apps: apps,
                                         displayAssertionPIDs: assertions, now: now,
                                         pid: { Self.property($0, kAudioProcessPropertyPID, as: pid_t.self, default: 0) },
                                         bundle: { Self.property($0, kAudioProcessPropertyBundleID, as: CFString?.self, default: nil).flatMap { $0 }.map { $0 as String } },
                                         running: { Self.property($0, $1, as: UInt32.self, default: 0).map { $0 != 0 } ?? false })
            sampled = Self.decide(audio: audio, displayAssertionPIDs: assertions,
                                  apps: apps, ownPID: ProcessInfo.processInfo.processIdentifier)
        }
        sampled?.sampledAt = now
        sampledAt = now
        lock.lock()
        cached = sampled
        readAt = now
        lock.unlock()
        return sampled
    }

    /// Refresh the PID every poll to catch reused audio object IDs. Bundle IDs
    /// are stable for a process, so cache them (with a bounded fallback expiry).
    /// Read live input only for call apps, and output only for call apps and display owners.
    struct AudioReader {
        private struct Identity {
            var pid: pid_t
            var bundleID: String
            var readAt: Date
        }
        private var identities: [AudioObjectID: Identity] = [:]

        mutating func read(objects: [AudioObjectID], apps: [App], displayAssertionPIDs: [pid_t], now: Date,
                           pid: (AudioObjectID) -> pid_t?, bundle: (AudioObjectID) -> String?,
                           running: (AudioObjectID, AudioObjectPropertySelector) -> Bool) -> [AudioProcess] {
            let live = Set(objects)
            identities = identities.filter { live.contains($0.key) }
            let processes: [(AudioObjectID, Identity)] = objects.compactMap { object in
                guard let processID = pid(object) else {
                    identities.removeValue(forKey: object)
                    return nil
                }
                if let cached = identities[object], cached.pid == processID,
                   (0..<60).contains(now.timeIntervalSince(cached.readAt)) {
                    return (object, cached)
                }
                guard let bundleID = bundle(object) else {
                    identities.removeValue(forKey: object)
                    return nil
                }
                let identity = Identity(pid: processID, bundleID: bundleID, readAt: now)
                identities[object] = identity
                return (object, identity)
            }
            // Retain all identities: a display assertion may belong to a helper
            // absent from NSWorkspace.runningApplications.
            let owners = Set(displayAssertionPIDs.compactMap { processID -> String? in
                guard let id = apps.first(where: { $0.pid == processID })?.bundleID
                    ?? processes.first(where: { $0.1.pid == processID })?.1.bundleID else { return nil }
                return Self.owner(id, apps: apps)
            })
            return processes.map { object, identity in
                let isCallApp = PresenceMonitor.callPrefixes.contains { identity.bundleID.hasPrefix($0) }
                let isDisplayOwner = owners.contains(Self.owner(identity.bundleID, apps: apps))
                return AudioProcess(pid: identity.pid, bundleID: identity.bundleID,
                                    input: isCallApp && running(object, kAudioProcessPropertyIsRunningInput),
                                    output: (isCallApp || isDisplayOwner) && running(object, kAudioProcessPropertyIsRunningOutput))
            }
        }

        private static func owner(_ bundleID: String, apps: [App]) -> String {
            PresenceMonitor.root(of: bundleID, apps: apps)?.bundleID ?? bundleID
        }
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

    private static func audioObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        // The list may shrink between the size query and the data read.
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}
