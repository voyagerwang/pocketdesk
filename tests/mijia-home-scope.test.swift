/**
 * [INPUT]: MijiaHomeScope 真实临时文件、Gateway/HTTP 的真实范围入口，以及账号、网络与任务存储替身。
 * [OUTPUT]: 验证家庭选择按账号持久化、损坏时拒绝访问、跨家庭与迟到准备拒绝，以及保存/换账号和执行互斥。
 * [POS]: tests 的米家家庭隔离回归；不读取正式账号、不启动真实网络或设备，文件仅写唯一临时目录。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin
import CryptoKit

enum Util { static func qrPNG(_ text: String) -> Data? { Data(text.utf8) } }
enum AgentRunner {
    enum ToolOutcome { case sent(String), needsInput(String), failed(String) }
}
enum TaskStore {
    struct Task { var status = Status.running; var mijiaOperations: [String: String]? }
    enum Status { case running }
    static var claims: [String: String] = [:]
    static var legacyByTask: [String: [String: String]] = [:]
    static func task(id: String) -> Task? { Task(mijiaOperations: legacyByTask[id]) }
    static func mijiaOperation(id: String, key: String, receipt: String? = nil) throws -> String? {
        let key = id + key
        if let receipt { claims[key] = receipt; return receipt }
        if let previous = claims[key] { return previous }
        claims[key] = "pending"; return nil
    }
}

private final class Fixture {
    let directory: URL
    let authURL: URL
    let fileURL: URL
    var homeRows: [[String: String]] = [["id": "home-1", "name": "我的家"], ["id": "home-2", "name": "我的家"]]
    var networkFailure = false
    var requestedOperations: [String] = []
    lazy var scope = MijiaHomeScope(dependencies: dependencies())
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mijia-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        authURL = directory.appendingPathComponent("auth.json"); fileURL = directory.appendingPathComponent("home-scope.json")
        try account("first-isolated-account")
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func dependencies() -> MijiaHomeScope.Dependencies {
        var value = MijiaHomeScope.Dependencies()
        value.authURL = authURL; value.fileURL = fileURL
        value.invoke = { [weak self] request in
            guard let self else { return .failure(.init(kind: "network", message: "gone")) }
            requestedOperations.append(request["operation"] as? String ?? "")
            return networkFailure ? .failure(.init(kind: "network", message: "isolated network failure")) : .success(["homes": homeRows])
        }
        return value
    }
    func account(_ id: String) throws {
        try JSONSerialization.data(withJSONObject: ["userId": id, "serviceToken": "isolated-not-real"]).write(to: authURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }
    func select(_ id: String = "home-1") throws { _ = try scope.saveSelection(homeID: id).get() }
    func saved() -> Data? { try? Data(contentsOf: fileURL) }
}

@main struct MijiaHomeScopeTests {
    static var checks = 0
    static var failures: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1; if !value() { failures.append(label) }
    }
    static func denied(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    static func needsInput(_ value: AgentRunner.ToolOutcome) -> Bool { if case .needsInput = value { return true }; return false }
    static func failed(_ value: AgentRunner.ToolOutcome) -> Bool { if case .failed = value { return true }; return false }
    static func sent(_ value: AgentRunner.ToolOutcome) -> Bool { if case .sent = value { return true }; return false }
    static func run(_ values: [String: Any], task: String = UUID().uuidString) -> AgentRunner.ToolOutcome {
        MijiaGateway.perform(arguments: MijiaGateway.encode(values), taskId: task, authorized: { true })
    }
    static func main() throws {
        // ---------- 账号绑定的持久化选择，始终不默认全部家庭 ----------
        do {
            let f = try Fixture()
            check(denied { _ = try f.scope.authorize() }, "未选择家庭禁止授权")
            let list = try f.scope.homeList().get()
            check(list["selectionRequired"] as? Bool == true && list["selectedHomeId"] is NSNull, "未配置清单要求显式选择")
            check((list["homes"] as? [[String: String]])?.count == 2, "同名家庭保留两个真实ID候选")
            check(f.saved() == nil && f.requestedOperations == ["list_homes"], "读取清单只读且不自动选第一项")
            try f.select("home-2")
            check((try? f.scope.authorize().homeID) == "home-2", "只按真实ID选择同名家庭")
            let reloaded = MijiaHomeScope(dependencies: f.dependencies())
            check((try? reloaded.authorize().homeID) == "home-2", "新实例重载持久选择")
            let saved = String(data: f.saved()!, encoding: .utf8)!
            check(!saved.contains("first-isolated-account") && !saved.contains("isolated-not-real"), "范围文件仅含账号摘要，不含uid或凭证")
            let attrs = try FileManager.default.attributesOfItem(atPath: f.fileURL.path)
            let parentAttrs = try FileManager.default.attributesOfItem(atPath: f.directory.path)
            check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (parentAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "范围文件0600且父目录0700")
            check(denied { _ = try f.scope.authorize(homeID: "home-1") }, "请求家庭与已选范围不同即拒绝")
            let before = f.saved()
            check(denied { _ = try f.scope.saveSelection(homeID: "unknown-home").get() }, "不存在的家庭不能选择")
            check(f.saved() == before, "未知家庭不改写原配置")
            f.networkFailure = true
            check(denied { _ = try f.scope.saveSelection(homeID: "home-1").get() }, "网络失败不保存新选择")
            check(f.saved() == before && (try? f.scope.authorize().homeID) == "home-2", "网络失败保留已授权家庭")
            f.networkFailure = false
            var dependencies = f.dependencies(); dependencies.save = { _, _ in throw CocoaError(.fileWriteNoPermission) }
            let unwritable = MijiaHomeScope(dependencies: dependencies)
            check(denied { _ = try unwritable.saveSelection(homeID: "home-1").get() }, "存储失败明确拒绝新选择")
            check(f.saved() == before && (try? f.scope.authorize().homeID) == "home-2", "保存失败保留原文件与授权")
            try f.account("second-isolated-account")
            check(denied { _ = try f.scope.authorize() }, "切换账号立即使旧家庭选择失效")
            let switched = try f.scope.homeList().get()
            check(switched["selectionRequired"] as? Bool == true && switched["selectedHomeId"] is NSNull, "切换账号不能沿用同ID家庭或自动选择")
            try f.select("home-1")
            check((try? f.scope.authorize().homeID) == "home-1", "新账号显式选择后恢复授权")
        }
        do {
            let f = try Fixture(); try f.select()
            try Data("corrupt".utf8).write(to: f.fileURL)
            check(denied { _ = try f.scope.authorize() }, "损坏配置禁止设备访问")
            check((try? f.scope.homeList().get()["selectionRequired"] as? Bool) == true, "损坏配置要求重新选择")
            try f.select()
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.fileURL.path)
            check(denied { _ = try f.scope.authorize() }, "非私有范围文件拒绝授权")
            try f.select()
            var document = try JSONSerialization.jsonObject(with: f.saved()!) as! [String: Any]
            document["version"] = 999
            try JSONSerialization.data(withJSONObject: document).write(to: f.fileURL)
            check(denied { _ = try f.scope.authorize() }, "未知范围版本不猜测迁移")
        }
        do {
            let f = try Fixture(); try f.select(); let before = f.saved()
            var dependencies = f.dependencies()
            dependencies.invoke = { _ in .success(["homes": [["id": "home-2", "name": "家"]], "truncated": true]) }
            let incomplete = MijiaHomeScope(dependencies: dependencies)
            check(denied { _ = try incomplete.homeList().get() }, "不完整家庭列表不能冒充完整候选")
            check(denied { _ = try incomplete.saveSelection(homeID: "home-2").get() } && f.saved() == before, "列表截断时不能保存选择且保留旧文件")
        }

        // ---------- Gateway 强制注入范围并拒绝目标漂移 ----------
        do {
            let f = try Fixture(); MijiaGateway.scope = f.scope
            var calls: [[String: Any]] = []
            MijiaGateway.invoke = { calls.append($0); return .success(["authenticated": true]) }
            check(needsInput(run(["operation": "list_devices"])), "未选家庭的模型查询要求用户选择")
            check(needsInput(run(["operation": "set_property", "device": "foreign-did", "property": "2.1", "value": true])), "未选家庭的设备写入拒绝")
            check(calls.isEmpty, "未选择家庭没有SDK调用")
            check(sent(run(["operation": "status"])) && calls.count == 1, "只读账号status不要求家庭")
            if case .sent(let status) = run(["operation": "status"]) {
                let value = try JSONSerialization.jsonObject(with: Data(status.utf8)) as! [String: Any]
                check(value["scopeRequired"] as? Bool == true && value["selectedHomeId"] is NSNull, "账号已连但未选家庭时status明确尚需选择")
            } else { check(false, "未选家庭status应正常返回") }
            calls.removeAll(); try f.select()
            if case .sent(let status) = run(["operation": "status"]) {
                let value = try JSONSerialization.jsonObject(with: Data(status.utf8)) as! [String: Any]
                check(value["scopeRequired"] as? Bool == false && value["selectedHomeId"] as? String == "home-1" && !status.contains("first-isolated-account"), "已选范围status只返回家庭信息不返回账号标识")
            } else { check(false, "已选家庭status应正常返回") }
            calls.removeAll()
            check(needsInput(run(["operation": "list_devices", "home_id": "home-2"])) && calls.isEmpty, "模型参数不能扩大家庭")
            check(sent(run(["operation": "list_devices", "query": "灯"])) && calls.last?["home_id"] as? String == "home-1", "查询强制注入持久家庭ID")
            calls.removeAll()
            MijiaGateway.invoke = { request in calls.append(request); return .failure(.init(kind: "scope", message: "设备不在家庭范围")) }
            check(needsInput(run(["operation": "device_info", "device": "foreign-did"])) && calls[0]["home_id"] as? String == "home-1", "直接did也带家庭并遵守桥接拒绝")
            calls.removeAll()
            check(needsInput(run(["operation": "run_scene", "scene": "scene-1"])) && calls.isEmpty, "无法证明影响范围的场景拒绝执行")
            check(needsInput(run(["operation": "action", "device": "speaker", "action": "5.1", "inputs": ["查看摄像头"]])) && calls.isEmpty, "通用音箱动作不能绕过最小能力边界")
            check(needsInput(run(["operation": "list_scenes"])) && calls.isEmpty, "不把敏感场景名称交给模型")
            let request: [String: Any] = ["operation": "set_property", "device": "同名灯", "property": "2.1", "value": true]
            var writes = 0
            MijiaGateway.invoke = { value in
                if value["operation"] as? String == "prepare" {
                    let inner = value["request"] as! [String: Any]
                    check(inner["home_id"] as? String == "home-1", "准备阶段也强制家庭范围")
                    var canonical = inner; canonical["device"] = "same-name-other-home"; canonical["home_id"] = "home-2"
                    return .success(["request": canonical])
                }
                writes += 1; return .success(["status": "verified", "message": "isolated receipt"])
            }
            check(failed(run(request)) && writes == 0, "prepare返回其他家庭目标时零写入")
            let claims = TaskStore.claims.count
            MijiaGateway.invoke = { value in
                if value["operation"] as? String == "prepare" {
                    let canonical = value["request"] as! [String: Any]
                    _ = f.scope.saveSelection(homeID: "home-2")
                    return .success(["request": canonical])
                }
                writes += 1; return .success(["status": "verified", "message": "isolated receipt"])
            }
            check(needsInput(run(request)) && writes == 0 && TaskStore.claims.count == claims, "准备在途时切换家庭，迟到准备不能占用或写入旧家庭")
            try f.select()
            MijiaGateway.invoke = { value in
                if value["operation"] as? String == "prepare" { return .success(["request": value["request"]!]) }
                writes += 1; check(value["home_id"] as? String == "home-1", "实际执行带已选家庭")
                return .success(["status": "verified", "message": "isolated receipt"])
            }
            check(sent(run(request)) && writes == 1, "合法范围内的规范请求执行一次")
            var canonical = request; canonical["home_id"] = "home-1"
            let legacyKey = SHA256.hash(data: Data(MijiaGateway.encode(canonical).utf8)).map { String(format: "%02x", $0) }.joined()
            for oldReceipt in ["pending", "旧版已完成回执"] {
                let taskID = UUID().uuidString
                TaskStore.legacyByTask[taskID] = [legacyKey: oldReceipt]
                check(needsInput(run(request, task: taskID)) && writes == 1, "旧版台账 \(oldReceipt) 不换摘要重放，也不冒充当前账号成功")
            }
        }

        // ---------- 已发调用与选择保存/账号替换使用同一锁 ----------
        do {
            let f = try Fixture(); try f.select(); let ticket = try f.scope.authorize()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = try? f.scope.withAuthorization(ticket) { entered.signal(); _ = release.wait(timeout: .now() + 5) }
                finished.signal()
            }
            check(entered.wait(timeout: .now() + 2) == .success, "旧家庭已发操作取得范围锁")
            let saved = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = f.scope.saveSelection(homeID: "home-2"); saved.signal() }
            check(saved.wait(timeout: .now() + 0.05) == .timedOut, "家庭保存等待旧家庭已发调用结束")
            release.signal()
            check(finished.wait(timeout: .now() + 2) == .success && saved.wait(timeout: .now() + 2) == .success, "调用结束后家庭保存完成")
            check(denied { _ = try f.scope.withAuthorization(ticket) { 1 } }, "保存完成后旧授权票据永久无效")
            let current = try f.scope.authorize()
            DispatchQueue.global().async {
                _ = try? f.scope.withAuthorization(current) { entered.signal(); _ = release.wait(timeout: .now() + 5) }
                finished.signal()
            }
            check(entered.wait(timeout: .now() + 2) == .success, "账号替换前现有调用持锁")
            let replaced = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { f.scope.withAccountReplacement { try? f.account("replacement-isolated-account") }; replaced.signal() }
            check(replaced.wait(timeout: .now() + 0.05) == .timedOut, "扫码账号提交等待已发调用结束")
            release.signal()
            check(finished.wait(timeout: .now() + 2) == .success && replaced.wait(timeout: .now() + 2) == .success, "调用结束后替换账号")
            check(denied { _ = try f.scope.withAuthorization(current) { 1 } }, "账号替换后旧票据不能执行")
        }

        // ---------- HTTP 家庭接口异步执行并限制参数 ----------
        do {
            let f = try Fixture()
            var connectionDependencies = MijiaConnection.Dependencies(); connectionDependencies.authURL = f.directory.appendingPathComponent("no-connection-auth")
            let connection = MijiaConnection(dependencies: connectionDependencies)
            func http(_ method: String, _ path: String, _ body: String = "") -> (Int, [String: Any]) {
                let done = DispatchSemaphore(value: 0); var code = 0; var output: [String: Any] = [:]
                let handled = MijiaHTTP.handle(method: method, path: path, rawPath: path, body: Data(body.utf8), connection: connection, scope: f.scope) { status, data, _ in
                    code = status; output = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]; done.signal()
                }
                check(handled && done.wait(timeout: .now() + 2) == .success, "家庭HTTP在有界时间回包")
                return (code, output)
            }
            let homes = http("GET", "/api/console/mijia/homes")
            check(homes.0 == 200 && homes.1["selectionRequired"] as? Bool == true, "GET homes返回候选及未选状态")
            let chosen = http("POST", "/api/console/mijia/home", "{\"homeId\":\"home-2\"}")
            check(chosen.0 == 200 && chosen.1["selectedHomeId"] as? String == "home-2", "POST home核验并持久化真实ID")
            check(http("POST", "/api/console/mijia/home", "{\"homeId\":\"home-1\",\"extra\":true}").0 == 400, "家庭选择拒绝额外字段")
            check(http("POST", "/api/console/mijia/home", "[]").0 == 400, "家庭选择拒绝数组")
            check(http("POST", "/api/console/mijia/home", "{\"homeId\":\"unknown\"}").0 == 409, "未知家庭HTTP拒绝并保留原选择")
            check((try? f.scope.authorize().homeID) == "home-2", "非法请求不改变家庭")
            f.networkFailure = true
            check(http("GET", "/api/console/mijia/homes").0 == 502, "家庭网络错误明确返回失败")
        }
        for failure in failures { print("FAIL: \(failure)") }
        print("Mijia home scope: \(checks - failures.count)/\(checks) checks passed")
        if !failures.isEmpty { exit(1) }
    }
}
