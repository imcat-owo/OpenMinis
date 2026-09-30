import Foundation
import BridgeCore

/// 剪贴板工具（合并第 19 条）：接 NativeOffloads 的 `apple-clipboard` 现成实现。
/// 子命令：get / set / clear / status。
enum ClipboardDeviceTool {
    static let toolName = "device_clipboard"
    static let commandName = "apple-clipboard"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "剪贴板：读取或写入手机剪贴板里的文字",
                detail: """
                    参数 action：get 读剪贴板（默认），set 写入，clear 清空，status 看剪贴板里有什么类型的内容。
                    set 时 text 必填；get/set 可带 image（沙箱内图片路径）：get 是把剪贴板里的图片存到该路径，set 是把该路径的图片复制进剪贴板。
                    """,
                keywords: ["剪贴板", "粘贴", "复制", "clipboard", "pasteboard", "拷贝"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["get","set","clear","status"],"description":"动作，默认 get"},
                      "text":{"type":"string","description":"set 时要写入剪贴板的文字"},
                      "image":{"type":"string","description":"沙箱内图片路径，如 /var/minis/attachments/a.png"}},
                     "required":["action"]}
                    """#
            )
        ) { arguments in
            let action = arguments.string("action") ?? "get"
            var tokens: [String] = [action]
            switch action {
            case "get":
                OffloadToolRunner.appendString(&tokens, flag: "--image", from: arguments, key: "image")
            case "set":
                OffloadToolRunner.appendString(&tokens, flag: "--text", from: arguments, key: "text")
                OffloadToolRunner.appendString(&tokens, flag: "--image", from: arguments, key: "image")
                if arguments.string("text") == nil, arguments.string("image") == nil {
                    return ToolOutput(
                        text: "参数不对：set 需要给 text（要写入的文字）或 image（图片路径）至少一个。",
                        isError: true)
                }
            case "clear", "status":
                break
            default:
                return ToolOutput(
                    text: "参数不对：action 只能是 get / set / clear / status。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 30)
        }
    }
}
