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

/// Vertical 24-hour timeline for a single day (right column of
/// `ActivitiesView`, only shown for `range.kind == .day`). Hour gridlines run
/// the width of the column with right-edge 0-23 labels; blocks are
/// absolutely positioned by minutes-from-midnight so their y-offset lines up
/// with the gridlines regardless of zoom. Owns its own zoom level so the
/// +/- controls can live right above the scrollable area they affect.
struct DayTimelineView: View {
    let blocks: [TimelineBlock]

    @State private var hourHeight: CGFloat

    private let minHourHeight: CGFloat = 24
    private let maxHourHeight: CGFloat = 96
    private let hourStep: CGFloat = 12
    private let labelWidth: CGFloat = 24

    init(blocks: [TimelineBlock], hourHeight: CGFloat = 48) {
        self.blocks = blocks
        self._hourHeight = State(initialValue: hourHeight)
    }

    var body: some View {
        VStack(spacing: 6) {
            zoomControls
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

    private var timelineBody: some View {
        GeometryReader { geo in
            let blockWidth = max(0, geo.size.width - labelWidth - 4)
            ZStack(alignment: .topLeading) {
                ForEach(0..<24, id: \.self) { hour in
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: blockWidth, height: 1)
                        .offset(y: CGFloat(hour) * hourHeight)
                    Text("\(hour)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                        .offset(x: blockWidth + 4, y: CGFloat(hour) * hourHeight - 6)
                        .id(hour)
                }
                ForEach(blocks) { block in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(block.color.opacity(0.85))
                        .frame(width: blockWidth, height: max(2, CGFloat(block.duration / 3600) * hourHeight))
                        .offset(y: minutesFromMidnight(block.start) / 60 * hourHeight)
                        .help(block.tooltip)
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
