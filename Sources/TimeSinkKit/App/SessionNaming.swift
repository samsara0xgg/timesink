import Foundation

/// F1 会话: cut off the main actor, named one at a time off the main actor,
/// names cached per session in the database.
extension AppModel {
    /// A day's sessions: cached when nothing was written since, otherwise cut
    /// on a background task from the spans already in memory.
    public func sessions(for day: DateInterval) async -> [WorkSession] {
        loadSessionOverrides()
        let version = dataVersion, threshold = sessionThreshold, splitsVersion = sessionSplitsVersion
        if let hit = sessionCache[day], hit.version == version, hit.threshold == threshold, hit.splits == splitsVersion { return hit.value }
        if let running = sessionTasks[day] { return await running.value }
        let items = rangedSpans(for: day)
        let verdicts = resolver.projectVerdicts
        let splits = (try? observationStore?.sessionSplits(in: day)) ?? []
        let joins = (try? observationStore?.sessionJoins(in: day)) ?? []
        let task = Task.detached(priority: .userInitiated) {
            SessionSegmenter.sessions(items, threshold: threshold, splits: splits, joins: joins, projectVerdicts: verdicts)
        }
        sessionTasks[day] = task
        let value = await task.value
        sessionTasks[day] = nil
        if sessionCache.count > 40 { sessionCache.removeAll() }
        sessionCache[day] = (version, threshold, splitsVersion, value)
        return value
    }

    func loadSessionOverrides() {
        guard !sessionOverridesLoaded, let store = observationStore else { return }
        sessionOverridesLoaded = true
        sessionOverrides = (try? store.sessionNames()) ?? [:]
    }

    /// Queues the sessions without a name yet. The newest go first.
    public func requestNames(for sessions: [WorkSession]) {
        let queued = Set(namingQueue.map(\.nameKey))
        let missing = sessions.filter { sessionLabels[$0.nameKey] == nil && !queued.contains($0.nameKey) }
        guard !missing.isEmpty, let store = observationStore else { return }
        namingQueue.insert(contentsOf: missing.reversed(), at: 0)
        guard namingTask == nil else { return }
        let namer = sessionNamer
        namingTask = Task { @MainActor [weak self] in
            while let self, !self.namingQueue.isEmpty {
                let session = self.namingQueue.removeFirst()
                let label = await Task.detached(priority: .utility) { () -> SessionLabel in
                    if let cached = try? store.sessionLabel(key: session.nameKey) { return cached }
                    let label = await namer.name(session)
                    try? store.save(label)
                    return label
                }.value
                self.sessionLabels[session.nameKey] = label
            }
            self?.namingTask = nil
        }
    }

    /// What the session is called: your name for its kind, else the model's
    /// or the fallback's; nil lists the apps instead.
    public func sessionTitle(_ session: WorkSession) -> String? {
        sessionOverrides[session.signature]?.name ?? sessionLabels[session.nameKey]?.name
    }

    /// Your own assignment, else the project Jev's verdicts give the session,
    /// else its repo or folder (shown as your project of that name, if you have one).
    public func sessionProject(_ session: WorkSession) -> String? {
        SessionProjectResolver.resolve(override: sessionOverrides[session.signature]?.project,
                                       jev: session.jevProjectID.flatMap { projectNames[$0] },
                                       ruleLabel: session.projectLabel, userNames: projects.map(\.name))
    }

    /// Reused for every session of the same kind.
    public func renameSession(_ session: WorkSession, to name: String) {
        try? observationStore?.setSessionName(signature: session.signature, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        sessionOverrides = (try? observationStore?.sessionNames()) ?? sessionOverrides
    }

    public func assignSession(_ session: WorkSession, toProject project: String) {
        try? observationStore?.setSessionName(signature: session.signature, project: project.trimmingCharacters(in: .whitespacesAndNewlines))
        sessionOverrides = (try? observationStore?.sessionNames()) ?? sessionOverrides
    }

    public func splitSession(at date: Date) {
        try? observationStore?.addSessionSplit(at: date)
        sessionSplitsVersion += 1
    }

    /// Joins the session onto the one before it, even across a gap or a change
    /// the segmenter cut on its own.
    public func joinSession(_ session: WorkSession) {
        try? observationStore?.addSessionJoin(at: session.start)
        sessionSplitsVersion += 1
    }

    public func unjoinSession(startingAt date: Date) {
        try? observationStore?.removeSessionJoin(at: date)
        sessionSplitsVersion += 1
    }

    /// Projects you have used, for the assign menu: yours first, then the
    /// names found in records that are not one of yours spelled differently.
    public var knownProjects: [String] {
        let mine = projects.map(\.name)
        let taken = Set(mine.map(SessionProjectResolver.normalized))
        let seen = Set(sessionOverrides.values.compactMap(\.project) + sessionCache.values.flatMap { $0.value.compactMap(\.projectLabel) })
            .filter { !taken.contains(SessionProjectResolver.normalized($0)) }.sorted()
        return mine + seen
    }

    // MARK: - Projects

    /// Re-reads the project list; the sessions pick the change up on the next `dataVersion`.
    public func reloadProjects() {
        projects = (try? categoryStore.projects.list()) ?? []
        projectNames = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        resolver.refreshProjectVerdicts()
        projectSuggestionCache = nil
    }

    /// After adding, renaming or removing a project.
    public func projectsChanged() {
        reloadProjects()
        sessionOverridesLoaded = false
        loadSessionOverrides()
        settingsChanged()
    }

    /// Candidate projects from the last two weeks, worked out off the main actor and kept ten minutes.
    public func projectSuggestions() async -> ProjectSuggester.Result {
        if let cache = projectSuggestionCache, Date().timeIntervalSince(cache.at) < 600 { return cache.value }
        let now = Date()
        let interval = DateInterval(start: now.addingTimeInterval(-Double(ProjectSuggester.lookbackDays) * 86400), end: now)
        let store = spanStore, existing = projects.map(\.name)
        let value = await Task.detached(priority: .utility) {
            ProjectSuggester.suggest((try? store.spans(overlapping: interval)) ?? [], existing: existing)
        }.value
        projectSuggestionCache = (now, value)
        return value
    }
}
