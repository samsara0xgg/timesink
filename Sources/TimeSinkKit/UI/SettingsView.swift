import SwiftUI

/// Settings window: four tabs — 通用 (idle threshold, login item, permission
/// status), 分类 (edit the 12 taxonomy categories), 规则 (URL classification
/// rules), 未分类 (last-30-days spans still resolving to "uncategorized").
/// The LLM tab is added in Task 13. Opens via ⌘, from the main window or the
/// menu bar's SettingsLink (`TimeSinkApp`'s `Settings` scene).
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsPane(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            CategoriesSettingsPane(model: model)
                .tabItem { Label("分类", systemImage: "tag") }
            RulesSettingsPane(model: model)
                .tabItem { Label("规则", systemImage: "list.bullet.rectangle") }
            UncategorizedSettingsPane(model: model)
                .tabItem { Label("未分类", systemImage: "questionmark.circle") }
        }
        .frame(width: 560, height: 420)
    }
}
