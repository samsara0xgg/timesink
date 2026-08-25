import SwiftUI

/// One colored interval on the day timeline. Callers (`ActivitiesModel`)
/// merge adjacent same-category spans and drop/absorb sub-30s slivers before
/// producing these, so each block is already the final visual unit.
struct TimelineBlock: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let color: Color
    let label: String
    let tooltip: String

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// One calendar event drawn in the timeline's event lane (C3). Distinct from
/// `TimelineBlock`: events are the day's calendar overlay, not tracked
/// activity, so they render in their own column with their own visual
/// language (outlined, not filled) rather than being mixed into `blocks`.
struct TimelineEventBlock: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let tooltip: String

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Vertical 24-hour timeline for a single day (right column of
/// `ActivitiesView`, shown for single-day-ish ranges -- see
/// `ActivitiesModel.showsTimeline`). Hour gridlines run
/// the width of the column with right-edge 0-23 labels; blocks are
/// absolutely positioned by minutes-from-midnight so their y-offset lines up
/// with the gridlines regardless of zoom. Owns its own zoom level so the
/// +/- controls can live right above the scrollable area they affect.
struct DayTimelineView: View {
    let blocks: [TimelineBlock]
    /// C3 calendar event lane -- see `timelineBody`'s 55/40/5 column split.
    let events: [TimelineEventBlock]
    /// All-day event titles, shown as a fixed chip row below the zoom
    /// controls rather than in the scrollable hour grid (an all-day event
    /// has no meaningful y-position).
    let allDay: [String]

    @State private var hourHeight: CGFloat

    private let minHourHeight: CGFloat = 24
    private let maxHourHeight: CGFloat = 96
    private let hourStep: CGFloat = 12
    private let labelWidth: CGFloat = 24

    init(blocks: [TimelineBlock], events: [TimelineEventBlock] = [], allDay: [String] = [],
         hourHeight: CGFloat = 48) {
        self.blocks = blocks
        self.events = events
        self.allDay = allDay
        self._hourHeight = State(initialValue: hourHeight)
    }

    var body: some View {
        VStack(spacing: 6) {
            zoomControls
            if !allDay.isEmpty {
                allDayRow
            }
            ScrollViewReader { proxy in
                ScrollView {
                    timelineBody
                }
                .onAppear {
                    let hour = Calendar.current.component(.hour, from: Date())
                    proxy.scrollTo(hour, anchor: .center)
                }
            }
        }
    }

    /// Fixed horizontal-scrolling chip row for all-day calendar events.
    private var allDayRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(allDay, id: \.self) { title in
                    Text(title)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Spacer()
            Button {
                hourHeight = max(minHourHeight, hourHeight - hourStep)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(hourHeight <= minHourHeight)
            Button {
                hourHeight = min(maxHourHeight, hourHeight + hourStep)
            } label: {
                Image(systemName: "plus")
            }
            .disabled(hourHeight >= maxHourHeight)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    /// Splits the grid width into activity (55%), a gap (5%), and the C3
    /// calendar event lane (40%) -- gridlines still span the full width so
    /// both columns share the same hour-aligned backdrop.
    private var timelineBody: some View {
        GeometryReader { geo in
            let totalWidth = max(0, geo.size.width - labelWidth - 4)
            let activityWidth = totalWidth * 0.55
            let eventWidth = totalWidth * 0.40
            let eventX = totalWidth * 0.60
            ZStack(alignment: .topLeading) {
                ForEach(0..<24, id: \.self) { hour in
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: totalWidth, height: 1)
                        .offset(y: CGFloat(hour) * hourHeight)
                    Text("\(hour)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                        .offset(x: totalWidth + 4, y: CGFloat(hour) * hourHeight - 6)
                        .id(hour)
                }
                ForEach(blocks) { block in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(block.color.opacity(0.85))
                        .frame(width: activityWidth, height: max(2, CGFloat(block.duration / 3600) * hourHeight))
                        .offset(y: minutesFromMidnight(block.start) / 60 * hourHeight)
                        .help(block.tooltip)
                }
                ForEach(events) { event in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(event.color.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(event.color, lineWidth: 1.5)
                        )
                        .frame(width: eventWidth, height: max(2, CGFloat(event.duration / 3600) * hourHeight))
                        .offset(x: eventX, y: minutesFromMidnight(event.start) / 60 * hourHeight)
                        .help(event.tooltip)
                }
            }
        }
        .frame(height: 24 * hourHeight)
    }

    private func minutesFromMidnight(_ date: Date) -> CGFloat {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        return CGFloat(date.timeIntervalSince(startOfDay) / 60)
    }
}
