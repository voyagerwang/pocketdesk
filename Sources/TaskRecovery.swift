/**
 * [INPUT]: 依赖 Foundation 与 AgentTask 的状态、持久操作证据及完整工具历史；不读取错误文案推断能力或是否已执行。
 * [OUTPUT]: 对外提供 TaskRecovery 恢复类型、两端共用的主动作/输入文案与 task_feedback 契约；仅完整只读或明确未发送历史允许一键续跑。
 * [POS]: Sources 的任务恢复语义层；AgentRunner 记录未完成原因，TaskService 保存事实，桌面与手机共用提示。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

struct TaskRecovery: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case clarification, prerequisite, capabilityLimit, executionFailure, unconfirmed
    }
    enum InputIntent { case automatic, supplement, newTask }
    struct Action: Equatable {
        enum Kind: String { case retry, input }
        let kind: Kind
        let title: String
    }
    var kind: Kind
    var nextStep: String? = nil

    var headline: String {
        switch kind {
        case .clarification: return "等你补充"
        case .prerequisite: return "需要先准备"
        case .capabilityLimit: return "当前能力有限"
        case .executionFailure: return "这次没完成"
        case .unconfirmed: return "接收待核实"
        }
    }

    var continuationHint: String {
        switch kind {
        case .clarification: return "直接补充这一点就好。"
        case .prerequisite: return "准备好后可以接着处理。"
        case .capabilityLimit: return "可以调整目标或要求。"
        case .executionFailure: return "可以接着处理刚才的事。"
        case .unconfirmed: return "先核对结果，不重复发送。"
        }
    }

    var inputLabel: String {
        switch kind {
        case .clarification: return "补充信息"
        case .prerequisite, .executionFailure: return "补充要求"
        case .capabilityLimit: return "调整要求"
        case .unconfirmed: return "核对结果"
        }
    }

    // MARK: - 恢复动作

    /// retry 只续接原任务。状态为失败或模型说“未执行”，都不能单独证明可重做。
    static func action(for task: AgentTask) -> Action {
        guard let recovery = forTask(task) else { return Action(kind: .input, title: "继续处理") }
        if recovery.kind == .unconfirmed || hasUnconfirmedEffect(task) {
            return Action(kind: .input, title: "核对结果")
        }
        switch recovery.kind {
        case .executionFailure, .prerequisite:
            if hasOnlyReadHistory(task) {
                return Action(kind: .retry, title: recovery.kind == .prerequisite ? "准备好了，继续" : "再试一次")
            }
            return Action(kind: .input, title: "继续处理")
        case .clarification, .capabilityLimit, .unconfirmed:
            return Action(kind: .input, title: recovery.inputLabel)
        }
    }

    private static func hasUnconfirmedEffect(_ task: AgentTask) -> Bool {
        if task.appDispatchReceipt?.state == .unconfirmed { return true }
        if task.feishuDelivery != nil && task.feishuDelivery?.messageId == nil { return true }
        if [task.workbenchOperations, task.mijiaOperations, task.feishuOperations]
            .contains(where: { $0?.values.contains("pending") == true }) { return true }
        return task.messages.contains(where: { $0.toolName == "dispatch_to_app" })
            && task.appDispatchReceipt?.submissionAttempted == nil
    }

    /// 白名单必须与工具职责一致；新工具先走输入恢复，不从名称或返回文字猜只读。
    private static let readTools: Set<String> = [
        "read_page", "search_web", "search_bookmarks", "search_computer_files", "feishu_help", "task_feedback",
        "search_workbench_tasks", "search_workbench_events", "search_workbench_notes", "search_workbench_knowledge",
        "read_workbench_task", "read_workbench_event", "read_workbench_note", "read_workbench_knowledge"
    ]
    private static let mijiaReadOperations: Set<String> = ["status", "list_devices", "device_info", "get_property", "query_environment", "list_scenes"]

    private static func hasOnlyReadHistory(_ task: AgentTask) -> Bool {
        guard task.feishuDelivery == nil,
              [task.workbenchOperations, task.mijiaOperations, task.feishuOperations].allSatisfy({ $0?.isEmpty != false }),
              task.handoffTargetId == nil, task.handoffRequested != true,
              let raw = task.transcriptJSON, let data = raw.data(using: .utf8),
              let history = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              history.contains(where: { $0["role"] as? String == "user" }) else { return false }
        let unsent = task.appDispatchReceipt.map {
            $0.submissionAttempted == false && [.failed, .needsInput].contains($0.state)
        } ?? false
        if task.appDispatchReceipt != nil && !unsent { return false }
        let dispatchReservations = task.messages.filter { $0.toolName == "dispatch_to_app" }
        guard dispatchReservations.isEmpty || (unsent && dispatchReservations.count == 1
            && dispatchReservations[0].dispatchAttempt == task.attempt) else { return false }

        var calls: [String: String] = [:]
        var names = Set<String>()
        var unsentCalls = 0
        for message in history {
            guard let role = message["role"] as? String, ["system", "user", "assistant", "tool"].contains(role),
                  message["function_call"] == nil else { return false }
            if let rawCalls = message["tool_calls"] {
                guard role == "assistant", let toolCalls = rawCalls as? [[String: Any]] else { return false }
                for call in toolCalls {
                    guard call["type"] as? String == "function", let id = call["id"] as? String, !id.isEmpty, calls[id] == nil,
                          let function = call["function"] as? [String: Any], let name = function["name"] as? String,
                          let arguments = function["arguments"] as? String, let bytes = arguments.data(using: .utf8),
                          let values = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
                    if name == "mijia" {
                        guard let operation = values["operation"] as? String, mijiaReadOperations.contains(operation) else { return false }
                    } else if !readTools.contains(name) {
                        let dispatch = name == "dispatch_to_app"
                            || (name == "agent_workspace" && values["action"] as? String == "send_task")
                            || (name == "codex_action" && ["send_project", "send_task", "send_dot"].contains(values["action"] as? String ?? ""))
                        guard unsent, dispatch else { return false }
                        unsentCalls += 1
                        guard unsentCalls == 1 else { return false }
                    }
                    calls[id] = name
                    names.insert(name)
                }
            }
            if role == "tool" {
                guard let id = message["tool_call_id"] as? String, let name = calls[id],
                      message["name"] == nil || message["name"] as? String == name else { return false }
            }
        }
        if !dispatchReservations.isEmpty && unsentCalls != 1 { return false }
        return task.messages.filter { $0.role == .tool }.allSatisfy {
            guard let name = $0.toolName else { return false }
            if name == "dispatch_to_app" { return unsent && unsentCalls == 1 }
            return names.contains(name) && (readTools.contains(name) || name == "mijia")
        }
    }

    static func forTask(_ task: AgentTask) -> TaskRecovery? {
        switch task.status {
        case .needsInput, .failed, .submitted:
            if let recovery = task.recovery { return recovery }
            if task.status == .submitted || (task.status == .needsInput && task.appDispatchReceipt == nil
                && task.messages.contains(where: { $0.toolName == "dispatch_to_app" })) {
                return .init(kind: .unconfirmed)
            }
            return .init(kind: task.status == .needsInput ? .clarification : .executionFailure)
        default: return nil
        }
    }

    static var tool: [String: Any] {
        ["type": "function", "function": [
            "name": "task_feedback",
            "description": "本轮任务未完成时结束本轮并说明下一步，不执行任何电脑操作。缺信息或需要选择用 clarification；真实权限、配置或界面前置条件用 prerequisite；只有工具目录明确不覆盖的范围用 capabilityLimit；暂时失败或未经核实的原因用 executionFailure。发送未核实由执行器处理，不能用这个工具改写发送事实。",
            "parameters": ["type": "object", "properties": [
                "kind": ["type": "string", "enum": Kind.allCases.filter { $0 != .unconfirmed }.map(\.rawValue)],
                "message": ["type": "string", "description": "简短说明具体真实的问题、限制或哪一步未完成；缺信息时只问一个关键问题，不要求重说整段"],
                "nextStep": ["type": "string", "description": "一个可行的下一步；能力限制时可邀请用户说明真实目标或调整范围，不让用户徒劳换说法"]
            ], "required": ["kind", "message"], "additionalProperties": false] as [String: Any]
        ] as [String: Any]]
    }

    static func parse(_ arguments: String) -> (message: String, recovery: TaskRecovery)? {
        guard let data = arguments.data(using: .utf8), data.count <= 16 * 1024,
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(values.keys).isSubset(of: ["kind", "message", "nextStep"]),
              let rawKind = values["kind"] as? String, let kind = Kind(rawValue: rawKind), kind != .unconfirmed,
              let rawMessage = values["message"] as? String else { return nil }
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 2000 else { return nil }
        var nextStep: String?
        if let rawStep = values["nextStep"] {
            guard let step = rawStep as? String else { return nil }
            let trimmed = step.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 500 else { return nil }
            nextStep = trimmed
        }
        return (message, .init(kind: kind, nextStep: nextStep))
    }
}
