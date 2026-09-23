import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision
import os

/// Looks at the front window on the tracker's schedule and stores one
/// capture (OCR text + a 1x JPEG of that window only) per distinct content.
/// Everything happens off the main actor; `TrackerEngine` hands each tick's
/// sample over and never waits for a capture.
///
/// A check is a window screenshot reduced to a 32x20 signature. Content is
/// judged in two stages: a signature that moved less than
/// `ScreenSignature.ocrFraction` is the same content and only extends the
/// row; between that and `changedFraction` the OCR text decides (one new
/// chat line moves few cells but changes the text); above `changedFraction`
/// it is a new row whatever the text says. Unchanged content is still
/// re-read every `refreshInterval`, so a small change the signature cannot
/// see is caught within that bound. A window whose title changed is new
/// content whatever the picture and the text say: the title is part of
/// what was on screen. Text that reads the same moves the comparison
/// baseline to the new frame (no OCR every check for a picture that
/// merely shifted), but the picture is also compared with the frame whose
/// image was saved: small steps that add up to `changedFraction` store a
/// new row and a new image, so a slowly changing chart is not lost.
public actor ScreenCollector {
    /// Never captured, whatever is in front.
    public static let excludedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.bitwarden.desktop",
    ]

    private let store: ObservationStore
    private let imagesRoot: URL
    private var policy: ScreenCapturePolicy
    /// Longest an unchanged-looking window goes without a fresh OCR read.
    public nonisolated let refreshInterval: TimeInterval
    /// Signature movement at or above which OCR runs to compare the text.
    private let ocrFraction: Double
    /// The row of the current observation segment, so re-checks of unchanged
    /// content extend it instead of inserting a duplicate. Same content seen
    /// again in a later segment (came back to the window, unlocked, resumed)
    /// is a new row: the stretch in between was not observed.
    private var current: (segment: Int, rowID: Int64, signature: [UInt8], saved: [UInt8], title: String?,
                          text: String, readAt: Date)?
    private var inFlight = false
    /// Test seam replacing the screenshot, the front-window recheck and OCR.
    typealias FrameProvider = @Sendable (WindowKey) async -> (image: CGImage, text: String)?
    private var frameProvider: FrameProvider?
    private var permissionLogged = false
    private var lastPrune = Date.distantPast
    public private(set) var paused: Bool
    /// Counters for the current health window; flushed as one `captureHealth`
    /// row every `healthWindow` seconds and on every interruption.
    public private(set) var health = CaptureHealth(windowStart: .distantPast, windowEnd: .distantPast)
    public static let healthWindow: TimeInterval = 600
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "screen")

    /// `policy`, `refreshInterval` and `ocrFraction` are knobs for tests and
    /// the tsprobe bench; the app uses the defaults.
    public init(store: ObservationStore, imagesRoot: URL, paused: Bool,
                policy: ScreenCapturePolicy = ScreenCapturePolicy(), refreshInterval: TimeInterval = 120,
                ocrFraction: Double = ScreenSignature.ocrFraction) {
        self.store = store
        self.imagesRoot = imagesRoot
        self.paused = paused
        self.policy = policy
        self.refreshInterval = refreshInterval
        self.ocrFraction = ocrFraction
    }

    public static func defaultImagesRoot() throws -> URL {
        try AppDatabase.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("captures", isDirectory: true)
    }

    public func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        interrupt()
        store.logState(value ? "pause" : "resume")
    }

    /// Lock, sleep or stop: the current observation segment ends now, not
    /// when the tick gap is noticed. The health window closes with it.
    public func interrupt() {
        policy.interrupt()
        flushHealth(at: Date())
    }

    func install(frameProvider: @escaping FrameProvider) {
        self.frameProvider = frameProvider
    }

    /// One tracker tick. `spanID` is the open span's row, nil while idle.
    public func tick(now: Date, sample: Sample, spanID: Int64?) async {
        if now.timeIntervalSince(lastPrune) > 3600 {
            lastPrune = now
            prune(now: now)
        }
        if health.windowStart == .distantPast {
            health = CaptureHealth(windowStart: now, windowEnd: now)
        } else if now.timeIntervalSince(health.windowStart) >= Self.healthWindow {
            flushHealth(at: now)
        }
        var key: WindowKey?
        if !paused, !Self.excludedBundleIDs.contains(sample.appBundleID), let id = sample.windowID {
            key = WindowKey(bundleID: sample.appBundleID, windowID: id)
        }
        guard policy.tick(now: now, window: key, title: sample.windowTitle), let key else { return }
        health.checks += 1
        guard !inFlight else { health.skippedBusy += 1; return }
        guard frameProvider != nil || hasPermission() else { health.permissionDenied += 1; return }
        inFlight = true
        defer { inFlight = false }
        await capture(key: key, sample: sample, spanID: spanID, at: now)
    }

    private func hasPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !permissionLogged {
            permissionLogged = true
            store.logState("screen_denied")
            CGRequestScreenCaptureAccess()
        }
        return false
    }

    private func capture(key: WindowKey, sample: Sample, spanID: Int64?, at now: Date) async {
        // Read before the awaits: ticks keep flowing through the actor while
        // the screenshot is in flight and may start a new segment meanwhile.
        let segment = policy.segment
        let frame: (image: CGImage, text: String?)?
        if let frameProvider {
            frame = await frameProvider(key).map { ($0.image, $0.text) }
            if frame == nil { health.screenshotFailed += 1 }
        } else {
            frame = await look(at: key).map { ($0, nil) }
        }
        guard let frame else { return }
        let signature = Self.signature(of: frame.image)
        var text: String?
        if let current, current.segment == segment, current.title == sample.windowTitle {
            let moved = ScreenSignature.fraction(current.signature, signature)
            // Against the saved image, not the last compared frame: small
            // steps that add up to a different picture are stored.
            let drifted = ScreenSignature.fraction(current.saved, signature)
            let stale = now.timeIntervalSince(current.readAt) >= refreshInterval
            if moved < ocrFraction && drifted < ScreenSignature.changedFraction && !stale {
                health.unchanged += 1
                extend(current.rowID, at: now)
                return
            }
            text = await read(frame)
            guard let read = text else { return }
            if moved < ScreenSignature.changedFraction && drifted < ScreenSignature.changedFraction
                && read == current.text {
                health.textSame += 1
                // This frame is the row's content now: compare the next one
                // against it, or every later check would re-run OCR.
                self.current?.signature = signature
                self.current?.readAt = now
                extend(current.rowID, at: now)
                return
            }
        } else {
            text = await read(frame)
        }
        guard let text else { return }
        let imagePath = writeJPEG(frame.image, at: now)
        let capture = Capture(at: now, lastSeenAt: now, appBundleID: sample.appBundleID,
                              appName: sample.appName, windowID: Int64(key.windowID),
                              title: sample.windowTitle, spanID: spanID, text: text, imagePath: imagePath)
        do {
            let inserted = try store.insert(capture)
            health.inserted += 1
            if let id = inserted.id { current = (segment, id, signature, signature, sample.windowTitle, text, now) }
        } catch {
            logger.error("capture insert failed: \(String(describing: error))")
        }
    }

    /// OCR of a frame, counted; nil when Vision failed (an empty page is "").
    private func read(_ frame: (image: CGImage, text: String?)) async -> String? {
        if let text = frame.text { return text }
        health.ocrRuns += 1
        // First OCR in a process warms the model up (see `ocrQueue`), then ~1 s.
        let image = frame.image
        let recognized = await withCheckedContinuation { continuation in
            Self.ocrQueue.async { continuation.resume(returning: Self.recognizeText(in: image)) }
        }
        guard let text = recognized else {
            health.ocrFailed += 1
            return nil
        }
        return text
    }

    private func extend(_ rowID: Int64, at now: Date) {
        health.extended += 1
        try? store.extend(id: rowID, lastSeenAt: now)
    }

    private func flushHealth(at now: Date) {
        guard health.windowStart != .distantPast else { return }
        health.windowEnd = now
        if health.hasActivity {
            store.record(health)
        }
        health = CaptureHealth(windowStart: now, windowEnd: now)
    }

    // MARK: - OS calls

    private func look(at key: WindowKey) async -> CGImage? {
        guard let image = await screenshot(windowID: key.windowID) else {
            health.screenshotFailed += 1
            return nil
        }
        // The window may have changed while the screenshot was in flight;
        // a sample of A must never be filed under B.
        guard await Self.frontWindowKey() == key else {
            health.notFront += 1
            return nil
        }
        return image
    }

    private func screenshot(windowID: UInt32) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                logger.error("window \(windowID) not in shareable content")
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.showsCursor = false
            config.captureResolution = .nominal
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            logger.error("screenshot failed: \(String(describing: error))")
            return nil
        }
    }

    private static func frontWindowKey() async -> WindowKey? {
        guard let app = await MainActor.run(body: { WindowSampler().frontmostApp() }),
              let id = WindowSampler().focusedWindow(pid: app.pid).id else { return nil }
        return WindowKey(bundleID: app.bundleID, windowID: id)
    }

    /// Grayscale thumbnail, one byte per cell, row-major.
    static func signature(of image: CGImage) -> [UInt8] {
        let w = ScreenSignature.columns, h = ScreenSignature.rows
        var cells = [UInt8](repeating: 0, count: w * h)
        cells.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return cells
    }

    /// OCR is never urgent, and on Apple silicon background QoS runs on the
    /// efficiency cores. A GCD queue, not a Task: awaiting a lower-priority
    /// Task from this actor would escalate it back to the caller's priority.
    /// Measured 2026-09-23 (tsprobe, same desktop, both builds at once): 6.3 J
    /// instead of 22.2 J over three steady minutes, no capture lost. Known
    /// gap: one cold model load took ~100 s here instead of ~20 s, and checks
    /// are skipped while it runs; give the first OCR default QoS if that matters.
    private static let ocrQueue = DispatchQueue(label: "com.alllllenshi.TimeSink.ocr", qos: .background)

    /// Recognized text top to bottom; nil when the request itself failed.
    static func recognizeText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let results = request.results else { return nil }
        // Vision's origin is bottom-left; read top to bottom.
        return results
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func writeJPEG(_ image: CGImage, at now: Date) -> String? {
        let day = CaptureRetention.dayStamp(now)
        let dir = imagesRoot.appendingPathComponent(day, isDirectory: true)
        let relative = "\(day)/\(Int(now.timeIntervalSince1970 * 1000)).jpg"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = imagesRoot.appendingPathComponent(relative)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? relative : nil
        } catch {
            logger.error("capture image write failed: \(String(describing: error))")
            return nil
        }
    }

    /// Deletes day folders older than the retention window and forgets
    /// their paths; capture rows and text stay.
    private func prune(now: Date) {
        let fm = FileManager.default
        let days = (try? fm.contentsOfDirectory(atPath: imagesRoot.path)) ?? []
        for day in days where CaptureRetention.isExpired(dayFolder: day, now: now) {
            try? fm.removeItem(at: imagesRoot.appendingPathComponent(day))
        }
        try? store.forgetImages(before: CaptureRetention.cutoff(now: now))
    }
}
