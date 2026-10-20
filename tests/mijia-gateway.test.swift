/**
 * [INPUT]: MijiaGateway 的进程替身、临时家庭授权、真实 TaskStore 和 MijiaBridge 的临时 Python 子进程。
 * [OUTPUT]: 验证模型工具不开放动作/场景、敏感设备说明、准确名称发现提示、云端在线标记原样回灌、真实目标去重、不同确认强度回执、失权零写入、登录/歧义恢复、未知结果不重放及限时 JSON 协议。
 * [POS]: tests 的米家执行边界回归；不访问小米服务，不调用真实设备或正式账号。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin
import CryptoKit

@main struct MijiaGatewayTests {
    static var checks = 0
    static var failures: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !value() { failures.append(label) }
    }
    static func sent(_ result: AgentRunner.ToolOutcome) -> Bool {
        if case .sent = result { return true }; return false
    }
    static func needsInput(_ result: AgentRunner.ToolOutcome) -> Bool {
        if case .needsInput = result { return true }; return false
    }
    static func failed(_ result: AgentRunner.ToolOutcome) -> Bool {
        if case .failed = result { return true }; return false
    }
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mijia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let authFile = temporary.appendingPathComponent("auth.json")
        try Data("{\"userId\":\"isolated-gateway-test\"}".utf8).write(to: authFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
        var homeDependencies = MijiaHomeScope.Dependencies()
        homeDependencies.authURL = authFile; homeDependencies.fileURL = temporary.appendingPathComponent("home-scope.json")
        homeDependencies.invoke = { _ in .success(["homes": [["id": "home-1", "name": "隔离测试家庭"]]]) }
        MijiaGateway.scope = MijiaHomeScope(dependencies: homeDependencies)
        _ = try MijiaGateway.scope.saveSelection(homeID: "home-1").get()
        TaskStore.resetCache(directory: temporary.appendingPathComponent("tasks"))
        func task() throws -> AgentTask {
            var task = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: "打开米家客厅灯", context: nil)
            task.status = .running
            try TaskStore.save(task)
            return task
        }
        let first = try task(), stale = first
        let set: [String: Any] = ["operation": "set_property", "device": "客厅灯", "property": "on", "value": true]
        let canonical: [String: Any] = ["operation": "set_property", "device": "device-1", "home_id": "home-1", "property": "2.1", "value": true]
        var writes = 0, prepared = 0
        MijiaGateway.invoke = { request in
            if request["operation"] as? String == "prepare" {
                prepared += 1
                return .success(["request": canonical, "label": "客厅灯 开关"])
            }
            writes += 1
            check(request["device"] as? String == "device-1", "副作用只接受真实规范化设备")
            return .success(["status": "confirmed", "message": "客厅灯开关已读回确认开启。"])
        }
        func run(_ request: [String: Any], _ id: String, _ authorized: () -> Bool = { true }) -> AgentRunner.ToolOutcome {
            MijiaGateway.perform(arguments: MijiaGateway.encode(request), taskId: id, authorized: authorized)
        }
        check(sent(run(set, first.id)), "确认属性可完成")
        check(writes == 1 && prepared == 1, "准备阶段零写入，确认后只写一次")
        try TaskStore.save(stale)
        TaskStore.resetCache()
        var alias = set; alias["device"] = "device-1"; alias["property"] = "2.1"
        check(sent(run(alias, first.id)), "名称与ID别名返回同一已存回执")
        check(writes == 1, "旧快照及重载不重复写入")
        let legacyKey = SHA256.hash(data: Data(MijiaGateway.encode(canonical).utf8)).map { String(format: "%02x", $0) }.joined()
        for receipt in ["pending", "旧账号已执行"] {
            let legacy = try task()
            _ = try TaskStore.mijiaOperation(id: legacy.id, key: legacyKey)
            if receipt != "pending" { _ = try TaskStore.mijiaOperation(id: legacy.id, key: legacyKey, receipt: receipt) }
            TaskStore.resetCache()
            check(needsInput(run(set, legacy.id)), "重载旧版台账 \(receipt) 后需人工核对")
            check(writes == 1, "旧版台账 \(receipt) 不因新摘要重新发送")
        }
        let uncertain = try task()
        MijiaGateway.invoke = { request in
            if request["operation"] as? String == "prepare" { return .success(["request": canonical]) }
            writes += 1
            return .success(["status": "unconfirmed", "message": "网关接受指令，状态尚未核实。"])
        }
        check(needsInput(run(set, uncertain.id)), "网关未知结果要求核对")
        let uncertainCount = writes
        TaskStore.resetCache()
        check(needsInput(run(set, uncertain.id)), "重载后未知结果仍不重试")
        check(writes == uncertainCount, "未知结果零重放")
        let disconnected = try task()
        var authorized = true
        MijiaGateway.invoke = { _ in authorized = false; return .success(["request": canonical]) }
        check(failed(run(set, disconnected.id, { authorized })), "准备后失去控制权阻止副作用")
        check(TaskStore.task(id: disconnected.id)?.mijiaOperations == nil, "失权不占用新操作")
        let auth = try task()
        MijiaGateway.invoke = { _ in .failure(.init(kind: "auth", message: "请扫码登录米家。")) }
        check(needsInput(run(set, auth.id)), "账号失效返回恢复入口")
        check(TaskStore.task(id: auth.id)?.mijiaOperations == nil, "登录缺失不消耗操作")
        MijiaGateway.invoke = { _ in .failure(.init(kind: "choice", message: "同名设备请选择。", candidates: [["did": "one", "name": "灯"], ["did": "two", "name": "灯"]])) }
        check(needsInput(run(set, auth.id)), "同名设备请求澄清")
        var calls = 0
        MijiaGateway.invoke = { _ in calls += 1; return .success([:]) }
        check(failed(run(["operation": "login"], auth.id)), "模型不能启动登录")
        check(failed(run(["operation": "list_devices", "shell": "anything"], auth.id)), "拒绝任意额外参数")
        check(failed(run(["operation": "list_devices"], auth.id, { false })), "无租约拒绝查询")
        check(calls == 0, "无效操作与失权零子进程")
        MijiaGateway.invoke = { _ in .success(["devices": [["did": "one", "name": "灯"]]]) }
        check(sent(run(["operation": "list_devices"], auth.id)), "真实查询可回灌模型")

        // ---------- 真实 AgentRunner 路由 ----------
        let routed = try task()
        var rounds = 0, routedCalls = 0, sawReceipt = false
        AgentRunner.canControl = { _ in true }
        AgentRunner.resolveQuickApp = { _ in nil }
        AgentRunner.readBookmarks = { [] }
        MijiaGateway.invoke = { request in
            routedCalls += 1
            check(request["query"] == nil && request["home_id"] as? String == "home-1", "未知名称可省略检索词，仍只查询已选家庭")
            return .success(["devices": [["did": "one", "name": "客厅灯", "online": false]]])
        }
        AgentRunner.sendModel = { _, messages, tools, _, done in
            check(tools?.contains { ($0["function"] as? [String: Any])?["name"] as? String == "mijia" } == true, "生产模型工具目录包含米家")
            rounds += 1
            if rounds == 1 {
                let system = messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
                let tool = tools?.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "mijia" }
                let description = tool?["description"] as? String ?? ""
                for prompt in [system, description] {
                    check(prompt.contains("省略 query") && (prompt.contains("完整清单") || prompt.contains("完整设备清单")), "模型提示未知名称先完整发现")
                    check(prompt.contains("摄像头") && prompt.contains("均不开放"), "模型说明敏感设备硬限制")
                    check(prompt.contains("云端在线标记") && prompt.contains("不能断言设备不可控"), "模型提示不把云端离线当不可控证据")
                    check(prompt.contains("灯与开关对应关系") && prompt.contains("询问用户") && prompt.contains("不能猜测"), "模型提示缺少灯与开关映射须澄清")
                }
                let parameters = tool?["parameters"] as? [String: Any]
                let properties = parameters?["properties"] as? [String: Any]
                let operations = (properties?["operation"] as? [String: Any])?["enum"] as? [String] ?? []
                check(!operations.isEmpty && Set(operations).isDisjoint(with: ["action", "run_scene", "list_scenes"]), "工具不向模型开放通用动作和场景")
                let call: [String: Any] = ["id": "mijia-test", "type": "function", "function": ["name": "mijia", "arguments": "{\"operation\":\"list_devices\"}"]]
                done(.success(ModelTurn(toolCalls: [call], rawMessage: ["role": "assistant", "tool_calls": [call]], usage: ["total_tokens": 1])))
            } else {
                sawReceipt = messages.contains { message in
                    guard message["role"] as? String == "tool", let content = message["content"] as? String,
                          let data = content.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let device = (result["devices"] as? [[String: Any]])?.first else { return false }
                    return device["name"] as? String == "客厅灯" && device["online"] as? Bool == false
                }
                done(.success(ModelTurn(content: "已查到客厅灯。", rawMessage: ["role": "assistant", "content": "已查到客厅灯。"], usage: ["total_tokens": 1])))
            }
        }
        var routedOutcome: AgentRunner.Outcome?
        let finished = DispatchSemaphore(value: 0)
        AgentRunner.run(config: ModelConfig(backend: .codex), task: routed, readPage: { .failure(.emptyPage) }) {
            routedOutcome = $0; finished.signal()
        }
        check(finished.wait(timeout: .now() + 5) == .success, "米家真实工具循环可收尾")
        check(rounds == 2 && routedCalls == 1 && sawReceipt && routedOutcome?.error == nil, "真实查询回灌模型后完成，无额外操作")

        // ---------- 写入回执保留确认强度，不由模型预判代替 ----------
        for (status, receipt) in [("verified", "客厅灯开关已读回确认开启。"), ("accepted", "米家已接受客厅灯开启请求，当前状态尚未确认。") ] {
            let controlled = try task()
            var controlRounds = 0, controlWrites = 0, receivedExact = false
            MijiaGateway.invoke = { request in
                if request["operation"] as? String == "prepare" { return .success(["request": canonical]) }
                controlWrites += 1
                return .success(["status": status, "message": receipt])
            }
            AgentRunner.sendModel = { _, messages, _, _, done in
                controlRounds += 1
                if controlRounds == 1 {
                    let call: [String: Any] = ["id": "mijia-control", "type": "function", "function": ["name": "mijia", "arguments": MijiaGateway.encode(set)]]
                    done(.success(ModelTurn(toolCalls: [call], rawMessage: ["role": "assistant", "tool_calls": [call]], usage: ["total_tokens": 1])))
                } else {
                    receivedExact = messages.contains { $0["role"] as? String == "tool" && $0["content"] as? String == receipt }
                    done(.success(ModelTurn(content: receipt, rawMessage: ["role": "assistant", "content": receipt], usage: ["total_tokens": 1])))
                }
            }
            var controlOutcome: AgentRunner.Outcome?
            let controlledFinished = DispatchSemaphore(value: 0)
            AgentRunner.run(config: ModelConfig(backend: .codex), task: controlled, readPage: { .failure(.emptyPage) }) {
                controlOutcome = $0; controlledFinished.signal()
            }
            check(controlledFinished.wait(timeout: .now() + 5) == .success, "\(status) 写入工具循环可收尾")
            check(controlRounds == 2 && controlWrites == 1 && receivedExact, "\(status) 仅写一次并将原始回执交回模型")
            check(controlOutcome?.content == receipt && controlOutcome?.error == nil, "\(status) 保留实际确认强度")
            check(Array(TaskStore.task(id: controlled.id)?.mijiaOperations?.values ?? [:].values) == [receipt], "\(status) 台账保存执行器事实")
        }

        // ---------- 真实进程协议 ----------
        let helper = temporary.appendingPathComponent("bridge.py")
        let source = """
        import json, sys, time
        request = json.loads(sys.stdin.read())
        print('secret-not-for-model', file=sys.stderr)
        if request['operation'] == 'slow': time.sleep(2)
        if request['operation'] == 'bad': print('not json')
        elif request['operation'] == 'integer': print(json.dumps({'ok': 1, 'data': {}}))
        elif request['operation'] == 'choice': print(json.dumps({'ok': False, 'error': {'kind': 'choice', 'message': 'choose', 'candidates': [{'did': 'a'}]}}))
        else: print(json.dumps({'ok': True, 'data': {'argument': request.get('query', '')}}))
        """
        try source.write(to: helper, atomically: true, encoding: .utf8)
        let environment = ["POCKETDESK_MIJIA_PYTHON", "POCKETDESK_MIJIA_BRIDGE", "POCKETDESK_MIJIA_AUTH"]
        let previous = environment.map { ProcessInfo.processInfo.environment[$0] }
        defer {
            for (name, value) in zip(environment, previous) {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
            MijiaBridge.timeout = 40
        }
        setenv(environment[0], "/usr/bin/python3", 1)
        setenv(environment[1], helper.path, 1)
        setenv(environment[2], temporary.appendingPathComponent("unused-auth.json").path, 1)
        let literal = "--anything; $(touch /tmp/should-never-exist) 中文"
        if case .success(let result) = MijiaBridge.run(["operation": "list_devices", "query": literal]) {
            check(result["argument"] as? String == literal, "参数原样走stdin，不经过shell")
            check(!MijiaGateway.encode(result).contains("secret-not-for-model"), "stderr不回传模型")
        } else { check(false, "有效JSON进程应成功") }
        if case .failure(let error) = MijiaBridge.run(["operation": "choice"]) {
            check(error.kind == "choice" && error.candidates.count == 1, "结构化歧义回执保留候选")
        } else { check(false, "歧义回执必须失败") }
        for operation in ["bad", "integer"] {
            if case .failure = MijiaBridge.run(["operation": operation]) { check(true, "拒绝非法JSON或伪布尔") }
            else { check(false, "拒绝非法JSON或伪布尔") }
        }
        MijiaBridge.timeout = 0.05
        let started = Date()
        if case .failure(let error) = MijiaBridge.run(["operation": "slow"]) {
            check(error.kind == "network", "进程超时分类可核对")
        } else { check(false, "超时必须失败") }
        check(Date().timeIntervalSince(started) < 2, "限时终止不等待慢子进程")
        print("mijia gateway: \(checks) checks, \(failures.count) failures")
        for failure in failures { print("FAIL: " + failure) }
        if !failures.isEmpty { exit(1) }
    }
}
