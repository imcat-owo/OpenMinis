import SwiftUI

/// 「桥·对外连接」设置页（合并第 17、18(a) 条的设置 UI 统一在此）：
///
///   ① 「MCP 对外服务」开关 —— 驱动 BridgeExternalMCPService 起/停；
///   ② 「中继连接」开关 —— 开 = 先起本地对外服务、再连 Cloudflare 中继；
///   ③ 中继地址输入框（host，存 UserDefaults）；
///   ④ 口令安全输入框（默认遮住，只存 iOS 钥匙串，见 BridgeRelayTokenStore）；
///   ⑤ 中继状态行（在线 / 离线 / 连接中 / 口令错误）。
///
/// 口令与完整中继地址不进日志；口令在界面上默认只以 •••• 出现，
/// 与本 App 其他凭据输入框（如 API Key）同一套交互：眼睛按钮才明文。
struct BridgeExternalConnectionView: View {
    @ObservedObject private var relay = BridgeRelayClient.shared

    @AppStorage(BridgeRelayPreferences.hostKey) private var host: String = ""
    @State private var tokenInput: String = ""
    @State private var showTokenPlaintext = false

    @State private var mcpExternalOn: Bool = BridgeRelayPreferences.externalMCPEnabled
    @State private var mcpStatusText: String = ""
    @State private var mcpError: String?

    var body: some View {
        Form {
            Section {
                Toggle(AppLocalized("MCP 对外服务"), isOn: Binding(
                    get: { mcpExternalOn },
                    set: { setMCPExternal($0) }
                ))
                LabeledContent(AppLocalized("运行状态")) {
                    Text(mcpStatusText)
                        .foregroundStyle(.secondary)
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
        }
        .navigationTitle(AppLocalized("桥·对外连接"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tokenInput = BridgeRelayTokenStore.load() ?? ""
            relay.restoreFromPreferences()
            restoreMCPExternal()
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
                mcpExternalOn = true
                BridgeRelayPreferences.externalMCPEnabled = true
            } catch {
                mcpExternalOn = false
                BridgeRelayPreferences.externalMCPEnabled = false
                mcpError = error.localizedDescription
            }
        } else {
            BridgeExternalMCPService.shared.stop()
            mcpExternalOn = false
            BridgeRelayPreferences.externalMCPEnabled = false
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
        }
        relay.setEnabled(on)
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
        if mcpExternalOn, !BridgeExternalMCPService.shared.isRunning {
            do {
                try BridgeExternalMCPService.shared.ensureRunning()
            } catch {
                mcpExternalOn = false
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
}
