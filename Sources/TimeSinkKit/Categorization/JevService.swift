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
    /// Verdicts under this are listed for review.
    public static let lowConfidence = 0.6

    private let categoryStore: CategoryStore
    private let settings: SettingsStore
    private let resolver: CategoryResolver
    private let worker: JevWorker
    private var loop: Task<Void, Never>?
    private var running = false
    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "jev")

    /// Called after new verdicts changed what spans resolve to.
    public var onChange: (() -> Void)?
    public private(set) var lastRun: JevWorker.RunResult?

    public init(categoryStore: CategoryStore, settings: SettingsStore, resolver: CategoryResolver,
                transport: any JevTransport = URLSessionJevTransport(),
                apiKey: @escaping @Sendable () -> String? = { Keychain.get(account: JevService.apiKeyAccount) }) {
        self.categoryStore = categoryStore
        self.settings = settings
        self.resolver = resolver
        self.worker = JevWorker(categoryStore: categoryStore, settings: settings, transport: transport, apiKey: apiKey)
        resolver.jevEnabled = settings.jevEnabled
    }

    public var isEnabled: Bool { settings.jevEnabled }
    public var monthSpend: Double { settings.jevSpend() }
    public var monthlyCap: Double { settings.jevMonthlyCap }
    public var hasKey: Bool { !(Keychain.get(account: Self.apiKeyAccount) ?? "").isEmpty }
    /// The fields sent per window, for the screen that asks to enable it.
    public static var sentFields: [String] { JevPrompt.sentFields }

    /// Turning it on starts the backfill; turning it off stops asking and
    /// goes back to the rules and shipped lists (user verdicts stay).
    public func setEnabled(_ on: Bool) {
        settings.setJevEnabled(on)
        resolver.jevEnabled = on
        onChange?()
        if on { start(); nudge() }
    }

    /// Starts the background loop; a no-op while one runs. Call at launch.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runOnce()
                // A failed request waits for the next pass, not a tight retry.
                try? await Task.sleep(for: .seconds(180))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Looks for unclassified window contents now, e.g. after a category edit
    /// changed the prompt.
    public func nudge() {
        Task { await runOnce() }
    }

    private func runOnce() async {
        guard settings.jevEnabled, !running else { return }
        running = true
        defer { running = false }
        let since = Calendar.current.date(byAdding: .day, value: -Self.lookbackDays, to: Date()) ?? Date()
        let result = await worker.run(since: since)
        lastRun = result
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
        public var offline: Bool
    }

    /// What the settings screen's status line reports.
    public func status() throws -> Status {
        let categories = try categoryStore.rawCategories()
        let since = Calendar.current.date(byAdding: .day, value: -Self.lookbackDays, to: Date()) ?? Date()
        let queued = try categoryStore.pendingCombos(since: since, promptVersion: JevPrompt.version(categories)).count
        return Status(classified: try categoryStore.verdicts().filter { $0.source == "jev" }.count, queued: queued,
                      pausedAtCap: monthSpend >= monthlyCap, offline: lastRun?.error != nil)
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
