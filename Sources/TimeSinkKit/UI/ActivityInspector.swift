import SwiftUI

struct ActivityInspector: View {
    let model: AppModel
    @Bindable var activities: ActivitiesModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: CategorizedSpan?
    @State private var scope: ReclassificationEdit.Scope = .segment
    @State private var categoryID = "writing"
    @State private var pattern = ""
    @State private var history: [CategorizedSpan] = []
    @State private var captures: [Capture] = []
    @State private var selectedCapture: Capture?
    @State private var error: String?
    @State private var undoEdit: ReclassificationEdit?
    @State private var undoKey = ""
    @State private var toast: String?
    @State private var toastSeconds = 6
    @State private var toastHovered = false
    @State private var reason = ""

    private var affected: (count: Int, seconds: TimeInterval) {
        guard let selected else { return (0, 0) }
        if scope == .segment { return selected.categoryID == categoryID ? (0, 0) : (1, selected.span.duration) }
        let matches = model.resolver.previewEdit(span: selected.span, scope: scope, categoryID: categoryID, pattern: pattern, items: history)
        return (matches.count, matches.reduce(0) { $0 + $1.span.duration })
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
                    Button("撤销", action: undo).keyboardShortcut("z").controlSize(.small)
                }.padding(12).foregroundStyle(.white)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .padding(10).onHover { toastHovered = $0 }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: activities.selectedActivity) { load() }
        .onChange(of: activities.selectedStart) { _, _ in load() }
        .onChange(of: model.dataVersion) { _, _ in load(keepForm: true) }
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
            HStack(spacing: 10) {
                AppIcon(bundleID: item.span.appBundleID, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.span.domain ?? item.span.appName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(model.time(item.span.start))–\(model.time(item.span.end)) · \(Format.duration(item.span.duration))")
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
                Text("只改这一段 · \(Format.duration(item.span.duration))").tag(ReclassificationEdit.Scope.segment)
                Text("所有 \(item.span.domain ?? item.span.appName)").tag(ReclassificationEdit.Scope.activity)
                Text("匹配标题 · 以后自动归类").tag(ReclassificationEdit.Scope.title)
            }.pickerStyle(.radioGroup).labelsHidden().font(.system(size: 12))
            if scope == .title {
                TextField("标题包含，至少两个字", text: $pattern).textFieldStyle(.roundedBorder)
            }
            Text(String(localized: "\(scope == .segment ? "" : String(localized: "近 30 天 · "))会影响 \(affected.count) 段 · \(Format.duration(affected.seconds))"))
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
                                CaptureThumbnail(capture: capture).frame(height: 50).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(capture.at, format: .dateTime.hour().minute()).font(.system(size: 11)).monospacedDigit()
                            }
                        }.buttonStyle(.plain).help("打开本机截图")
                    }
                }
            }
        }
    }

    private func load(keepForm: Bool = false) {
        let all = model.rangedSpans()
        guard let selection = activities.selectedActivity else { selected = nil; return }
        let matching = all.filter { selection.matches(ActivitiesModel.selection(for: $0)) }
        let item = matching.first { span in
            guard let start = activities.selectedStart else { return false }
            return span.span.start <= start && start < span.span.end
        } ?? matching.first
        // Keep the saved row visible even when changing category moves its list group.
        if let item { selected = item }
        else if keepForm, let previous = selected, let updated = all.first(where: { $0.span.id == previous.span.id }) { selected = updated }
        else { selected = nil }
        guard let selected else { return }
        if !keepForm { categoryID = selected.categoryID; scope = .segment; pattern = "" }
        reason = model.resolver.explanation(for: selected.span)
        history = model.rangedSpans(for: DateRangeSelection(kind: .last30, anchor: Date()))
        captures = (try? model.observationStore?.captures(overlapping: DateInterval(start: selected.span.start, end: selected.span.end))) ?? []
        captures = captures.filter { $0.appBundleID == selected.span.appBundleID }
    }

    private func save() {
        guard let selected else { return }
        do {
            let edit = try model.categoryStore.reclassify(span: selected.span, scope: scope, categoryID: categoryID, pattern: pattern)
            let key = selected.span.domain ?? selected.span.appBundleID
            undoEdit = edit; undoKey = key
            model.resolver.refresh(); model.dataChanged()
            error = nil
            withAnimation(RefinedStyle.motion(reduced: reduceMotion)) { toast = String(localized: "已归为「\(model.resolver.categoriesByID[categoryID]?.name ?? categoryID)」") }
        } catch { self.error = error.localizedDescription }
    }
    private func undo() {
        guard let undoEdit else { return }
        do {
            try model.categoryStore.undoReclassification(undoEdit, activityKey: undoKey)
            model.resolver.refresh(); model.dataChanged()
            self.undoEdit = nil; toast = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

extension Capture: Identifiable {}

struct CaptureThumbnail: View {
    let capture: Capture
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary).background(.quaternary) }
        }.task(id: capture.imagePath) {
            if let path = capture.imagePath, let root = try? ScreenCollector.defaultImagesRoot() {
                let url = root.appendingPathComponent(path).standardizedFileURL
                guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
                image = NSImage(contentsOf: url)
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
