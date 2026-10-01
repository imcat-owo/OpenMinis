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

    // MARK: - 主人打断（第 20 条）

    /// 小管家当前在跑/排队的任务（设置页展示「正在干什么」用）。
    func activeStewardTasks() async -> [StewardTaskSummary] {
        await steward.activeTaskSummaries()
    }

    /// 主人打断：停掉在跑与排队的全部任务。每个被打断的任务都会以
    /// 「主人打断」专属文案收尾回给正在等结果的外部 AI；同时逐个写进
    /// 跨会话共享事件日志（刺 3），其他会话能看到主人打断过外部任务。
    @discardableResult
    func interruptStewardTasksByOwner() async -> [StewardTaskSummary] {
        let tasks = await steward.activeTaskSummaries()
        for task in tasks {
            await steward.interruptByOwner(task.id)
            let instruction = String(task.instruction.prefix(80))
            SharedEventLog.shared.emit(
                event: "bridge.task_interrupted",
                summary: "主人打断了小管家任务（工具：\(task.toolName ?? "未定")，指令：\(instruction)）",
                sessionId: task.id.uuidString)
        }
        return tasks
    }
}
