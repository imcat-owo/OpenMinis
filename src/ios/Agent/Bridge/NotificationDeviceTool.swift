import Foundation
import BridgeCore

/// 通知工具（合并第 19 条）：接 NativeOffloads 的 `apple-notification` 现成实现。
/// 子命令：pending / delivered / settings / schedule / cancel。
enum NotificationDeviceTool {
    static let toolName = "device_notification"
    static let commandName = "apple-notification"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "本地通知：查看或安排手机本地通知提醒",
                detail: """
                    参数 action：pending 看待触发的通知，delivered 看已送达的，settings 看通知授权状态，
                    schedule 安排一条本地通知（title/body 至少给一个；时间给 after 秒数或 at ISO 时间，
                    repeat=true 为重复提醒，action_spec 可带交互按钮，格式 "按钮名:id" 逗号分隔），
                    cancel 取消（id 指定一条，或 all=true 全部取消）。
                    """,
                keywords: ["通知", "提醒", "闹钟提醒", "notification", "schedule", "定时提醒"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["pending","delivered","settings","schedule","cancel"],"description":"动作"},
                      "title":{"type":"string","description":"schedule 的通知标题"},
                      "body":{"type":"string","description":"schedule 的通知正文"},
                      "after":{"type":"integer","description":"schedule：多少秒后触发"},
                      "at":{"type":"string","description":"schedule：ISO 时间，如 2026-10-01T09:00:00"},
                      "repeat":{"type":"boolean","description":"schedule：是否重复（配合 at 为每天该时刻，配合 after 为每 N 秒、最短 60）"},
                      "action_spec":{"type":"string","description":"schedule：交互按钮，如 Continue:continue,Stop:stop"},
                      "id":{"type":"string","description":"cancel：要取消的通知标识"},
                      "all":{"type":"boolean","description":"cancel：true 时取消全部待触发通知"}},
                     "required":["action"]}
                    """#
            )
        ) { arguments in
            let action = arguments.string("action") ?? ""
            var tokens: [String] = [action]
            switch action {
            case "pending", "delivered", "settings":
                break
            case "schedule":
                if arguments.string("title") == nil, arguments.string("body") == nil {
                    return ToolOutput(
                        text: "参数不对：schedule 需要至少给 title（标题）或 body（正文）一个。",
                        isError: true)
                }
                if arguments.int("after") == nil, arguments.string("at") == nil {
                    return ToolOutput(
                        text: "参数不对：schedule 需要给时间：after（多少秒后）或 at（ISO 时间）至少一个。",
                        isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--title", from: arguments, key: "title")
                OffloadToolRunner.appendString(&tokens, flag: "--body", from: arguments, key: "body")
                OffloadToolRunner.appendInt(&tokens, flag: "--after", from: arguments, key: "after")
                OffloadToolRunner.appendString(&tokens, flag: "--at", from: arguments, key: "at")
                OffloadToolRunner.appendSwitch(&tokens, flag: "--repeat", from: arguments, key: "repeat")
                OffloadToolRunner.appendString(&tokens, flag: "--action", from: arguments, key: "action_spec")
            case "cancel":
                if arguments.string("id") == nil, arguments.bool("all") != true {
                    return ToolOutput(
                        text: "参数不对：cancel 需要给 id（通知标识）或 all=true（全部取消）。",
                        isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--id", from: arguments, key: "id")
                OffloadToolRunner.appendSwitch(&tokens, flag: "--all", from: arguments, key: "all")
            default:
                return ToolOutput(
                    text: "参数不对：action 只能是 pending / delivered / settings / schedule / cancel。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 30)
        }
    }
}
