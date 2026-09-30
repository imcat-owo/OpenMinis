import Foundation
import BridgeCore

/// 「桥」小管家内核在 App 侧的组装点（合并第 16 条：内核搬入）。
///
/// 只负责按依赖顺序造出三件套：工具注册中心 → 小管家 → 会话管理。
/// 工具往注册中心里挂是第 19 条的事，对外入口（CF 中转/局域网）开启
/// 是第 17、18 条的事，都不在这里。本类目前不被任何现有流程调用，
/// App 现有行为零变化；后续步骤从这里取内核实例接线。
final class BridgeKernelAssembly {
    let registry: ToolRegistry
    let steward: Steward
    let sessionManager: MCPSessionManager

    init() {
        let registry = ToolRegistry()
        self.registry = registry
        let steward = Steward(registry: registry)
        self.steward = steward
        self.sessionManager = MCPSessionManager(registry: registry, steward: steward)
    }
}
