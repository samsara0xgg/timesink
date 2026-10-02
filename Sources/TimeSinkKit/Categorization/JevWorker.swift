import Foundation

/// Asks Jev about the window contents that have no current verdict, a few
/// requests at a time, and stores each answer as it arrives. Stops at the
/// monthly spend cap, at a key or balance error, and leaves a failed
/// request for the next run.
public actor JevWorker {
    public struct RunResult: Equatable, Sendable {
        public var calls = 0
        public var saved = 0
        public var failed = 0
        public var inputTokens = 0
        public var costUSD = 0.0
        public var latencies: [Double] = []
        public var stoppedByCap = false
        public var error: String?
        public var medianLatency: Double? {
            latencies.isEmpty ? nil : latencies.sorted()[latencies.count / 2]
        }
    }

    private let categoryStore: CategoryStore
    private let settings: SettingsStore
    private let transport: any JevTransport
    private let apiKey: @Sendable () -> String?

    public init(categoryStore: CategoryStore, settings: SettingsStore, transport: any JevTransport = URLSessionJevTransport(),
                apiKey: @escaping @Sendable () -> String?) {
        self.categoryStore = categoryStore
        self.settings = settings
        self.transport = transport
        self.apiKey = apiKey
    }

    /// One pass over everything seen since `since`.
    public func run(since: Date, maxConcurrent: Int = 10) async -> RunResult {
        var result = RunResult()
        guard settings.jevEnabled, let key = apiKey(), !key.isEmpty, let endpoint = URL(string: settings.jevEndpoint) else { return result }
        do {
            let categories = try categoryStore.rawCategories()
            let criteria = JevPrompt.criteria(categories)
            let version = JevPrompt.version(categories)
            let ids = Set(criteria.map(\.id))
            let todo = try categoryStore.pendingCombos(since: since, promptVersion: version)
            let client = JevClient(endpoint: endpoint, apiKey: key, transport: transport)

            typealias Outcome = (combo: JevCombo, answer: Result<JevAnswer, any Error>, seconds: Double)
            let settings = settings, categoryStore = categoryStore
            func capReached() -> Bool { settings.jevSpend() >= settings.jevMonthlyCap }

            result = await withTaskGroup(of: Outcome.self, returning: RunResult.self) { group in
                var result = RunResult()
                var next = 0
                var stop = false
                func launch() {
                    guard !stop, next < todo.count else { return }
                    if capReached() { stop = true; result.stoppedByCap = true; return }
                    let combo = todo[next]
                    next += 1
                    result.calls += 1
                    let state = JevState(app: combo.appName, bundleID: combo.key.appBundleID, domain: combo.key.domain,
                                         url: combo.url, title: combo.key.title, document: combo.key.document)
                    group.addTask {
                        let t0 = ContinuousClock.now
                        do {
                            let answer = try await client.decide(state, criteria: criteria)
                            return (combo, .success(answer), Self.seconds(since: t0))
                        } catch {
                            return (combo, .failure(error), Self.seconds(since: t0))
                        }
                    }
                }
                for _ in 0..<maxConcurrent { launch() }
                while let done = await group.next() {
                    switch done.answer {
                    case .success(let answer):
                        result.latencies.append(done.seconds)
                        result.inputTokens += answer.inputTokens
                        result.costUSD += answer.cost
                        settings.addJevSpend(answer.cost)
                        if let verdict = Self.verdict(for: done.combo, answer: answer, ids: ids, version: version),
                           (try? categoryStore.saveVerdict(verdict)) != nil {
                            result.saved += 1
                        } else {
                            result.failed += 1
                        }
                    case .failure(let error):
                        result.failed += 1
                        result.error = error.localizedDescription
                        if (error as? JevError)?.stopsTheRun == true { stop = true }
                    }
                    launch()
                }
                return result
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// nil when the answer names a category that was not offered.
    static func verdict(for combo: JevCombo, answer: JevAnswer, ids: Set<String>, version: String) -> JevVerdict? {
        guard ids.contains(answer.choice) else { return nil }
        let ranked = answer.probabilities.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let runnerUp = ranked.first { $0.key != answer.choice }
        return JevVerdict(appBundleID: combo.key.appBundleID, domain: combo.key.domain, title: combo.key.title,
                          document: combo.key.document, categoryID: answer.choice,
                          prob: answer.probabilities[answer.choice] ?? answer.confidence,
                          runnerUp: runnerUp?.key ?? "", runnerUpProb: runnerUp?.value ?? 0,
                          promptVersion: version, at: Date(), source: "jev")
    }
}
