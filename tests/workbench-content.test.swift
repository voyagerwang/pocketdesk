/**
 * [INPUT]: 内存 HTTP 替身与临时 TaskStore，消费 WorkbenchContent 与 AgentRunner 的真实创建路径。
 * [OUTPUT]: 四类创建/读回/未知结果/去重/租约/参数、待办默认今天与明确日期回执、跨午夜及旧回执去重与 AgentRunner 路由验证。
 * [POS]: 工作台创建的隔离回归；以 HTTP 字段及完成回执证明保存结果，不操作真实工作台。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CryptoKit
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
        let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let today = clock.date(from: "2026-10-13T23:59")!; let tomorrow = clock.date(from: "2026-10-14T00:01")!
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
                if path == "/api/tasks" {
                    for (input, output) in [("plannedDate", "planned_date"), ("dueAt", "due_at"), ("remindAt", "remind_at")] {
                        assert(body?[input] as? String == expected[output] as? String)
                    }
                }
                return .success(["id": 123])
            }
            reads += 1
            if failure == "read" { return .success(["id": 123, "title": "错误内容"]) }
            if failure == "date" { return .success(expected.merging(["id": 123, "planned_date": "2026-10-14"]) { _, new in new }) }
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
        // 缺少计划/截止日期才默认今天；明确的未来排期不被今天覆盖，提醒独立保留。
        let schedules: [([String: Any], String?, [String])] = [
            ([:], "2026-10-13", ["计划日期：2026-10-13"]),
            (["plannedDate": NSNull(), "dueAt": ""], "2026-10-13", ["计划日期：2026-10-13"]),
            (["remindAt": "2026-10-14T09:00"], "2026-10-13", ["计划日期：2026-10-13"]),
            (["plannedDate": "2026-10-20"], "2026-10-20", ["计划日期：2026-10-20"]),
            (["dueAt": "2026-10-20T17:00"], nil, ["截止：2026-10-20 17:00"]),
            (["plannedDate": "2026-10-20", "dueAt": "2026-10-21T17:00"], "2026-10-20", ["计划日期：2026-10-20", "截止：2026-10-21 17:00"])
        ]
        for (schedule, planned, details) in schedules {
            let args: [String: Any] = ["kind": "task", "title": "排期说明", "content": "完整待办正文"].merging(schedule) { _, new in new }
            let input = json(args); let spec = try WorkbenchContent.parse(input, now: today); expected = spec.expected
            assert(spec.body["plannedDate"] as? String == planned && expected["planned_date"] as? String == planned)
            assert(spec.body["remindAt"] as? String == schedule["remindAt"] as? String)
            let t = try task(); let beforeWrites = writes; let beforeReads = reads
            guard case .sent(let receipt) = WorkbenchContent.perform(arguments: input, taskId: t.id, authorized: { true }, now: today) else {
                assertionFailure("待办创建应保存并返回核实回执"); continue
            }
            assert(writes == beforeWrites + 1 && reads == beforeReads + 1)
            assert(receipt.contains("ID：123") && details.allSatisfy(receipt.contains))
            assert(!receipt.contains("未排期"))
        }
        // 午夜后原操作沿用已核实回执或 pending，只有新任务才采用新一天。
        let undated = json(["kind": "task", "title": "跨午夜", "content": "正文"])
        let first = try WorkbenchContent.parse(undated, now: today); let next = try WorkbenchContent.parse(undated, now: tomorrow)
        assert(next.body["plannedDate"] as? String == "2026-10-14")
        let legacyData = try JSONSerialization.data(withJSONObject: ["kind": "task", "body": ["title": "跨午夜", "notes": "正文"]], options: [.sortedKeys])
        let legacyKey = SHA256.hash(data: legacyData).map { String(format: "%02x", $0) }.joined()
        for mode in ["", "write", "date"] {
            let t = try task(); let before = writes; failure = mode; expected = first.expected
            let original = WorkbenchContent.perform(arguments: undated, taskId: t.id, authorized: { true }, now: today)
            assert(sent(original) == mode.isEmpty)
            assert(TaskStore.task(id: t.id)?.workbenchOperations?[legacyKey] != nil)
            failure = ""; try TaskStore.save(t); TaskStore.resetCache(directory: directory)
            let replay = WorkbenchContent.perform(arguments: undated, taskId: t.id, authorized: { true }, now: tomorrow)
            assert(sent(replay) == mode.isEmpty && writes == before + 1)
            if case .sent(let receipt) = replay { assert(receipt.contains("计划日期：2026-10-13")) }
        }
        let legacy = try task(); _ = try TaskStore.workbenchOperation(id: legacy.id, key: legacyKey)
        let beforeLegacy = writes
        assert(!sent(WorkbenchContent.perform(arguments: undated, taskId: legacy.id, authorized: { true }, now: today)))
        assert(writes == beforeLegacy, "旧版无日期的未知创建也不能重放")
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
            ["kind":"task","title":"测试","content":"","url":"http://evil.test"],
            ["kind":"task","title":"测试","content":"","plannedDate":"2026-02-30"]
        ] { assert(!sent(WorkbenchContent.perform(arguments: json(value), taskId: t.id, authorized: { true }))) }
        assert(writes == before)
        // 原子占用：同一键只能一个调用获得首次执行权。
        var claims = 0; let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if try! TaskStore.workbenchOperation(id: t.id, key: "parallel") == nil { lock.lock(); claims += 1; lock.unlock() }
        }
        assert(claims == 1)
        let routedInput = json(["kind": "task", "title": "测试", "content": "完整内容"])
        expected = try WorkbenchContent.parse(routedInput).expected
        let routed = try task(); var turns = 0
        AgentRunner.canControl = { _ in true }
        AgentRunner.sendModel = { _, messages, tools, _, done in
            turns += 1
            assert((tools ?? []).contains { ($0["function"] as? [String: Any])?["name"] as? String == "create_workbench_task" })
            assert((messages.first?["content"] as? String)?.contains("由执行器默认安排到今天") == true)
            if turns == 1 {
                let calls: [[String: Any]] = [["id":"fixture", "type":"function", "function":["name":"create_workbench_task", "arguments": json(["title":"测试", "content":"完整内容"])]]]
                done(.success(ModelTurn(toolCalls:calls, rawMessage:["role":"assistant","tool_calls":calls])))
            } else {
                let receipt = messages.last?["content"] as! String; assert(receipt.contains("个人工作台") && receipt.contains("123"))
                done(.success(ModelTurn(content:receipt, rawMessage:["role":"assistant","content":receipt])))
            }
        }
        let completed = DispatchSemaphore(value: 0)
        AgentRunner.run(config:ModelConfig(baseURL:"https://invalid.test",model:"fixture",apiKey:"fixture"),task:routed) { result in
            assert(result.error == nil && result.content?.contains("待办") == true && result.content?.contains("计划日期：" + (expected["planned_date"] as! String)) == true); completed.signal()
        }
        assert(completed.wait(timeout:.now()+5) == .success)
        print("PASS workbench: four types, default today, explicit dates, midnight and legacy deduplication, schedule receipts, readback, stale save/restart, unknown write/read, lease, validation, atomic claim, runner routing")
    }
}
