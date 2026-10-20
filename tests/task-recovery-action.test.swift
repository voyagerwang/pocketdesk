/**
 * [INPUT]: 消费 TaskRecovery 与 AgentModels 的纯值类型；使用合成 transcript 和操作台账，不读正式任务。
 * [OUTPUT]: 验证桌面/手机共用动作 JSON、只读失败可续跑、已执行/未知/缺失历史拒绝一键重做及单次明确未发送例外。
 * [POS]: tests 的恢复动作策略回归；独立编译两个领域文件，不启动模型、服务、桌面输入或外部设备。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct TaskRecoveryActionTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ description: String) {
        precondition(value(), description)
        checks += 1
    }
    static func json(_ value: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    static func history(_ tools: [(String, [String: Any])] = []) -> String {
        var rows: [[String: Any]] = [["role": "system", "content": "test"], ["role": "user", "content": "原要求"]]
        for (index, tool) in tools.enumerated() {
            let id = "call-\(index)"
            rows.append(["role": "assistant", "tool_calls": [["id": id, "type": "function",
                "function": ["name": tool.0, "arguments": json(tool.1)]]]])
            rows.append(["role": "tool", "tool_call_id": id, "content": "合成回执"])
        }
        return json(rows)
    }
    static func task(_ kind: TaskRecovery.Kind = .executionFailure, tools: [(String, [String: Any])] = []) -> AgentTask {
        var value = AgentTask(subject: "test", requestId: "test", status: .failed, text: "原要求",
                              messages: [TaskMessage(role: .user, text: "原要求")], transcriptJSON: history(tools))
        value.recovery = .init(kind: kind)
        return value
    }
    static func main() {
        let failed = task()
        check(TaskRecovery.action(for: failed) == .init(kind: .retry, title: "再试一次"), "模型请求失败且无工具记录可重试")
        check(TaskRecovery.action(for: task(.prerequisite)) == .init(kind: .retry, title: "准备好了，继续"), "无副作用前置条件可继续")
        for (kind, label) in [(TaskRecovery.Kind.clarification, "补充信息"), (.capabilityLimit, "调整要求"), (.unconfirmed, "核对结果")] {
            check(TaskRecovery.action(for: task(kind)) == .init(kind: .input, title: label), "补充、能力限制和未知结果均需输入")
            check(TaskRecovery(kind: kind).inputLabel == label, "输入标签与主动作语义一致")
        }
        check(TaskRecovery(kind: .executionFailure).inputLabel == "补充要求", "失败的另一路径是补充要求")

        for name in ["read_page", "search_web", "search_bookmarks", "search_computer_files", "feishu_help", "task_feedback",
                     "search_workbench_tasks", "read_workbench_knowledge"] {
            check(TaskRecovery.action(for: task(tools: [(name, [:])])).kind == .retry, "已知只读工具允许续跑")
        }
        for operation in ["status", "list_devices", "device_info", "get_property", "list_scenes"] {
            check(TaskRecovery.action(for: task(tools: [("mijia", ["operation": operation])])).kind == .retry, "米家只读操作允许续跑")
        }
        for operation in ["set_property", "action", "run_scene", "future_operation", ""] {
            check(TaskRecovery.action(for: task(tools: [("mijia", ["operation": operation])])).kind == .input, "米家写入及未知操作不允许一键重做")
        }
        for name in ["open_app", "open_page", "desktop_action", "lock_computer", "create_workbench_task",
                     "feishu_execute", "send_files_to_phone", "search_future_service"] {
            check(TaskRecovery.action(for: task(tools: [(name, [:])])).kind == .input, "副作用或未知工具不能凭名字猜只读")
        }
        check(TaskRecovery.action(for: task(tools: [("open_page", [:]), ("read_page", [:])])).kind == .input, "最后一步只读不能覆盖前面写入")

        var value = failed
        value.mijiaOperations = ["operation": "pending"]
        check(TaskRecovery.action(for: value) == .init(kind: .input, title: "核对结果"), "米家未知结果先核对")
        value.mijiaOperations = ["operation": "verified"]
        check(TaskRecovery.action(for: value) == .init(kind: .input, title: "继续处理"), "已确认米家写入仍不整段重做")
        value = failed; value.workbenchOperations = ["operation": "42"]
        check(TaskRecovery.action(for: value).kind == .input, "工作台已创建不能重建")
        value = failed; value.feishuOperations = ["operation": "pending"]
        check(TaskRecovery.action(for: value).title == "核对结果", "飞书未知回执先核对")
        value = failed; value.feishuDelivery = .init(recipient: "联系人", messageId: nil)
        check(TaskRecovery.action(for: value).title == "核对结果", "发送占用没有回执不能重发")
        value.feishuDelivery?.messageId = "message-id"
        check(TaskRecovery.action(for: value).kind == .input, "已发送也不能重发")
        value = failed; value.handoffTargetId = "app"
        check(TaskRecovery.action(for: value).kind == .input, "已交接不能整段重做")
        value = failed; value.messages.append(TaskMessage(role: .tool, text: "操作记录", toolName: "desktop_action"))
        check(TaskRecovery.action(for: value).kind == .input, "独立桌面台账不能被只读 transcript 覆盖")

        value = task(tools: [("dispatch_to_app", [:])])
        var reservation = TaskMessage(role: .tool, text: "发送占用", toolName: "dispatch_to_app")
        reservation.dispatchAttempt = value.attempt
        value.messages.append(reservation)
        check(TaskRecovery.action(for: value).title == "核对结果", "派单缺回执保守核对")
        value.appDispatchReceipt = .init(state: .failed, detail: "未发送", submissionAttempted: false)
        check(TaskRecovery.action(for: value).kind == .retry, "唯一当轮派单明确未发送可以续跑")
        value.messages.append(reservation)
        check(TaskRecovery.action(for: value).kind == .input, "一个未发送回执不能覆盖多个派单占用")
        value.messages.removeLast(); value.messages[value.messages.count - 1].dispatchAttempt = nil
        check(TaskRecovery.action(for: value).kind == .input, "旧轮次未知的占用不能凭最新未发送回执解除")
        value.messages.removeLast(); value.appDispatchReceipt = .init(state: .unconfirmed, detail: "结果未知", submissionAttempted: true)
        check(TaskRecovery.action(for: value).title == "核对结果", "真实未知派单优先于错误 recovery 类别")
        for name in ["agent_workspace", "codex_action"] {
            value = task(tools: [(name, ["action": "send_task"])])
            value.appDispatchReceipt = .init(state: .failed, detail: "未发送", submissionAttempted: false)
            check(TaskRecovery.action(for: value).kind == .retry, "专属派单明确未发送可恢复")
        }

        for raw: String? in [nil, "", "not-json", "[]", "{}", json([["role": "tool", "tool_call_id": "missing"]]),
                            json([["role": "user"], ["role": "tool", "tool_call_id": "missing"]]),
                            json([["role": "user"], ["role": "assistant", "function_call": ["name": "legacy"]]]),
                            json([["role": "user"], ["role": "assistant", "tool_calls": "invalid"]])] {
            value = failed; value.transcriptJSON = raw
            check(TaskRecovery.action(for: value).kind == .input, "缺失、损坏、不完整或旧格式历史不暴露一键重做")
        }
        value = failed; value.error = "已确认未执行，可以重复发送。"
        value.transcriptJSON = nil
        check(TaskRecovery.action(for: value).kind == .input, "错误文案没有授权重试的效力")
        value = failed; value.status = .running
        check(TaskRecovery.action(for: value).kind == .input, "执行中不显示重试")

        let payload = failed.json()["recovery"] as! [String: Any]
        let action = payload["primaryAction"] as! [String: String]
        check(action == ["kind": "retry", "title": "再试一次"], "JSON 主动作与原生契约一致")
        check(payload["inputLabel"] as? String == "补充要求", "JSON 暴露输入标签")
        let decoded = try! JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(failed))
        check(TaskRecovery.action(for: decoded) == TaskRecovery.action(for: failed), "重载后动作判定不丢证据")
        print("task recovery action: \(checks) checks passed")
    }
}
