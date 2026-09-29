import SwiftUI
import AppKit
import os

private let budgetSettingsLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "budgetSettings")

/// Picks apps from the ones installed in the Applications folders: the apps
/// focus hides (Focus page) or never records (Privacy settings, via
/// `onSave`). Writes back through `blockedApps` so the caller's chips update
/// immediately.
struct FocusBlockedAppsEditor: View {
    let model: AppModel
    var title = String(localized: "选择专注期间隐藏的应用")
    var onSave: (([String]) -> Void)? = nil
    @Binding var blockedApps: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var apps: [(id: String, name: String)] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .semibold))
            TextField("搜索已安装的应用", text: $search).textFieldStyle(.roundedBorder)
            List(apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.id) { app in
                Toggle(isOn: Binding(get: { selected.contains(app.id) }, set: { value in
                    if value { selected.insert(app.id) } else { selected.remove(app.id) }
                })) {
                    HStack(spacing: 10) { AppIcon(bundleID: app.id); Text(app.name) }
                }.padding(.vertical, 3)
            }.listStyle(.inset)
            Text(onSave == nil ? "只在专注时隐藏，记录照常；修改从下一次专注开始生效。" : "选中的应用不会记录活动或保存屏幕画面。密码管理器始终不记录。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("已选择 \(selected.count) 个").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    blockedApps = selected.sorted(); if let onSave { onSave(blockedApps) } else { model.settings.setFocusBlockedApps(blockedApps) }; dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 420, height: 480)
        .task {
            selected = Set(blockedApps)
            // Walking three folders and opening every bundle takes a moment;
            // the sheet opens first. Never launches apps or asks for access.
            let own = Bundle.main.bundleIdentifier
            var found = await Task.detached(priority: .userInitiated) { Self.installedApps(excluding: own) }.value
            for id in blockedApps where found[id] == nil { found[id] = AppIcon.name(for: id) }
            apps = found.map { (id: $0.key, name: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    nonisolated private static func installedApps(excluding own: String?) -> [String: String] {
        var found: [String: String] = [:]
        for root in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                if let id = Bundle(url: url)?.bundleIdentifier, id != own {
                    found[id] = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                }
            }
        }
        return found
    }
}
