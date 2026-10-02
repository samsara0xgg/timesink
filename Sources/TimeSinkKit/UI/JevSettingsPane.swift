import SwiftUI

/// Jev classification, default off. The API key never touches the database;
/// it lives in the Keychain under `JevService.apiKeyAccount`. Endpoint and
/// monthly cap are ordinary settings.
struct JevSettingsPane: View {
    let model: AppModel

    @State private var enabled = false
    @State private var screenText = false
    @State private var endpoint = ""
    @State private var cap = ""
    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var apiKeyStatus: String?
    @State private var status: JevService.Status?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("用 Jev 给每段使用时间判断分类", isOn: $enabled)
                        .disabled(!hasStoredKey && !enabled)
                        .onChange(of: enabled) { _, newValue in model.jev?.setEnabled(newValue); refreshStatus() }
                    if !hasStoredKey && !enabled {
                        Text("先在下面保存 API 密钥，才能开启。").font(.caption).foregroundStyle(.orange)
                    }
                    Text("开启后，每段使用时间会向下面的服务发送这些内容。不会发送屏幕截图本身。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(JevService.sentFields, id: \.self) { Text("· \($0)").font(.caption).foregroundStyle(.secondary) }
                }
                if enabled, let line = statusLine { Text(line).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                Toggle("同时发送屏幕截图里的文字", isOn: $screenText)
                    .onChange(of: screenText) { _, newValue in model.jev?.setScreenText(newValue); refreshStatus() }
                Text("开启后，会把截图识别出的文字（先去掉邮箱和 6 位以上的数字，最多 1200 字）一并发送到下面的服务，用于判断拿不准的内容和没有标题的 AI 应用画面。需要先开启上面的开关才会生效；默认关闭。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("服务") {
                TextField("地址", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitFields)
                HStack {
                    // Never shows the stored key; typing replaces it.
                    SecureField(hasStoredKey ? String(localized: "已保存 · 输入新密钥可替换") : String(localized: "API 密钥"), text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveKey() }
                    if hasStoredKey {
                        Button("移除密钥", role: .destructive) { removeKey() }
                    }
                }
                if let apiKeyStatus {
                    Text(apiKeyStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("费用") {
                HStack {
                    Text("每月上限（美元）")
                    Spacer()
                    TextField("", text: $cap).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 80)
                        .onSubmit(commitFields)
                }
                if let jev = model.jev {
                    Text("本月已用 $\(String(format: "%.2f", jev.monthSpend)) / 上限 $\(String(format: "%.2f", jev.monthlyCap))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("到上限后 Jev 暂停，已有的判断继续生效；下个月自动恢复。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            enabled = model.settings.jevEnabled
            screenText = model.settings.jevScreenText
            endpoint = model.settings.jevEndpoint
            cap = Self.format(model.settings.jevMonthlyCap)
            hasStoredKey = model.jev?.hasKey ?? false
            refreshStatus()
        }
        // Switching tabs must not drop what was typed.
        .onDisappear(perform: commitFields)
    }

    /// Checked in this order: no run has been blocked by the cap before a
    /// network failure is reported.
    private var statusLine: String? {
        guard let status else { return nil }
        if status.pausedAtCap { return String(localized: "已到本月上限，暂停判断 · 已判断 \(status.classified) 项，\(status.queued) 项排队") }
        if status.offline { return String(localized: "连不上服务，稍后重试 · 已判断 \(status.classified) 项，\(status.queued) 项排队") }
        return String(localized: "已判断 \(status.classified) 项，\(status.queued) 项排队")
    }

    private func refreshStatus() { status = try? model.jev?.status() }

    static func format(_ value: Double) -> String { String(format: "%g", value) }

    /// Parses a cap typed by the user; nil when it is not a non-negative number.
    static func parseCap(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
    }

    private func commitFields() {
        if endpoint != model.settings.jevEndpoint { model.settings.setJevEndpoint(endpoint) }
        if let value = Self.parseCap(cap), value != model.settings.jevMonthlyCap {
            model.settings.setJevMonthlyCap(value)
            model.jev?.nudge()
        } else {
            cap = Self.format(model.settings.jevMonthlyCap)
        }
    }

    /// An empty field is not a request to erase the key; 移除密钥 is.
    private func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try Keychain.set(key, account: JevService.apiKeyAccount)
            apiKeyInput = ""
            hasStoredKey = true
            apiKeyStatus = String(localized: "已保存")
        } catch {
            apiKeyStatus = String(localized: "保存失败：\(error.localizedDescription)")
        }
    }

    private func removeKey() {
        Keychain.delete(account: JevService.apiKeyAccount)
        hasStoredKey = false
        apiKeyStatus = String(localized: "已移除，判断会停止")
        if enabled { enabled = false }
    }
}
