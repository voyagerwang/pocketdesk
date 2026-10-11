/**
 * [INPUT]: Codex 规划协议、CLI 客户端与仅写临时元数据的假 CLI，不读取真实账号或执行桌面动作。
 * [OUTPUT]: 验证工具白名单/参数、完成回执/退出状态、用量、登录闸门、超时与临时目录清理。
 * [POS]: tests 的 Codex 后端隔离回归；真实 Luna 规划探针必须显式加 --live 且不执行工具。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

// 模型配置的支持目录替身；不打开或写入真实配置。
enum TargetStore { static let supportDirectory = FileManager.default.temporaryDirectory }

@main struct CodexModelTests {
    static let catalog: [String: Any] = ["models": [
        ["slug": "gpt-6-luna", "tool_mode": "code_mode_only", "shell_type": "unified_exec",
         "apply_patch_tool_type": "freeform", "experimental_supported_tools": ["clock"], "node_repl_disabled": false],
        ["slug": "other-model", "unchanged": "original metadata"]
    ]]
    static let tools: [[String: Any]] = [["type": "function", "function": [
        "name": "inspect_fixture", "description": "读取隔离夹具，不执行桌面操作",
        "parameters": ["type": "object", "properties": [
            "name": ["type": "string", "enum": ["sample"]], "count": ["type": "integer", "minimum": 1],
            "enabled": ["type": "boolean"]
        ], "required": ["name"], "additionalProperties": false]
    ]]]

    static func main() throws {
        CodexModelClient.resetDiagnosticsForTesting()
        let argv = CodexModelClient.execArguments(schema: URL(fileURLWithPath: "/fixture/output-schema.json"), cwd: URL(fileURLWithPath: "/fixture"))
        let analyticsFlag = argv.firstIndex(of: "analytics.enabled=false")!
        assert(analyticsFlag > 0 && argv[analyticsFlag-1] == "-c", "只关闭本次 CLI 子进程 analytics")
        assert(argv.contains("--ignore-user-config") && argv.contains("read-only") && argv.contains("features.code_mode_host=false"))
        let planningCatalog = try CodexModelProtocol.plannerCatalog(catalog)
        let catalogModels = planningCatalog["models"] as! [[String: Any]]
        assert(catalogModels.count == 2 && catalogModels[1]["unchanged"] as? String == "original metadata")
        assert(catalogModels[0]["tool_mode"] is NSNull && catalogModels[0]["shell_type"] as? String == "disabled")
        assert(catalogModels[0]["node_repl_disabled"] as? Bool == true)
        assert((catalog["models"] as! [[String: Any]])[0]["tool_mode"] as? String == "code_mode_only")
        for invalid in [["models": [["slug": "other"]]], ["models": [["slug": "gpt-6-luna"]]]] as [[String: Any]] {
            do { _ = try CodexModelProtocol.plannerCatalog(invalid); fatalError("未知目录格式不得启用工具") } catch { }
        }
        let definitions = try CodexModelProtocol.toolList(tools)
        let schema = CodexModelProtocol.outputSchema(tools: definitions)
        assert(JSONSerialization.isValidJSONObject(schema))
        let answer = try CodexModelProtocol.turn(text: "{\"content\":\"连接成功。\",\"tool_calls\":[]}", tools: [], usage: nil)
        assert(answer.content == "连接成功。" && answer.toolCalls == nil)
        assert(JSONSerialization.isValidJSONObject(CodexModelProtocol.outputSchema(tools: [])))
        let turn = try CodexModelProtocol.turn(text: "{\"content\":\"先读取夹具。\",\"tool_calls\":[{\"name\":\"inspect_fixture\",\"arguments\":\"{\\\"name\\\":\\\"sample\\\",\\\"count\\\":1,\\\"enabled\\\":true}\"}]}", tools: definitions, usage: nil)
        assert(turn.toolCalls?.count == 1)
        assert((turn.rawMessage?["tool_calls"] as? [[String: Any]])?.count == 1)
        assert((turn.toolCalls?[0]["function"] as? [String: Any])?["name"] as? String == "inspect_fixture")
        let sourceMessages: [[String: Any]] = [["role": "system", "content": "保留当前权限与事实。"],
            ["role": "assistant", "tool_calls": [["id": "old", "type": "function", "function": ["name": "inspect_fixture", "arguments": "{\"name\":\"sample\"}"]]]],
            ["role": "tool", "tool_call_id": "old", "content": "{\"found\":true,\"url\":\"https://fixture.invalid/a\"}"]]
        let compact = try CodexModelProtocol.prompt(messages: sourceMessages, tools: tools)
        let compactObject = try JSONSerialization.jsonObject(with: Data(compact.utf8)) as! [String: Any]
        let compactCatalog = compactObject["tools"] as! [String: [String: Any]]
        assert(compactCatalog["inspect_fixture"]?["description"] as? String == "读取隔离夹具，不执行桌面操作")
        assert(compactCatalog["inspect_fixture"]?["parameters"] is [String: Any])
        let compactHistory = compactObject["messages"] as! [[String: Any]]
        assert(compactHistory[0]["content"] as? String == "保留当前权限与事实。")
        assert(compactHistory[2]["content"] is [String: Any] && sourceMessages[2]["content"] is String)
        func rejects(_ text: String) {
            do { _ = try CodexModelProtocol.turn(text: text, tools: definitions, usage: nil); fatalError("无效规划被接受") }
            catch { }
        }
        for args in ["{}", "{\"name\":\"wrong\"}", "{\"name\":\"sample\",\"count\":true}",
                     "{\"name\":\"sample\",\"enabled\":1}", "{\"name\":\"sample\",\"unknown\":1}", "[]"] {
            let data = try JSONSerialization.data(withJSONObject: ["content": "", "tool_calls": [["name": "inspect_fixture", "arguments": args]]])
            rejects(String(decoding: data, as: UTF8.self))
        }
        rejects("{\"content\":\"\",\"tool_calls\":[{\"name\":\"run_shell\",\"arguments\":\"{}\"}]}")
        rejects("{\"content\":\"\",\"tool_calls\":[]}")
        rejects("{\"content\":\"完成\",\"tool_calls\":[],\"extra\":true}")
        let usage = CodexModelProtocol.usage(["input_tokens": 120, "output_tokens": 25, "cached_input_tokens": 64])!
        assert(usage["total_tokens"] as? Int == 145 && usage["provider"] as? String == "codex")
        assert(usage["model"] as? String == ModelConfig.codexModel)
        assert(CodexModelProtocol.usage(["input_tokens": -1, "output_tokens": 25]) == nil)
        let filtered = CodexModelClient.environment(["OPENAI_API_KEY": "dummy", "ANTHROPIC_API_KEY": "dummy",
                                                    "OPENAI_BASE_URL": "https://dummy.invalid", "CODEX_HOME": "/fixture/auth", "PATH": "/usr/bin"])
        assert(filtered["OPENAI_API_KEY"] == nil && filtered["ANTHROPIC_API_KEY"] == nil && filtered["OPENAI_BASE_URL"] == nil)
        assert(filtered["CODEX_HOME"] == "/fixture/auth")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-model-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fake-cli.py")
        try fakeCLI.write(to: fixture, atomically: true, encoding: .utf8)
        for mode in ["success", "missing-completed", "nonzero", "invalid-json", "unknown-tool", "invalid-args", "native-tool", "native-router-error", "noauth", "timeout"] {
            let trace = directory.appendingPathComponent(mode + ".jsonl")
            let result = request(fixture: fixture, mode: mode, trace: trace)
            switch result {
            case .success(let value):
                assert(mode == "success", "\(mode) 不得成功")
                assert(value.toolCalls?.count == 1 && value.usage?["total_tokens"] as? Int == 145)
            case .failure(let failure):
                assert(mode != "success", "成功夹具失败：\(failure.message)")
                if mode == "noauth" { assert(failure.httpStatus == 401) }
                assert(!failure.message.contains("credential-canary"), "错误不得回显 stderr 凭据")
            }
            let rows = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            assert(rows.count == (mode == "noauth" ? 1 : 2), "登录与规划各只允许一个进程，无重试")
            for row in rows {
                let cwd = row["cwd"] as! String
                assert(!FileManager.default.fileExists(atPath: cwd), "完成回调之前应清理临时 cwd")
            }
            let metrics = CodexModelClient.diagnostics(limit: 1).first!
            assert(metrics["totalMs"] is Double && metrics["toolCount"] as? Int == 1)
            if mode == "native-router-error" { assert(metrics["nativeRouterErrors"] as? Int == 1) }
        }
        let authHome = directory.appendingPathComponent("fake-auth")
        try FileManager.default.createDirectory(at: authHome, withIntermediateDirectories: true)
        let authFile = authHome.appendingPathComponent("auth.json")
        try Data("metadata-fixture".utf8).write(to: authFile)
        let fakeBinary = URL(fileURLWithPath: "/usr/bin/python3")
        let before = CodexModelClient.loginFingerprint(binary: fakeBinary, prefix: [], environment: ["CODEX_HOME": authHome.path])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: authFile.path)
        let after = CodexModelClient.loginFingerprint(binary: fakeBinary, prefix: [], environment: ["CODEX_HOME": authHome.path])
        assert(before != nil && before != after, "账号元数据变化必须让登录缓存失效")
        print("codex model: 规划/参数/登录/完成回执/用量/超时/无重试/清理 全部通过")
        if CommandLine.arguments.contains("--live") { try livePlanning() }
    }

    static func request(fixture: URL, mode: String, trace: URL) -> Result<ModelTurn, ModelFailure> {
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var result: Result<ModelTurn, ModelFailure>?, completions = 0
        CodexModelClient.sendForTesting(binary: URL(fileURLWithPath: "/usr/bin/python3"),
                                       prefixArguments: [fixture.path, mode, trace.path],
                                       messages: [["role": "user", "content": "读取 sample 夹具。"]], tools: tools,
                                       catalog: catalog,
                                       timeoutSeconds: mode == "timeout" ? 0.3 : 5) { value in
            lock.lock(); completions += 1; result = value; lock.unlock(); done.signal()
        }
        assert(done.wait(timeout: .now() + 10) == .success, "假 CLI 未及时结束")
        lock.lock(); defer { lock.unlock() }
        assert(completions == 1, "完成回调必须只触发一次")
        return result!
    }

    static func livePlanning() throws {
        let done = DispatchSemaphore(value: 0)
        var result: Result<ModelTurn, ModelFailure>?
        CodexModelClient.send(config: ModelConfig(), messages: [["role": "system", "content": "只能提出工具计划，不执行。"],
            ["role": "user", "content": "请提出一次 inspect_fixture，name 为 sample；不要执行工具。"]],
            tools: tools, timeoutSeconds: 90) { value in result = value; done.signal() }
        assert(done.wait(timeout: .now() + 100) == .success)
        switch result! {
        case .success(let turn):
            assert(turn.toolCalls?.count == 1)
            print("codex model live: Luna 已返回隔离工具规划；没有执行工具")
            print("reported tokens: \(turn.usage?["total_tokens"] as? Int ?? -1)")
            if let metrics = CodexModelClient.diagnostics(limit: 1).first,
               let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]) {
                print("timing: " + String(decoding: data, as: UTF8.self))
            }
        case .failure(let error): throw error
        }
    }

    static let fakeCLI = #"""
    import sys,json,os,time
    mode,trace=sys.argv[1:3]
    login='login' in sys.argv[3:]
    with open(trace,'a') as f: f.write(json.dumps({'cwd':os.getcwd(),'stage':'login' if login else 'exec'})+'\n')
    print('credential-canary',file=sys.stderr,flush=True)
    if login:
        print('Not logged in' if mode=='noauth' else 'Logged in using ChatGPT',file=sys.stderr,flush=True)
        sys.exit(1 if mode=='noauth' else 0)
    def event(x): print(json.dumps(x),flush=True)
    event({'type':'thread.started','thread_id':'fixture'})
    event({'type':'item.completed','item':{'type':'error','message':'Host disabled startup warning'}})
    event({'type':'turn.started'})
    sys.stdin.read()
    if mode=='timeout': time.sleep(4);sys.exit(0)
    if mode=='native-tool':
        event({'type':'item.started','item':{'type':'command_execution','command':'never executed'}})
        time.sleep(3);sys.exit(0)
    if mode=='native-router-error':
        print('ERROR codex_core::tools::router: error=unsupported custom tool call: exec',file=sys.stderr,flush=True)
        time.sleep(3);sys.exit(0)
    args={'name':'wrong' if mode=='invalid-args' else 'sample'}
    plan={'content':'读取夹具。','tool_calls':[{'name':'unknown' if mode=='unknown-tool' else 'inspect_fixture','arguments':json.dumps(args)}]}
    event({'type':'item.completed','item':{'type':'reasoning','text':'ignored'}})
    event({'type':'item.completed','item':{'type':'agent_message','text':'invalid' if mode=='invalid-json' else json.dumps(plan)}})
    if mode!='missing-completed':event({'type':'turn.completed','usage':{'input_tokens':120,'output_tokens':25,'cached_input_tokens':64}})
    sys.exit(1 if mode=='nonzero' else 0)
    """#
}
