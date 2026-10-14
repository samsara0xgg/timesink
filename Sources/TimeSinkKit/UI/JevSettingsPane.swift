import SwiftUI

/// Jev classification, default off. The API key never touches the database;
/// it lives in the Keychain under `JevService.apiKeyAccount`. Endpoint, pinned
/// model id and monthly cap are ordinary settings.
struct JevSettingsPane: View {
    let model: AppModel

    @State private var enabled = false
    @State private var screenText = false
    @State private var endpoint = ""
    @State private var jevModel = ""
    @State private var cap = ""
    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var apiKeyStatus: String?
    @State private var status: JevService.Status?
    @FocusState private var keyFocused: Bool

    @State private var advancedOpen = false
    @State private var keyError: String?
    /// The answer of the last key test, and whether it was good news.
    @State private var keyCheck: String?
    @State private var keyCheckOK = false
    @State private var checkingKey = false

    /// Where an OpenRouter key is made, and credits bought.
    static let keysPage = URL(string: "https://openrouter.ai/keys")!

    var body: some View {
        Form {
            Section {
                Toggle("用 Jev 给每段使用时间判断分类", isOn: $enabled)
                    .disabled(!hasStoredKey && !enabled)
                    .onChange(of: enabled) { _, newValue in model.jev?.setEnabled(newValue); refreshStatus() }
                if !hasStoredKey && !enabled {
                    Text("先在下面保存 API 密钥，才能开启。").font(.note).foregroundStyle(Design.warning)
                    keyField
                }
                if hasStoredKey {
                    HStack {
                        Label("API 密钥已保存", systemImage: "checkmark.circle.fill").font(.note).foregroundStyle(Design.live)
                        Spacer()
                        Button("测试密钥") { testKey() }.disabled(checkingKey)
                    }
                    if let keyCheck {
                        Text(keyCheck).font(.note).foregroundStyle(keyCheckOK ? Design.ink2 : Design.alert)
                    }
                }
                Link("在 OpenRouter 创建 API 密钥或充值", destination: Self.keysPage).font(.note)
                if enabled, let jev = model.jev {
                    if let line = statusLine { Text(line).font(.note).foregroundStyle(Design.ink2) }
                    if let lastRunAt = status?.lastRunAt {
                        Text("上次运行 \(Self.relative(lastRunAt))").font(.note).foregroundStyle(Design.ink2)
                    }
                    if let status {
                        Text("本月 \(status.verdictsThisMonth) 项判断").font(.note).foregroundStyle(Design.ink2)
                    }
                    Text(Self.spendLine(spend: jev.monthSpend, cap: jev.monthlyCap)).font(.note).foregroundStyle(Design.ink2)
                    if let n = status?.toConfirm, n > 0 {
                        HStack {
                            Text("\(n) 项待确认").font(.note).foregroundStyle(Design.ink2)
                            Spacer()
                            Button("去分类页查看") { model.sidebarSelection = .organization }
                        }
                    }
                }
                DisclosureGroup("会发送哪些内容") {
                    Text("每段使用时间会向下面的服务发送这些内容，不会发送屏幕截图本身：")
                        .font(.note).foregroundStyle(Design.ink2)
                    ForEach(JevService.sentFields, id: \.self) { Text("· \($0)").font(.note).foregroundStyle(Design.ink2) }
                    Text("网址、窗口标题和文档名发出前会去掉邮箱、电话和卡号等长数字，以及 API 密钥和令牌。")
                        .font(.note).foregroundStyle(Design.ink2)
                }
                .font(.note)
            }
            Section {
                Toggle("同时发送屏幕截图里的文字", isOn: $screenText)
                    .disabled(!enabled)
                    .onChange(of: screenText) { _, newValue in model.jev?.setScreenText(newValue); refreshStatus() }
                Text("会发送截图识别出的文字（已去掉邮箱、6 位以上数字和 API 密钥、令牌，最多 1200 字），用于判断拿不准的内容。需先开启上面的开关；默认关闭。")
                    .font(.note).foregroundStyle(Design.ink2)
            }
            Section("费用") {
                HStack {
                    Text("每月上限（美元）")
                    Spacer()
                    TextField("", text: $cap).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 80)
                        .onSubmit(commitFields)
                }
                Text("到上限后 Jev 暂停，已有的判断继续生效；下个月自动恢复。").font(.note).foregroundStyle(Design.ink2)
            }
            Section {
                DisclosureGroup("高级", isExpanded: $advancedOpen) {
                    TextField("地址", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitFields)
                    TextField("模型", text: $jevModel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitFields)
                    if hasStoredKey { keyField }
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, 12, for: .scrollContent)
        .onAppear {
            enabled = model.settings.jevEnabled
            screenText = model.settings.jevScreenText
            endpoint = model.settings.jevEndpoint
            jevModel = model.settings.jevModel
            cap = Self.format(model.settings.jevMonthlyCap)
            hasStoredKey = model.jev?.hasKey ?? false
            refreshStatus()
        }
        // Switching tabs must not drop what was typed.
        .onDisappear(perform: commitFields)
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Never shows the stored key; typing replaces it.
                SecureField(hasStoredKey ? String(localized: "已保存 · 输入新密钥可替换") : String(localized: "API 密钥"), text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onSubmit { saveKey() }
                    .onChange(of: keyFocused) { _, focused in if !focused { saveKey() } }
                    .onChange(of: apiKeyInput) { _, _ in keyError = nil }
                if apiKeyStatus == String(localized: "已保存") {
                    Label("已保存", systemImage: "checkmark").font(.note).foregroundStyle(Design.live)
                }
                if hasStoredKey {
                    Button("移除密钥", role: .destructive) { removeKey() }
                }
            }
            if let keyError { Text(keyError).font(.note).foregroundStyle(Design.alert) }
            else if let apiKeyStatus, apiKeyStatus != String(localized: "已保存") {
                Text(apiKeyStatus).font(.note).foregroundStyle(Design.ink2)
            }
        }
    }

    static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    /// "本月 $0.10 / $1".
    static func spendLine(spend: Double, cap: Double) -> String {
        String(localized: "本月 $\(String(format: "%.2f", spend)) / $\(format(cap))")
    }

    /// Checked in this order: no run has been blocked by the cap before a
    /// network failure is reported.
    private var statusLine: String? {
        guard let status else { return nil }
        if status.pausedAtCap { return String(localized: "已到本月上限，暂停判断 · 已判断 \(status.classified) 项，\(status.queued) 项排队") }
        // A bad key, no credits, a wrong model or address, and the service being down each read differently.
        if let problem = status.problem { return String(localized: "\(problem.message) · 已判断 \(status.classified) 项，\(status.queued) 项排队") }
        return String(localized: "已判断 \(status.classified) 项，\(status.queued) 项排队")
    }

    private func refreshStatus() { status = try? model.jev?.status() }

    static func format(_ value: Double) -> String { String(format: "%g", value) }

    /// Parses a cap typed by the user; nil when it is not a non-negative number.
    static func parseCap(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
    }

    private func commitFields() {
        let changed = endpoint != model.settings.jevEndpoint || jevModel.trimmingCharacters(in: .whitespaces) != model.settings.jevModel
        if endpoint != model.settings.jevEndpoint { model.settings.setJevEndpoint(endpoint) }
        if jevModel != model.settings.jevModel { model.settings.setJevModel(jevModel) }
        jevModel = model.settings.jevModel
        // A corrected model or address is tried now, not after the backoff a refusal started.
        if changed { model.jev?.nudge() }
        if let value = Self.parseCap(cap), value != model.settings.jevMonthlyCap {
            model.settings.setJevMonthlyCap(value)
            model.jev?.nudge()
        } else {
            cap = Self.format(model.settings.jevMonthlyCap)
        }
    }

    /// Outcome of saving the typed key; never carries the key itself.
    enum KeySave: Equatable { case saved, empty, invalid, failed(String) }

    /// An empty field is not a request to erase the key; 移除密钥 is.
    static func commitKey(_ input: String, set: (String) throws -> Void) -> KeySave {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .empty }
        guard key.hasPrefix("sk-or-") else { return .invalid }
        do { try set(key); return .saved } catch { return .failed(error.localizedDescription) }
    }

    /// Runs on Return and on focus loss, so a filled field is never left unsaved.
    private func saveKey() {
        switch Self.commitKey(apiKeyInput, set: { try Keychain.set($0, account: JevService.apiKeyAccount) }) {
        case .empty: break
        case .invalid: keyError = String(localized: "这不像 OpenRouter 密钥：应以 sk-or- 开头。")
        case .saved:
            apiKeyInput = ""
            hasStoredKey = model.jev?.hasKey ?? true
            apiKeyStatus = String(localized: "已保存")
            keyError = nil
            keyCheck = nil
            model.jev?.nudge()
        case .failed(let message):
            apiKeyStatus = String(localized: "保存失败：\(message)")
        }
    }

    /// Asks OpenRouter about the stored key (a typed one is saved first). The
    /// call is free; it tells a bad key from a good one and shows what the key
    /// has spent and may still spend.
    private func testKey() {
        saveKey()
        // A typed key that could not be saved is not silently swapped for the stored one.
        guard apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = Keychain.get(account: JevService.apiKeyAccount), !key.isEmpty else { return }
        let endpoint = model.settings.jevEndpoint
        checkingKey = true
        keyCheck = nil
        Task { @MainActor in
            do {
                let info = try await JevClient.checkKey(endpoint: endpoint, apiKey: key)
                keyCheck = Self.keyLine(info)
                keyCheckOK = !info.isFreeTier
            } catch {
                keyCheck = Self.keyErrorLine(error)
                keyCheckOK = false
            }
            checkingKey = false
        }
    }

    /// "密钥有效 · 已用 $0.12，额度还剩 $4.88".
    static func keyLine(_ info: JevKeyInfo) -> String {
        if info.isFreeTier { return String(localized: "密钥有效，但这个 OpenRouter 账户还没有充值过；Jev 需要账户里有余额") }
        let used = String(format: "%.2f", info.usage)
        guard let limit = info.limit else { return String(localized: "密钥有效 · 已用 $\(used)，密钥没有额度上限") }
        let left = String(format: "%.2f", info.limitRemaining ?? max(0, limit - info.usage))
        return String(localized: "密钥有效 · 已用 $\(used)，额度还剩 $\(left)")
    }

    /// An invalid key (401/403), no credits (402), a wrong address (400/404) and
    /// the service being down each read differently.
    static func keyErrorLine(_ error: any Error) -> String {
        if let jevError = error as? JevError, case .badAnswer = jevError { return JevProblem.badModelOrEndpoint.message }
        return JevProblem(error)?.message ?? error.localizedDescription
    }

    private func removeKey() {
        Keychain.delete(account: JevService.apiKeyAccount)
        hasStoredKey = false
        keyCheck = nil
        apiKeyStatus = String(localized: "已移除，判断会停止")
        if enabled { enabled = false }
    }
}
