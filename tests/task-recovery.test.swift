/**
 * [INPUT]: 消费 TaskRecovery、AgentModels、TaskService 和 AgentRunner；模型、配置、派单使用替身，TaskStore 指向临时目录。
 * [OUTPUT]: 验证恢复提示与旧存储兼容、模型追问/能力限制的真实终态、临时失败分类、完整历史接续、无限累计补充、幂等及未核实发送不可重放。
 * [POS]: tests 的任务恢复回归；只验证生命周期与结构化事实，不联网、不打开应用、不发送真实任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct TaskRecoveryTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ description: String) {
        precondition(value(), description)
        checks += 1
        print("  ok - " + description)
    }
    static func encoded(_ value: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    static func toolTurn(_ name: String, _ arguments: [String: Any], extra: [[String: Any]] = []) -> ModelTurn {
        let calls: [[String: Any]] = [["id": UUID().uuidString, "type": "function",
                                     "function": ["name": name, "arguments": encoded(arguments)]]] + extra
        return ModelTurn(toolCalls: calls, rawMessage: ["role": "assistant", "tool_calls": calls])
    }
    static func waitFor(_ id: String, status: TaskStatus) -> AgentTask {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let task = TaskStore.task(id: id), task.status == status { return task }
            Thread.sleep(forTimeInterval: 0.005)
        }
        fatalError("任务没有进入 \(status)：\(String(describing: TaskStore.task(id: id)?.status))")
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pd-task-recovery-" + UUID().uuidString)
        TaskStore.resetCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfig(baseURL: "https://invalid.test", model: "test", apiKey: "test")
        TaskService.loadModelConfig = { config }
        AgentRunner.isCodexApp = { _ in false }
        AgentRunner.resolveApp = { _ in nil }
        AgentRunner.canControl = { _ in true }
        TaskService.classifyInput = { _, _, _, done in done(.same) }

        // --- 纯投影与旧存储 ---
        var legacy = AgentTask(subject: "test", requestId: "legacy", text: "原要求")
        check(TaskRecovery.forTask(legacy) == nil, "已接收任务不显示旧恢复提示")
        legacy.recovery = .init(kind: .capabilityLimit)
        legacy.status = .succeeded
        check(TaskRecovery.forTask(legacy) == nil, "已完成任务忽略过时恢复事实")
        legacy.recovery = nil
        legacy.status = .failed
        legacy.error = "某服务不支持当前请求"
        let projected = TaskRecovery.forTask(legacy)
        check(projected?.kind == .executionFailure, "旧错误中含不支持仍不猜能力限制")
        check(legacy.json()["statusText"] as? String == "这次没完成", "HTTP状态文字来自恢复事实")
        let oldData = try JSONEncoder().encode(legacy)
        var oldObject = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        oldObject.removeValue(forKey: "recovery")
        let restored = try JSONDecoder().decode(AgentTask.self, from: JSONSerialization.data(withJSONObject: oldObject))
        check(restored.recovery == nil && restored.status == .failed, "旧任务无recovery字段仍能解码")
        legacy.status = .needsInput
        check(TaskRecovery.forTask(legacy)?.kind == .clarification, "旧待补充任务投影为澄清")
        legacy.messages = [TaskMessage(role: .tool, text: "派单尝试", toolName: "dispatch_to_app")]
        check(TaskRecovery.forTask(legacy)?.kind == .unconfirmed, "旧派单证据保留接收待核实语义")
        legacy.status = .submitted
        check(TaskRecovery.forTask(legacy)?.kind == .unconfirmed, "提交未核实保持独立恢复语义")
        check(TaskRecovery.parse("{\"kind\":\"unconfirmed\",\"message\":\"已成功\"}") == nil, "模型不能伪造发送未核实事实")
        check(TaskRecovery.parse("{\"kind\":\"clarification\",\"message\":\"  \"}") == nil, "空问题不可收尾")
        check(TaskRecovery.parse("{\"kind\":\"clarification\",\"message\":\"请选目标\",\"nextStep\":42}") == nil, "无效下一步类型不可收尾")

        // --- 模型结构化收尾与执行事实优先 ---
        func run(_ turns: [ModelTurn], permitted: Bool = true) throws -> AgentRunner.Outcome {
            var task = try TaskStore.claim(subject: "runner", requestId: UUID().uuidString, text: "帮我完成这个目标", context: nil)
            task.status = .running
            try TaskStore.save(task)
            AgentRunner.canControl = { _ in permitted }
            var index = 0
            AgentRunner.sendModel = { _, _, _, _, done in
                precondition(index < turns.count, "不应多请求一轮模型")
                let turn = turns[index]; index += 1
                done(.success(turn))
            }
            var outcome: AgentRunner.Outcome?
            let finished = DispatchSemaphore(value: 0)
            AgentRunner.run(config: config, task: task, readPage: { .failure(.emptyPage) }) {
                outcome = $0; finished.signal()
            }
            precondition(finished.wait(timeout: .now() + 5) == .success)
            return outcome!
        }
        var writes = 0
        AgentRunner.openPage = { _ in writes += 1; return .success(()) }
        let skipped: [String: Any] = ["id": "skip", "type": "function", "function": ["name": "open_page", "arguments": "{\"url\":\"https://invalid.test\"}"]]
        let clarification = try run([toolTurn("task_feedback", ["kind": "clarification", "message": "日程几点开始？", "nextStep": "直接告诉我起止时间。"], extra: [skipped])], permitted: false)
        check(clarification.needsInput && clarification.error == nil && clarification.content == "日程几点开始？", "结构化追问保持待补充且不需要电脑租约")
        check(clarification.recovery?.kind == .clarification && writes == 0, "反馈无副作用并封闭同批后续写动作")
        let limitation = try run([toolTurn("task_feedback", ["kind": "capabilityLimit", "message": "个人工作台当前只能创建单次日程。", "nextStep": "可以改为单次安排，或说明你希望怎样重复。"] )])
        check(limitation.content == nil && limitation.error != nil && !limitation.needsInput, "能力限制不冒充完成或要求徒劳澄清")
        check(limitation.recovery?.kind == .capabilityLimit && limitation.recovery?.nextStep?.contains("单次安排") == true, "能力限制保留一个可行下一步")
        AgentRunner.openPage = { _ in .failure(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "暂时打不开"])) }
        let priorFailure = try run([toolTurn("open_page", ["url": "https://invalid.test"]), toolTurn("task_feedback", ["kind": "capabilityLimit", "message": "没有打开网页能力。"] )])
        check(priorFailure.error == "未打开：暂时打不开" && priorFailure.recovery?.kind == .executionFailure, "后续模型不能把真实暂时执行失败改成能力限制")
        let controlLoss = try run([toolTurn("open_page", ["url": "https://invalid.test"]), toolTurn("task_feedback", ["kind": "clarification", "message": "你能换个说法吗？"] )], permitted: false)
        check(controlLoss.recovery?.kind == .prerequisite && controlLoss.error?.contains("控制权") == true, "真实控制前置条件优先于模型追问")
        AgentRunner.canControl = { _ in true }

        // --- 生命周期使用真实Runner、网络错误不猜能力 ---
        TaskService.runAgent = { config, task, done in AgentRunner.run(config: config, task: task, completion: done) }
        AgentRunner.sendModel = { _, _, _, _, done in
            done(.success(toolTurn("task_feedback", ["kind": "clarification", "message": "你想操作哪个窗口？", "nextStep": "直接说窗口名称。"])))
        }
        let question = try TaskService.submit(subject: "service", requestId: "question", text: "把窗口放到右边", context: nil)
        let waiting = waitFor(question.id, status: .needsInput)
        check(waiting.recovery?.kind == .clarification && waiting.result == "你想操作哪个窗口？", "模型追问经生命周期保存为待补充")
        AgentRunner.sendModel = { _, _, _, _, done in
            done(.success(toolTurn("task_feedback", ["kind": "capabilityLimit", "message": "当前工具只能按每个窗口清理重复标签。", "nextStep": "可改为按每个窗口分别清理。"])))
        }
        let scope = try TaskService.submit(subject: "service", requestId: "limitation", text: "跨窗口清理标签", context: nil)
        let limited = waitFor(scope.id, status: .failed)
        check(limited.recovery?.kind == .capabilityLimit && limited.json()["statusText"] as? String == "当前能力有限", "能力限制保存为未完成与明确状态文字")
        AgentRunner.sendModel = { _, _, _, _, done in done(.failure(.init(httpStatus: nil, message: "连接暂时超时"))) }
        let network = try TaskService.submit(subject: "service", requestId: "network", text: "读取我的安排", context: nil)
        let disconnected = waitFor(network.id, status: .failed)
        check(disconnected.recovery?.kind == .executionFailure, "模型网络错误保守归执行失败")

        // --- 无配置仍保存原目标，缺runtime历史也完整续接 ---
        TaskService.loadModelConfig = { ModelConfig(baseURL: "", model: "", apiKey: "") }
        let unconfigured = try TaskService.submit(subject: "service", requestId: "unconfigured", text: "在个人工作台保存完整原目标与约束", context: nil)
        check(unconfigured.status == .failed && unconfigured.recovery?.kind == .prerequisite, "模型未配置也持久保存真实原任务")
        let duplicate = try TaskService.submit(subject: "service", requestId: "unconfigured", text: "在个人工作台保存完整原目标与约束", context: nil)
        check(duplicate.id == unconfigured.id, "未配置提交按原requestId幂等查账")
        TaskService.loadModelConfig = { config }
        let captureLock = NSLock()
        var captures: [AgentTask] = []
        TaskService.runAgent = { _, task, done in
            captureLock.lock(); captures.append(task); captureLock.unlock()
            done(.init(content: nil, usage: .none, error: "仍未确认执行结果", pages: [], rounds: 0, drifted: false,
                       recovery: .init(kind: .executionFailure)))
        }
        var current = try TaskService.supplement(taskId: unconfigured.id, text: "补充：只保存这次明确的内容", expectedRevision: unconfigured.revision, requestId: "supplement-1")
        current = waitFor(current.id, status: .failed)
        captureLock.lock(); let resumed = captures.last!; captureLock.unlock()
        let history = resumed.transcript!
        check(history.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String } == [unconfigured.text, "补充：只保存这次明确的内容"], "没有runtime历史仍保留原user和新补充的先后关系")
        check(history.contains { $0["role"] as? String == "assistant" && ($0["content"] as? String)?.contains("没有配置模型") == true }, "无runtime历史保留上一轮真实助手错误")
        check(history.contains { $0["role"] as? String == "assistant" && ($0["content"] as? String)?.contains("上轮执行回执") == true }, "上一轮执行错误作为独立助手数据回放")
        check(!history.contains { $0["role"] as? String == "system" && ($0["content"] as? String)?.contains("上轮执行回执") == true }, "外部错误不会被升级为系统规则")
        check(resumed.recovery == nil && resumed.error == nil && resumed.result == nil, "每轮开始清除旧恢复状态")
        let countBeforeDuplicate = current.supplementCount
        let duplicatedSupplement = try TaskService.supplement(taskId: current.id, text: "补充：只保存这次明确的内容", expectedRevision: current.revision, requestId: "supplement-1")
        check(duplicatedSupplement.id == current.id && duplicatedSupplement.supplementCount == countBeforeDuplicate, "同补充requestId不新增轮数或重复执行")
        for index in 2...6 {
            let accepted = try TaskService.supplement(taskId: current.id, text: "继续补充第\(index)句", expectedRevision: current.revision, requestId: "supplement-\(index)")
            current = waitFor(accepted.id, status: .failed)
        }
        check(current.supplementCount == 6, "超过五轮仍可在同一任务继续补充")
        check(current.messages.first?.text == unconfigured.text && current.messages.last(where: { $0.role == .user })?.text == "继续补充第6句", "多轮补充保留完整原目标及最新解释")
        captureLock.lock(); let sixthHistory = captures.last!.transcript!; captureLock.unlock()
        check(sixthHistory.contains { $0["role"] as? String == "assistant" && ($0["content"] as? String)?.contains("仍未确认执行结果") == true }, "每轮补充都回放上一轮失败事实")

        // --- 显式按钮意图不受自动关系判断与时间窗口约束 ---
        var classifications = 0
        TaskService.classifyInput = { _, _, _, done in classifications += 1; done(.new) }
        var old = current
        old.updatedAt = Date().timeIntervalSince1970 - 31 * 60
        try TaskStore.save(old)
        func send(_ text: String, previous: String?, intent: TaskRecovery.InputIntent, subject: String = "service") -> Result<AgentTask, Error> {
            let finished = DispatchSemaphore(value: 0)
            var result: Result<AgentTask, Error>?
            TaskService.send(subject: subject, requestId: UUID().uuidString, text: text, context: nil,
                             controlSession: nil, previousTaskId: previous, inputIntent: intent) { result = $0; finished.signal() }
            precondition(finished.wait(timeout: .now() + 5) == .success)
            return result!
        }
        let explicit = try send("我明确补充刚才的要求", previous: old.id, intent: .supplement).get()
        let continued = waitFor(explicit.id, status: .failed)
        check(continued.id == old.id && classifications == 0, "显式补充超过30分钟仍续接原任务并跳过分类")
        let fresh = try send("独立做另一件事", previous: old.id, intent: .newTask).get()
        _ = waitFor(fresh.id, status: .failed)
        check(fresh.id != old.id && classifications == 0, "显式新任务忽略原任务且跳过分类")
        if case .failure(let error) = send("补充", previous: "missing-task", intent: .supplement) {
            check((error as? TaskServiceError)?.localizedDescription == TaskServiceError.notFound.localizedDescription, "显式补充丢失原任务时返回错误")
        } else { fatalError("不能悄悄新建丢失上下文的补充") }
        if case .failure = send("补充", previous: old.id, intent: .supplement, subject: "other-subject") {
            check(true, "显式补充拒绝另一主体的任务")
        } else { fatalError("必须核验任务主体") }
        TaskService.loadModelConfig = { ModelConfig(baseURL: "", model: "", apiKey: "") }
        let blockedSupplement = try send("模型配置前我也要保留这句解释", previous: old.id, intent: .supplement).get()
        check(blockedSupplement.recovery?.kind == .prerequisite && blockedSupplement.pendingInputRelation == false
              && blockedSupplement.messages.last(where: { $0.role == .user })?.text == "模型配置前我也要保留这句解释", "无配置显式补充仍保留解释并不误报关系待确认")
        TaskService.loadModelConfig = { config }

        // --- 安全重试票据不能解除后来发送的占用 ---
        var preflight = try TaskStore.claim(subject: "service", requestId: "preflight", text: "派单前准备失败的原任务", context: nil)
        preflight.status = .running
        try TaskStore.save(preflight)
        let firstReservation = try TaskStore.reserveAppDispatch(id: preflight.id, label: "第一轮准备占用")
        check(firstReservation, "模拟首轮派单准备已占用")
        preflight = TaskStore.task(id: preflight.id)!
        preflight.status = .failed
        preflight.appDispatchReceipt = .init(state: .failed, detail: "发送前界面尚未准备好", submissionAttempted: false)
        try TaskStore.save(preflight)
        let abandonedRun = DispatchSemaphore(value: 0)
        var retryReserved = false
        var clearedPreflightReceipt = false
        TaskService.runAgent = { _, task, done in
            clearedPreflightReceipt = task.appDispatchReceipt == nil
            retryReserved = (try? TaskStore.reserveAppDispatch(id: task.id, label: "第二轮已发送占用")) == true
            _ = try! TaskService.abandon(taskId: task.id)
            done(.init(content: "已尝试发送，接收待核实", usage: .none, error: nil, pages: [], rounds: 0, drifted: false,
                       appDispatchReceipt: .init(state: .unconfirmed, detail: "已尝试发送，接收待核实", submissionAttempted: true)))
            abandonedRun.signal()
        }
        _ = try TaskService.supplement(taskId: preflight.id, text: "继续原派单", expectedRevision: preflight.revision, requestId: "preflight-retry")
        precondition(abandonedRun.wait(timeout: .now() + 5) == .success)
        let abandoned = TaskStore.task(id: preflight.id)!
        check(retryReserved && clearedPreflightReceipt, "明确未发送允许一次重试且开始时清旧false回执")
        check(abandoned.status == .abandoned && abandoned.appDispatchReceipt == nil, "放弃发生在发送后时不会残留旧未发送回执")
        var duplicateReserved = false
        TaskService.runAgent = { _, task, done in
            duplicateReserved = (try? TaskStore.reserveAppDispatch(id: task.id, label: "不应发生的第三轮发送")) == true
            done(.init(content: nil, usage: .none, error: "本任务已有发送占用，只能核对", pages: [], rounds: 0, drifted: false,
                       recovery: .init(kind: .executionFailure)))
        }
        let afterAbandon = try TaskService.supplement(taskId: abandoned.id, text: "补充核对已发送的任务", expectedRevision: abandoned.revision, requestId: "preflight-after-abandon")
        let blockedReplay = waitFor(afterAbandon.id, status: .failed)
        check(!duplicateReserved && TaskStore.hasBlockedAppDispatch(blockedReplay), "发送后放弃再补充不能用旧false回执解除占用并重发")

        // --- 未核实发送不被反馈改写，不重新发送 ---
        TaskService.runAgent = { config, task, done in AgentRunner.run(config: config, task: task, completion: done) }
        var dispatchCount = 0
        AgentRunner.dispatchToApp = { _, _, taskId, _, done in
            precondition((try? TaskStore.reserveAppDispatch(id: taskId, label: "派单尝试：ExampleAgent")) == true)
            dispatchCount += 1
            done(.init(state: .unconfirmed, detail: "已尝试发送，接收待核实", targetName: "ExampleAgent", submissionAttempted: true))
        }
        AgentRunner.sendModel = { _, _, _, _, done in
            done(.success(toolTurn("dispatch_to_app", ["app": "ExampleAgent", "text": "完整任务", "mode": "new"])))
        }
        let dispatched = try TaskService.submit(subject: "service", requestId: "dispatch", text: "把完整任务发给ExampleAgent", context: nil)
        let pending = waitFor(dispatched.id, status: .submitted)
        check(pending.recovery?.kind == .unconfirmed && dispatchCount == 1, "未核实派单结束为submitted并保存恢复事实")
        AgentRunner.sendModel = { _, messages, _, _, done in
            check((messages.first?["content"] as? String)?.contains("不可重放") == true, "续接prompt保留已提交派单占用事实")
            done(.success(toolTurn("task_feedback", ["kind": "clarification", "message": "你再解释一遍任务。"])))
        }
        let review = try TaskService.supplement(taskId: pending.id, text: "核对刚才有没有收到", expectedRevision: pending.revision, requestId: "dispatch-check")
        let stillPending = waitFor(review.id, status: .submitted)
        check(stillPending.appDispatchReceipt?.state == .unconfirmed && stillPending.recovery?.kind == .unconfirmed, "模型反馈不能改写原接收未核实事实")
        check(dispatchCount == 1 && TaskStore.hasBlockedAppDispatch(stillPending), "补充核对不重发且原子发送证据仍有效")
        AgentRunner.sendModel = { _, _, _, _, done in
            done(.success(toolTurn("task_feedback", ["kind": "unconfirmed", "message": "无效反馈"])) )
        }
        let invalidFeedback = try TaskService.supplement(taskId: stillPending.id, text: "继续核对", expectedRevision: stillPending.revision, requestId: "dispatch-invalid-feedback")
        let afterInvalid = waitFor(invalidFeedback.id, status: .submitted)
        check(afterInvalid.appDispatchReceipt?.state == .unconfirmed && afterInvalid.error == nil, "无效模型反馈仍优先保留接收未核实回执")
        AgentRunner.sendModel = { _, _, _, _, done in
            done(.success(ModelTurn(content: "已完成发送并成功接收。", rawMessage: ["role": "assistant", "content": "已完成发送并成功接收。"])))
        }
        let plainAnswer = try TaskService.supplement(taskId: afterInvalid.id, text: "再核对接收结果", expectedRevision: afterInvalid.revision, requestId: "dispatch-plain-answer")
        let afterPlain = waitFor(plainAnswer.id, status: .submitted)
        check(afterPlain.appDispatchReceipt?.state == .unconfirmed && afterPlain.result == "已尝试发送，接收待核实", "无工具的模型成功文字不能清旧回执或把任务变成succeeded")
        check(afterPlain.messages.last?.text == afterPlain.result && dispatchCount == 1, "最终消息与事件依据真实回执且仍只发送一次")
        TaskStore.resetCache()
        check(TaskStore.task(id: afterPlain.id)?.recovery?.kind == .unconfirmed, "恢复事实在缓存重载后仍保存")
        print("task recovery: \(checks) checks passed")
    }
}
