import Foundation
import BridgeCore

/// 通知工具（合并第 19 条）：接 NativeOffloads 的 `apple-notification` 现成实现。
/// 子命令：pending / delivered / settings / schedule / cancel。
///
/// 拆两个工具：`device_notification` 是查看与取消（pending / delivered /
/// settings / cancel），标准级；`device_notification_schedule` 只做安排
/// 本地通知——会在主人手机上弹出提醒、打扰主人，标敏感级，未经主人确认不执行。
enum NotificationDeviceTool {
    static let toolName = "device_notification"
    static let scheduleToolName = "device_notification_schedule"
    static let commandName = "apple-notification"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "本地通知：查看或取消手机本地通知",
                detail: """
                    参数 action：pending 看待触发的通知，delivered 看已送达的，settings 看通知授权状态，
                    cancel 取消（id 指定一条，或 all=true 全部取消）。
                    安排新通知请用 device_notification_schedule 工具（需主人确认）。
                    """,
                keywords: ["通知", "提醒", "notification", "取消提醒"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["pending","delivered","settings","cancel"],"description":"动作"},
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
                    text: "参数不对：action 只能是 pending / delivered / settings / cancel（安排通知请用 device_notification_schedule）。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 30)
        }

        // 安排通知：敏感级，调度层未带主人确认标记时不会执行到这里。
        try await registry.register(
            descriptor: ToolDescriptor(
                name: scheduleToolName,
                summary: "安排通知：在手机上安排一条本地通知提醒（敏感动作，需主人确认）",
                detail: """
                    安排一条本地通知。title/body 至少给一个；时间给 after（多少秒后）或 at（ISO 时间）至少一个，
                    repeat=true 为重复提醒（配合 at 为每天该时刻，配合 after 为每 N 秒、最短 60），
                    action_spec 可带交互按钮，格式 "按钮名:id" 逗号分隔。
                    会在主人手机上弹出提醒，执行前必须经主人确认。
                    查看/取消通知用 device_notification 工具。
                    """,
                keywords: ["安排通知", "定时提醒", "schedule 通知", "闹钟提醒", "notification schedule"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "title":{"type":"string","description":"通知标题"},
                      "body":{"type":"string","description":"通知正文"},
                      "after":{"type":"integer","description":"多少秒后触发"},
                      "at":{"type":"string","description":"ISO 时间，如 2026-10-01T09:00:00"},
                      "repeat":{"type":"boolean","description":"是否重复（配合 at 为每天该时刻，配合 after 为每 N 秒、最短 60）"},
                      "action_spec":{"type":"string","description":"交互按钮，如 Continue:continue,Stop:stop"}},
                     "required":[]}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
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
            var tokens: [String] = ["schedule"]
            OffloadToolRunner.appendString(&tokens, flag: "--title", from: arguments, key: "title")
            OffloadToolRunner.appendString(&tokens, flag: "--body", from: arguments, key: "body")
            OffloadToolRunner.appendInt(&tokens, flag: "--after", from: arguments, key: "after")
            OffloadToolRunner.appendString(&tokens, flag: "--at", from: arguments, key: "at")
            OffloadToolRunner.appendSwitch(&tokens, flag: "--repeat", from: arguments, key: "repeat")
            OffloadToolRunner.appendString(&tokens, flag: "--action", from: arguments, key: "action_spec")
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 30)
        }
    }
}
