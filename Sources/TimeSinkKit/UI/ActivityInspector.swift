import SwiftUI
import ImageIO

struct ActivityInspector: View {
    let model: AppModel
    @Bindable var activities: ActivitiesModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @State private var selected: CategorizedSpan?
    @State private var scope: ReclassificationEdit.Scope = .segment
    @State private var categoryID = "writing"
    @State private var pattern = ""
    /// The last 30 days, read only once a scope needs a preview and again
    /// after a user edit -- never on the tracker's own writes.
    @State private var history: [CategorizedSpan] = []
    @State private var historyEdits = -1
    @State private var affected: (count: Int, seconds: TimeInterval) = (0, 0)
    @State private var captures: [Capture] = []
    @State private var selectedCapture: Capture?
    @State private var error: String?
    @State private var undoEdit: ReclassificationEdit?
    @State private var undoKey = ""
    @State private var toast: String?
    @State private var toastSeconds = 6
    @State private var toastHovered = false
    @State private var reason = ""

    private struct SelectionKey: Equatable {
        let activity: ActivitySelection?
        let start: Date?
    }
    private struct PreviewKey: Equatable {
        let span: Int64?
        let spanCategory: String?
        let scope: ReclassificationEdit.Scope
        let categoryID: String
        let pattern: String
        let edits: Int
    }

    private func preview() {
        guard let selected else { affected = (0, 0); return }
        if scope == .segment { affected = selected.categoryID == categoryID ? (0, 0) : (1, selected.span.duration); return }
        if historyEdits != model.dataEditVersion {
            history = model.rangedSpans(for: DateRangeSelection(kind: .last30, anchor: Date()))
            historyEdits = model.dataEditVersion
        }
        let matches = model.resolver.previewEdit(span: selected.span, scope: scope, categoryID: categoryID, pattern: pattern, items: history)
        affected = (matches.count, matches.reduce(0) { $0 + $1.span.duration })
    }

    var body: some View {
        ScrollView {
            if let selected {
                inspector(selected).padding(16)
            } else {
                ContentUnavailableView("选择一段活动", systemImage: "sidebar.right", description: Text("查看分类来源、调整分类，或回看当时的屏幕。"))
                    .frame(minHeight: 250)
            }
        }
        .background(RefinedStyle.panel)
        .overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(toast).font(.system(size: 12)).lineLimit(2)
                        ProgressView(value: Double(toastSeconds), total: 6).tint(.white)
                    }
                    Button("撤销", action: undo).controlSize(.small)
                }.padding(12).foregroundStyle(.white)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .padding(10).onHover { toastHovered = $0 }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: SelectionKey(activity: activities.selectedActivity, start: activities.selectedStart)) { load() }
        .onPageChange(of: model.dataVersion) { load(keepForm: true) }
        .task(id: PreviewKey(span: selected?.span.id, spanCategory: selected?.categoryID, scope: scope,
                             categoryID: categoryID, pattern: pattern, edits: model.dataEditVersion)) { preview() }
        .task(id: toast) {
            guard toast != nil else { return }
            toastSeconds = 6
            while toastSeconds > 0 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if !toastHovered { toastSeconds -= 1 }
            }
            withAnimation(.easeOut(duration: 0.15)) { self.toast = nil }
        }
        .sheet(item: $selectedCapture) { CaptureReviewSheet(capture: $0) }
    }

    private func inspector(_ item: CategorizedSpan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let segment = activities.selectedBlock?.segment, segment.parts.count > 1 {
                stretch(segment, current: ActivitiesModel.selection(for: item).row)
            }
            HStack(spacing: 10) {
                AppIcon(bundleID: item.span.appBundleID, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.span.domain ?? item.span.appName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    // A record inside one minute reads as a moment, not "10:36–10:36".
                    let start = model.time(item.span.start), end = model.time(item.span.end)
                    Text(start == end ? "\(start) · \(Format.duration(item.span.duration))" : "\(start)–\(end) · \(Format.duration(item.span.duration))")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text(String(localized: "标题")).foregroundStyle(.secondary); Text(item.span.title ?? String(localized: "无标题")).textSelection(.enabled) }
                if let url = item.span.url { GridRow { Text("网址").foregroundStyle(.secondary); Text(url).font(.system(size: 11)).textSelection(.enabled) } }
                GridRow { Text("分类").foregroundStyle(.secondary); CategoryChip(category: model.resolver.categoriesByID[item.categoryID]) }
            }.font(.system(size: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("为什么是这个分类").fontWeight(.semibold)
                Text(reason).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(item.categoryID == "uncategorized" ? RefinedStyle.warning.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            Text("改为").font(.system(size: 12, weight: .semibold))
            Picker("分类", selection: $categoryID) {
                ForEach(model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { category in
                    Text(category.name).tag(category.id)
                }
            }.labelsHidden()
            Text("应用到").font(.system(size: 12, weight: .semibold))
            Picker("应用范围", selection: $scope) {
                Text("只改这条记录 · \(Format.duration(item.span.duration))").tag(ReclassificationEdit.Scope.segment)
                Text("所有 \(item.span.domain ?? item.span.appName)").tag(ReclassificationEdit.Scope.activity)
                Text("匹配标题 · 以后自动归类").tag(ReclassificationEdit.Scope.title)
            }.pickerStyle(.radioGroup).labelsHidden().font(.system(size: 12))
            if scope == .title {
                TextField("标题包含，至少两个字", text: $pattern).textFieldStyle(.roundedBorder)
            }
            Text(categoryID == item.categoryID && affected.count == 0
                 ? String(localized: "已经是这个分类，选择别的分类再保存")
                 : String(localized: "\(scope == .segment ? "" : String(localized: "近 30 天 · "))会影响 \(affected.count) 条记录 · \(Format.duration(affected.seconds))"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("取消") { categoryID = item.categoryID; scope = .segment; pattern = "" }
                Spacer()
                Button("保存并重新归类", action: save).buttonStyle(.borderedProminent)
                    .disabled(scope == .title && TitleRuleInput.normalizedPattern(pattern) == nil || affected.count == 0)
            }.controlSize(.small)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            Divider()
            HStack {
                Text("屏幕回看").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("只在本机").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if captures.isEmpty {
                Text("这段时间没有保存的画面。可在「记录与隐私」中查看采集状态。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(captures, id: \.id) { capture in
                        Button { selectedCapture = capture } label: {
                            VStack(spacing: 3) {
                                CaptureThumbnail(capture: capture, maxPixels: 240).frame(height: 50).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(capture.at, format: .dateTime.hour().minute()).font(.system(size: 11)).monospacedDigit()
                            }
                        }.buttonStyle(.plain).help("打开本机截图")
                    }
                }
            }
        }
    }

    /// A folded timeline block holds several activities: show what it is
    /// made of, and let each part be opened on its own.
    private func stretch(_ segment: TimelineSegment, current: ActivitySelection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("这段时间").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 6)
                Text("\(model.time(segment.start))–\(model.time(segment.end)) · \(Format.duration(segment.recorded))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            CompositionBar(segment: segment) { id in
                RefinedStyle.category(id, hex: model.resolver.categoriesByID[id]?.colorHex ?? "#C7C7CC")
            }.frame(height: 6)
            VStack(spacing: 1) {
                ForEach(segment.parts.prefix(5)) { part in
                    Button { activities.select(part.selection, start: part.longest.span.start) } label: {
                        HStack(spacing: 8) {
                            ActivityIcon(bundleID: part.appBundleID, domain: part.longest.span.domain, size: 16)
                            Text(part.label).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(Format.duration(part.seconds)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12)).padding(.vertical, 4).padding(.horizontal, 6)
                        .background(part.selection == current ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(part.selection == current ? .isSelected : [])
                }
            }
            let rest = segment.parts.dropFirst(5)
            if !rest.isEmpty || segment.switches > 0 {
                Text([rest.isEmpty ? nil : String(localized: "另有 \(rest.count) 项 · \(Format.duration(rest.reduce(0) { $0 + $1.seconds }))"),
                      segment.switches > 0 ? String(localized: "\(segment.spanCount) 条记录 · 切换 \(segment.switches) 次") : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private func load(keepForm: Bool = false) {
        let all = model.rangedSpans()
        guard let selection = activities.selectedActivity else { selected = nil; return }
        // Time first: the identity check (a URL parse) then runs on a handful
        // of spans instead of the whole range.
        let item = activities.selectedStart.flatMap { start in
            all.first { $0.span.start <= start && start < $0.span.end && selection.matches(ActivitiesModel.selection(for: $0)) }
        } ?? all.first { selection.matches(ActivitiesModel.selection(for: $0)) }
        // Keep the saved row visible even when changing category moves its list group.
        if let item { selected = item }
        else if keepForm, let previous = selected, let updated = all.first(where: { $0.span.id == previous.span.id }) { selected = updated }
        else { selected = nil }
        guard let selected else { return }
        if !keepForm { categoryID = selected.categoryID; scope = .segment; pattern = "" }
        reason = model.resolver.explanation(for: selected.span)
        captures = (try? model.observationStore?.captures(overlapping: DateInterval(start: selected.span.start, end: selected.span.end))) ?? []
        captures = captures.filter { $0.appBundleID == selected.span.appBundleID }
    }

    private func save() {
        guard let selected else { return }
        do {
            let edit = try model.categoryStore.reclassify(span: selected.span, scope: scope, categoryID: categoryID, pattern: pattern)
            let key = selected.span.domain ?? selected.span.appBundleID
            undoEdit = edit; undoKey = key
            // ⌘Z reaches this through the window's undo stack (Edit ▸ Undo),
            // so a focused text field keeps undoing its own typing first.
            undoManager?.registerUndo(withTarget: model) { _ in MainActor.assumeIsolated { revert(edit, key: key) } }
            undoManager?.setActionName(String(localized: "更改分类"))
            model.resolver.refresh(); model.dataChanged()
            error = nil
            withAnimation(RefinedStyle.motion(reduced: reduceMotion)) { toast = String(localized: "已归为「\(model.resolver.categoriesByID[categoryID]?.name ?? categoryID)」") }
        } catch { self.error = error.localizedDescription }
    }
    /// The toast's button: reverts its own edit, whatever is on top of the
    /// undo stack, and drops the category edits registered there.
    private func undo() {
        guard let undoEdit else { return }
        undoManager?.removeAllActions(withTarget: model)
        revert(undoEdit, key: undoKey)
    }
    private func revert(_ edit: ReclassificationEdit, key: String) {
        do {
            try model.categoryStore.undoReclassification(edit, activityKey: key)
            model.resolver.refresh(); model.dataChanged()
            undoEdit = nil; toast = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

extension Capture: Identifiable {}

struct CaptureThumbnail: View {
    let capture: Capture
    /// Longest edge to decode at; the review sheet asks for the full image.
    var maxPixels = 1600
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary).background(.quaternary) }
        }.task(id: capture.imagePath) {
            if let path = capture.imagePath, let root = try? ScreenCollector.defaultImagesRoot() {
                let url = root.appendingPathComponent(path).standardizedFileURL
                guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
                // Decoding a full screenshot takes tens of milliseconds; a grid
                // of them must not run on the main actor.
                let maxPixels = maxPixels
                image = await Task.detached(priority: .userInitiated) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                    ] as CFDictionary)
                }.value
            }
        }
    }
}

private struct CaptureReviewSheet: View {
    let capture: Capture
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(capture.appName).font(.headline)
                Text(capture.at, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            CaptureThumbnail(capture: capture).frame(maxWidth: .infinity, maxHeight: .infinity)
            if capture.imagePath == nil { Text("画面已到期删除，以下为当时识别的文字。").foregroundStyle(.secondary) }
            ScrollView { Text(capture.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
        }.padding(20).frame(width: 800, height: 620)
    }
}
