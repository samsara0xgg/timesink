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
    @State private var showingHistory = false

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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let sync = model.sync {
                        HStack {
                            Button("立即同步") { run { await sync.syncNow() } }
                                .disabled(sync.isSyncing || !syncEnabled)
                            Button("同步记录…") { showingHistory = true }
                            if sync.isSyncing { ProgressView().controlSize(.small) }
                            Spacer()
                            Text("待上传 \(sync.pending) 条")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(syncLine(sync))
                            .font(.caption)
                            .foregroundStyle(sync.lastError == nil ? Color.secondary : Color.red)
                            .sheet(isPresented: $showingHistory) {
                                SyncHistorySheet(spanStore: model.spanStore, sync: sync)
                            }
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let status {
                Section { Text(status).font(.caption).foregroundStyle(.red) }
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
            return String(localized: "最近一轮 \(last.formatted(date: .abbreviated, time: .shortened))：上传 \(sync.passPushed) 条，下载 \(sync.passPulled) 条")
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

/// Settings › 账号 › 同步记录: the totals the span table holds, then one line
/// per hour that moved rows or failed, newest first.
private struct SyncHistorySheet: View {
    let spanStore: SpanStore
    let sync: SyncEngine

    @Environment(\.dismiss) private var dismiss
    @State private var hours: [SpanStore.SyncHour] = []
    @State private var totals = (uploaded: 0, downloaded: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("同步记录").font(.headline)
            Text("本机已上传 \(totals.uploaded) 条，已从其他设备下载 \(totals.downloaded) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                if hours.isEmpty {
                    Text("还没有记录").foregroundStyle(.secondary)
                }
                ForEach(days, id: \.0) { day, rows in
                    Section(day.formatted(.dateTime.month().day().weekday())) {
                        ForEach(rows, id: \.hour) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.hour.formatted(date: .omitted, time: .shortened))
                                    Spacer()
                                    Text("上传 \(row.pushed) 条 · 下载 \(row.pulled) 条")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                if row.failures > 0 {
                                    Text("失败 \(row.failures) 次：\(row.lastError ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
            Text("保留最近 \(SpanStore.syncLogDays) 天")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440, height: 400)
        .onAppear(perform: load)
        .onChange(of: sync.isSyncing) { _, running in
            if !running { load() }
        }
    }

    private var days: [(Date, [SpanStore.SyncHour])] {
        Dictionary(grouping: hours) { Calendar.current.startOfDay(for: $0.hour) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value) }
    }

    private func load() {
        hours = (try? spanStore.syncLog()) ?? []
        totals = (try? spanStore.syncTotals()) ?? totals
    }
}
