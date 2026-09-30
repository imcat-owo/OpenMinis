import Foundation
import BridgeCore

/// 「桥」小管家内核在 App 侧的组装点（合并第 16 条：内核搬入）。
///
/// 只负责按依赖顺序造出三件套：工具注册中心 → 小管家 → 会话管理，
/// 并把设备能力工具组（第 19 条，DeviceTools）挂进注册中心——注册是
/// 异步的（注册中心是 actor），组装时起一个任务完成，失败只记日志、
/// 不影响三件套本身。对外入口（CF 中转/局域网）开启是第 17、18 条的事，
/// 不在这里。本类目前只被对外服务（BridgeExternalMCPService）在用户
/// 于设置页开启时构造，App 现有行为零变化。
final class BridgeKernelAssembly {
    let registry: ToolRegistry
    let steward: Steward
    let sessionManager: MCPSessionManager

    private static let logger = AppLogger(category: "BridgeAssembly")

    init() {
        let registry = ToolRegistry()
        self.registry = registry
        let steward = Steward(registry: registry)
        self.steward = steward
        self.sessionManager = MCPSessionManager(registry: registry, steward: steward)

        Task {
            do {
                try await DeviceTools.registerAll(into: registry)
            } catch {
                Self.logger.error("设备能力工具注册失败：\(error)")
            }
        }
    }
}
