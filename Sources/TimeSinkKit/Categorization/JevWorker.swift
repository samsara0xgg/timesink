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
        /// Seconds to wait after an HTTP 429; the pass stopped launching requests.
        public var retryAfter: Int?
        /// Requests in flight at most, this run.
        public var concurrency = 0
        public var medianLatency: Double? {
            latencies.isEmpty ? nil : latencies.sorted()[latencies.count / 2]
        }
    }

    private let categoryStore: CategoryStore
    private let projectStore: ProjectStore
    private let settings: SettingsStore
    private let transport: any JevTransport
    private let apiKey: @Sendable () -> String?
    /// The last run hit a 429: the next one asks fewer at a time.
    private var wasRateLimited = false

    public init(categoryStore: CategoryStore, settings: SettingsStore, transport: any JevTransport = URLSessionJevTransport(),
                apiKey: @escaping @Sendable () -> String?) {
        self.categoryStore = categoryStore
        self.projectStore = categoryStore.projects
        self.settings = settings
        self.transport = transport
        self.apiKey = apiKey
    }

    private enum Target: Sendable {
        case combo(JevCombo)
        /// A low-confidence verdict asked again with examples and/or screen text.
        case retry(JevVerdict)
        case capture(JevCapture)
    }
    private struct Job: Sendable {
        let state: JevState
        let target: Target
    }

    /// A combo's project is re-asked only when it was seen this recently.
    public static let projectLookbackDays = 14

    /// One pass over everything seen since `since` (and, for answers from an older prompt, since `staleSince`): window contents without a
    /// verdict, then unsure verdicts asked again with the user's examples (plus
    /// screen text when "send screenshot text" is on), then (that switch only)
    /// bare-title AI-app screens.
    public func run(since: Date, staleSince: Date? = nil, maxConcurrent: Int = 10) async -> RunResult {
        var result = RunResult()
        // Half the requests at a time after a 429 (at least 2); back to full after a clean run.
        let maxConcurrent = wasRateLimited ? min(maxConcurrent, max(2, maxConcurrent / 2)) : maxConcurrent
        result.concurrency = maxConcurrent
        guard settings.jevEnabled, let key = apiKey(), !key.isEmpty, let endpoint = URL(string: settings.jevEndpoint) else { return result }
        do {
            let categories = try categoryStore.rawCategories()
            let criteria = JevPrompt.criteria(categories)
            let version = JevPrompt.version(categories)
            let ids = Set(criteria.map(\.id))
            let model = settings.jevModel
            // With projects, the same request also asks which one the window belongs to.
            let projects = try projectStore.list()
            let projectCriteria = projects.isEmpty ? [] : JevPrompt.projectCriteria(projects)
            let projectVersion = projects.isEmpty ? nil : JevPrompt.projectVersion(projects)
            let projectIDs = Set(projects.map(\.id))
            let projectSince = Calendar.current.date(byAdding: .day, value: -Self.projectLookbackDays, to: Date())
            let client = JevClient(endpoint: endpoint, apiKey: key, model: settings.jevModel, transport: transport)
            let settings = settings, categoryStore = categoryStore

            func combo(_ c: JevCombo) -> Job {
                Job(state: JevState(app: c.appName, bundleID: c.key.appBundleID, domain: c.key.domain, url: c.url,
                                    title: c.key.title, document: c.key.document), target: .combo(c))
            }
            let pending = try categoryStore.pendingCombos(since: since, staleSince: staleSince, promptVersion: version,
                                                          projectVersion: projectVersion, projectSince: projectSince)
            var halted = await Self.pass(pending.map(combo), client: client, criteria: criteria, projects: projectCriteria,
                                         settings: settings, maxConcurrent: maxConcurrent, into: &result) { job, answer in
                guard case .combo(let c) = job.target else { return false }
                let project = projectVersion.map { Self.projectFields(answer, ids: projectIDs, version: $0) }
                // The category is settled (the user's, or Jev's current): only the project is new.
                if c.projectOnly {
                    guard let project else { return false }
                    return (try? categoryStore.saveProjectVerdict(c.key, projectID: project.id, prob: project.prob,
                                                                  runnerUp: project.runnerUp, promptVersion: project.version)) != nil
                }
                guard var v = Self.verdict(for: c, answer: answer, ids: ids, version: version, model: model) else { return false }
                if let project {
                    v.projectID = project.id
                    v.projectProb = project.prob
                    v.projectRunnerUp = project.runnerUp
                    v.projectPromptVersion = project.version
                }
                return (try? categoryStore.saveVerdict(v)) != nil
            }
            guard !halted else { wasRateLimited = result.retryAfter != nil; return result }

            // Unsure verdicts are asked again with the user's own examples (and screen text, when that switch is on).
            let screenOn = settings.jevScreenText
            let examples = try categoryStore.jevExamples()
            let retries = try categoryStore.lowConfidenceRetries(since: since, promptVersion: version, below: JevService.lowConfidence).compactMap { r -> Job? in
                let picked = JevExample.select(from: examples, bundleID: r.verdict.appBundleID, domain: r.verdict.domain)
                let text = screenOn ? r.text : nil
                guard text != nil || !picked.isEmpty else { return nil }   // nothing new to say: the same question again
                return Job(state: JevState(app: r.appName, bundleID: r.verdict.appBundleID, domain: r.verdict.domain, url: r.url,
                                           title: r.verdict.title, document: r.verdict.document, screenText: text,
                                           examples: picked.isEmpty ? nil : picked), target: .retry(r.verdict))
            }
            halted = await Self.pass(retries, client: client, criteria: criteria, settings: settings, maxConcurrent: maxConcurrent, into: &result) { job, answer in
                guard case .retry(let old) = job.target else { return false }
                let combo = JevCombo(key: old.key, appName: "", url: "", seconds: 0)
                if var v = Self.verdict(for: combo, answer: answer, ids: ids, version: version, model: model), v.prob > old.prob {
                    v.screenText = job.state.screenText == nil ? 2 : 1
                    return (try? categoryStore.saveVerdict(v)) != nil
                }
                try? categoryStore.markScreenAsked(old.key)
                return true
            }
            guard settings.jevScreenText, !halted else { wasRateLimited = result.retryAfter != nil; return result }

            let captures = try categoryStore.pendingCaptures(since: since, staleSince: staleSince, promptVersion: version).map { c in
                Job(state: JevState(app: c.appName, bundleID: c.bundleID, domain: "", url: "", title: c.title, document: "", screenText: c.text),
                    target: .capture(c))
            }
            _ = await Self.pass(captures, client: client, criteria: criteria, settings: settings, maxConcurrent: maxConcurrent, into: &result) { job, answer in
                guard case .capture(let c) = job.target, ids.contains(answer.choice) else { return false }
                let ranked = answer.probabilities.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                let runnerUp = ranked.first { $0.key != answer.choice }
                return (try? categoryStore.saveCaptureVerdict(
                    key: c.key, categoryID: answer.choice, prob: answer.probabilities[answer.choice] ?? answer.confidence,
                    runnerUp: runnerUp?.key ?? "", runnerUpProb: runnerUp?.value ?? 0, promptVersion: version, model: model)) != nil
            }
        } catch {
            result.error = error.localizedDescription
        }
        wasRateLimited = result.retryAfter != nil
        return result
    }

    /// Runs `jobs` a few at a time, adding to `result`. True when the run
    /// must stop altogether (monthly cap, or a key or balance error).
    private static func pass(_ jobs: [Job], client: JevClient, criteria: [(id: String, text: String)],
                             projects: [(id: String, text: String)] = [], settings: SettingsStore,
                             maxConcurrent: Int, into result: inout RunResult,
                             apply: @escaping @Sendable (Job, JevAnswer) -> Bool) async -> Bool {
        typealias Outcome = (job: Job, answer: Result<JevAnswer, any Error>, seconds: Double)
        func capReached() -> Bool { settings.jevSpend() >= settings.jevMonthlyCap }
        var next = 0
        var stop = false
        var snapshot = result
        await withTaskGroup(of: Outcome.self) { group in
            func launch() {
                guard !stop, next < jobs.count else { return }
                if capReached() { stop = true; snapshot.stoppedByCap = true; return }
                let job = jobs[next]
                next += 1
                snapshot.calls += 1
                group.addTask {
                    let t0 = ContinuousClock.now
                    do {
                        let answer = try await client.decide(job.state, criteria: criteria, projects: projects)
                        return (job, .success(answer), Self.seconds(since: t0))
                    } catch {
                        return (job, .failure(error), Self.seconds(since: t0))
                    }
                }
            }
            for _ in 0..<maxConcurrent { launch() }
            while let done = await group.next() {
                switch done.answer {
                case .success(let answer):
                    snapshot.latencies.append(done.seconds)
                    snapshot.inputTokens += answer.inputTokens
                    snapshot.costUSD += answer.cost
                    settings.addJevSpend(answer.cost)
                    if apply(done.job, answer) { snapshot.saved += 1 } else { snapshot.failed += 1 }
                case .failure(let error):
                    // A 429 leaves the combo queued: not failed, no spend; stop launching, let in-flight ones finish.
                    if case JevError.rateLimited(let secs) = error {
                        snapshot.retryAfter = max(snapshot.retryAfter ?? 0, secs)
                        stop = true
                        break
                    }
                    snapshot.failed += 1
                    snapshot.error = error.localizedDescription
                    if (error as? JevError)?.stopsTheRun == true { stop = true }
                }
                launch()
            }
        }
        result = snapshot
        return stop
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// The project columns for an answer: the project chosen, or 'none' when it chose none, named
    /// an id that was not offered, or the reply had no project answer (asked, so not asked again).
    static func projectFields(_ answer: JevAnswer, ids: Set<String>, version: String) -> (id: String, prob: Double, runnerUp: String, version: String) {
        let choice = answer.projectChoice.flatMap { ids.contains($0) ? $0 : nil } ?? JevPrompt.noProject
        let probabilities = answer.projectProbabilities ?? [:]
        let ranked = probabilities.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return (choice, probabilities[choice] ?? (answer.projectChoice == choice ? answer.projectConfidence ?? 0 : 0),
                ranked.first { $0.key != choice }?.key ?? "", version)
    }

    /// nil when the answer names a category that was not offered.
    static func verdict(for combo: JevCombo, answer: JevAnswer, ids: Set<String>, version: String, model: String = "") -> JevVerdict? {
        guard ids.contains(answer.choice) else { return nil }
        let ranked = answer.probabilities.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let runnerUp = ranked.first { $0.key != answer.choice }
        return JevVerdict(appBundleID: combo.key.appBundleID, domain: combo.key.domain, title: combo.key.title,
                          document: combo.key.document, categoryID: answer.choice,
                          prob: answer.probabilities[answer.choice] ?? answer.confidence,
                          runnerUp: runnerUp?.key ?? "", runnerUpProb: runnerUp?.value ?? 0,
                          promptVersion: version, at: Date(), source: "jev", model: model)
    }
}
