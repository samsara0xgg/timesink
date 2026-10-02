import Foundation

/// F4 离开补记: after 10 minutes or more away from the Mac, the menu bar
/// asks once what that time was. Not after 4 hours (a night, a closed lid),
/// at most 5 times a day, and an unanswered question folds away.
extension AppModel {
    static let awayMinimum: TimeInterval = 600
    static let awayMaximum: TimeInterval = 4 * 3600
    static let awayAsksPerDay = 5
    static let awayOfferLifetime: TimeInterval = 600

    public var awayPromptEnabled: Bool { settings.get("awayPromptEnabled") != "false" }

    /// Ticks stop while you are away, so a tick after a long silence is the
    /// return; the last recorded span's end (backdated to the last input)
    /// is when you left.
    func observeForAway(now: Date) {
        defer { lastTickAt = now }
        guard let last = lastTickAt, now.timeIntervalSince(last) >= 60, awayPromptEnabled, focus?.running == nil else { return }
        let lookback = DateInterval(start: now.addingTimeInterval(-Self.awayMaximum - 3600), end: now.addingTimeInterval(-5))
        guard let left = (try? spanStore.spans(overlapping: lookback))?.map(\.end).filter({ $0 < now.addingTimeInterval(-5) }).max()
        else { return }
        let away = now.timeIntervalSince(left)
        guard away >= Self.awayMinimum, away <= Self.awayMaximum else { return }
        // A pause you chose is not time away.
        let events = (try? observationStore?.stateEvents(in: DateInterval(start: left, end: now))) ?? []
        guard !events.contains(where: { $0.kind == "tracking_pause" }) else { return }
        let day = Calendar.current.startOfDay(for: now)
        if awayAsked.day != day { awayAsked = (day, 0) }
        guard awayAsked.count < Self.awayAsksPerDay else { return }
        awayAsked.count += 1
        let offer = DateInterval(start: left, end: now)
        awayOffer = offer
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.awayOfferLifetime))
            if self?.awayOffer == offer { self?.awayOffer = nil }
        }
    }

    /// The calendar event that covers most of the stretch, if any.
    func awaySuggestion(for interval: DateInterval) -> CalendarEvent? {
        todayMeetingEvents
            .filter { !$0.isAllDay && !$0.isDeclined && $0.start < interval.end && $0.end > interval.start }
            .max { overlap($0, interval) < overlap($1, interval) }
            .flatMap { overlap($0, interval) >= interval.duration / 2 ? $0 : nil }
    }

    private func overlap(_ event: CalendarEvent, _ interval: DateInterval) -> TimeInterval {
        min(event.end, interval.end).timeIntervalSince(max(event.start, interval.start))
    }

    /// Names the stretch (nil label: 不记, left blank and not asked again).
    func answerAway(label: String?, symbol: String) {
        guard let offer = awayOffer else { return }
        awayOffer = nil
        guard let label, !label.isEmpty else { return }
        try? observationStore?.insert(AwayNote(start: offer.start, end: offer.end, label: label, symbol: symbol))
        dataChanged()
    }

    /// Names a stretch chosen on the Today page, not the one the menu bar
    /// offered. Kept apart from spans like any other note.
    func fillAway(_ interval: DateInterval, label: String, symbol: String) {
        guard !label.isEmpty else { return }
        try? observationStore?.insert(AwayNote(start: interval.start, end: interval.end, label: label, symbol: symbol))
        if awayOffer == interval { awayOffer = nil }
        dataChanged()
    }
}
