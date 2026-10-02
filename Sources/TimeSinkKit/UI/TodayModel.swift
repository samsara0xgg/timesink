import Foundation
import Observation

/// What the Today page shows, loaded off the main actor and handed to the
/// view as one finished `TodayPlan`: the view's body only reads it.
@MainActor @Observable
final class TodayModel {
    var plan: TodayPlan?
    var loadError: String?
    /// Days in a row at 70 or more; today only.
    var streakDays = 0
    /// Yesterday's recorded time up to this time of day; today only.
    var yesterdayTotal: TimeInterval?

    @ObservationIgnored private let overviewModel = DayOverviewModel()
    @ObservationIgnored private let dashboard = TodayDashboardModel()
    @ObservationIgnored private var generation = 0

    /// How far back the page can step.
    static let farthestBack = -90

    func refresh(model: AppModel, dayOffset: Int) async {
        generation += 1
        let request = generation
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: dayOffset, to: today),
              let interval = calendar.dateInterval(of: .day, for: start) else { return }
        let isToday = dayOffset == 0
        // A past day is read as of its last second, so its "now" is its end.
        await overviewModel.refresh(model: model, now: isToday ? Date() : interval.end.addingTimeInterval(-1))
        guard request == generation else { return }
        guard let overview = overviewModel.overview, overview.day.start == interval.start else {
            if let error = overviewModel.loadError { loadError = error }
            return
        }
        let sessions = await model.sessions(for: interval)
        let episodes = await model.interruptions(for: interval).episodes
        guard request == generation, !Task.isCancelled else { return }
        model.requestNames(for: sessions)

        let notes = (try? model.observationStore?.awayNotes(overlapping: interval)) ?? []
        var lastFocus: (day: Date, minutes: Int)?
        if isToday, overview.sessions.isEmpty,
           let earlier = try? model.focusStore?.sessions(overlapping: DateInterval(start: today.addingTimeInterval(-60 * 86400), end: today)),
           let last = earlier.last(where: { $0.end > $0.start }) {
            lastFocus = (last.start, Int(last.end.timeIntervalSince(last.start) / 60))
        }
        if isToday {
            await dashboard.recompute(model: model, forceStreak: false, headlineOnly: true)
            guard request == generation, !Task.isCancelled else { return }
            streakDays = dashboard.streakDays
            yesterdayTotal = dashboard.yesterdayTotal
        } else {
            streakDays = 0
            yesterdayTotal = nil
        }
        plan = TodayPlan.build(overview: overview, sessions: sessions, explicit: sessions.map { model.sessionProject($0) },
                               episodes: episodes, notes: notes, categories: model.resolver.categoriesByID,
                               lastFocus: lastFocus, hasFocusToday: !overview.sessions.isEmpty, isToday: isToday)
        loadError = nil
    }
}
