/**
 * [INPUT]: AgentRunner 当前轮的工具计划及工具调用 ID；不读任务状态、不执行工具。
 * [OUTPUT]: 判断单次打开与尾部预写反馈的边界，并为未执行的调用生成明确历史回执。
 * [POS]: Agent 工具循环的纯批次策略；执行器事实由 AgentRunner 决定，模型预判不能覆盖本批真实结果。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum AgentToolBatch {
    static func name(_ call: [String: Any]) -> String {
        (call["function"] as? [String: Any])?["name"] as? String ?? ""
    }
    static func isOpening(_ name: String) -> Bool {
        ["open_target", "open_app", "open_bookmark", "open_page"].contains(name)
    }
    static func openingCanFinish(_ calls: [[String: Any]]) -> Bool {
        guard let first = calls.first, isOpening(name(first)) else { return false }
        return calls.dropFirst().allSatisfy { name($0) == "task_feedback" }
    }
    static func feedbackNeedsReceipt(_ calls: [[String: Any]], at index: Int) -> Bool {
        calls.prefix(index).contains { name($0) != "task_feedback" }
    }
    static func skipped(_ calls: [[String: Any]], from index: Int, reason: String) -> [[String: Any]] {
        calls.dropFirst(index).map { ["role": "tool", "tool_call_id": $0["id"] as? String ?? "", "content": reason] }
    }
}
