import Foundation
import Security

// MARK: - 中继口令的钥匙串存取（合并第 18(a) 条）
//
// 协议 v1 约定：kSecClassGenericPassword，service "bridge.relay"，
// account "token"。口令由用户在设置页粘贴填入（本任务不生成口令），
// 只存钥匙串、不进 UserDefaults、不进日志、不进界面默认明文展示。
// 写法沿用 MCPOAuthController 的仓内现成套路：不可同步（不走 iCloud）、
// AfterFirstUnlock 可读（后台重连时也能取到）。

enum BridgeRelayTokenStore {
    static let service = "bridge.relay"
    static let account = "token"

    private static let log = AppLogger(category: "BridgeRelay")

    /// 保存口令。空白视为清除（与仓内其他 secret 存储同口径）。
    static func save(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete()
            return
        }
        keychainSet(Data(trimmed.utf8))
    }

    /// 读口令。取不到（没填 / 钥匙串异常）返回 nil；调用方据此提示
    /// 「口令错误 / 未配置」，不要拿空串去连——那只会白撞一次中继。
    static func load() -> String? {
        keychainGet().flatMap { String(data: $0, encoding: .utf8) }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Keychain primitives（与 MCPOAuthController 同形）

    private static func keychainSet(_ data: Data) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // 只记状态码，绝不记口令内容。
            log.error("[Keychain] relay token save failed status=\(status)")
        }
    }

    private static func keychainGet() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

// MARK: - 中继相关偏好（UserDefaults，非敏感部分）

/// 中继的非敏感配置：中继地址（host）与两个开关的期望状态。
/// 口令不在此列（只进钥匙串，见 BridgeRelayTokenStore）。
/// host 虽然不是秘密，但按协议约定同样不打进日志。
enum BridgeRelayPreferences {
    static let hostKey = "bridge.relay.host"
    static let relayEnabledKey = "bridge.relay.enabled"
    static let externalMCPEnabledKey = "bridge.externalMCP.enabled"

    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }

    static var relayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: relayEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: relayEnabledKey) }
    }

    static var externalMCPEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: externalMCPEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: externalMCPEnabledKey) }
    }
}
