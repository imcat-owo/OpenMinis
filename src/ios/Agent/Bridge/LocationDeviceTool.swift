import Foundation
import BridgeCore

/// 定位工具（合并第 19 条）：接 NativeOffloads 的 `apple-location` 现成实现。
/// 子命令：current（当前位置）/ geocode（经纬度→地址）/ forward（地址→经纬度）。
enum LocationDeviceTool {
    static let toolName = "device_location"
    static let commandName = "apple-location"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "定位：查手机当前位置，或在地址与经纬度之间换算",
                detail: """
                    参数 action：current 查当前 GPS 位置（默认，可带 accuracy：best/near/km），
                    geocode 把经纬度换成地址（需 lat、lng），forward 把地址换成经纬度（需 address）。
                    """,
                keywords: ["定位", "位置", "在哪", "经纬度", "地址", "location", "gps", "geocode", "坐标"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["current","geocode","forward"],"description":"动作，默认 current"},
                      "accuracy":{"type":"string","enum":["best","near","km"],"description":"current 的精度，默认 best"},
                      "lat":{"type":"number","description":"geocode 的纬度"},
                      "lng":{"type":"number","description":"geocode 的经度"},
                      "address":{"type":"string","description":"forward 要换算的地址文字"}},
                     "required":["action"]}
                    """#
            )
        ) { arguments in
            let action = arguments.string("action") ?? "current"
            var tokens: [String] = [action]
            switch action {
            case "current":
                OffloadToolRunner.appendString(&tokens, flag: "--accuracy", from: arguments, key: "accuracy")
            case "geocode":
                guard arguments.double("lat") != nil, arguments.double("lng") != nil else {
                    return ToolOutput(
                        text: "参数不对：geocode 需要同时给 lat（纬度）和 lng（经度）。",
                        isError: true)
                }
                OffloadToolRunner.appendDouble(&tokens, flag: "--lat", from: arguments, key: "lat")
                OffloadToolRunner.appendDouble(&tokens, flag: "--lng", from: arguments, key: "lng")
            case "forward":
                guard let address = arguments.string("address"), !address.isEmpty else {
                    return ToolOutput(
                        text: "参数不对：forward 需要给 address（要换算的地址文字）。",
                        isError: true)
                }
                tokens.append("--address")
                tokens.append(address)
            default:
                return ToolOutput(
                    text: "参数不对：action 只能是 current / geocode / forward。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 45)
        }
    }
}
