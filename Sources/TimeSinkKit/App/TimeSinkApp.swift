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
    /// C4: stored so `body`'s `.onAppear` (which runs long after `init`
    /// returns) can still hand it to `appDelegate` for `timesink://`
    /// handling -- the same instance `focusController.redirectChrome` uses.
    let chromeBlocker: ChromeBlocker

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

        // C4 budgets -- assigned AFTER `AppModel` construction (post-init
        // injection convention, see `AppModel.budgetMonitor`'s doc comment):
        // `model`'s own bootstrap `refreshMenu()` call inside `AppModel.init`
        // already ran with `budgetMonitor == nil`, so it's a free
        // didBootstrap guard against evaluating budgets/summary before
        // launch settles.
        let budgetStore = BudgetStore(db)
        let notifier = NotifierFactory.make()
        model.budgetStore = budgetStore
        model.notifier = notifier
        model.budgetMonitor = BudgetMonitor(budgetStore: budgetStore, settings: settingsStore, notifier: notifier)
        let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        try? budgetStore.pruneAlerts(before: BudgetEngine.dayStamp(ninetyDaysAgo, calendar: Calendar.current))

        // C4 focus sessions -- same post-init injection convention as
        // calendar/budgets above.
        let focusStore = FocusSessionStore(db)
        let focusController = FocusSessionController(store: focusStore, settings: settingsStore)
        let chromeBlocker = ChromeBlocker()
        self.chromeBlocker = chromeBlocker
        let focusHUD = FocusHUDController()

        focusController.notifier = notifier
        focusController.categoryForDomain = { [weak model] domain, url in
            guard let model else { return "uncategorized" }
            // A throwaway Span just to reuse `CategoryResolver`'s existing
            // domain/url classification path -- no span is ever persisted
            // from this.
            let probe = Span(start: Date(), end: Date(), appBundleID: "com.google.Chrome",
                              appName: "Chrome", title: nil, url: url, domain: domain)
            return model.resolver.categoryID(for: probe)
        }
        // Production hideApp: doesn't check `hide()`'s return value (it lies
        // in practice) and doesn't poll/retry -- `FocusBlockPolicy`'s
        // cooldown already rate-limits repeat attempts.
        focusController.hideApp = { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.hide()
        }
        focusController.redirectChrome = { [weak chromeBlocker] urlString in
            chromeBlocker?.setActiveTabURL(urlString) ?? false
        }
        focusController.showHUD = { [weak focusController, focusHUD] appName, hideCount in
            guard let focusController else { return }
            focusHUD.show(remaining: focusController.remaining, appName: appName, hideCount: hideCount,
                           keepFocusAppKey: focusController.lastHiddenAppKey ?? "", controller: focusController)
        }
        // `finish(completed:)` invokes `onFinish` BEFORE clearing `running`
        // (see its doc comment), so `focusController.running`'s
        // `plannedSeconds` is still readable here.
        focusController.onFinish = { [weak model, weak focusController, notifier] completed, appBlocks, siteBlocks in
            guard let model else { return }
            let running = focusController?.running
            let plannedMinutes = (running?.plannedSeconds ?? 0) / 60
            let prefix = completed ? "" : "提前结束，"
            let body = "\(prefix)\(plannedMinutes) 分钟完成，期间拦下 \(appBlocks + siteBlocks) 次分心（\(siteBlocks) 次网站 · \(appBlocks) 次应用）。"
            // Keyed by the session's row id, not a fixed string -- a fixed id
            // would make consecutive sessions silently replace each other's
            // notification at the OS level (the same de-dup mechanism budget
            // alerts use deliberately; here every finished session is a
            // distinct event that deserves its own visible notification).
            let notificationID = running.map { "focus.finished.\($0.id)" } ?? "focus.finished"
            notifier.post(id: notificationID, title: "专注会话结束", body: body, route: .activitiesToday)
            // Explicit user-visible completion -> direct dataChanged() call
            // (allowed per spec: this is the one non-debounced path) so the
            // timeline's focus block appears immediately.
            model.dataChanged()
        }
        model.focusStore = focusStore
        model.focus = focusController
        engine.focusInterceptor = { [weak focusController] sample, now in
            focusController?.intercept(sample: sample, at: now) ?? false
        }

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
                    // C4: a tapped notification decodes to a route on
                    // `appDelegate`; any route that arrived before this
                    // assignment (e.g. a cold launch from Notification
                    // Center) is buffered and flushed automatically by
                    // `onRoute`'s `didSet` -- see `TimeSinkAppDelegate`.
                    appDelegate.onRoute = { model.pendingRoute = $0 }
                    // C4: timesink:// URL handling (block page buttons) --
                    // see `TimeSinkAppDelegate.application(_:open:)`.
                    appDelegate.focus = model.focus
                    appDelegate.blocker = chromeBlocker
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

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.chromeDegraded
                  ? "hourglass.badge.exclamationmark" : "hourglass")
                .accessibilityLabel(model.chromeDegraded ? "Chrome 采集降级" : "TimeSink")
            // C4: while a focus session is running, the label swaps to a
            // live mm:ss countdown regardless of `menuTextEnabled` -- an
            // active session is itself worth surfacing even with the menu
            // bar text normally hidden. `model.focus?.running`/`.remaining`
            // are both `@Observable` reads on `FocusSessionController`
            // (itself `@MainActor @Observable`), so this registers
            // correctly without the 1s countdown timer ever calling
            // `dataChanged()`.
            if let focus = model.focus, focus.running != nil {
                Text(Format.mmss(focus.remaining))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
            } else if model.menuTextEnabled {
                Text(model.menuTitle).monospacedDigit()
            }
        }
        // C4: consumes a tapped notification's route. This label is the
        // menu bar's persistent view (unlike the popover content, which is
        // only alive while open), so it's the one reliable place to observe
        // `model.pendingRoute` regardless of what's currently on screen.
        .onChange(of: model.pendingRoute) { _, route in
            guard let route else { return }
            switch route {
            case .statsToday:
                model.range = .today()
                model.sidebarSelection = .stats
                openWindow(id: "main")
            case .activitiesToday:
                model.range = .today()
                model.sidebarSelection = .activities
                openWindow(id: "main")
            case .settingsBudget:
                model.settingsTab = .budget
                // R-T11c: `openSettings()` alone doesn't bring the app
                // forward while running `.accessory` (no Dock icon, e.g. the
                // main window isn't currently open) -- the Settings window
                // could otherwise open behind whatever app was frontmost.
                //
                // R-T11g: activate ONLY -- do NOT flip
                // `.setActivationPolicy(.regular)` here the way
                // `MainWindowView.onAppear` does for its own window. That
                // pairs with `.onDisappear` restoring `.accessory`; this
                // branch never opens (or closes) the "main" window, so a
                // policy flip here would have no matching restore path and
                // the Dock icon would linger indefinitely -- violating the
                // app's menubar-first `.accessory` design.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            model.pendingRoute = nil
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
    /// C4: set by `TimeSinkApp.body`'s `.onAppear`, read by
    /// `application(_:open:)` for `timesink://focus/...` URL handling.
    var focus: FocusSessionController?
    var blocker: ChromeBlocker?

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
        MainActor.assumeIsolated {
            engine?.stop()
            // Idempotent -- the popover's 退出 button already stops the
            // engine above; a running focus session still needs its row
            // closed out as "manually ended" regardless of which quit path
            // got here first.
            focus?.finish(completed: false)
        }
        return .terminateNow
    }

    /// C4: handles `timesink://focus/back` and `timesink://focus/allow?domain=x`
    /// links tapped from the local block page. `focus/back` redirects to a
    /// fresh new-tab page rather than closing the tab -- ScriptingBridge's
    /// tab-close semantics are unreliable enough (per `ChromeBlocker`'s
    /// design note) that a redirect is the honest degradation; recorded as a
    /// known interaction-spec deviation in manual QA. `focus/allow` marks
    /// the domain allowed for the rest of its 5-minute window, then
    /// redirects to `https://\(domain)` (ruling: redirect to the real site,
    /// not back to the block page).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                guard url.scheme == "timesink", url.host == "focus" else { continue }
                switch url.path {
                case "/back":
                    blocker?.setActiveTabURL("chrome://newtab")
                case "/allow":
                    guard let domain = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "domain" })?.value,
                        !domain.isEmpty else { continue }
                    focus?.allowDomain(domain)
                    blocker?.setActiveTabURL("https://\(domain)")
                default:
                    break
                }
            }
        }
    }
}
