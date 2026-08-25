import SwiftUI
import GRDB
import os
import AppKit

public struct TimeSinkApp: App {
    let model: AppModel
    /// True only when running as the installed bundle (`swift run` bare
    /// execution has no bundle identifier) and Accessibility isn't yet
    /// granted — gates whether the onboarding sheet opens at launch.
    let needsOnboarding: Bool

    @Environment(\.openWindow) private var openWindow
    @State private var showOnboarding: Bool
    @NSApplicationDelegateAdaptor(TimeSinkAppDelegate.self) private var appDelegate

    public init() {
        // A second launch (e.g. installed app + `swift run` dev build with the
        // same bundle id, or a double-open) would run a second 1s sampler into
        // the same database and double-count every span -- hand off to the
        // existing instance instead.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != .current }
            if let existing = others.first {
                existing.activate()
                exit(0)
            }
        }

        NSApplication.shared.setActivationPolicy(.accessory)

        let db: any DatabaseWriter
        do {
            db = try AppDatabase.open(at: try AppDatabase.defaultURL())
        } catch {
            Logger(subsystem: "com.alllllenshi.TimeSink", category: "app")
                .fault("failed to open database: \(String(describing: error))")
            fatalError("cannot open TimeSink database: \(error)")
        }

        let spanStore = SpanStore(db)
        let settingsStore = SettingsStore(db)
        let categoryStore = CategoryStore(db)
        SeedImporter.importIfNeeded(categoryStore: categoryStore, settings: settingsStore)

        let resolver = CategoryResolver(categoryStore: categoryStore)
        let engine = TrackerEngine(spanStore: spanStore, settings: settingsStore)
        engine.llmCoordinator = LLMCoordinator(
            categoryStore: categoryStore, settings: settingsStore, resolver: resolver, service: nil
        )

        let model = AppModel(
            categoryStore: categoryStore,
            spanStore: spanStore,
            settings: settingsStore,
            resolver: resolver,
            engine: engine
        )
        self.model = model

        let calendarStore = CalendarStore()
        model.calendarStore = calendarStore
        engine.isInMeetingProvider = { [weak model] in model?.isNowInMeeting ?? false }
        model.observeCalendarChanges()
        model.startCalendarRefreshLoop()

        let needsOnboarding = Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink"
            && !Permissions.accessibilityGranted(prompt: false)
        self.needsOnboarding = needsOnboarding
        _showOnboarding = State(initialValue: needsOnboarding)

        engine.start()
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuBarDashboardView(model: model)
        } label: {
            MenuBarLabel(model: model)
                .onAppear {
                    // The menu bar label renders as soon as the app launches
                    // (before any window is shown), so this is a reliable
                    // launch hook for force-opening the main window when
                    // onboarding is needed.
                    appDelegate.engine = model.engine
                    if needsOnboarding {
                        openWindow(id: "main")
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Window("TimeSink", id: "main") {
            MainWindowView(model: model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The menu bar's icon + optional text label. Text is today's focus time
/// (`model.menuTitle` -- not `todayTotalTitle`), hidden entirely when
/// `menuTextEnabled` is off so only the icon remains. The icon itself swaps
/// to a badged variant while `model.chromeDegraded` is true, signaling that
/// Chrome tab titles/URLs aren't being captured. Reads the `AppModel` mirror
/// rather than `model.engine.chromeCaptureDegraded` directly -- `TrackerEngine`
/// isn't `@Observable`, so a direct read would register no dependency and the
/// icon would never update on its own (see `AppModel.chromeDegraded`).
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.chromeDegraded
                  ? "hourglass.badge.exclamationmark" : "hourglass")
                .accessibilityLabel(model.chromeDegraded ? "Chrome 采集降级" : "TimeSink")
            if model.menuTextEnabled {
                Text(model.menuTitle).monospacedDigit()
            }
        }
    }
}

/// The menu-bar 退出 button is the only in-app quit path that stops the
/// engine; logout, shutdown, and Cmd-Q would otherwise skip `stop()` and
/// drop up to 30s of the in-progress span (spans younger than 30s vanish
/// entirely -- they are first written at their first heartbeat). Routing
/// every termination through the delegate closes that daily loss path.
///
/// Also conforms to `UNUserNotificationCenterDelegate` -- that conformance
/// and its callbacks live in an extension in `Notifier.swift` instead of
/// here, so `import UserNotifications` stays confined to that one file (the
/// crash-gate file for `UNUserNotificationCenter` access).
///
/// `@unchecked Sendable`: instances are reached from multiple execution
/// contexts -- AppKit's main-thread delegate calls, and
/// `UNUserNotificationCenterDelegate`'s off-main-thread ones -- but every
/// mutation is manually disciplined onto the main actor (`MainActor
/// .assumeIsolated` where AppKit guarantees the call site is already main
/// thread, `Task { @MainActor in ... }` where it doesn't; see `route(_:)`
/// and `Notifier.swift`), so this promise is upheld by convention rather
/// than by the compiler.
final class TimeSinkAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var engine: TrackerEngine?

    /// Set by Task 11's wiring; invoked when a delivered notification is
    /// tapped, decoded from its `userInfo["route"]`. `@MainActor @Sendable`
    /// so the value itself is safe to store and to invoke on the main actor
    /// from the `UNUserNotificationCenterDelegate` callback's actor hop (in
    /// `Notifier.swift`). If a route arrives before this is assigned (e.g.
    /// macOS cold-launching the app from a notification tap, ahead of
    /// SwiftUI's post-launch wiring), `route(_:)` buffers it in
    /// `pendingRoute` instead; this `didSet` flushes that buffer once set.
    var onRoute: (@MainActor @Sendable (NotificationRoute) -> Void)? {
        didSet {
            guard let onRoute else { return }
            MainActor.assumeIsolated {
                guard let pending = pendingRoute else { return }
                pendingRoute = nil
                onRoute(pending)
            }
        }
    }

    /// A route decoded from a tapped notification that arrived before
    /// `onRoute` was assigned. Flushed by `onRoute`'s `didSet`. Read-only
    /// outside this file (mutated only by `route(_:)` and that `didSet`,
    /// both main-actor-disciplined per the type's `@unchecked Sendable`
    /// note above); exposed for tests.
    private(set) var pendingRoute: NotificationRoute?

    /// Delivers a decoded notification route: invokes `onRoute` immediately
    /// if it's set, otherwise buffers it in `pendingRoute` for delivery once
    /// `onRoute` is assigned. Doesn't touch `UNUserNotificationCenter`, so
    /// it's directly unit-testable; called from `Notifier.swift`'s
    /// `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:)`
    /// after hopping to the main actor.
    @MainActor
    func route(_ route: NotificationRoute) {
        if let onRoute {
            onRoute(route)
        } else {
            pendingRoute = route
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { engine?.stop() }
        return .terminateNow
    }
}
