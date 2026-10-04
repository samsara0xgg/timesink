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
    /// Everything the chosen list row stands for: the header says the row's
    /// total, not just the one record shown below it.
    @State private var rowTotal: (count: Int, seconds: TimeInterval)?

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
                inspector(selected).padding(Design.Space.lg)
            }
        }
        .scrollContentBackground(.hidden)
        .fadeFoot()
        .overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: Design.Space.md) {
                    Text(toast).font(.body).lineLimit(2)
                    Button("撤销", action: undo).buttonStyle(PillButtonStyle(height: 24))
                }
                .padding(.horizontal, Design.Space.lg).padding(.vertical, Design.Space.md)
                .floatingCard()
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
        let aggregate = block == nil ? rowTotal.flatMap { $0.count > 1 ? $0 : nil } : nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ActivityIcon(bundleID: item.span.appBundleID, domain: item.span.domain, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(block?.label ?? item.span.domain ?? item.span.appName).font(.body.weight(.semibold)).lineLimit(1)
                    // A record inside one minute reads as a moment, not "10:36–10:36".
                    let from = model.time(start), to = model.time(end)
                    if let aggregate {
                        (Text("合计 \(Format.duration(aggregate.seconds))") + Text(verbatim: " · ") + Text("\(aggregate.count) 次"))
                            .font(.body).foregroundStyle(Design.ink2).monospacedDigit()
                    } else {
                        Text(from == to ? "\(from) · \(Format.duration(seconds))" : "\(from)–\(to) · \(Format.duration(seconds))")
                            .font(.body).foregroundStyle(Design.ink2).monospacedDigit()
                    }
                }
            }
            if let segment = block?.segment {
                composition(segment, block: block!, current: ActivitiesModel.selection(for: item).row).padding(.top, 14)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("归为").foregroundStyle(Design.ink2)
                    Spacer()
                    CategoryChip(category: model.resolver.categoriesByID[item.categoryID])
                }
                Text(reason).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .font(.body).padding(Design.Space.md).frame(maxWidth: .infinity, alignment: .leading)
            .background(item.categoryID == "uncategorized" ? Design.warning.opacity(0.15) : Design.floor,
                        in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            .padding(.top, Design.Space.md)

            Group {
                if activities.isEditingCategory {
                    form(item)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                } else {
                    Button { setEditing(true) } label: {
                        Label("修改分类…", systemImage: "tag").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle())
                    .transition(.opacity)
                }
            }
            .padding(.top, 12)
            if let error { Text(error).font(.body).foregroundStyle(Design.alert).padding(.top, 8) }

            HStack {
                Text("屏幕回看").font(.body.weight(.semibold))
                Spacer()
                Text("只在本机").font(.note).foregroundStyle(Design.ink2)
            }.padding(.top, 16).padding(.bottom, 8)
            if captures.isEmpty {
                Text("这段时间没有保存的画面。可在「记录与隐私」中查看采集状态。")
                    .font(.note).foregroundStyle(Design.ink2)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(captures, id: \.id) { capture in
                        Button { selectedCapture = capture } label: {
                            VStack(spacing: 3) {
                                CaptureThumbnail(capture: capture, maxPixels: 240).frame(height: 50).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(capture.at, format: .dateTime.hour().minute()).font(.note).monospacedDigit()
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
            Text("归为").font(.body.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { category in
                    let chosen = category.id == categoryID
                    Button { categoryID = category.id } label: {
                        HStack(spacing: 5) {
                            Circle().fill(RefinedStyle.category(category.id, hex: category.colorHex)).frame(width: 6, height: 6)
                            Text(category.name).lineLimit(1)
                        }
                        .font(.body.weight(chosen ? .semibold : .regular)).foregroundStyle(Design.ink)
                        .padding(.horizontal, Design.Space.sm).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
                        .background(chosen ? Design.selectedFill : Design.surface,
                                    in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                            .strokeBorder(chosen ? Design.ink.opacity(0.5) : Design.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            Text("应用到").font(.body.weight(.semibold))
            Segmented(options: [ReclassificationEdit.Scope.segment, .activity, .title], selection: $scope, height: 24) { option in
                switch option {
                case .segment: Text("这一段")
                case .activity: Text(item.span.domain == nil ? "整个应用" : "整个网站")
                default: Text("按标题")
                }
            }
            .accessibilityLabel("应用范围")
            if scope == .title {
                TextField("标题包含，至少两个字", text: $pattern).textFieldStyle(.roundedBorder)
            }
            Text(previewLine(item)).font(.note).foregroundStyle(Design.ink2)
            HStack(spacing: 8) {
                Button { cancelEdit(item) } label: { Text("取消").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
                Button(action: save) { Text("重新归类").frame(maxWidth: .infinity) }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(scope == .title && TitleRuleInput.normalizedPattern(pattern) == nil || affected.count == 0)
            }
        }
        .padding(Design.Space.md)
        .background(Design.floor, in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
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
                    .foregroundStyle(Design.ink2).lineLimit(1).minimumScaleFactor(0.85)
            }.font(.body)
            VStack(spacing: 7) {
                ForEach(parts.isEmpty ? Array(segment.parts.prefix(1)) : Array(parts)) { part in
                    Button { activities.select(part.selection, start: part.longest.span.start) } label: {
                        HStack(spacing: 8) {
                            ActivityIcon(bundleID: part.appBundleID, domain: part.longest.span.domain, size: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(part.label).lineLimit(1).truncationMode(.middle)
                                GeometryReader { proxy in
                                    Capsule().fill(Design.track)
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(RefinedStyle.category(part.categoryID, hex: model.resolver.categoriesByID[part.categoryID]?.colorHex ?? "#C7C7CC"))
                                                .frame(width: proxy.size.width * min(1, part.seconds / max(1, segment.recorded)))
                                        }
                                }.frame(height: 4)
                            }
                            Text(Format.duration(part.seconds)).monospacedDigit().foregroundStyle(Design.ink2).frame(width: 58, alignment: .trailing)
                        }
                        .font(.body).contentShape(Rectangle())
                        .padding(.vertical, 1)
                        .background(part.selection == current ? Design.selectedFill : .clear,
                                    in: RoundedRectangle(cornerRadius: Design.Radius.mark, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(part.selection == current ? .isSelected : [])
                }
            }
            .padding(.horizontal, Design.Space.md).padding(.vertical, Design.Space.md)
            .background(Design.floor, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            if !outs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(outs.prefix(6), id: \.start) { out in
                        HStack(spacing: 7) {
                            Text(model.time(out.start)).monospacedDigit().foregroundStyle(Design.ink2).fixedSize()
                            ActivityIcon(bundleID: out.bundleID, domain: nil, size: 14)
                            (Text(out.label) + Text(" ") + Text(Format.duration(out.seconds)).foregroundStyle(Design.ink2))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(out.tag).font(.note.weight(.semibold)).fixedSize()
                                .foregroundStyle(out.isInterruption ? Color.red : Color.secondary)
                        }
                        .font(.body).frame(height: 22)
                    }
                    if outs.count > 6 {
                        Text("还有 \(outs.count - 6) 次").font(.note).foregroundStyle(Design.ink2).padding(.leading, 47)
                    }
                }
                .padding(.top, 2)
            }
            if peeks > 0 || passes > 0 {
                Text([peeks > 0 ? String(localized: "看一眼的 \(peeks) 次不画刻度，也不算打断") : nil,
                      passes > 0 ? String(localized: "另有 \(passes) 次不到 3 秒的路过") : nil]
                    .compactMap { $0 }.joined(separator: String(localized: "；")) + String(localized: "。"))
                    .font(.note).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
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
        where !model.resolver.distractingIDs.contains(excursion.categoryID)
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
        rowTotal = activities.selectedStart == nil
            ? all.filter { selection.matches(ActivitiesModel.selection(for: $0)) }.reduce((0, 0)) { ($0.0 + 1, $0.1 + $1.span.duration) }
            : nil
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
            else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(Design.ink2).background(.quaternary) }
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
                Text(capture.appName).font(.body.weight(.semibold))
                Text(capture.at, format: .dateTime.month().day().hour().minute()).foregroundStyle(Design.ink2)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            CaptureThumbnail(capture: capture).frame(maxWidth: .infinity, maxHeight: .infinity)
            if capture.imagePath == nil { Text("画面已到期删除，以下为当时识别的文字。").foregroundStyle(Design.ink2) }
            ScrollView { Text(capture.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
        }.padding(20).frame(width: 800, height: 620)
    }
}
