/**
 * [INPUT]: AgentRunner 的模型/搜索/打开执行器替身，TaskRecovery 的反馈契约与临时 TaskStore。
 * [OUTPUT]: 验证同批反馈不能预判尚未看到的执行结果；真实打开失败保留，纯反馈可独立收尾，准确单开仍直接回执。
 * [POS]: tests 的工具结果与反馈顺序回归；只操作内存替身与临时任务，不联网、不打开浏览器、不调用真实模型。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct AgentFeedbackOrderTests {
    static var checks = 0
    static var failures: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }
    static func calls(_ values: [(String, [String: Any])]) -> ModelTurn {
        let batch = values.map { name, arguments -> [String: Any] in
            let json = try! JSONSerialization.data(withJSONObject: arguments)
            return ["id": "test-" + UUID().uuidString, "type": "function",
                    "function": ["name": name, "arguments": String(decoding: json, as: UTF8.self)]]
        }
        return ModelTurn(toolCalls: batch, rawMessage: ["role": "assistant", "tool_calls": batch],
                         usage: ["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12])
    }
    static let answer = ModelTurn(content: "已提交打开网页请求。", rawMessage: ["role": "assistant", "content": "已提交打开网页请求。"],
                                  usage: ["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12])
    static let feedback: (String, [String: Any]) = ("task_feedback", ["kind": "executionFailure", "message": "网页尚未打开，当前没有打开结果。", "nextStep": "请核对打开步骤。"])
    static func opening(_ complete: Bool = false) -> (String, [String: Any]) {
        ("open_page", ["url": "https://example.test/entry", "completesTask": complete])
    }

    final class Probe {
        var modelCalls = 0
        var opens = 0
        var searches = 0
        var inputs: [[[String: Any]]] = []
        var responses: [ModelTurn]
        var failOpen: Bool
        var permitted: Bool
        init(_ responses: [ModelTurn], failOpen: Bool = false, permitted: Bool = true) {
            self.responses = responses; self.failOpen = failOpen; self.permitted = permitted
        }
        func run(_ text: String = "打开测试入口，核对这个目标") throws -> (AgentTask, AgentRunner.Outcome) {
            AgentRunner.resolveQuickApp = { _ in nil }
            AgentRunner.resolveApp = { _ in nil }
            AgentRunner.readBookmarks = { [] }
            AgentRunner.isCodexApp = { _ in false }
            AgentRunner.canControl = { _ in self.permitted }
            AgentRunner.openPage = { _ in
                self.opens += 1
                if self.failOpen {
                    return .failure(NSError(domain: "FeedbackOrderTest", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "真实打开执行器失败"]))
                }
                return .success(())
            }
            AgentRunner.searchWeb = { _, done in
                self.searches += 1
                done("{\"results\":[{\"title\":\"测试入口\",\"url\":\"https://example.test/entry\",\"snippet\":\"模拟证据\"}],\"hint\":\"测试候选\"}")
            }
            AgentRunner.sendModel = { _, messages, _, _, done in
                let index = self.modelCalls
                self.modelCalls += 1; self.inputs.append(messages)
                if index < self.responses.count { done(.success(self.responses[index])) }
                else { done(.failure(.init(httpStatus: nil, message: "替身不允许额外模型请求"))) }
            }
            var task = try TaskStore.claim(subject: "feedback-order-" + UUID().uuidString,
                                           requestId: UUID().uuidString, text: text, context: nil)
            task.status = .running; try TaskStore.save(task)
            var outcome: AgentRunner.Outcome?
            let finished = DispatchSemaphore(value: 0)
            AgentRunner.run(config: ModelConfig(backend: .codex), task: task,
                            readPage: { .failure(.emptyPage) }) { result in outcome = result; finished.signal() }
            guard finished.wait(timeout: .now() + 5) == .success, let outcome else {
                throw NSError(domain: "FeedbackOrderTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "执行没有按时结束"])
            }
            return (TaskStore.task(id: task.id) ?? task, outcome)
        }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pd-feedback-order-" + UUID().uuidString)
        TaskStore.resetCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        // ---------- 真实失败形状：先搜索，再同批打开和预写失败反馈 ----------
        let latest = Probe([calls([("search_web", ["query": "测试入口"])]), calls([opening(), feedback]), answer])
        let (_, latestResult) = try latest.run()
        check(latest.searches == 1 && latest.opens == 1, "搜索和打开各执行一次")
        check(latest.modelCalls == 3 && latestResult.error == nil, "混批失败反馈不能覆盖已成功打开的真实回执")
        let continued = latest.inputs.last ?? []
        check(continued.contains { $0["role"] as? String == "tool" && ($0["content"] as? String)?.hasPrefix("已向") == true }, "下一轮确实收到打开回执")

        // ---------- 首项反馈保留原语义：先澄清/结束，不执行封闭后的动作 ----------
        let before = Probe([calls([feedback, opening()]), answer])
        let (_, beforeResult) = try before.run()
        check(before.opens == 0 && before.modelCalls == 1 && beforeResult.error != nil, "反馈在首项仍结束本轮并封闭后续动作")
        let clarifyFirst = Probe([calls([("task_feedback", ["kind": "clarification", "message": "请选一个目标。"]), opening()])], permitted: false)
        let (_, clarifyFirstResult) = try clarifyFirst.run()
        check(clarifyFirst.opens == 0 && clarifyFirst.modelCalls == 1 && clarifyFirstResult.needsInput, "先请求澄清不能继续操作电脑")

        // ---------- 本机真实失败优先，不能被乐观最终回答覆盖 ----------
        let failed = Probe([calls([opening(), feedback]), answer], failOpen: true)
        let (_, failedResult) = try failed.run()
        check(failed.opens == 1 && failedResult.error?.contains("真实打开执行器失败") == true, "打开执行器的真实失败始终保留")

        // ---------- 纯反馈不需要租约、不产生写操作 ----------
        let pure = Probe([calls([("task_feedback", ["kind": "clarification", "message": "请选一个目标。"])] )], permitted: false)
        let (_, pureResult) = try pure.run()
        check(pure.modelCalls == 1 && pure.opens == 0 && pureResult.needsInput && pureResult.error == nil, "纯反馈仍能独立等待补充")

        // ---------- 准确单开可忽略尾部反馈并省掉最终模型往返 ----------
        let quick = Probe([calls([opening(true), feedback])])
        let (quickTask, quickResult) = try quick.run("打开测试官网")
        check(quick.opens == 1 && quick.modelCalls == 1 && quickResult.error == nil, "单次完整打开不因尾部反馈失去直接回执")
        check(quickResult.content?.hasPrefix("已向") == true, "快速打开只报告本机收到请求的事实")
        let quickTools = (quickTask.transcript ?? []).filter { $0["role"] as? String == "tool" }
        check(quickTools.count == 2 && !(quickTools.last?["content"] as? String ?? "").contains("网页尚未打开"), "尾部反馈记录为未执行而非失败事实")

        let partial = Probe([calls([opening(false), feedback]), answer])
        let (_, partialResult) = try partial.run("打开另一测试官网")
        check(partial.modelCalls == 2 && partial.opens == 1 && partialResult.error == nil, "completesTask=false不能被提升为完整任务快捷收尾")

        let compound = Probe([calls([opening(true), feedback]), answer])
        let (_, compoundResult) = try compound.run()
        check(compound.modelCalls == 2 && compound.opens == 1 && compoundResult.error == nil, "复合打开不能因模型标记完整就绕过保守快速通道")

        // ---------- 多次打开保持普通循环，不能变成单次快捷完成 ----------
        let multi = Probe([calls([opening(), opening(), feedback]), answer])
        let (_, multiResult) = try multi.run()
        check(multi.opens == 2 && multi.modelCalls == 2 && multiResult.error == nil, "多次打开不作为单次快捷收尾，反馈仍须等待真实回执")

        let toolData = try JSONSerialization.data(withJSONObject: AgentRunner.tools, options: [.sortedKeys])
        let toolBytes = toolData.count
        if CommandLine.arguments.contains("--dump-tools") {
            try toolData.write(to: URL(fileURLWithPath: "/private/tmp/pocketdesk-codex-original-tools.json"), options: .atomic)
        }
        let definitions = try CodexModelProtocol.toolList(AgentRunner.tools)
        let schemaBytes = try JSONSerialization.data(withJSONObject: CodexModelProtocol.outputSchema(tools: definitions), options: [.sortedKeys]).count
        print("tool schema: \(AgentRunner.tools.count) tools, \(toolBytes) bytes; planner output schema: \(schemaBytes) bytes")
        for message in failures { print("FAIL: " + message) }
        print("agent feedback order: \(checks - failures.count)/\(checks) 项通过")
        if !failures.isEmpty { exit(1) }
    }
}
