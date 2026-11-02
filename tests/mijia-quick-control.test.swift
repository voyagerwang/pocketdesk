/**
 * [INPUT]: 灯光/空调插座快路径、真实Gateway与家庭票据；临时绑定/任务及云请求替身。
 * [OUTPUT]: 验证零模型单句、不可变绑定、失权/跨家庭/规格拒绝、持久防重和失败不重发。
 * [POS]: 固定设备延迟优化的授权回归；不读取正式账号，不连接真实设备。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin

enum Usage { case zero }
struct TaskRecovery { enum Kind { case executionFailure }; let kind: Kind }
struct AgentTask {
    enum Status { case running, succeeded }
    let id: String
    var text: String
    var attempt = 1
    var supplementCount = 0
    var context: Int? = nil
    var transcript: [[String: Any]]? = nil
    var status = Status.running
    var mijiaOperations: [String: String]? = nil
}
enum AgentRunner {
    enum ToolOutcome { case sent(String), needsInput(String), failed(String) }
    struct Outcome {
        var content: String?; var usage: Usage; var error: String?; var pages: [String]; var rounds: Int
        var drifted: Bool; var needsInput = false; var recovery: TaskRecovery? = nil
    }
    static var canControl: (String) -> Bool = { _ in true }
}
enum TaskStore {
    static var rows: [String: AgentTask] = [:]
    static func task(id: String) -> AgentTask? { rows[id] }
    static func save(_ task: AgentTask) throws { rows[task.id] = task }
    static func mijiaOperation(id: String, key: String, receipt: String? = nil) throws -> String? {
        let previous = rows[id]?.mijiaOperations?[key]
        if receipt == nil && previous != nil { return previous }
        var record = rows[id]!
        record.mijiaOperations = record.mijiaOperations ?? [:]
        record.mijiaOperations?[key] = receipt ?? "pending"
        rows[id] = record
        return previous
    }
}
@main struct QuickLightTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !condition() { print("FAIL: " + label); exit(1) }
    }
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-light-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auth = dir.appendingPathComponent("auth.json"), selected = dir.appendingPathComponent("home-scope.json")
        try Data("{\"userId\":\"isolated\"}".utf8).write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        var dep = MijiaHomeScope.Dependencies(); dep.authURL = auth; dep.fileURL = selected
        dep.invoke = { _ in .success(["homes": [["id": "one", "name": "Test"], ["id": "two", "name": "Other"]]]) }
        let scope = MijiaHomeScope(dependencies: dep); _ = try scope.saveSelection(homeID: "one").get()
        MijiaGateway.scope = scope
        let ticket = try scope.authorize()
        let binding = MijiaQuickControl.Binding(version: 1, account: ticket.account, homeID: ticket.homeID,
            revision: ticket.revision, deviceID: "light-one", propertyID: "2.1", name: "客厅灯",
            aliases: ["灯", "客厅灯", "客厅的灯", "示例家庭客厅的灯"])
        let path = dir.appendingPathComponent("quick-light.json"); MijiaQuickControl.bindingURL = path
        try JSONEncoder().encode(binding).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        defer { chflags(path.path, 0); try? FileManager.default.removeItem(at: dir) }
        check((try? MijiaQuickControl.load()) == nil, "可变绑定不授权")
        check(chflags(path.path, UInt32(UF_IMMUTABLE)) == 0, "封存隔离绑定")
        check((try? MijiaQuickControl.load())?.deviceID == "light-one", "读取私有不可变绑定")
        for text in ["帮我熄灯", "关灯", "请关闭示例家庭客厅的灯", "把客厅灯关掉"] {
            check(MijiaQuickControl.request(in: text, aliases: binding.aliases)?.value == false, text)
        }
        for text in ["开灯", "请帮我打开客厅的灯", "灯打开一下", "亮灯", "帮我亮灯", "打开开灯", "打开灯"] {
            check(MijiaQuickControl.request(in: text, aliases: binding.aliases)?.value == true, text)
        }
        for text in ["不要关灯", "关灯吗", "开灯然后发消息", "如果有人就开灯", "打开我的家台灯", "关闭卧室灯", "开灯\n关灯", "关灯并锁门", "不要亮灯", "亮灯吗", "打开开灯并锁门"] {
            check(MijiaQuickControl.request(in: text, aliases: binding.aliases) == nil, "不误写：" + text)
        }
        let acPath = dir.appendingPathComponent("quick-ac.json")
        let ac = MijiaQuickControl.Binding(version: 1, account: ticket.account, homeID: ticket.homeID,
            revision: ticket.revision, deviceID: "socket-one", propertyID: "2.1", name: "空调插座",
            aliases: ["空调", "空调插座"])
        try JSONEncoder().encode(ac).write(to: acPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: acPath.path)
        check(chflags(acPath.path, UInt32(UF_IMMUTABLE)) == 0, "封存独立插座绑定")
        defer { chflags(acPath.path, 0) }
        for (text, value) in [("打开空调", true), ("关闭空调", false), ("帮我开空调", true)] {
            let resolved = MijiaQuickControl.resolve(text)
            check(resolved?.0.deviceID == "socket-one" && resolved?.1.value == value, "插座路由：" + text)
        }
        check(MijiaQuickControl.resolve("亮空调") == nil, "亮灯语法不扩展到空调")
        check(MijiaQuickControl.resolve("打开开灯")?.0.deviceID == "light-one", "口误只控制原灯")
        check(MijiaQuickControl.resolve("打开空调并开灯") == nil, "复合请求不单独通电")
        var calls: [[String: Any]] = []
        MijiaGateway.invoke = { request in
            calls.append(request)
            check(request["operation"] as? String == "set_property", "无额外发现/模型前置调用")
            check(request["home_id"] as? String == "one" && request["device"] as? String == "light-one", "固定目标")
            check(request["value"] as? Bool == false, "准确关闭")
            return .success(["status": "verified", "message": "设备直接读回关闭。"])
        }
        func run(_ id: String, text: String = "帮我熄灯", configure: ((inout AgentTask) -> Void)? = nil) -> AgentRunner.Outcome? {
            var task = AgentTask(id: id, text: text); configure?(&task); TaskStore.rows[id] = task
            let done = DispatchSemaphore(value: 0); var output: AgentRunner.Outcome?
            let accepted = AgentRunner.tryQuickControl(task: task) { output = $0; done.signal() }
            if !accepted { return nil }
            check(done.wait(timeout: .now() + 2) == .success, "快路径返回")
            return output
        }
        let output = run("first")
        check(output?.content == "设备直接读回关闭。" && output?.rounds == 0, "直接真实回执零模型")
        check(calls.count == 1, "只调一次受限桥接")
        let done = DispatchSemaphore(value: 0)
        MijiaGateway.executeBound(.init(ticket: ticket, device: "light-one", property: "2.1", value: false), taskId: "first", authorized: { true }) { _ in done.signal() }
        check(done.wait(timeout: .now() + 2) == .success && calls.count == 1, "同任务同操作不重写")
        AgentRunner.canControl = { _ in false }
        check(run("denied")?.error != nil, "失权不写")
        check(calls.count == 1, "失权零云调用")
        AgentRunner.canControl = { _ in true }
        check(run("followup", configure: { $0.supplementCount = 1 }) == nil, "补充不快跑")
        check(run("context", configure: { $0.context = 1 }) == nil, "页面上下文不快跑")
        MijiaGateway.invoke = { _ in calls.append([:]); return .failure(.init(kind: "scope", message: "设备已迁出，拒绝。")) }
        check(run("moved")?.needsInput == true, "Python迁出/规格失败不变成功")
        let previous = calls.count
        let refused = DispatchSemaphore(value: 0)
        MijiaGateway.executeBound(.init(ticket: ticket, device: "light-one", property: "2.1", value: false), taskId: "moved", authorized: { true }) { _ in refused.signal() }
        check(refused.wait(timeout: .now() + 2) == .success && calls.count == previous, "不明失败不重发")
        MijiaGateway.invoke = { request in
            calls.append(request)
            check(request["device"] as? String == "socket-one" && request["value"] as? Bool == true, "空调别名仅写已绑定插座")
            return .success(["status": "verified", "message": "插座已通电并读回。"])
        }
        check(run("ac", text: "打开空调")?.content == "插座已通电并读回。", "插座共享真实回执流程")
        let afterAC = calls.count
        _ = try scope.saveSelection(homeID: "two").get()
        check(run("changed") == nil && calls.count == afterAC, "家庭漂移不沿用绑定")
        chflags(acPath.path, 0)
        let ambiguous = MijiaQuickControl.Binding(version: 1, account: ticket.account, homeID: ticket.homeID,
            revision: ticket.revision, deviceID: "socket-one", propertyID: "2.1", name: "空调插座", aliases: ["灯"])
        try JSONEncoder().encode(ambiguous).write(to: acPath)
        check(chflags(acPath.path, UInt32(UF_IMMUTABLE)) == 0, "封存歧义夹具")
        check(MijiaQuickControl.resolve("开灯") == nil, "重复别名不按文件顺序通电")
        chflags(acPath.path, 0)
        try Data("invalid".utf8).write(to: acPath)
        check(chflags(acPath.path, UInt32(UF_IMMUTABLE)) == 0, "封存损坏夹具")
        check(MijiaQuickControl.resolve("开灯") == nil, "损坏绑定不猜测目标")
        print("Mijia quick control: \(count) checks passed")
    }
}
