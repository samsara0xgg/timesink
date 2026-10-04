#if DEBUG
import AppKit
import SwiftUI

/// `--onboarding-frames <outdir>`: the welcome card's intro at progress 0, 0.1 ... 1,
/// and the settled card with the first-record row, as 2x PNGs. No visible window, no activation, a fixture model, never the system's permissions.
public enum OnboardingFrames {
    @MainActor public static func run(outdir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        Task { @MainActor in
            do {
                let dir = URL(fileURLWithPath: outdir, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let model = try RefinedPreview.fixture()
                for step in 0...10 {
                    try await write(OnboardingView(model: model, preview: .init(progress: Double(step) / 10, live: nil)), to: dir.appendingPathComponent(String(format: "intro-%02d.png", step * 10)))
                }
                try await write(OnboardingView(model: model, preview: .init(progress: 1, live: ("Safari", "com.apple.Safari", 3.4))), to: dir.appendingPathComponent("final-live.png"))
            } catch { print("Frames failed: \(error)"); exit(1) }
            exit(0)
        }
        app.run()
    }

    /// A borderless window far off every screen, ordered front without activating
    /// anything: the controls and app icons only draw for real when hosted in one.
    @MainActor private static func write(_ view: OnboardingView, to url: URL) async throws {
        let size = OnboardingView.size
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))
        guard let host = window.contentView,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = size
        host.layoutSubtreeIfNeeded()
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
#endif
