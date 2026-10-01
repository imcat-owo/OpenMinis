import Foundation
import Security
import UIKit
import BridgeCore

/// 报问题工具（合并第 21 条）：主人在桥里张嘴说哪里有问题，小管家把
/// 问题连同当时情况和相关日志打包，POST 到 GitHub 仓库
/// imcat-owo/OpenMinis 的 Issues，不用填表。
///
/// 执行端整个在 App 侧（本文件），不进 BridgeCore 内核：内核只管调度，
/// 网络与令牌都是宿主的事。敏感级（permission: .sensitive）——这是往
/// 外发东西，调度层未带主人确认标记时不会执行到这里（与第 19 条
/// 相册删除同款）。
///
/// 脱敏红线：令牌只进 Authorization 请求头，绝不进 Issue 正文、
/// 绝不进日志、绝不进报错文案。往外发的正文只有三样：主人原话、
/// 版本/时间这类环境信息、已脱敏的共享事件日志片段。
enum ReportIssueTool {
    static let toolName = "report_issue"
    static let repoFullName = "imcat-owo/OpenMinis"
    static let issuesEndpoint = "https://api.github.com/repos/imcat-owo/OpenMinis/issues"

    private static let logger = AppLogger(category: "BridgeReportIssue")

    static func register(into registry: ToolRegistry, steward: Steward) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "报问题：把 App 的问题连同当时情况打包发到 GitHub 问题列表",
                detail: """
                    主人说 App 哪里有问题、哪里不好用时用这个工具：把问题打包发到 \
                    GitHub 仓库 \(repoFullName) 的 Issues，主人不用填表。
                    参数 title：一句话问题标题（必填，简短说清是什么问题）。
                    参数 detail：主人的原话描述（可选，尽量原样转述，别改写、别脑补）。
                    工具会自动附上当时情况（App 版本、系统版本、当前时间、小管家\
                    当时在忙的任务）和最近的共享事件日志片段，不用再另外传。
                    这是往外发东西的敏感动作，执行前必须经主人确认。
                    """,
                keywords: ["报问题", "反馈", "问题", "毛病", "bug", "issue", "报错", "故障", "不好用", "report"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "title":{"type":"string","description":"一句话问题标题"},
                      "detail":{"type":"string","description":"主人的原话描述（可选）"}},
                     "required":["title"]}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
            guard let rawTitle = arguments.string("title") else {
                return ToolOutput(
                    text: "参数不对：需要给 title（一句话说清是什么问题）。",
                    isError: true)
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return ToolOutput(
                    text: "参数不对：title 是空的，需要一句话说清是什么问题。",
                    isError: true)
            }
            let detail = arguments.string("detail")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return await submit(
                title: String(title.prefix(200)),
                detail: (detail?.isEmpty == false) ? detail : nil,
                steward: steward)
        }
    }

    // MARK: - 执行：组装正文 → POST GitHub Issues

    private static func submit(title: String, detail: String?, steward: Steward) async -> ToolOutput {
        // 未填令牌不许假装成功：回明确提示，让主人先去设置页填。
        guard let token = BridgeGitHubTokenStore.load(), !token.isEmpty else {
            return ToolOutput(
                text: """
                    还没法发：GitHub 报问题令牌还没填。请先到 设置 > 桥·对外连接 > \
                    「报问题到 GitHub」里粘贴令牌——需要一个对 \(repoFullName) 有 \
                    Issues 写权限的 fine-grained PAT（个人访问令牌），填好后我再发。
                    """,
                isError: true)
        }

        let body = await composeBody(title: title, detail: detail, steward: steward)

        var request = URLRequest(url: URL(string: issuesEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        // 令牌只在这里用：只进 Authorization 头，不进正文/日志/报错。
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["title": title, "body": body])
        } catch {
            return ToolOutput(text: "发送失败：问题内容打包出错，没能发出去。", isError: true)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // 网络层错误描述不含请求头，不会带出令牌。
            logger.warning("GitHub 发 Issue 网络失败：\(error.localizedDescription)")
            return ToolOutput(
                text: "发送失败：网络连不上 GitHub（\(error.localizedDescription)）。请确认网络正常后再让我重发。",
                isError: true)
        }
        guard let http = response as? HTTPURLResponse else {
            return ToolOutput(text: "发送失败：GitHub 没有回正常的响应，请稍后再让我重发。", isError: true)
        }

        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if http.statusCode == 201,
           let number = parsed?["number"] as? Int,
           let htmlURL = parsed?["html_url"] as? String {
            // 成功留痕：只记编号和链接，绝不记令牌。
            SharedEventLog.shared.emit(
                event: "bridge.issue_reported",
                summary: "问题已发到 GitHub：Issue #\(number) \(htmlURL)")
            return ToolOutput(text: """
                已经把问题发到 GitHub 了。
                Issue 编号：#\(number)
                链接：\(htmlURL)
                请把编号和链接转述给主人。
                """)
        }

        if http.statusCode == 201 {
            // 发成功了但回执没解析出编号/链接：如实说，别误导重发造成重复。
            SharedEventLog.shared.emit(
                event: "bridge.issue_reported",
                summary: "问题已发到 GitHub（回执未解析出编号）")
            return ToolOutput(text: "已经把问题发到 GitHub 了（GitHub 回了成功，但回执里没解析出编号和链接，请到仓库 \(repoFullName) 的 Issues 列表里看最新一条）。")
        }

        logger.warning("GitHub 发 Issue 失败 status=\(http.statusCode)")
        let githubMessage = parsed?["message"] as? String
        return ToolOutput(
            text: failureText(statusCode: http.statusCode, githubMessage: githubMessage),
            isError: true)
    }

    /// 组装 Issue 正文。只有三部分：主人原话、当时情况（版本/时间/
    /// 小管家在忙什么）、最近共享事件日志片段。日志落盘时已脱敏，
    /// 这里再限长；任何情况下都不附令牌/口令。
    private static func composeBody(title: String, detail: String?, steward: Steward) async -> String {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let appBuild = info?["CFBundleVersion"] as? String ?? "?"

        let timeFormatter = ISO8601DateFormatter()
        timeFormatter.formatOptions = [.withInternetDateTime]
        timeFormatter.timeZone = TimeZone.current
        let nowText = timeFormatter.string(from: Date())

        // 小管家当时在忙什么（排除正在执行的 report_issue 自己）。
        let otherTasks = await steward.activeTaskSummaries()
            .filter { $0.toolName != toolName }
        let taskText: String
        if otherTasks.isEmpty {
            taskText = "当时没有其他任务在跑"
        } else {
            taskText = otherTasks.map { task in
                let name = task.toolName ?? "未定工具"
                let instruction = String(task.instruction.prefix(80))
                return "\(name)：\(instruction)"
            }.joined(separator: "；")
        }

        let logLines = SharedEventLog.shared.recentEntries(limit: 20)
        let logText = logLines.isEmpty
            ? "（暂无记录）"
            : String(logLines.joined(separator: "\n").prefix(3000))

        var sections: [String] = []
        sections.append("## 主人反馈的问题")
        sections.append(detail.map { String($0.prefix(4000)) } ?? title)
        sections.append("## 当时情况")
        sections.append("""
            - 时间：\(nowText)
            - App 版本：\(appVersion)（build \(appBuild)）
            - 系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)（\(UIDevice.current.model)）
            - 小管家当时在忙：\(taskText)
            """)
        sections.append("## 最近的共享事件日志")
        sections.append("```\n\(logText)\n```")
        sections.append("（由桥内「报问题」自动打包发送，正文不含任何令牌/口令。）")
        return sections.joined(separator: "\n\n")
    }

    /// GitHub 状态码 → 中文人话。GitHub 原话（message 字段）只在需要
    /// 定位时附上——那是 GitHub 的公开报错，不含令牌。
    private static func failureText(statusCode: Int, githubMessage: String?) -> String {
        let suffix = githubMessage.map { "（GitHub 原话：\($0)）" } ?? ""
        switch statusCode {
        case 401:
            return "发送失败：令牌不对，或者已经失效了（GitHub 回 401）。请到 设置 > 桥·对外连接 > 「报问题到 GitHub」里重新粘贴一个有效的令牌，再让我重发。"
        case 403:
            return "发送失败：这把令牌没有往 \(repoFullName) 发问题的权限（GitHub 回 403）。请确认令牌是只给这个仓库、带 Issues 读写权限的 fine-grained PAT。\(suffix)"
        case 404:
            return "发送失败：仓库找不到，或者这把令牌看不到这个仓库（GitHub 回 404）。目标仓库是 \(repoFullName)，请确认生成令牌时选对了仓库。"
        case 422:
            return "发送失败：GitHub 觉得内容有问题、拒绝接收（422）。\(suffix)"
        default:
            return "发送失败：GitHub 回了 \(statusCode)。\(suffix)请稍后再让我重发。"
        }
    }
}

// MARK: - 报问题令牌的钥匙串存取
//
// 专用条目：kSecClassGenericPassword，service "bridge.github"，
// account "issue-token"。写法沿用 BridgeRelayTokenStore 的仓内现成
// 套路：不可同步（不走 iCloud）、AfterFirstUnlock 可读。
// 令牌只存钥匙串、不进 UserDefaults、不进日志；界面只显示已填/未填。
enum BridgeGitHubTokenStore {
    static let service = "bridge.github"
    static let account = "issue-token"

    private static let log = AppLogger(category: "BridgeGitHubToken")

    /// 保存令牌。空白视为清除（与仓内其他 secret 存储同口径）。
    static func save(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete()
            return
        }
        keychainSet(Data(trimmed.utf8))
    }

    /// 读令牌。取不到（没填 / 钥匙串异常）返回 nil；调用方据此提示
    /// 「先去设置页填令牌」，不要拿空串去撞 GitHub。
    static func load() -> String? {
        keychainGet().flatMap { String(data: $0, encoding: .utf8) }
    }

    static var hasToken: Bool {
        load().map { !$0.isEmpty } ?? false
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Keychain primitives（与 BridgeRelayTokenStore 同形）

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
            // 只记状态码，绝不记令牌内容。
            log.error("[Keychain] github issue token save failed status=\(status)")
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
