import Foundation
import os

/// Owns the Jev feature at run time: the on/off switch, the background loop
/// that keeps verdicts current, and what the category screens ask of it.
@MainActor
public final class JevService {
    /// Keychain account of the key (service `com.alllllenshi.TimeSink`). Not
    /// the old OpenAI key's account: that key belongs to another provider.
    nonisolated public static let apiKeyAccount = "jevAPIKey"
    /// First enable asks about this many days back.
    public static let lookbackDays = 30
    /// After a category edit, answers from the old prompt are asked again for combos seen this far back; older ones keep their answer.
    public static let staleLookbackDays = 90
    /// Verdicts under this are listed for review.
    nonisolated public static let lowConfidence = 0.6

    private let categoryStore: CategoryStore
    private let settings: SettingsStore
    private let resolver: CategoryResolver
    private let worker: JevWorker
    private var loop: Task<Void, Never>?
    private var nudged: Task<Void, Never>?
    private var running = false
    /// Runs in a row that a key, account, model or service problem stopped; each one waits longer.
    private var troubledRuns = 0
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "jev")

    /// Called after new verdicts changed what spans resolve to.
    public var onChange: (() -> Void)?
    public private(set) var lastRun: JevWorker.RunResult?
    public private(set) var lastRunAt: Date?

    public init(categoryStore: CategoryStore, settings: SettingsStore, resolver: CategoryResolver,
                transport: any JevTransport = URLSessionJevTransport(),
                apiKey: @escaping @Sendable () -> String? = { Keychain.get(account: JevService.apiKeyAccount) }) {
        self.categoryStore = categoryStore
        self.settings = settings
        self.resolver = resolver
        self.worker = JevWorker(categoryStore: categoryStore, settings: settings, transport: transport, apiKey: apiKey)
        resolver.jevEnabled = settings.jevEnabled
        resolver.jevScreenText = settings.jevScreenText
    }

    public var isEnabled: Bool { settings.jevEnabled }
    public var monthSpend: Double { settings.jevSpend() }
    public var monthlyCap: Double { settings.jevMonthlyCap }
    public var hasKey: Bool { !(Keychain.get(account: Self.apiKeyAccount) ?? "").isEmpty }
    /// The fields sent per window, for the screen that asks to enable it.
    public static var sentFields: [String] { JevPrompt.sentFields }

    /// Turning it on starts the backfill; turning it off stops asking at once
    /// (the run in progress is cancelled) and goes back to the rules and
    /// shipped lists (user verdicts stay).
    public func setEnabled(_ on: Bool) {
        settings.setJevEnabled(on)
        resolver.jevEnabled = on
        onChange?()
        if on { start(); nudge() } else { stop() }
    }

    public var screenTextEnabled: Bool { settings.jevScreenText }

    /// A separate consent from the main switch: screenshot text is sent only while this is on.
    public func setScreenText(_ on: Bool) {
        settings.setJevScreenText(on)
        resolver.jevScreenText = on
        onChange?()
        if on { nudge() }
    }

    /// Starts the background loop; a no-op while one runs. Call at launch.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runOnce()
                // A failed request waits for the next pass, not a tight retry; a 429 waits as long as the server asked.
                try? await Task.sleep(for: .seconds(await self?.nextDelay ?? 180))
            }
        }
    }

    /// Stops the loop and cancels a run in progress, requests in flight included.
    public func stop() {
        loop?.cancel()
        loop = nil
        nudged?.cancel()
        nudged = nil
    }

    /// Looks for unclassified window contents now, e.g. after a category edit
    /// changed the prompt, or a new key or model was saved.
    public func nudge() {
        guard !running else { return }
        nudged = Task { await runOnce() }
    }

    /// Seconds until the loop's next pass: what a 429 asked for; after runs a
    /// key, account, model or service problem stopped, 3 minutes doubled per
    /// such run in a row, at most an hour; else 3 minutes.
    private var nextDelay: Int { Self.delay(retryAfter: lastRun?.retryAfter, troubledRuns: troubledRuns) }

    nonisolated static func delay(retryAfter: Int?, troubledRuns: Int) -> Int {
        if let retryAfter { return retryAfter }
        guard troubledRuns > 0 else { return 180 }
        return min(180 << min(troubledRuns, 5), 3_600)
    }

    private func runOnce() async {
        guard settings.jevEnabled, !running else { return }
        running = true
        defer { running = false }
        let since = Calendar.current.date(byAdding: .day, value: -Self.lookbackDays, to: Date()) ?? Date()
        let staleSince = Calendar.current.date(byAdding: .day, value: -Self.staleLookbackDays, to: Date()) ?? since
        let result = await worker.run(since: since, staleSince: staleSince, userRules: resolver.classificationContext)
        lastRun = result
        lastRunAt = Date()
        troubledRuns = result.problem == nil ? 0 : troubledRuns + 1
        if let error = result.error { logger.error("jev run: \(error, privacy: .public)") }
        if result.saved > 0 {
            resolver.refresh()
            onChange?()
        }
    }

    // MARK: - For the category screens

    /// Unsure verdicts covering time in `range`, longest first.
    public func lowConfidenceVerdicts(in range: DateInterval) throws -> [LowConfidenceVerdict] {
        try categoryStore.lowConfidenceVerdicts(in: range, below: Self.lowConfidence)
    }

    public struct Status: Equatable, Sendable {
        public var classified: Int
        public var queued: Int
        public var pausedAtCap: Bool
        /// What stopped the last run, if anything did: a bad key, no credits, a wrong model or address, the service down.
        public var problem: JevProblem?
        /// Jev verdicts written this calendar month.
        public var verdictsThisMonth = 0
        /// Unsure verdicts waiting in 待确认 (the last `lookbackDays`).
        public var toConfirm = 0
        public var lastRunAt: Date?
    }

    /// What the settings screen's status line reports.
    public func status() throws -> Status {
        let categories = try categoryStore.rawCategories()
        let since = Calendar.current.date(byAdding: .day, value: -Self.lookbackDays, to: Date()) ?? Date()
        let staleSince = Calendar.current.date(byAdding: .day, value: -Self.staleLookbackDays, to: Date()) ?? since
        // Not counted: what the user's own rules decide, and questions given up on after repeated unusable answers.
        let attempts = try categoryStore.jevAttempts()
        let queued = try categoryStore.pendingCombos(since: since, staleSince: staleSince, promptVersion: JevPrompt.version(categories),
                                                     userRules: resolver.classificationContext)
            .filter { (attempts[JevAttemptKey.category($0.key)]?.attempts ?? 0) < JevAttempt.maxAttempts }.count
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? .distantPast
        let jev = try categoryStore.verdicts().filter { $0.source == "jev" }
        return Status(classified: jev.count, queued: queued, pausedAtCap: monthSpend >= monthlyCap, problem: lastRun?.problem,
                      verdictsThisMonth: jev.filter { $0.at >= monthStart }.count,
                      toConfirm: try lowConfidenceVerdicts(in: DateInterval(start: since, end: Date())).count, lastRunAt: lastRunAt)
    }

    public enum SavedRule: Sendable { case none, domain, app }

    /// Confirms or changes one verdict. It becomes the user's verdict, which
    /// wins over Jev; `rule` also keeps it as a site or app rule.
    public func setVerdict(_ key: VerdictKey, categoryID: String, rule: SavedRule = .none) throws {
        try categoryStore.setUserVerdict(key, categoryID: categoryID)
        switch rule {
        case .domain where !key.domain.isEmpty: try categoryStore.setUserDomain(key.domain, categoryID: categoryID)
        case .app: try categoryStore.setUserApp(key.appBundleID, categoryID: categoryID)
        default: break
        }
        resolver.refresh()
        onChange?()
    }
}
