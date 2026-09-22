/**
 * [INPUT]: Foundation/CryptoKit、Bridge 纯编码与配置函数；不连接生产服务。
 * [OUTPUT]: 同机限制、稳定调用关联、跨语言摘要、G2 固定路径与真实只读 HTTP 断言。
 * [POS]: G1 Swift 消费端契约验证；不代表手机真机切流验收。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
@main struct WorkbenchBridgeTests {
    static func main() async throws {
        var env = ["POCKETDESK_BRIDGE_ENABLED": "1", "POCKETDESK_BRIDGE_TOKEN": String(repeating: "a", count: 32), "POCKETDESK_DEVICE_ID": "test-mac"]
        let config = WorkbenchBridge.Configuration.load(env)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        precondition(WorkbenchBridge.Configuration.loadLocal(file: file, env: [:]) == nil)
        try JSONEncoder().encode(env).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        precondition(WorkbenchBridge.Configuration.loadLocal(file: file, env: [:])?.device == "test-mac")
        precondition(WorkbenchBridge.Configuration.loadLocal(file: file, env: ["POCKETDESK_BRIDGE_ENABLED": "0"]) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        precondition(WorkbenchBridge.Configuration.loadLocal(file: file, env: [:]) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("invalid".utf8).write(to: file)
        precondition(WorkbenchBridge.Configuration.loadLocal(file: file, env: [:]) == nil)
        for path in ["capabilities", "requests/req-1", "artifacts/1", "views/tasks", "views/tasks/20", "views/memories", "views/task-result/20260922-1"] {
            precondition(WorkbenchBridge.readPath("/api/v1/workbench/" + path) == "api/bridge/" + path)
        }
        for path in ["views/tasks/0", "views/tasks/-1", "views/tasks/9007199254740992", "views/tasks?owner=x", "views/tasks//1", "views/task-result/../x", "views/task-result/%2e%2e", "artifacts/abc", "../tasks", "views/tasks/"] {
            precondition(WorkbenchBridge.readPath("/api/v1/workbench/" + path) == nil)
        }
        for url in ["http://example.com", "http://localhost:8787", "http://127.0.0.1@evil.com", "http://127.0.0.1:8787/a", "http://127.0.0.1?x=1"] {
            env["WORKBENCH_BRIDGE_URL"] = url; precondition(WorkbenchBridge.Configuration.load(env) == nil)
        }
        let invocation = try WorkbenchBridge.invocation(requestID: "req-1", title: "手机笔记", body: "测试正文 / 中文\n保留尾空白 ", subject: String(repeating: "b", count: 64), configuration: config)
        precondition(invocation["operationId"] as? String == "note-req-1")
        precondition(invocation["capabilityId"] as? String == "note.create")
        precondition(invocation["argumentHash"] as? String == "6d1ac34efeafae6caec595a581413b03bd1cc18464fdce43a105571658159fc1")
        precondition((try? WorkbenchBridge.invocation(requestID: "../escape", title: "x", body: "x", subject: "x", configuration: config)) == nil)
        if CommandLine.arguments.contains("--integration") {
            let live = WorkbenchBridge.Configuration.load()!
            let subject = String(repeating: "b", count: 64)
            let payload = try WorkbenchBridge.invocation(requestID: "swift-integration", title: "手机笔记", body: "测试正文 / 中文\n保留尾空白 ", subject: subject, configuration: live)
            func send(_ path: String, _ body: [String: Any]? = nil) async -> (Int, [String: Any]) {
                await withCheckedContinuation { continuation in
                    WorkbenchBridge.request(configuration: live, subject: subject, path: path, method: body == nil ? "GET" : "POST", payload: body) { code, value in
                        continuation.resume(returning: (code, value))
                    }
                }
            }
            let first = await send("api/bridge/pocketdesk/inbound", payload)
            precondition(first.0 == 200 && first.1["state"] as? String == "succeeded", "\(first)")
            let again = await send("api/bridge/pocketdesk/inbound", payload)
            precondition(NSDictionary(dictionary: first.1).isEqual(to: again.1))
            let recovered = await send("api/bridge/requests/swift-integration")
            precondition(NSDictionary(dictionary: first.1).isEqual(to: recovered.1))
            let artifact = (first.1["artifacts"] as! [[String: Any]])[0]["id"] as! String
            let read = await send("api/bridge/artifacts/\(artifact)")
            precondition(read.0 == 200 && read.1["content"] as? String == "测试正文 / 中文\n保留尾空白 ")
            let tasks = await send(WorkbenchBridge.readPath("/api/v1/workbench/views/tasks")!)
            precondition(tasks.0 == 200 && tasks.1["scopeRef"] as? String == "workbench:owner", "\(tasks)")
            precondition((tasks.1["tasks"] as? [[String: Any]])?.first?["objective"] as? String == "Swift 只读任务")
            let memories = await send(WorkbenchBridge.readPath("/api/v1/workbench/views/memories")!)
            precondition(memories.0 == 200 && memories.1["projection"] as? String == "memory_page")
            precondition((memories.1["entries"] as? [[String: Any]])?.first?["content"] as? String == "Swift 显式记忆")
            print("Swift → Workbench HTTP：提交、同键重投、查账、真实成果读回通过")
            print("Swift → Workbench G2：固定路径、任务与机主记忆真实只读 HTTP 通过")
        } else {
            print("Swift Bridge：配置边界、稳定编号、跨语言摘要通过")
        }
    }
}
