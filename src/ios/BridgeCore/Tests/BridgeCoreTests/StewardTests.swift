import XCTest

@testable import BridgeCore

final class StewardTests: XCTestCase {

    private func makeSteward() async throws -> Steward {
        let registry = ToolRegistry()
        try await FakeTools.registerAll(into: registry)
        return Steward(registry: registry)
    }

    func testHappyPathNamedTool() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(
            StewardRequest(
                instruction: "复述一下",
                toolName: FakeTools.echoName,
                arguments: try StrictJSON.parseObject(#"{"text":"你好，桥"}"#)))
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.toolName, FakeTools.echoName)
        XCTAssertEqual(result.cleanedText, "你好，桥")
        XCTAssertEqual(result.rawText, "你好，桥")
        XCTAssertFalse(result.isError)
        let history = await steward.stateHistory(of: result.id)
        XCTAssertEqual(
            history,
            [
                .queued,
                .dispatched(toolName: FakeTools.echoName),
                .executing(toolName: FakeTools.echoName),
                .cleaning,
                .finished,
            ])
    }

    func testAutoRouteByInstruction() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(StewardRequest(instruction: "现在几点"))
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.toolName, FakeTools.currentTimeName)
        XCTAssertTrue(result.cleanedText?.contains("现在是") ?? false)
    }

    func testNoMatchingToolFails() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(StewardRequest(instruction: "变个魔术给我看 xyz123"))
        guard case .failed(let reason) = result.state else {
            return XCTFail("应失败，实际：\(result.state)")
        }
        XCTAssertTrue(reason.contains("找不到"))
        XCTAssertTrue(result.isError)
    }

    func testUnknownNamedToolFails() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(
            StewardRequest(instruction: "执行", toolName: "ghost_tool"))
        guard case .failed(let reason) = result.state else {
            return XCTFail("应失败，实际：\(result.state)")
        }
        XCTAssertTrue(reason.contains("未在册"))
    }

    func testToolErrorPreservedNotSwallowed() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(
            StewardRequest(instruction: "执行", toolName: FakeTools.alwaysFailName))
        guard case .failed(let reason) = result.state else {
            return XCTFail("应失败，实际：\(result.state)")
        }
        XCTAssertTrue(reason.contains("FAKE_TOOL_FAILURE"), "错误原文必须保留：\(reason)")
        XCTAssertTrue(result.cleanedText?.contains("FAKE_TOOL_FAILURE") ?? false)
        XCTAssertTrue(result.isError)
    }

    func testNoiseOutputCleanedEndToEnd() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(
            StewardRequest(instruction: "执行", toolName: FakeTools.noiseName))
        XCTAssertEqual(result.state, .finished)
        let cleaned = try XCTUnwrap(result.cleanedText)
        XCTAssertFalse(cleaned.contains("\u{1B}"), "ANSI 应被洗掉")
        XCTAssertTrue(cleaned.contains("进度 50%（重复 5 次）"))
        XCTAssertTrue(cleaned.contains("噪声任务结束"))
        XCTAssertFalse(cleaned.contains("internalNote"), "JSON 冗余字段应被滤掉")
        XCTAssertFalse(cleaned.contains("debugTrace"))
        // 原文保留备查
        XCTAssertTrue(result.rawText?.contains("internalNote") ?? false)
    }

    func testQueueIsSerial() async throws {
        let steward = try await makeSteward()
        let slowID = await steward.submit(
            StewardRequest(
                instruction: "等一下",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":800}"#),
                timeoutSeconds: 10))
        let echoID = await steward.submit(
            StewardRequest(
                instruction: "复述",
                toolName: FakeTools.echoName,
                arguments: try StrictJSON.parseObject(#"{"text":"排队中"}"#)))
        let echoStateWhileSlowRuns = await steward.state(of: echoID)
        XCTAssertEqual(echoStateWhileSlowRuns, .queued, "前一个没跑完，后一个必须排队")
        let slowResult = await steward.waitForCompletion(slowID)
        let echoResult = await steward.waitForCompletion(echoID)
        XCTAssertEqual(slowResult.state, .finished)
        XCTAssertEqual(echoResult.state, .finished)
        XCTAssertEqual(echoResult.cleanedText, "排队中")
    }

    func testCancelRunningTask() async throws {
        let steward = try await makeSteward()
        let id = await steward.submit(
            StewardRequest(
                instruction: "等很久",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":30000}"#),
                timeoutSeconds: 60))
        // 给它一点时间进入执行
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        await steward.cancel(id)
        let result = await steward.waitForCompletion(id)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result.state, .cancelled)
        XCTAssertLessThan(elapsed, 5, "取消应很快收尾，不该等满 30 秒")
    }

    func testCancelQueuedTask() async throws {
        let steward = try await makeSteward()
        let slowID = await steward.submit(
            StewardRequest(
                instruction: "等一下",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":600}"#),
                timeoutSeconds: 10))
        let queuedID = await steward.submit(
            StewardRequest(instruction: "复述", toolName: FakeTools.echoName))
        await steward.cancel(queuedID)
        let queuedResult = await steward.waitForCompletion(queuedID)
        XCTAssertEqual(queuedResult.state, .cancelled)
        let slowResult = await steward.waitForCompletion(slowID)
        XCTAssertEqual(slowResult.state, .finished, "取消排队任务不影响正在跑的")
    }

    func testTimeoutFuse() async throws {
        let steward = try await makeSteward()
        let started = Date()
        let result = await steward.execute(
            StewardRequest(
                instruction: "等很久",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":30000}"#),
                timeoutSeconds: 0.3))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result.state, .timedOut)
        XCTAssertTrue(result.cleanedText?.contains("超时") ?? false)
        XCTAssertLessThan(elapsed, 5, "超时熔断应很快收尾")
    }

    func testSensitiveToolNeedsApproval() async throws {
        let registry = ToolRegistry()
        try await registry.register(
            descriptor: ToolDescriptor(
                name: "danger_op", summary: "敏感操作假工具", permission: .sensitive)
        ) { _ in ToolOutput(text: "已执行敏感操作") }
        let steward = Steward(registry: registry)

        let denied = await steward.execute(
            StewardRequest(instruction: "执行", toolName: "danger_op"))
        guard case .failed(let reason) = denied.state else {
            return XCTFail("未确认的敏感工具应失败，实际：\(denied.state)")
        }
        XCTAssertTrue(reason.contains("需要主人确认"))

        let approved = await steward.execute(
            StewardRequest(instruction: "执行", toolName: "danger_op", sensitiveApproved: true))
        XCTAssertEqual(approved.state, .finished)
        XCTAssertEqual(approved.cleanedText, "已执行敏感操作")
    }

    func testDisabledToolRejectedBySteward() async throws {
        let registry = ToolRegistry()
        try await FakeTools.registerAll(into: registry)
        try await registry.setEnabled(false, for: FakeTools.echoName)
        let steward = Steward(registry: registry)
        let result = await steward.execute(
            StewardRequest(instruction: "复述", toolName: FakeTools.echoName))
        guard case .failed(let reason) = result.state else {
            return XCTFail("停用工具应失败，实际：\(result.state)")
        }
        XCTAssertTrue(reason.contains("已停用"))
    }
}
