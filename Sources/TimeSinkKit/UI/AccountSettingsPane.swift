import SwiftUI

/// Settings › 账号: sign in / out, the sync switch, a manual sync, last
/// result, delete account. Deliberately plain -- the layout is the user's
/// to refine; this pane exists so the cloud path is reachable.
struct AccountSettingsPane: View {
    let model: AppModel

    @State private var email: String?
    @State private var syncEnabled = false
    @State private var busy = false
    @State private var status: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            if !CloudConfig.isConfigured {
                Section {
                    Text("云端尚未配置：部署 cloud/infra 后把输出填进 CloudConfig.swift。")
                        .foregroundStyle(.secondary)
                }
            } else if let email {
                Section("账号") {
                    LabeledContent("邮箱", value: email)
                    Button("退出登录") { run { await model.cloudAuth?.signOut(); model.settings.setCloudSyncEnabled(false) } }
                }
                Section("同步") {
                    Toggle("同步到云端", isOn: $syncEnabled)
                        .onChange(of: syncEnabled) { _, on in
                            model.settings.setCloudSyncEnabled(on)
                            if on { run { await model.sync?.syncNow() } }
                        }
                    Text("上传每段活动的应用、窗口标题、网址和起止时间。截图和识别出的文字只留在本机。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("立即同步") { run { await model.sync?.syncNow() } }
                            .disabled(busy || !syncEnabled)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    if let last = model.sync?.lastSyncAt {
                        Text("上次同步：\(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = model.sync?.lastError {
                        Text("上次失败：\(error)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button("删除账号…", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("删除账号会清空云端的全部记录，且不可恢复。本机数据保留。",
                                            isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("删除账号", role: .destructive) {
                                run {
                                    try await model.sync?.deleteAccount()
                                    await model.cloudAuth?.signOut()
                                }
                            }
                        }
                }
            } else {
                Section {
                    Button("登录 / 注册") {
                        run {
                            if let sub = try await model.cloudAuth?.signIn() {
                                try model.sync?.accountChanged(to: sub)
                            }
                        }
                    }
                    .disabled(busy)
                    Text("登录后可以把活动记录备份到云端，并在多台 Mac 之间合并。默认不上传。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let status {
                Section { Text(status).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        email = model.cloudAuth?.isSignedIn == true ? (model.settings.cloudEmail ?? "已登录") : nil
        syncEnabled = model.settings.cloudSyncEnabled
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        status = nil
        Task { @MainActor in
            do { try await work() } catch { status = String(describing: error) }
            busy = false
            load()
        }
    }
}
