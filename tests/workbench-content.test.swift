/** [INPUT]: 内存 HTTP 替身与临时 TaskStore。[OUTPUT]: 四类创建/读回/未知结果/去重/租约/参数和 AgentRunner 路由验证。 */
import Foundation
@main struct WorkbenchContentTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        TaskStore.resetCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        func task() throws -> AgentTask {
            var t = try TaskStore.claim(subject: "fixture", requestId: UUID().uuidString, text: "保存到个人工作台", context: nil)
            t.status = .running; try TaskStore.save(t); return t
        }
        func json(_ value: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
        func sent(_ value: AgentRunner.ToolOutcome) -> Bool { if case .sent = value { return true }; return false }
        var writes = 0; var reads = 0; var expected: [String: Any] = [:]; var failure = ""; var permit = true
        WorkbenchContent.request = { method, path, body in
            if path == "/api/health" {
                if failure == "health" { return .failure(.init(message: "离线")) }
                if failure == "lease" { permit = false }
                return .success(["ok": true, "name": "workbench"])
            }
            if method == "POST" {
                writes += 1
                if failure == "write" { return .failure(.init(message: "超时")) }
                if path == "/api/events" { assert(body?["requestId"] as? String != nil) }
                return .success(["id": 123])
            }
            reads += 1
            if failure == "read" { return .success(["id": 123, "title": "错误内容"]) }
            return .success(expected.merging(["id": 123]) { _, new in new })
        }
        for kind in ["task", "event", "knowledge", "note"] {
            var args: [String: Any] = ["kind": kind, "title": "测试标题", "content": "正文\n第二行"]
            if kind == "event" { args.merge(["startAt": "2026-10-01T10:00", "endAt": "2026-10-01T11:00", "location": "会议室"]) { _, new in new } }
            if kind == "task" { args["plannedDate"] = "2026-10-01"; args["dueAt"] = "2026-10-01T17:00" }
            let input = json(args); expected = try WorkbenchContent.parse(input).expected
            let t = try task(); let before = writes
            assert(sent(WorkbenchContent.perform(arguments: input, taskId: t.id, authorized: { true })))
            assert(writes == before + 1)
            try TaskStore.save(t) // 旧快照不能清除回执
            TaskStore.resetCache(directory: directory)
            assert(sent(WorkbenchContent.perform(arguments: input, taskId: t.id, authorized: { true })))
            assert(writes == before + 1)
        }
        let input = json(["kind": "note", "title": "测试", "content": "完整内容", "startAt": "", "endAt": NSNull(), "allDay": false, "dueAt": ""])
        for mode in ["write", "read"] {
            failure = mode; let t = try task(); let before = writes
            assert(!sent(WorkbenchContent.perform(arguments: input, taskId: t.id, authorized: { true })))
            failure = ""; TaskStore.resetCache(directory: directory)
            assert(!sent(WorkbenchContent.perform(arguments: input, taskId: t.id, authorized: { true })))
            assert(writes == before + 1, "未知结果禁止重放")
        }
        for mode in ["health", "lease"] {
            failure = mode; permit = true; let t = try task(); let before = writes
            assert(!sent(WorkbenchContent.perform(arguments: input, taskId: t.id, authorized: { permit })))
            assert(writes == before && TaskStore.task(id: t.id)?.workbenchOperations == nil)
        }
        failure = ""
        let t = try task(); let before = writes
        assert(!sent(WorkbenchContent.perform(arguments: input, taskId: t.id, authorized: { false })))
        for value: [String: Any] in [
            ["kind":"event","title":"测试","content":""],
            ["kind":"event","title":"测试","content":"","startAt":"2026-02-30T10:00","endAt":"2026-03-01T11:00"],
            ["kind":"note","title":"测试","content":"", "dueAt":"2026-10-01T10:00"],
            ["kind":"task","title":"测试","content":"","url":"http://evil.test"]
        ] { assert(!sent(WorkbenchContent.perform(arguments: json(value), taskId: t.id, authorized: { true }))) }
        assert(writes == before)
        // 原子占用：同一键只能一个调用获得首次执行权。
        var claims = 0; let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if try! TaskStore.workbenchOperation(id: t.id, key: "parallel") == nil { lock.lock(); claims += 1; lock.unlock() }
        }
        assert(claims == 1)
        expected = try WorkbenchContent.parse(input).expected
        let routed = try task(); var turns = 0
        AgentRunner.canControl = { _ in true }
        AgentRunner.sendModel = { _, messages, tools, _, done in
            turns += 1
            assert((tools ?? []).contains { ($0["function"] as? [String: Any])?["name"] as? String == "create_workbench_note" })
            if turns == 1 {
                let calls: [[String: Any]] = [["id":"fixture", "type":"function", "function":["name":"create_workbench_note", "arguments": json(["title":"测试", "content":"完整内容"])]]]
                done(.success(ModelTurn(toolCalls:calls, rawMessage:["role":"assistant","tool_calls":calls])))
            } else {
                let receipt = messages.last?["content"] as! String; assert(receipt.contains("个人工作台") && receipt.contains("123"))
                done(.success(ModelTurn(content:receipt, rawMessage:["role":"assistant","content":receipt])))
            }
        }
        let completed = DispatchSemaphore(value: 0)
        AgentRunner.run(config:ModelConfig(baseURL:"https://invalid.test",model:"fixture",apiKey:"fixture"),task:routed) { result in
            assert(result.error == nil && result.content?.contains("随手记") == true); completed.signal()
        }
        assert(completed.wait(timeout:.now()+5) == .success)
        print("PASS workbench: four types, readback, stale save/restart, unknown write/read, lease, validation, atomic claim, runner routing")
    }
}
