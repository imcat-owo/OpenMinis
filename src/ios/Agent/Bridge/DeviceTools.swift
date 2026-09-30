import Foundation
import BridgeCore

/// 设备能力工具组（合并第 19 条）：把 OpenMinis 已有的 apple-* 能力
/// 注册进桥的工具注册中心，对外经「搜」「命令」调度。
///
/// 一项能力一个文件（BluetoothDeviceTool / PhotosDeviceTool /
/// LocationDeviceTool / NotificationDeviceTool / ClipboardDeviceTool），
/// 每个文件的 `register(into:)` 照 FakeTools 的声明格式写；
/// 执行统一走 OffloadToolRunner 落到 NativeOffloads 的现成实现。
enum DeviceTools {
    static func registerAll(into registry: ToolRegistry) async throws {
        try await ClipboardDeviceTool.register(into: registry)
        try await LocationDeviceTool.register(into: registry)
        try await NotificationDeviceTool.register(into: registry)
        try await PhotosDeviceTool.register(into: registry)
    }
}
