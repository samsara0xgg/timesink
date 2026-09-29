import AppKit
import SwiftUI

private let spaceInk = Color(red: 0.94, green: 0.94, blue: 0.92)
private let spaceMuted = Color(red: 0.65, green: 0.68, blue: 0.69)
private let spaceOrange = Color(red: 0.94, green: 0.59, blue: 0.36)
private let spaceBackground = Color(red: 0.057, green: 0.067, blue: 0.074)

struct TimeSpaceView: View {
    @StateObject private var state = SpaceState()
    @State private var showsSnapshots = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let event = state.selected {
                VStack(spacing: 0) {
                    header
                    spaceScene(event)
                    inspector(event)
                    dayTimeline
                }
                .accessibilityHidden(state.isExpanded)
                .disabled(state.isExpanded)
                if state.isExpanded, let snapshot = state.snapshot {
                    OriginalCaptureView(snapshot: snapshot, title: event.title, app: event.app,
                                        index: state.snapshotIndex, count: state.snapshots.count,
                                        onPrevious: { state.pickSnapshot(state.snapshotIndex - 1) },
                                        onNext: { state.pickSnapshot(state.snapshotIndex + 1) },
                                        onClose: { state.isExpanded = false })
                        .transition(.opacity)
                        .zIndex(2)
                }
            } else {
                ContentUnavailableView("今天还没有可回看的记录", systemImage: "photo.on.rectangle.angled",
                    description: Text(state.library.error ?? "在 TimeSink 中开启屏幕采集后，再打开这个预览。"))
            }
        }
        .background(spaceBackground)
        .foregroundStyle(spaceInk)
        .tint(spaceOrange)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.isExpanded)
        .onChange(of: state.isFocused) { _, focused in if !focused { showsSnapshots = false } }
        .onExitCommand { state.closeDetail() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("TimeSink").font(.system(size: 15, weight: .semibold))
            Text("/").foregroundStyle(spaceMuted.opacity(0.5))
            Text("时间空间").font(.system(size: 12)).foregroundStyle(spaceMuted)
            Spacer()
            Text("\(SpaceEvent.localDate(state.library.date, format: "M月d日 EEEE")) · \(state.events.count) 段记忆")
                .font(.system(size: 11)).foregroundStyle(spaceMuted)
            Spacer()
            HStack(spacing: 3) {
                Button { state.setZoom(state.zoom - 0.1) } label: {
                    Image(systemName: "minus").frame(width: 24, height: 26)
                }
                .disabled(state.zoom <= SpaceState.zoomRange.lowerBound)
                .accessibilityLabel("缩小切片")
                Button { state.setZoom(SpaceState.defaultZoom) } label: {
                    Text("\(Int((state.zoom * 100).rounded()))%")
                        .monospacedDigit().frame(width: 44, height: 26)
                }
                .help("触控板双指捏合缩放 · 50%–100% · 点按恢复 80%")
                .accessibilityLabel("恢复默认缩放，当前 \(Int((state.zoom * 100).rounded()))%")
                Button { state.setZoom(state.zoom + 0.1) } label: {
                    Image(systemName: "plus").frame(width: 24, height: 26)
                }
                .disabled(state.zoom >= SpaceState.zoomRange.upperBound)
                .accessibilityLabel("放大切片")
            }
            .font(.system(size: 11)).buttonStyle(SpaceQuietButton())
            if state.isFocused {
                Button { state.isFocused = false } label: {
                    Label("返回空间", systemImage: "arrow.left").font(.system(size: 11))
                        .padding(.horizontal, 10).frame(height: 28)
                }
                .buttonStyle(SpaceQuietButton())
            } else {
                Text("滚动穿行 · 点选靠近").font(.system(size: 11)).foregroundStyle(spaceMuted)
            }
        }
        .padding(.leading, 88).padding(.trailing, 30)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Divider().opacity(0.30) }
    }

    private func spaceScene(_ event: SpaceEvent) -> some View {
        SpaceCanvasView(state: state, reduceMotion: reduceMotion)
            .accessibilityLabel("三维时间空间")
            .accessibilityValue("\(event.time)，\(event.title)")
            .accessibilityHint("使用下方的上一段、下一段和回看过程按钮")
            .frame(maxHeight: .infinity)
    }

    private func inspector(_ event: SpaceEvent) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(event.app).foregroundStyle(event.category.color)
                    Text(event.durationLabel).foregroundStyle(spaceMuted)
                    Text("·").foregroundStyle(spaceMuted)
                    Text(state.isFocused ? (state.snapshot?.time ?? "未保存画面") : "\(event.time) — \(event.endTime)")
                        .foregroundStyle(spaceMuted)
                }
                .font(.system(size: 11, weight: .medium))
                Text(event.title).font(.system(size: 14, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).help(event.title)
            }
            Spacer(minLength: 12)
            if state.isFocused {
                Slider(value: Binding(get: { Double(state.snapshotIndex) }, set: { state.pickSnapshot(Int($0.rounded())) }),
                       in: 0...Double(max(1, state.snapshots.count - 1)), step: 1)
                    .controlSize(.small).frame(width: 150).disabled(state.snapshots.count < 2)
                    .accessibilityLabel("这段活动的快照")
                Button { showsSnapshots.toggle() } label: {
                    Label("\(state.snapshotIndex + 1) / \(state.snapshots.count) 张", systemImage: "rectangle.stack")
                        .font(.system(size: 11)).padding(.horizontal, 10).frame(height: 32)
                }
                .buttonStyle(SpaceQuietButton()).disabled(state.snapshots.isEmpty)
                .accessibilityLabel("展开快照序列")
                .popover(isPresented: $showsSnapshots, arrowEdge: .bottom) {
                    snapshotStrip.frame(width: 760).background(spaceBackground)
                }
            } else {
                Button { state.isFocused = true } label: {
                    Label("回看过程", systemImage: "rectangle.stack")
                        .font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32)
                }
                .buttonStyle(SpaceQuietButton())
                .keyboardShortcut(.space, modifiers: [])
            }
            Button(action: state.openOriginal) {
                Label("完整原图", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 32)
                    .background(spaceInk.opacity(0.95), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(spaceBackground)
            }
            .buttonStyle(.plain).disabled(state.snapshot == nil)
            .opacity(state.snapshot == nil ? 0.4 : 1)
            .keyboardShortcut(.return, modifiers: [])
            memoryNavigation
        }
        .padding(.horizontal, 20).frame(height: 54)
        .background(.white.opacity(0.022))
        .overlay(alignment: .top) { Divider().opacity(0.30) }
    }

    private var snapshotStrip: some View {
        VStack(spacing: 9) {
            HStack {
                Text("这一段的快照").font(.system(size: 12, weight: .medium))
                Spacer()
                Button { showsSnapshots = false } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 26)
                }
                .buttonStyle(SpaceQuietButton()).accessibilityLabel("收起快照序列")
            }
            .padding(.horizontal, 18)
            if state.snapshots.isEmpty {
                Text("这段活动没有保存截图").font(.system(size: 12)).foregroundStyle(spaceMuted)
                    .frame(height: 82)
            } else {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 9) {
                            ForEach(Array(state.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                                Button { state.pickSnapshot(index) } label: {
                                    VStack(spacing: 5) {
                                        SnapshotThumbnail(snapshot: snapshot)
                                            .frame(width: 220, height: 138)
                                            .background(.black.opacity(0.25))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(state.snapshotIndex == index ? spaceOrange : .clear, lineWidth: 2)
                                            }
                                        Text(snapshot.time).font(.system(size: 10)).monospacedDigit()
                                            .foregroundStyle(state.snapshotIndex == index ? spaceInk : spaceMuted)
                                    }
                                    .padding(2)
                                }
                                .buttonStyle(.plain).id(snapshot.id)
                                .accessibilityLabel("查看 \(snapshot.time) 的快照")
                                .accessibilityAddTraits(state.snapshotIndex == index ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                    .onAppear { if let snapshot = state.snapshot { reader.scrollTo(snapshot.id, anchor: .center) } }
                    .onChange(of: state.snapshotIndex) { _, _ in
                        if let snapshot = state.snapshot { reader.scrollTo(snapshot.id, anchor: .center) }
                    }
                }
                .frame(height: 161)
                HStack(spacing: 13) {
                    Text("拖动回看").font(.system(size: 10)).foregroundStyle(spaceMuted)
                    Slider(value: Binding(get: { Double(state.snapshotIndex) }, set: { state.pickSnapshot(Int($0.rounded())) }),
                           in: 0...Double(max(1, state.snapshots.count - 1)), step: 1)
                        .controlSize(.mini).disabled(state.snapshots.count < 2)
                        .accessibilityLabel("这段活动的快照")
                    Text("\(state.snapshotIndex + 1) / \(state.snapshots.count)")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(spaceMuted)
                }
                .padding(.horizontal, 32)
            }
        }
        .padding(.top, 12).padding(.bottom, 10)
        .background(.white.opacity(0.012))
    }

    private var dayTimeline: some View {
        HStack(spacing: 12) {
            Text(state.events.first?.time ?? "")
            GeometryReader { geo in
                Canvas { context, size in
                    guard let first = state.events.first, let last = state.events.last else { return }
                    let span = max(1, last.end.timeIntervalSince(first.start))
                    for event in state.events {
                        let x = event.start.timeIntervalSince(first.start) / span * size.width
                        let width = max(1.2, event.duration / span * size.width)
                        let isSelected = state.index == event.id
                        let rect = CGRect(x: x, y: isSelected ? 2 : 6, width: width, height: isSelected ? 18 : 10)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(event.category.color.opacity(isSelected ? 1 : 0.48)))
                    }
                    if let selected = state.selected {
                        let x = selected.start.timeIntervalSince(first.start) / span * size.width
                        context.fill(Path(CGRect(x: max(0, min(size.width - 2, x)), y: 0, width: 2, height: 22)), with: .color(spaceInk))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard let first = state.events.first, let last = state.events.last else { return }
                    let fraction = min(1, max(0, value.location.x / geo.size.width))
                    let date = first.start.addingTimeInterval(last.end.timeIntervalSince(first.start) * fraction)
                    if let nearest = SpaceEvent.nearest(to: date, in: state.events) {
                        state.select(nearest.id)
                    }
                })
                .accessibilityElement().accessibilityLabel("今天的记忆时间条")
                .accessibilityValue(state.selected?.time ?? "")
                .accessibilityAdjustableAction { direction in
                    state.select(state.index + (direction == .increment ? 1 : -1))
                }
            }
            .frame(height: 23)
            Text(state.events.last?.endTime ?? "")
            Text("\(state.index + 1) / \(state.events.count)").frame(minWidth: 64, alignment: .trailing)
        }
        .font(.system(size: 10)).monospacedDigit().foregroundStyle(spaceMuted)
        .padding(.horizontal, 20).frame(height: 36)
    }

    private var memoryNavigation: some View {
        HStack(spacing: 8) {
            Button { state.select(state.index - 1) } label: {
                Image(systemName: "chevron.left").frame(width: 31, height: 29)
            }
            .buttonStyle(SpaceQuietButton()).disabled(state.index == 0)
            .keyboardShortcut(.leftArrow, modifiers: []).accessibilityLabel("上一段记忆")
            Button { state.select(state.index + 1) } label: {
                Image(systemName: "chevron.right").frame(width: 31, height: 29)
            }
            .buttonStyle(SpaceQuietButton()).disabled(state.index == state.events.count - 1)
            .keyboardShortcut(.rightArrow, modifiers: []).accessibilityLabel("下一段记忆")
        }
    }
}

private struct SnapshotThumbnail: View {
    let snapshot: SpaceSnapshot
    var body: some View {
        if let url = snapshot.url, let image = SpaceImages.thumbnail(url, maxPixel: 480) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "photo").foregroundStyle(spaceMuted)
        }
    }
}

private struct OriginalCaptureView: View {
    let snapshot: SpaceSnapshot
    let title: String
    let app: String
    let index: Int
    let count: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    @State private var original: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: onClose) {
                    Label("返回时间空间", systemImage: "arrow.left").font(.system(size: 12))
                        .padding(.horizontal, 12).frame(height: 32)
                }
                .buttonStyle(SpaceQuietButton()).keyboardShortcut(.escape, modifiers: [])
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Text("完整原图").font(.system(size: 11)).foregroundStyle(spaceMuted)
            }
            .padding(.leading, 88).padding(.trailing, 16).frame(height: 38)
            GeometryReader { geometry in
                if let original {
                    Image(nsImage: original).resizable().interpolation(.high).scaledToFit()
                        .frame(width: max(0, geometry.size.width - 16), height: max(0, geometry.size.height - 8))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .accessibilityLabel("\(app)，\(snapshot.time) 保存的完整原图")
                } else {
                    ContentUnavailableView("这张截图已不可用", systemImage: "photo", description: Text("原始文件可能已被 TimeSink 清理。返回后可查看其他快照。"))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            HStack(spacing: 12) {
                Text(app).font(.system(size: 12, weight: .medium))
                Text(snapshot.time).monospacedDigit()
                if let representation = original?.representations.first {
                    Text("·  \(representation.pixelsWide) × \(representation.pixelsHigh)")
                }
                Spacer()
                Button(action: onPrevious) { Image(systemName: "chevron.left").frame(width: 31, height: 29) }
                    .buttonStyle(SpaceQuietButton()).disabled(index == 0)
                    .keyboardShortcut(.leftArrow, modifiers: []).accessibilityLabel("上一张原图")
                Text("\(index + 1) / \(count)").monospacedDigit().frame(minWidth: 44)
                Button(action: onNext) { Image(systemName: "chevron.right").frame(width: 31, height: 29) }
                    .buttonStyle(SpaceQuietButton()).disabled(index >= count - 1)
                    .keyboardShortcut(.rightArrow, modifiers: []).accessibilityLabel("下一张原图")
            }
            .font(.system(size: 11)).foregroundStyle(spaceMuted)
            .padding(.horizontal, 20).frame(height: 36)
        }
        .background(spaceBackground)
        .onAppear(perform: loadOriginal)
        .onChange(of: snapshot.id) { _, _ in loadOriginal() }
    }
    private func loadOriginal() { original = snapshot.url.flatMap { NSImage(contentsOf: $0) } }
}

private struct SpaceQuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(spaceInk.opacity(isEnabled ? 1 : 0.25))
            .background(.white.opacity(configuration.isPressed ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
