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
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 10) {
                    Text(toast).font(.system(size: 12)).lineLimit(2)
                    Button("撤销", action: undo).controlSize(.small).glassButton()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassSurface(cornerRadius: 14)
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

    /// Read-only until 修改分类… (⌘E): the form grows out of the button.
    private func inspector(_ item: CategorizedSpan) -> some View {
        let block = activities.selectedBlock
        let start = block?.start ?? item.span.start, end = block?.end ?? item.span.end
        let seconds = block?.segment?.recorded ?? item.span.duration
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ActivityIcon(bundleID: item.span.appBundleID, domain: item.span.domain, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(block?.label ?? item.span.domain ?? item.span.appName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    // A record inside one minute reads as a moment, not "10:36–10:36".
                    let from = model.time(start), to = model.time(end)
                    Text(from == to ? "\(from) · \(Format.duration(seconds))" : "\(from)–\(to) · \(Format.duration(seconds))")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let segment = block?.segment {
                composition(segment, block: block!, current: ActivitiesModel.selection(for: item).row).padding(.top, 14)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("分类").foregroundStyle(.secondary)
                    Spacer()
                    CategoryChip(category: model.resolver.categoriesByID[item.categoryID])
                }
                Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(item.categoryID == "uncategorized" ? RefinedStyle.warning.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .glassPlatter(cornerRadius: 12)
            .padding(.top, 10)

            Group {
                if activities.isEditingCategory {
                    form(item)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                } else {
                    Button { setEditing(true) } label: {
                        Label("修改分类…", systemImage: "tag").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .transition(.opacity)
                }
            }
            .padding(.top, 12)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 8) }

            HStack {
                Text("屏幕回看").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("只在本机").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(.top, 16).padding(.bottom, 8)
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

    private func setEditing(_ editing: Bool) {
        withAnimation(RefinedStyle.motion(reduced: reduceMotion)) { activities.isEditingCategory = editing }
    }

    private func form(_ item: CategorizedSpan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("归为").font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { category in
                    let chosen = category.id == categoryID
                    Button { categoryID = category.id } label: {
                        HStack(spacing: 5) {
                            Circle().fill(RefinedStyle.category(category.id, hex: category.colorHex)).frame(width: 6, height: 6)
                            Text(category.name).lineLimit(1)
                        }
                        .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(chosen ? Color.white : .primary)
                        .background(chosen ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            Text("应用到").font(.system(size: 12, weight: .semibold))
            Picker("应用范围", selection: $scope) {
                Text("这一段").tag(ReclassificationEdit.Scope.segment)
                Text(item.span.domain == nil ? "整个应用" : "整个网站").tag(ReclassificationEdit.Scope.activity)
                Text("按标题").tag(ReclassificationEdit.Scope.title)
            }.pickerStyle(.segmented).labelsHidden()
            if scope == .title {
                TextField("标题包含，至少两个字", text: $pattern).textFieldStyle(.roundedBorder)
            }
            Text(previewLine(item)).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { cancelEdit(item) } label: { Text("取消").frame(maxWidth: .infinity) }
                    .glassButton().keyboardShortcut(.cancelAction)
                Button(action: save) { Text("重新归类").frame(maxWidth: .infinity) }
                    .glassProminentButton().keyboardShortcut(.defaultAction)
                    .disabled(scope == .title && TitleRuleInput.normalizedPattern(pattern) == nil || affected.count == 0)
            }
        }
        .padding(12)
        .glassPlatter(cornerRadius: 14, strong: true)
    }

    private func previewLine(_ item: CategorizedSpan) -> String {
        if categoryID == item.categoryID && affected.count == 0 { return String(localized: "已经是这个分类，选择别的分类再保存") }
        switch scope {
        case .segment: return String(localized: "这一段：\(Format.duration(affected.seconds))")
        case .activity: return String(localized: "\(item.span.domain == nil ? String(localized: "整个应用") : String(localized: "整个网站"))：近 30 天 \(affected.count) 段 · \(Format.duration(affected.seconds))，以后自动归类")
        case .title: return String(localized: "按标题：近 30 天 \(affected.count) 段 · \(Format.duration(affected.seconds))，以后自动归类")
        }
    }

    private func cancelEdit(_ item: CategorizedSpan) {
        categoryID = item.categoryID; scope = .segment; pattern = ""
        setEditing(false)
    }

    /// What the block is made of, then every switch out of it with its
    /// class -- the same rule that draws the ticks.
    private func composition(_ segment: TimelineSegment, block: TimelineBlock, current: ActivitySelection) -> some View {
        let outs = outs(of: block)
        let interruptions = outs.filter { $0.tag.hasPrefix(String(localized: "打断")) }.count
        let episodes = activities.dayInterruptions?.episodes.filter { $0.start >= block.start && $0.start < block.end } ?? []
        let peeks = episodes.filter { $0.kind == .peek }.count, passes = episodes.filter { $0.kind == .pass }.count
        let parts = segment.parts.filter { $0.seconds >= 20 }.prefix(4)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("构成").fontWeight(.semibold).fixedSize()
                Spacer()
                Text(outs.isEmpty ? String(localized: "没有切出")
                     : interruptions > 0 ? String(localized: "切出 \(outs.count) 次 · 打断 \(interruptions) 次")
                     : String(localized: "切出 \(outs.count) 次"))
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }.font(.system(size: 12))
            VStack(spacing: 7) {
                ForEach(parts.isEmpty ? Array(segment.parts.prefix(1)) : Array(parts)) { part in
                    Button { activities.select(part.selection, start: part.longest.span.start) } label: {
                        HStack(spacing: 8) {
                            ActivityIcon(bundleID: part.appBundleID, domain: part.longest.span.domain, size: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(part.label).lineLimit(1).truncationMode(.middle)
                                GeometryReader { proxy in
                                    Capsule().fill(Color.primary.opacity(0.08))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(RefinedStyle.category(part.categoryID, hex: model.resolver.categoriesByID[part.categoryID]?.colorHex ?? "#C7C7CC"))
                                                .frame(width: proxy.size.width * min(1, part.seconds / max(1, segment.recorded)))
                                        }
                                }.frame(height: 4)
                            }
                            Text(Format.duration(part.seconds)).monospacedDigit().foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                        }
                        .font(.system(size: 12)).contentShape(Rectangle())
                        .padding(.vertical, 1)
                        .background(part.selection == current ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(part.selection == current ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .glassPlatter(cornerRadius: 12)
            if !outs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(outs.prefix(6), id: \.start) { out in
                        HStack(spacing: 7) {
                            Text(model.time(out.start)).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
                            ActivityIcon(bundleID: out.bundleID, domain: nil, size: 14)
                            (Text(out.label) + Text(" ") + Text(Format.duration(out.seconds)).foregroundStyle(.tertiary))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(out.tag).font(.system(size: 10.5, weight: .semibold)).fixedSize()
                                .foregroundStyle(out.isInterruption ? Color.red : Color.secondary)
                        }
                        .font(.system(size: 12)).frame(height: 22)
                    }
                    if outs.count > 6 {
                        Text("还有 \(outs.count - 6) 次").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 47)
                    }
                }
                .padding(.top, 2)
            }
            if peeks > 0 || passes > 0 {
                Text([peeks > 0 ? String(localized: "看一眼的 \(peeks) 次不画刻度，也不算打断") : nil,
                      passes > 0 ? String(localized: "另有 \(passes) 次不到 3 秒的路过") : nil]
                    .compactMap { $0 }.joined(separator: String(localized: "；")) + String(localized: "。"))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct Out {
        let start: Date
        let seconds: TimeInterval
        let label: String
        let bundleID: String
        let tag: String
        let isInterruption: Bool
    }

    private func outs(of block: TimelineBlock) -> [Out] {
        var result: [Out] = []
        for episode in activities.dayInterruptions?.episodes ?? [] where episode.start >= block.start && episode.start < block.end {
            switch episode.kind {
            case .interruption:
                result.append(Out(start: episode.start, seconds: episode.dwell, label: episode.destinationLabel, bundleID: episode.destinationBundleID,
                                  tag: episode.reason == .typed ? String(localized: "打断 · 打字") : String(localized: "打断 · 停留"), isInterruption: true))
            case .peek:
                result.append(Out(start: episode.start, seconds: episode.dwell, label: episode.destinationLabel, bundleID: episode.destinationBundleID,
                                  tag: String(localized: "看一眼"), isInterruption: false))
            case .pass: break
            }
        }
        let rule = activities.interruptionRule
        for excursion in block.segment?.excursions ?? []
        where !InterruptionRule.distractingCategories.contains(excursion.categoryID)
            && (excursion.seconds >= rule.dwell || excursion.keySeconds >= InterruptionRule.typedKeySeconds) {
            result.append(Out(start: excursion.start, seconds: excursion.seconds, label: excursion.label,
                              bundleID: block.segment?.parts.first { $0.selection == excursion.row }?.appBundleID ?? "",
                              tag: String(localized: "相关"), isInterruption: false))
        }
        return result.sorted { $0.start < $1.start }
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
        if !keepForm { categoryID = selected.categoryID; scope = .segment; pattern = ""; activities.isEditingCategory = false }
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
            let name = model.resolver.categoriesByID[categoryID]?.name ?? categoryID
            withAnimation(RefinedStyle.motion(reduced: reduceMotion)) {
                toast = scope == .segment ? String(localized: "已把这一段归为「\(name)」")
                    : String(localized: "已把 \(key) 归为「\(name)」，以后自动归类")
                activities.isEditingCategory = false
            }
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

struct CaptureReviewSheet: View {
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
