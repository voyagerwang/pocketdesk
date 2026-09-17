/**
 * [INPUT]: 飞书业务适配、临时 TaskStore、固定 CLI 替身；--live 只读取当前用户资料。
 * [OUTPUT]: 验证同名选择、明确用户身份、argv 原文、幂等发送记录、失败不重发与租约失效。
 * [POS]: 飞书发送的隔离回归，任何测试都不向真实联系人发消息。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct FeishuMessagingTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        TaskStore.resetCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        func task() throws -> AgentTask {
            var task = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: "给张三发消息", context: nil)
            task.status = .running
            try TaskStore.save(task); return task
        }
        let one: [String: Any] = ["users": [["open_id": "ou_one", "localized_name": "张三", "department": "产品部"]], "has_more": false]
        let two: [String: Any] = ["users": [["open_id": "ou_one", "localized_name": "张三", "department": "产品部"], ["open_id": "ou_two", "localized_name": "张三", "department": "研发部"]], "has_more": false]
        var calls: [[String]] = []
        var search = one
        var failSend = false
        FeishuMessaging.invoke = { args in
            calls.append(args)
            if args[0] == "contact" { return .success(search) }
            return failSend ? .failure(.init(message: "timeout")) : .success(["message_id": "om_test"])
        }
        let text = "第一行\n$(echo secret); --as bot"
        let first = try task()
        guard case .sent = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: first.id, authorized: { true }) else { fatalError("single match failed") }
        let send = calls.last!
        assert(send[send.firstIndex(of: "--text")! + 1] == text)
        assert(send[send.firstIndex(of: "--as")! + 1] == "user")
        assert(send.contains("--idempotency-key"))
        let count = calls.count
        _ = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: first.id, authorized: { true })
        assert(calls.count == count)
        search = two
        let ambiguous = try task()
        guard case .needsInput(let question) = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: ambiguous.id, authorized: { true }) else { fatalError("must ask") }
        assert(question.contains("研发部") && !question.contains("ou_"))
        guard case .failed = FeishuMessaging.perform(recipient: "张三", text: text, choice: "1", taskId: ambiguous.id, authorized: { true }) else { fatalError("model cannot choose without user turn") }
        var selected = TaskStore.task(id: ambiguous.id)!; selected.supplementCount = 1; try TaskStore.save(selected)
        guard case .sent = FeishuMessaging.perform(recipient: "张三", text: text, choice: "2", taskId: ambiguous.id, authorized: { true }) else { fatalError("choice failed") }
        assert(calls.last!.contains("ou_two"))
        search = one; failSend = true
        let failed = try task()
        guard case .failed = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: failed.id, authorized: { true }) else { fatalError("unknown must fail") }
        let attempts = calls.count
        _ = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: failed.id, authorized: { true })
        assert(calls.count == attempts)
        let denied = try task()
        _ = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: denied.id, authorized: { false })
        assert(calls.count == attempts)
        search = ["users": [], "has_more": false]
        guard case .needsInput = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: denied.id, authorized: { true }) else { fatalError("not found must ask") }
        if CommandLine.arguments.contains("--live") {
            guard case .success(let data) = FeishuCLI.run(["contact", "+search-user", "--user-ids", "me", "--as", "user", "--format", "json"]), !(data["users"] as? [[String: Any]] ?? []).isEmpty else { fatalError("existing CLI authorization unavailable") }
            print("existing CLI authorization: read-only self lookup passed")
        }
        print("feishu: unique / ambiguity / user choice / argv / idempotency / unknown / lease passed")
    }
}
