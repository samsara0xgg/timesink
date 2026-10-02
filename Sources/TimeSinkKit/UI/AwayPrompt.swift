import SwiftUI

/// F4 离开补记 in the popover: what the stretch away was, one click. A
/// calendar event covering it comes first; 其他… takes a name; 不记 leaves
/// it blank.
struct AwayPrompt: View {
    let model: AppModel
    let interval: DateInterval
    /// A stretch picked on the Today page rather than offered by the menu
    /// bar: it is named directly, and `onDone` closes the popover.
    var manual = false
    var onDone: (() -> Void)?
    @State private var naming = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var minutes: Int { Format.minutes(interval.duration) }

    private func answer(_ label: String?, _ symbol: String) {
        guard manual else { model.answerAway(label: label, symbol: symbol); return }
        if let label { model.fillAway(interval, label: label, symbol: symbol) }
        onDone?()
    }
    /// 11:30-13:30 is usually lunch.
    private var looksLikeLunch: Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: interval.start)
        let lunch = DateInterval(start: day.addingTimeInterval(11.5 * 3600), end: day.addingTimeInterval(13.5 * 3600))
        return interval.intersects(lunch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(model.time(interval.start))–\(model.time(interval.end))")
                    .font(.body).foregroundStyle(Design.ink2).monospacedDigit()
                Text("刚才你离开了 \(minutes) 分钟").font(.figure)
                if let context { Text(verbatim: context).font(.body).foregroundStyle(Design.ink2).lineLimit(1) }
            }
            if let event = model.awaySuggestion(for: interval) {
                Button { answer(event.title, "person.2") } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Label("日历里正好有", systemImage: "sparkles").font(.note).foregroundStyle(Design.ink2)
                            Text(event.title).font(.body.weight(.semibold)).lineLimit(1)
                            Text(verbatim: "\(model.time(event.start))–\(model.time(event.end))")
                                .font(.body).foregroundStyle(Design.ink2).monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        Text("记为会议").font(.body.weight(.semibold)).foregroundStyle(.tint)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).glassPlatter(cornerRadius: Design.Radius.card, strong: true)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if naming {
                HStack(spacing: 8) {
                    TextField("这 \(minutes) 分钟是", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                        .onSubmit { answer(name.trimmingCharacters(in: .whitespaces), "pencil") }
                    Button("补记") { answer(name.trimmingCharacters(in: .whitespaces), "pencil") }
                        .glassProminentButton().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .onAppear { nameFocused = true }
            } else {
                // The likely answer gets a row of its own, saying why.
                if looksLikeLunch {
                    Button { answer(String(localized: "午饭"), "fork.knife") } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "fork.knife").frame(width: 16)
                            Text("午饭")
                            Spacer(minLength: 8)
                            Label("这个时间常是午饭", systemImage: "sparkles").font(.note).foregroundStyle(Design.ink2)
                        }
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 10).frame(height: 38).frame(maxWidth: .infinity, alignment: .leading)
                        .glassPlatter(cornerRadius: Design.Radius.control, strong: true).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    if !looksLikeLunch { option(String(localized: "午饭"), "fork.knife") }
                    option(String(localized: "休息"), "cup.and.saucer")
                    option(String(localized: "开会"), "person.2")
                    Button { naming = true } label: { tile(String(localized: "其他…"), "pencil") }.buttonStyle(.plain)
                    Button { answer(nil, "") } label: { tile(String(localized: "不记"), "circle.slash") }.buttonStyle(.plain)
                }
            }
            Text("补记画成虚线框，和电脑上的时间分开统计，不计入评分。")
                .font(.note).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Space.md).frame(maxWidth: .infinity, alignment: .leading).glassPlatter(cornerRadius: Design.Radius.card)
    }

    /// What was in front just before leaving and just after coming back.
    private var context: String? {
        let spans = model.rangedSpans(for: .today())
        func name(_ item: CategorizedSpan) -> String { item.span.domain ?? AppIcon.name(for: item.span.appBundleID) }
        let before = spans.last { $0.span.end <= interval.start.addingTimeInterval(60) }.map { String(localized: "离开前在 \(name($0))") }
        let after = spans.first { $0.span.start >= interval.end.addingTimeInterval(-60) }.map { String(localized: "回来打开了 \(name($0))") }
        let parts = [before, after].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func option(_ label: String, _ symbol: String) -> some View {
        Button { answer(label, symbol) } label: { tile(label, symbol) }.buttonStyle(.plain)
    }

    private func tile(_ label: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 16)
            Text(label).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 10).frame(height: 34).frame(maxWidth: .infinity, alignment: .leading)
        .glassPlatter(cornerRadius: Design.Radius.control)
        .contentShape(Rectangle())
    }
}
