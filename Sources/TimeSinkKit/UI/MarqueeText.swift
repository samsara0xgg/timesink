import SwiftUI

/// One line of text that truncates with "…" like a plain `Text`, and, when
/// the pointer rests on it, slides left until its last character shows --
/// the way Codex's sidebar reveals a long title. Moving the pointer away
/// puts it back. A line that fits never moves.
struct MarqueeText: View {
    private static let delay: Duration = .milliseconds(500)
    private static let pointsPerSecond: CGFloat = 40

    private let text: String
    @State private var boxWidth: CGFloat = 0
    @State private var fullWidth: CGFloat = 0
    @State private var hovering = false
    @State private var sliding = false
    @State private var offset: CGFloat = 0

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .opacity(sliding ? 0 : 1)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { boxWidth = $0 }
            .overlay(alignment: .leading) {
                Text(text)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { fullWidth = $0 }
                    .offset(x: offset)
                    .opacity(sliding ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .clipped()
            .onHover { hovering = $0 }
            .task(id: hovering) {
                let overflow = fullWidth - boxWidth
                guard hovering, overflow > 1 else {
                    sliding = false
                    offset = 0
                    return
                }
                try? await Task.sleep(for: Self.delay)
                guard !Task.isCancelled else { return }
                sliding = true
                withAnimation(.linear(duration: overflow / Self.pointsPerSecond)) {
                    offset = -overflow
                }
            }
    }
}
