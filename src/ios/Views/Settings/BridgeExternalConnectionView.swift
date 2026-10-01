import SwiftUI

/// 「桥·对外连接」设置页（合并第 17、18(a) 条的设置 UI 统一在此）：
///
///   ① 「MCP 对外服务」开关 —— 驱动 BridgeExternalMCPService 起/停；
///      开关值直接读持久化的期望状态（BridgeRelayPreferences，
///      五-3 唯一事实源），页面不自己再存一份；关它时中继同步关
///      （中继靠本地服务转发，服务关了中继必然断），开中继时它
///      同步亮——两个开关永远同源，不再出现「显示关着、服务却
///      被下一个转发请求偷偷拉起来」的假象；
///   ② 「中继连接」开关 —— 开 = 先起本地对外服务、再连 Cloudflare 中继；
///   ③ 中继地址输入框（host，存 UserDefaults）；
///   ④ 口令安全输入框（默认遮住，只存 iOS 钥匙串，见 BridgeRelayTokenStore）；
///   ⑤ 中继状态行（在线 / 离线 / 连接中 / 口令错误）；
///   ⑥ 「小管家」状态行 + 打断按钮（第 20 条）：服务开着时显示小管家
///      正在执行的任务，有任务在跑/排队时可一键打断，外部 AI 会收到
///      「主人打断」专属报错；
///   ⑦ 「报问题到 GitHub」区（第 21 条）：报问题令牌录入——只显示
///      已填/未填、不回显明文，令牌只存钥匙串（BridgeGitHubTokenStore）。
///
/// 口令与完整中继地址不进日志；口令在界面上默认只以 •••• 出现，
/// 与本 App 其他凭据输入框（如 API Key）同一套交互：眼睛按钮才明文。
struct BridgeExternalConnectionView: View {
    @ObservedObject private var relay = BridgeRelayClient.shared

    @AppStorage(BridgeRelayPreferences.hostKey) private var host: String = ""
    @State private var tokenInput: String = ""
    @State private var showTokenPlaintext = false

    @State private var mcpStatusText: String = ""
    @State private var mcpError: String?

    /// 小管家当前任务状态（第 20 条）：页面在屏时轮询刷新。
    @State private var stewardStatusText: String = ""
    @State private var hasActiveStewardTask: Bool = false

    /// GitHub 报问题令牌（第 21 条）：输入框只收新令牌，已存的只显示
    /// 已填/未填，绝不把钥匙串里的明文读回界面。
    @State private var githubTokenInput: String = ""
    @State private var hasGitHubToken: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle(AppLocalized("MCP 对外服务"), isOn: Binding(
                    get: { BridgeRelayPreferences.externalMCPEnabled },
                    set: { setMCPExternal($0) }
                ))
                LabeledContent(AppLocalized("运行状态")) {
                    Text(mcpStatusText)
                        .foregroundStyle(.secondary)
                }
                if BridgeRelayPreferences.externalMCPEnabled {
                    LabeledContent(AppLocalized("小管家")) {
                        Text(stewardStatusText)
                            .foregroundStyle(.secondary)
                    }
                    if hasActiveStewardTask {
                        Button(role: .destructive) {
                            Task { await interruptSteward() }
                        } label: {
                            Text(AppLocalized("打断小管家"))
                        }
                    }
                }
            } header: {
                Text(AppLocalized("本地服务"))
            } footer: {
                Text(AppLocalized("在本机开一个 MCP 入口，只对外露出「搜」和「命令」两个口。局域网里的 AI 和下面的中继都经它进来。默认关。"))
            }

            Section {
                Toggle(AppLocalized("中继连接"), isOn: Binding(
                    get: { relay.isEnabled },
                    set: { setRelayEnabled($0) }
                ))
                LabeledContent(AppLocalized("状态")) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(relayStatusColor)
                            .frame(width: 8, height: 8)
                        Text(relayStatusText)
                            .foregroundStyle(relay.state == .authError ? Color.red : Color.secondary)
                    }
                }
                LabeledContent(AppLocalized("中继地址")) {
                    TextField("xxx.workers.dev", text: $host)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { applyConfigChange() }
                }
                tokenField
            } header: {
                Text(AppLocalized("中继连接"))
            } footer: {
                Text(AppLocalized("先填中继地址和口令，再打开中继连接；改完按回车生效。口令只存本机钥匙串，不会上传；中继只转手、不存任何内容。"))
            }

            Section {
                LabeledContent(AppLocalized("报问题令牌")) {
                    Text(hasGitHubToken ? AppLocalized("已填") : AppLocalized("未填"))
                        .foregroundStyle(.secondary)
                }
                SecureField(AppLocalized("粘贴令牌"), text: $githubTokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    // 这是 GitHub PAT（不是短信验证码），用 .password 语义才对。
                    .textContentType(.password)
                    .submitLabel(.done)
                    .onSubmit { saveGitHubToken() }
                if hasGitHubToken {
                    Button(role: .destructive) {
                        clearGitHubToken()
                    } label: {
                        Text(AppLocalized("清除报问题令牌"))
                    }
                }
            } header: {
                Text(AppLocalized("报问题到 GitHub"))
            } footer: {
                Text(AppLocalized("在桥里跟小管家说哪里有问题，它会把问题连同当时的情况打包发到 GitHub 仓库 imcat-owo/OpenMinis 的问题列表里，不用填表。发送需要一把令牌：在 GitHub 里生成一个 fine-grained 个人访问令牌（PAT），只选 imcat-owo/OpenMinis 这一个仓库、权限只给 Issues 的读写。令牌只存本机钥匙串，界面不回显，也不会发到别处。填好按回车保存。"))
            }
        }
        .navigationTitle(AppLocalized("桥·对外连接"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tokenInput = BridgeRelayTokenStore.load() ?? ""
            hasGitHubToken = BridgeGitHubTokenStore.hasToken
            relay.restoreFromPreferences()
            restoreMCPExternal()
        }
        // 小管家任务状态轮询：页面在屏时每 2 秒刷新一次，离屏自动停
        // （.task 随视图消失取消），不留后台计时器。
        .task {
            while !Task.isCancelled {
                await refreshStewardStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .alert(AppLocalized("MCP 对外服务启动失败"), isPresented: Binding(
            get: { mcpError != nil },
            set: { if !$0 { mcpError = nil } }
        )) {
            Button("OK") { mcpError = nil }
        } message: {
            Text(mcpError ?? "")
        }
    }

    // MARK: 口令输入（默认 SecureField 遮住；眼睛按钮切明文，与 AddProviderView 同款）

    private var tokenField: some View {
        LabeledContent(AppLocalized("口令")) {
            HStack(spacing: 8) {
                Group {
                    if showTokenPlaintext {
                        TextField("", text: $tokenInput)
                    } else {
                        SecureField("", text: $tokenInput)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // 与 API Key 字段同口径：.oneTimeCode 把这个凭据框排除在
                // AutoFill 密码配对之外，避免系统把别的字段当用户名栏。
                .textContentType(.oneTimeCode)
                .submitLabel(.done)
                .onSubmit { applyConfigChange() }

                Button {
                    showTokenPlaintext.toggle()
                } label: {
                    Image(systemName: showTokenPlaintext ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 状态映射

    private var relayStatusText: String {
        switch relay.state {
        case .online: return AppLocalized("在线")
        case .connecting: return AppLocalized("连接中")
        case .offline: return AppLocalized("离线")
        case .authError: return AppLocalized("口令错误")
        }
    }

    private var relayStatusColor: Color {
        switch relay.state {
        case .online: return .green
        case .connecting: return .orange
        case .offline: return .gray
        case .authError: return .red
        }
    }

    // MARK: 动作

    private func setMCPExternal(_ on: Bool) {
        if on {
            do {
                try BridgeExternalMCPService.shared.ensureRunning()
                BridgeRelayPreferences.externalMCPEnabled = true
            } catch {
                BridgeRelayPreferences.externalMCPEnabled = false
                mcpError = error.localizedDescription
            }
        } else {
            BridgeExternalMCPService.shared.stop()
            BridgeRelayPreferences.externalMCPEnabled = false
            // 五-3 同源：中继靠本地服务转发，服务关了中继必然断，
            // 中继开关同步关——不再留「服务显示关着、中继还连着、
            // 下一个请求又把服务偷偷拉起来」的两套状态。
            if relay.isEnabled {
                relay.setEnabled(false)
            }
        }
        refreshMCPStatus()
    }

    private func setRelayEnabled(_ on: Bool) {
        if on {
            // 先把输入框里的口令落钥匙串、地址落 UserDefaults，
            // 再让客户端去连——顺序反了会拿旧口令白撞一次中继。
            BridgeRelayTokenStore.save(tokenInput)
            BridgeRelayPreferences.host = host
            do {
                try BridgeExternalMCPService.shared.ensureRunning()
            } catch {
                mcpError = error.localizedDescription
                return // 本地服务都没起来，不开中继开关
            }
            // 五-3 同源：本地服务是为中继起的，对外服务开关（读的
            // 是同一份持久化状态）同步亮，不再显示关着。
            BridgeRelayPreferences.externalMCPEnabled = true
        }
        relay.setEnabled(on)
        refreshMCPStatus()
    }

    /// 地址/口令改完提交：先落盘，开着中继就用新配置重连。
    private func applyConfigChange() {
        BridgeRelayTokenStore.save(tokenInput)
        BridgeRelayPreferences.host = host
        if relay.isEnabled {
            relay.reconnect()
        }
    }

    /// App 重启后回到本页时：开关期望值是开、服务却没在跑，就补起一次。
    private func restoreMCPExternal() {
        if BridgeRelayPreferences.externalMCPEnabled, !BridgeExternalMCPService.shared.isRunning {
            do {
                try BridgeExternalMCPService.shared.ensureRunning()
            } catch {
                BridgeRelayPreferences.externalMCPEnabled = false
            }
        }
        refreshMCPStatus()
    }

    private func refreshMCPStatus() {
        let service = BridgeExternalMCPService.shared
        if service.isRunning {
            if let port = service.boundPort {
                mcpStatusText = AppLocalized("运行中 · 端口 \(port)")
            } else {
                mcpStatusText = AppLocalized("运行中")
            }
        } else {
            mcpStatusText = AppLocalized("未运行")
        }
    }

    // MARK: GitHub 报问题令牌（第 21 条）

    /// 保存新令牌：落钥匙串后立刻清空输入框，界面只留「已填」状态。
    private func saveGitHubToken() {
        let trimmed = githubTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        BridgeGitHubTokenStore.save(trimmed)
        githubTokenInput = ""
        hasGitHubToken = BridgeGitHubTokenStore.hasToken
    }

    private func clearGitHubToken() {
        BridgeGitHubTokenStore.delete()
        githubTokenInput = ""
        hasGitHubToken = false
    }

    // MARK: 小管家任务状态与打断（第 20 条）

    private func refreshStewardStatus() async {
        let tasks = await BridgeExternalMCPService.shared.activeStewardTasks()
        hasActiveStewardTask = !tasks.isEmpty
        guard let first = tasks.first else {
            stewardStatusText = AppLocalized("空闲")
            return
        }
        let name = first.toolName ?? "…"
        stewardStatusText = tasks.count > 1
            ? AppLocalized("正在执行：\(name)（另有 \(tasks.count - 1) 个排队）")
            : AppLocalized("正在执行：\(name)")
    }

    /// 主人打断：停掉在跑与排队的全部任务（外部 AI 会收到「主人打断」
    /// 专属报错），打完立刻刷新状态行。
    private func interruptSteward() async {
        _ = await BridgeExternalMCPService.shared.interruptStewardTasksByOwner()
        await refreshStewardStatus()
    }
}
