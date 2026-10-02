import SwiftUI

/// What the top of a dashboard page shares: a small lead line over a large
/// sentence on the left, and a strip of numbers on a card on the right.
struct PageHeadline: View {
    let lead: Text
    let sentence: Text
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            lead.font(.num(13)).foregroundStyle(Design.ink2)
            sentence
                .font(.system(size: 28, weight: scheme == .dark ? .semibold : .bold)).tracking(-0.4)
                .foregroundStyle(Design.ink).lineLimit(2).minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .revealOnce(index: 0)
    }
}

struct StripStat: Identifiable {
    let id: Int
    let label: LocalizedStringKey
    let value: String
    var note = ""
    var color: Color = Design.ink
}

struct StatStrip: View {
    let stats: [StripStat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(stats) { stat in
                HStack(spacing: 0) {
                    if stat.id > 0 { Rectangle().fill(Design.line).frame(width: 1, height: 52) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stat.label).font(.system(size: 12)).foregroundStyle(Design.ink3)
                        Text(verbatim: stat.value).font(.num(22, .bold)).foregroundStyle(stat.color)
                            .glowInDark(stat.color, radius: 9, strength: 0.35)
                            .refinedNumberMotion(stat.value)
                        Text(verbatim: stat.note).font(.num(11)).foregroundStyle(Design.ink3).lineLimit(1)
                    }
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 6).frame(maxHeight: .infinity)
        .designCard(radius: Design.Radius.strip)
        .revealOnce(index: 1)
    }
}

/// The header row: sentence left, numbers right; stacked when narrow.
struct PageHeaderRow: View {
    let lead: Text
    let sentence: Text
    let stats: [StripStat]
    var width: CGFloat = 1280

    var body: some View {
        if width >= 1000 {
            HStack(alignment: .center, spacing: Design.Space.xxl) {
                PageHeadline(lead: lead, sentence: sentence).frame(maxWidth: .infinity, alignment: .leading)
                StatStrip(stats: stats).frame(width: min(600, CGFloat(stats.count) * 150))
            }.frame(height: 92)
        } else {
            VStack(alignment: .leading, spacing: Design.Space.md) {
                PageHeadline(lead: lead, sentence: sentence)
                StatStrip(stats: stats).frame(height: 84)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A card heading: the title, then a quiet caption.
struct CardHeading: View {
    let title: LocalizedStringKey
    var caption: Text?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).cardTitle()
            caption?.font(.system(size: 12)).foregroundStyle(Design.ink3)
        }
    }
}
