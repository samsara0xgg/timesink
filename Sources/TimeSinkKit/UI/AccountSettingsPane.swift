import SwiftUI

/// Settings › 账号: sign in / out, the sync switch, a manual sync with live
/// progress, last result, delete account. Plain on purpose -- the layout is
/// the user's to refine; this pane exists so the cloud path is reachable.
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
                    Text("此版本暂未提供云端同步。活动记录、截图与识别文字保留在这台 Mac 上。")
                        .foregroundStyle(Design.ink2)
                }
            } else if let email {
                Section("账号") {
                    LabeledContent("邮箱", value: email)
                    Button("退出登录") {
                        run {
                            await model.cloudAuth?.signOut()
                            model.settings.setCloudSyncEnabled(false)
                        }
                    }
                    .disabled(busy)
                }
                Section("同步") {
                    Toggle("同步到云端", isOn: $syncEnabled)
                        .onChange(of: syncEnabled) { _, on in
                            model.settings.setCloudSyncEnabled(on)
                            if on { run { await model.sync?.syncNow() } }
                        }
                    Text("上传每段活动的应用、窗口标题、网址和起止时间。截图和识别出的文字只留在本机。")
                        .font(.note)
                        .foregroundStyle(Design.ink2)
                    if let sync = model.sync {
                        HStack {
                            Button("立即同步") { run { await sync.syncNow() } }
                                .disabled(sync.isSyncing || !syncEnabled)
                            if sync.isSyncing { ProgressView().controlSize(.small) }
                            Spacer()
                            Text("待上传 \(sync.pending) 条")
                                .font(.note)
                                .foregroundStyle(Design.ink2)
                        }
                        Text(syncLine(sync))
                            .font(.note)
                            .foregroundStyle(sync.lastError == nil ? Color.secondary : Design.alert)
                    }
                }
                Section {
                    Button("删除账号…", role: .destructive) { confirmDelete = true }
                        .disabled(busy)
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
                    HStack {
                        Button("登录 / 注册") { signIn() }
                            .disabled(busy)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    Text("登录后可以把活动记录备份到云端，并在多台 Mac 之间合并。默认不上传，登录后仍需打开同步开关。")
                        .font(.note)
                        .foregroundStyle(Design.ink2)
                }
            }
            if let status {
                Section { Text(status).font(.note).foregroundStyle(Design.alert) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            load()
            model.sync?.refreshPending()
        }
    }

    private func syncLine(_ sync: SyncEngine) -> String {
        if sync.isSyncing {
            return String(localized: "正在同步：已上传 \(sync.passPushed) 条，已下载 \(sync.passPulled) 条")
        }
        if let error = sync.lastError { return String(localized: "上次同步失败：\(error)") }
        if let last = sync.lastSyncAt {
            let time = last.formatted(date: .abbreviated, time: .shortened)
            // The counts live only in memory and read 0/0 after a relaunch.
            if sync.passPushed + sync.passPulled == 0 { return String(localized: "上次同步 \(time)") }
            return String(localized: "上次同步 \(time)：上传 \(sync.passPushed) 条，下载 \(sync.passPulled) 条")
        }
        return syncEnabled ? String(localized: "还没有同步过") : String(localized: "同步已关闭")
    }

    private func signIn() {
        run {
            if let sub = try await model.cloudAuth?.signIn() {
                try model.sync?.accountChanged(to: sub)
            }
        }
    }

    private func load() {
        email = model.cloudAuth?.isSignedIn == true ? (model.settings.cloudEmail ?? String(localized: "已登录")) : nil
        syncEnabled = model.settings.cloudSyncEnabled
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        status = nil
        Task { @MainActor in
            do {
                try await work()
            } catch CloudAuthError.cancelled {
                // Closing the sign-in window is not a failure.
            } catch {
                status = error.localizedDescription
            }
            busy = false
            load()
        }
    }
}
