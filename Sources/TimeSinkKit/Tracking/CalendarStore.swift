import AppKit
import EventKit
import Foundation

/// A single EventKit calendar event, reduced to the plain value type the
/// rest of TimeSinkKit works with -- `EKEvent`/`EKParticipant` never cross
/// out of this file's `CalendarStore.convert(_:)`.
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var attendeeCount: Int
    public var isDeclined: Bool
    public var calendarTitle: String
    public var colorHex: String

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool,
                attendeeCount: Int, isDeclined: Bool, calendarTitle: String, colorHex: String) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendeeCount = attendeeCount
        self.isDeclined = isDeclined
        self.calendarTitle = calendarTitle
        self.colorHex = colorHex
    }

    /// Case-insensitive title keywords that count an event as a meeting even
    /// with a single (or unknown) attendee -- covers 1:1s and recurring
    /// team syncs that EventKit sometimes reports with a stale/empty
    /// attendee list.
    static let meetingKeywords = ["sync", "1:1", "standup", "组会", "例会", "meeting"]

    /// 纯谓词：非全天 && 未拒绝 && (2 人以上 || 标题命中会议词)。
    public var isMeeting: Bool {
        guard !isAllDay, !isDeclined else { return false }
        if attendeeCount >= 2 { return true }
        let lowered = title.lowercased()
        return Self.meetingKeywords.contains { lowered.contains($0) }
    }
}

/// Pure functions over `CalendarEvent`/`CategorizedSpan` -- no EventKit
/// types, no actor isolation, fully unit-testable.
public enum MeetingTagger {
    /// Span ids overlapping any meeting event by >= 50% of the span's own
    /// duration, plus the summed duration of those spans. Must run on the
    /// flat, pre-merge `CategorizedSpan` list (`ActivitiesModel.recompute`'s
    /// `items`, before `timelineBlocks`'s merge pipeline coalesces spans and
    /// loses individual span ids -- see spec §7) so every tagged span keeps
    /// its own row-level identity for the list's per-row "会议" badge.
    public static func tagged(items: [CategorizedSpan], events: [CalendarEvent])
        -> (spanIDs: Set<Int64>, seconds: TimeInterval) {
        let meetingEvents = events.filter(\.isMeeting)
        guard !meetingEvents.isEmpty else { return ([], 0) }

        var spanIDs: Set<Int64> = []
        var seconds: TimeInterval = 0
        for item in items {
            let span = item.span
            guard let id = span.id else { continue }
            let duration = span.duration
            guard duration > 0 else { continue }
            let half = duration * 0.5
            let overlaps = meetingEvents.contains { event in
                let overlapStart = max(span.start, event.start)
                let overlapEnd = min(span.end, event.end)
                return overlapEnd.timeIntervalSince(overlapStart) >= half
            }
            if overlaps {
                spanIDs.insert(id)
                seconds += duration
            }
        }
        return (spanIDs, seconds)
    }

    /// True when `date` falls within any meeting event's `[start, end)` --
    /// drives the idle-exemption seam (`TrackerEngine.isInMeetingProvider`).
    public static func inMeeting(at date: Date, events: [CalendarEvent]) -> Bool {
        events.contains { $0.isMeeting && $0.start <= date && date < $0.end }
    }
}

/// EventKit's sole home in TimeSinkKit -- `import EventKit` appears only
/// here and in `Permissions.swift`. Wraps a single `EKEventStore`, converts
/// `EKEvent`/`EKCalendar` to the plain `CalendarEvent`/hex-color value types
/// above, and caches per-day results until `invalidateCache()` (or process
/// restart) clears them.
///
/// `EKEventStore` is stored as a plain actor property, constructed eagerly
/// in `init()` -- unlike `SystemNotifier`'s lazy `UNUserNotificationCenter
/// .current()` access, merely constructing an `EKEventStore` does not touch
/// TCC or trigger an authorization prompt, so it's safe even in a
/// bundle-less process. `events(on:)` itself still guards on
/// `.fullAccess` before ever calling into it, so a bundle-less/unauthorized
/// caller never reaches the EventKit predicate/fetch calls below -- and
/// this actor is never constructed from a test target regardless (only
/// `TimeSinkApp.init` constructs one), per the brief's testing constraints.
public actor CalendarStore {
    private let store = EKEventStore()
    private var cache: [String: [CalendarEvent]] = [:]

    /// Birthday and subscription (holiday/read-only) calendars are noisy,
    /// all-day-dominated, and never meetings -- including them would flood
    /// the day timeline's all-day chip row with irrelevant entries.
    private static let excludedCalendarTypes: Set<EKCalendarType> = [.birthday, .subscription]

    public init() {}

    /// `day`'s events (cached per calendar day), excluding birthday/
    /// subscription calendars. Returns `[]` immediately -- without ever
    /// calling into `EKEventStore` -- unless calendar access is currently
    /// `.fullAccess`; `.writeOnly`/`.denied`/`.restricted`/`.notDetermined`
    /// all yield an empty overlay rather than a partial or crashing one.
    public func events(on day: Date) async -> [CalendarEvent] {
        guard Self.authorizedFullAccess() else { return [] }

        let key = Self.cacheKey(for: day)
        if let cached = cache[key] { return cached }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { event in
                // `event.calendar` is `null_unspecified` in the SDK -- a
                // mid-deletion account or malformed CalDAV item can hand
                // back nil here, and an unguarded `.type` access would trap
                // the whole actor. Drop the event rather than crash.
                guard let calendar = event.calendar else { return false }
                return !Self.excludedCalendarTypes.contains(calendar.type)
            }
            .compactMap(Self.convert)

        cache[key] = events
        return events
    }

    /// Drops the whole per-day cache -- called on `.EKEventStoreChanged`
    /// (see `observeChanges(_:)` below, wired up by `AppModel`) so the next
    /// `events(on:)` call re-fetches instead of serving stale data after a
    /// calendar/event edit made elsewhere. Also calls `store.reset()`:
    /// authorization can flip from not-granted to granted on the SAME
    /// `EKEventStore` instance's lifetime (the actor's `store` is
    /// constructed once, pre-authorization, at app launch), and an
    /// `EKEventStore` that first materialized its calendars/sources with
    /// zero authorized sources does not spontaneously re-materialize them
    /// afterward -- `reset()` forces that. Called both from here (the
    /// `.EKEventStoreChanged` path, which normally fires right after a
    /// grant) and explicitly from the enable flow as belt-and-braces.
    public func invalidateCache() {
        store.reset()
        cache.removeAll()
    }

    private static func cacheKey(for day: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    /// A cheap, non-prompting authorization read -- safe to call from
    /// anywhere, unlike `requestFullAccessToEvents()`. Kept local (rather
    /// than delegating to `Permissions.calendarState()`) to avoid a
    /// cross-actor `@MainActor` hop for what's just a synchronous status
    /// check.
    private static func authorizedFullAccess() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// `event.calendar`/`.startDate`/`.endDate` are all `null_unspecified`
    /// in the SDK -- an unguarded access traps the actor the moment any of
    /// them is nil (a mid-deletion account, a malformed CalDAV item).
    /// Returns `nil` to drop the event instead, via the caller's
    /// `compactMap`.
    private static func convert(_ event: EKEvent) -> CalendarEvent? {
        guard let calendar = event.calendar, let start = event.startDate, let end = event.endDate else {
            return nil
        }
        let attendees = event.attendees ?? []
        let isDeclined = attendees.first(where: \.isCurrentUser)?.participantStatus == .declined
        // `calendar.title` is likewise `null_unspecified`; binding through
        // an explicit `String?` local (rather than using it directly)
        // avoids an implicit force-unwrap on a nil title.
        let calendarTitle: String? = calendar.title
        // Per-occurrence id: every occurrence of a recurring event shares
        // one `eventIdentifier`, so using it alone would collide today's
        // and next week's instance of the same weekly standup into the same
        // SwiftUI identity. Folding in the occurrence's own start time makes
        // each occurrence unique without minting a fresh UUID on every
        // fetch for events that DO have a stable identifier.
        let id = "\(event.eventIdentifier ?? UUID().uuidString)-\(start.timeIntervalSince1970)"
        return CalendarEvent(
            id: id,
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            attendeeCount: attendees.count,
            isDeclined: isDeclined,
            calendarTitle: calendarTitle ?? "",
            colorHex: hexString(from: calendar.cgColor)
        )
    }

    /// Converts an `EKCalendar`'s `cgColor` to an uppercase "#RRGGBB" hex
    /// string, same clamp-to-sRGB approach as `Color.toHex()` in
    /// `ColorHex.swift`. Falls back to a neutral gray for a calendar with no
    /// color or an unconvertible color space.
    private static func hexString(from cgColor: CGColor?) -> String {
        guard let cgColor, let ns = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return "#98989D"
        }
        let r = clamp255(ns.redComponent * 255)
        let g = clamp255(ns.greenComponent * 255)
        let b = clamp255(ns.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func clamp255(_ v: Double) -> Int {
        max(0, min(255, Int(v.rounded())))
    }
}

extension CalendarStore {
    /// Registers `onChange` to run on the main actor whenever EventKit posts
    /// `.EKEventStoreChanged` (a calendar added/removed, or an event edited
    /// elsewhere). Bundle-gated the same way as
    /// `Permissions.requestCalendarAccess()`: observing this notification
    /// name is inert on its own, but gating registration keeps every
    /// EventKit touch-point in this file consistently behind the crash-gate
    /// rather than relying on callers to remember it.
    @MainActor
    public static func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        guard Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink" else { return }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }
}
