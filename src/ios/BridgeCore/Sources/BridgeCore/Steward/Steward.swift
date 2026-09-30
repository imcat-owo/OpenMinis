import Foundation

/// 管家任务状态机：排队 → 派发 → 执行 → 清洗 → 完成，
/// 异常分支：失败（带原因）/ 已取消 / 超时熔断。终态不可再变。
public enum StewardState: Sendable, Equatable {
    case queued
    case dispatched(toolName: String)
    case executing(toolName: String)
    case cleaning
    case finished
    case failed(reason: String)
    case cancelled
    case timedOut

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled, .timedOut:
            return true
        case .queued, .dispatched, .executing, .cleaning:
            return false
        }
    }
}

/// 一次「命令」的入参。
public struct StewardRequest: Sendable {
    /// 自然语言指令（未点名工具时，管家拿它去注册中心搜索路由）。
    public var instruction: String
    /// 点名的工具（外部 AI 经「搜」选定后可点名）；nil = 管家智能路由。
    public var toolName: String?
    /// 给工具的参数（严格 JSON 对象）。
    public var arguments: StrictJSONObject
    /// 超时熔断秒数。
    public var timeoutSeconds: Double
    /// 敏感工具放行标记：主人确认过才为 true。
    public var sensitiveApproved: Bool

    public init(
        instruction: String,
        toolName: String? = nil,
        arguments: StrictJSONObject = StrictJSONObject(raw: [:]),
        timeoutSeconds: Double = 30,
        sensitiveApproved: Bool = false
    ) {
        self.instruction = instruction
        self.toolName = toolName
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.sensitiveApproved = sensitiveApproved
    }
}

/// 任务结果：终态 + 实际用的工具 + 原文与清洗后文本（原文保留备查，
/// 对外只回清洗后的高密度结果）。
public struct StewardResult: Sendable, Equatable {
    public var id: UUID
    public var state: StewardState
    public var toolName: String?
    public var rawText: String?
    public var cleanedText: String?
    public var isError: Bool

    public init(
        id: UUID, state: StewardState, toolName: String?,
        rawText: String?, cleanedText: String?, isError: Bool
    ) {
        self.id = id
        self.state = state
        self.toolName = toolName
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.isError = isError
    }
}

/// 小管家调度：串行队列接单，逐个走完状态机。
///
/// - 队列：一台在跑时后面的排队，不并发抢工具；
/// - 取消：排队中的直接取消，运行中的取消其任务，收尾为 .cancelled；
/// - 超时熔断：执行与睡眠赛跑，先到者定性。熔断靠协作式取消——工具处理
///   函数必须响应 Task 取消（桥自己的工具都响应）；不理取消的工具会继续
///   占着队列直到自然结束，其结果被丢弃（这一条写死在语义里，不假装能强杀）。
/// - 错误：工具抛错/返回错误都收尾为 .failed，原因原文保留进结果，不吞。
public actor Steward {
    private let registry: ToolRegistry
    private let cleaner: ResultCleaner

    private var queue: [UUID] = []
    private var requests: [UUID: StewardRequest] = [:]
    private var results: [UUID: StewardResult] = [:]
    private var histories: [UUID: [StewardState]] = [:]
    private var waiters: [UUID: [CheckedContinuation<StewardResult, Never>]] = [:]
    private var runningID: UUID?
    private var runningTask: Task<Void, Never>?
    private var cancelRequested: Set<UUID> = []

    public init(registry: ToolRegistry, cleaner: ResultCleaner = ResultCleaner()) {
        self.registry = registry
        self.cleaner = cleaner
    }

    // MARK: - 提交与查询

    @discardableResult
    public func submit(_ request: StewardRequest) -> UUID {
        let id = UUID()
        requests[id] = request
        let initial = StewardResult(
            id: id, state: .queued, toolName: request.toolName,
            rawText: nil, cleanedText: nil, isError: false)
        results[id] = initial
        histories[id] = [.queued]
        queue.append(id)
        startNextIfIdle()
        return id
    }

    public func state(of id: UUID) -> StewardState? {
        results[id]?.state
    }

    public func result(of id: UUID) -> StewardResult? {
        results[id]
    }

    /// 任务的完整状态变迁史（审计日志的雏形：谁在何时走到哪一步都可查）。
    public func stateHistory(of id: UUID) -> [StewardState] {
        histories[id] ?? []
    }

    public func waitForCompletion(_ id: UUID) async -> StewardResult {
        if let result = results[id], result.state.isTerminal {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    /// 提交并等到终态，一步到位的便捷口（元工具「命令」走这里）。
    public func execute(_ request: StewardRequest) async -> StewardResult {
        let id = submit(request)
        return await waitForCompletion(id)
    }

    /// 取消任务：排队中的立刻收尾；运行中的标记并取消其任务，由运行流程收尾。
    public func cancel(_ id: UUID) {
        guard let result = results[id], !result.state.isTerminal else { return }
        cancelRequested.insert(id)
        if runningID == id {
            runningTask?.cancel()
        } else if queue.contains(id) {
            queue.removeAll { $0 == id }
            finish(
                id: id, state: .cancelled, toolName: result.toolName,
                rawText: nil, cleanedText: "任务已取消", isError: true)
        }
    }

    // MARK: - 内部流程

    private func startNextIfIdle() {
        guard runningID == nil, let next = queue.first else { return }
        queue.removeFirst()
        runningID = next
        guard let request = requests[next] else {
            runningID = nil
            return
        }
        runningTask = Task { [weak self] in
            await self?.run(id: next, request: request)
        }
    }

    private func run(id: UUID, request: StewardRequest) async {
        // —— 派发：定工具 ——
        let toolName: String
        if let explicit = request.toolName {
            toolName = explicit
        } else if let hit = await registry.search(request.instruction).first {
            toolName = hit.name
        } else {
            let reason = "找不到能处理这条指令的工具：\(request.instruction)"
            finish(
                id: id, state: .failed(reason: reason), toolName: nil,
                rawText: nil, cleanedText: reason, isError: true)
            completeRun(id: id)
            return
        }
        transition(id: id, to: .dispatched(toolName: toolName))

        // —— 派发校验：在册、启用、敏感权限 ——
        guard let descriptor = await registry.descriptor(for: toolName) else {
            let reason = "工具未在册：\(toolName)"
            finish(
                id: id, state: .failed(reason: reason), toolName: toolName,
                rawText: nil, cleanedText: reason, isError: true)
            completeRun(id: id)
            return
        }
        guard descriptor.isEnabled else {
            let reason = "工具已停用：\(toolName)"
            finish(
                id: id, state: .failed(reason: reason), toolName: toolName,
                rawText: nil, cleanedText: reason, isError: true)
            completeRun(id: id)
            return
        }
        if descriptor.permission == .sensitive, !request.sensitiveApproved {
            let reason = "工具 \(toolName) 是敏感操作，需要主人确认后才能执行"
            finish(
                id: id, state: .failed(reason: reason), toolName: toolName,
                rawText: nil, cleanedText: reason, isError: true)
            completeRun(id: id)
            return
        }

        // —— 执行（带超时熔断）——
        transition(id: id, to: .executing(toolName: toolName))
        let outcome = await executeWithTimeout(toolName: toolName, request: request)

        if cancelRequested.contains(id) {
            finish(
                id: id, state: .cancelled, toolName: toolName,
                rawText: nil, cleanedText: "任务已取消", isError: true)
            completeRun(id: id)
            return
        }

        switch outcome {
        case .output(let output) where !output.isError:
            transition(id: id, to: .cleaning)
            let cleaned = cleaner.clean(output.text)
            finish(
                id: id, state: .finished, toolName: toolName,
                rawText: output.text, cleanedText: cleaned, isError: false)
        case .output(let output):
            finish(
                id: id, state: .failed(reason: output.text), toolName: toolName,
                rawText: output.text, cleanedText: output.text, isError: true)
        case .threw(let message):
            finish(
                id: id, state: .failed(reason: message), toolName: toolName,
                rawText: nil, cleanedText: message, isError: true)
        case .timedOut:
            let message = "执行超时（超过 \(request.timeoutSeconds) 秒），已熔断"
            finish(
                id: id, state: .timedOut, toolName: toolName,
                rawText: nil, cleanedText: message, isError: true)
        case .cancelled:
            finish(
                id: id, state: .cancelled, toolName: toolName,
                rawText: nil, cleanedText: "任务已取消", isError: true)
        }
        completeRun(id: id)
    }

    private enum ExecutionOutcome: Sendable {
        case output(ToolOutput)
        case threw(String)
        case timedOut
        case cancelled
    }

    private func executeWithTimeout(
        toolName: String, request: StewardRequest
    ) async -> ExecutionOutcome {
        let registry = self.registry
        let arguments = request.arguments
        let timeout = request.timeoutSeconds
        return await withTaskGroup(of: ExecutionOutcome.self) { group in
            group.addTask {
                do {
                    let output = try await registry.invoke(name: toolName, arguments: arguments)
                    return .output(output)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .threw(String(describing: error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .threw("执行组没有产出结果")
            group.cancelAll()
            return first
        }
    }

    private func transition(id: UUID, to state: StewardState) {
        guard var result = results[id] else { return }
        result.state = state
        if case .dispatched(let name) = state {
            result.toolName = name
        }
        if case .executing(let name) = state {
            result.toolName = name
        }
        results[id] = result
        histories[id, default: []].append(state)
    }

    private func finish(
        id: UUID, state: StewardState, toolName: String?,
        rawText: String?, cleanedText: String?, isError: Bool
    ) {
        let result = StewardResult(
            id: id, state: state, toolName: toolName,
            rawText: rawText, cleanedText: cleanedText, isError: isError)
        results[id] = result
        histories[id, default: []].append(state)
        requests[id] = nil
        let pending = waiters.removeValue(forKey: id) ?? []
        for continuation in pending {
            continuation.resume(returning: result)
        }
    }

    private func completeRun(id: UUID) {
        if runningID == id {
            runningID = nil
            runningTask = nil
        }
        cancelRequested.remove(id)
        startNextIfIdle()
    }
}
