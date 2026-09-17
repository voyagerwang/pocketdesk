/**
 * [INPUT]: CLI 帮助/执行替身、临时 TaskStore，--live 仅查询现有授权和一页群列表。
 * [OUTPUT]: 通用业务域读取/写入、重复执行拦截、风险确认续接、参数注入隔离和群聊解析断言。
 * [POS]: 不产生真实消息或业务写入的飞书通用入口回归。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct GatewayTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        TaskStore.resetCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        func task() throws -> AgentTask {
            var task = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: "明确测试指令", context: nil)
            task.status = .running; try TaskStore.save(task); return task
        }
        var risk = "read"
        var calls: [[String]] = []
        FeishuGateway.help = { _ in .success(["help": "Risk: " + risk + "\n --query string\n --data string\n --flag bool\n --yes "]) }
        FeishuGateway.invoke = { calls.append($0); return .success(["ok": true]) }
        let t = try task()
        let options: [String: Any] = ["query": "--as bot; $(echo secret)", "flag": true]
        guard case .sent = FeishuGateway.perform(command: ["im", "+chat-search"], options: options, confirmed: false, taskId: t.id, authorized: { true }) else { fatalError("read") }
        assert(calls.last!.contains("--query=--as bot; $(echo secret)"))
        assert(calls.last!.contains("--flag=true"))
        let n = calls.count
        for command in [["auth", "token"], ["config", "show"], ["api", "GET"], ["im;echo", "bad"]] {
            guard case .failed = FeishuGateway.perform(command: command, options: [:], confirmed: false, taskId: t.id, authorized: { true }) else { fatalError("invalid root") }
        }
        guard case .failed = FeishuGateway.perform(command: ["im", "+chat-search"], options: ["as": "bot"], confirmed: false, taskId: t.id, authorized: { true }) else { fatalError("identity") }
        assert(calls.count == n)
        risk = "write"
        _ = FeishuGateway.perform(command: ["docs", "+create"], options: [:], confirmed: false, taskId: t.id, authorized: { true })
        let once = calls.count
        _ = FeishuGateway.perform(command: ["docs", "+create"], options: [:], confirmed: false, taskId: t.id, authorized: { true })
        assert(calls.count == once)
        risk = "high-risk-write"
        guard case .needsInput = FeishuGateway.perform(command: ["drive", "+delete"], options: [:], confirmed: true, taskId: t.id, authorized: { true }) else { fatalError("new risk requires user turn") }
        var follow = TaskStore.task(id: t.id)!; follow.supplementCount += 1; try TaskStore.save(follow)
        guard case .sent = FeishuGateway.perform(command: ["drive", "+delete"], options: [:], confirmed: true, taskId: t.id, authorized: { true }) else { fatalError("confirmed") }
        assert(calls.last!.contains("--yes"))
        let group = try task()
        FeishuMessaging.invoke = { args in
            calls.append(args)
            if args.contains("+chat-search") { return .success(["chats": [["chat_id":"oc_group", "name":"项目群", "description":"项目讨论"]], "has_more":false]) }
            return .success(["message_id":"om_test"])
        }
        guard case .sent = FeishuMessaging.perform(recipient: "项目群", text: "明天开会", choice: nil, taskId: group.id, kind: "group", authorized: { true }) else { fatalError("group send") }
        assert(calls.last!.contains("--chat-id") && calls.last!.contains("oc_group") && !calls.last!.contains("--user-id"))
        if CommandLine.arguments.contains("--live") {
            guard case .success(let auth) = FeishuCLI.capabilities(), auth["verified"] as? Bool == true else { fatalError("auth") }
            guard case .success = FeishuCLI.run(["im", "+chat-list", "--page-size", "1", "--as", "user", "--format", "json"]) else { fatalError("group read") }
            guard case .success(let doc) = FeishuCLI.help(["docs"]), doc["help"] != nil else { fatalError("help") }
            print("live: shared authorization / group read / domain help passed; no writes")
        }
        print("gateway: discovery / arguments / identity / dedupe / confirmation / group passed")
    }
}
