/**
 * [INPUT]: ModelConfigStore、AgentHTTP、TaskService、AgentRunner 与 TaskUsage；配置/任务写临时目录，模型和打开动作均注入替身。
 * [OUTPUT]: 验证旧单条只读迁移、多服务商逐条保存与显式切换、移除/旧清空不猜后端、按 ID 和同源隔离密钥且拒绝请求前零联网；保留 Codex 独立、回环边界、探针闭环与来源计量回归。
 * [POS]: tests 的模型后端与计量集成回归；不请求真实模型、不打开应用、不读取生产配置或任务正文。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct ModelRoutingTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pd-model-routing-" + UUID().uuidString)
        let originalFile = ModelConfigStore.file
        ModelConfigStore.file = directory.appendingPathComponent("model.json")
        TaskStore.resetCache(directory: directory.appendingPathComponent("tasks"))
        defer {
            ModelConfigStore.file = originalFile
            try? FileManager.default.removeItem(at: directory)
        }
        let backup = ModelConfig(baseURL: "https://api.deepseek.com", model: "deepseek-flash", apiKey: "test-secret")
        try ModelConfigStore.save(backup)
        func post(_ body: [String: Any], loopback: Bool = true, path: String = "/api/v1/model-config", method: String = "POST") -> (Int, [String: Any]) {
            var reply: (Int, [String: Any])?
            let completed = DispatchSemaphore(value: 0)
            let handled = AgentHTTP.handle(method: method, path: path,
                                           body: try! JSONSerialization.data(withJSONObject: body),
                                           fromLoopback: loopback, authorization: nil,
                                           queue: DispatchQueue(label: "test-model-route")) { reply = ($0, $1); completed.signal() }
            precondition(handled && completed.wait(timeout: .now() + 5) == .success && reply != nil)
            return reply!
        }
        check(post(["backend": "codex"]).0 == 200, "Codex 不要求额外 Key")
        var selected = ModelConfigStore.load()
        check(selected.backend == .codex && selected.activeModel == "gpt-6-luna", "选择 Luna")
        check(selected.apiKey == backup.apiKey && selected.baseURL == backup.baseURL && selected.model == backup.model, "API 备用完整保留")

        // --- 保存与测试共用凭证边界；拒绝发生在网络调用和写盘之前 ---
        var probeInvocations = 0
        var observedProbe: ModelConfig?
        AgentHTTP.probeModel = { config, _, _, _, done in
            probeInvocations += 1
            observedProbe = config
            done(.failure(ModelFailure(httpStatus: nil, message: "模拟探针停止，不请求真实服务。")))
        }
        let blockedDrafts: [[String: Any]] = [
            ["backend": "api", "baseURL": "https://other.example/v1"],
            ["backend": "api", "baseURL": "http://api.deepseek.com"],
            ["backend": "api", "baseURL": "https://api.deepseek.com:8443/v1"],
            ["backend": "api", "baseURL": "https://other.example/v1", "apiKey": ""],
            ["backend": "api", "baseURL": "https://other.example/v1", "apiKey": " \n\t"],
            ["baseURL": "https://other.example/v1"],
        ]
        for draft in blockedDrafts {
            check(post(draft).0 == 400, "跨源保存必须明确输入新 Key")
            check(ModelConfigStore.load() == selected, "跨源拒绝保留原配置")
            check(post(draft, path: "/api/v1/model-test").0 == 400, "跨源测试必须明确输入新 Key")
            check(probeInvocations == 0, "跨源拒绝不发任何模型请求")
        }
        for address in ["https://API.DEEPSEEK.COM:443/v1", "https://api.deepseek.com/compatible/v2"] {
            let draft: [String: Any] = ["backend": "api", "baseURL": address]
            check(post(draft, path: "/api/v1/model-test").0 == 200 && observedProbe?.apiKey == backup.apiKey, "同源路径和默认端口允许测试沿用 Key")
            check(ModelConfigStore.load() == selected, "测试同源草稿不写盘")
            check(post(draft).0 == 200 && ModelConfigStore.load().apiKey == backup.apiKey, "同源路径允许保存沿用 Key")
            try ModelConfigStore.save(selected)
            selected = ModelConfigStore.load()
        }
        let newService: [String: Any] = ["backend": "api", "baseURL": "https://other.example/v1", "apiKey": "fixture-new-key"]
        check(post(newService, path: "/api/v1/model-test").0 == 200 && observedProbe?.apiKey == "fixture-new-key", "明确新 Key 才能测试新服务")
        check(ModelConfigStore.load() == selected, "测试新 Key 不修改原配置")
        check(post(newService).0 == 200 && ModelConfigStore.load().apiKey == "fixture-new-key", "明确新 Key 可以保存新服务")
        try ModelConfigStore.save(selected)
        selected = ModelConfigStore.load()
        let emptyKey: [String: Any] = ["backend": "api", "apiKey": ""]
        let callsBeforeEmpty = probeInvocations
        check(post(emptyKey, path: "/api/v1/model-test").0 == 400 && probeInvocations == callsBeforeEmpty, "显式空 Key 的测试不偷偷沿用旧 Key")
        check(post(emptyKey).0 == 400 && ModelConfigStore.load() == selected, "显式空 Key 的 API 保存拒绝不完整配置")

        check(post(["backend": "api", "baseURL": ""], path: "/api/v1/model-test").0 == 400, "测试空地址不能偷用已存备用")
        check(post(["backend": "api", "model": ""], path: "/api/v1/model-test").0 == 400, "测试空模型不能偷用已存备用")
        check(post(["backend": "unsupported"]).0 == 400, "未知后端拒绝")
        check(ModelConfigStore.load().backend == .codex, "无效配置不落盘")
        check(post(["backend": "api"], loopback: false).0 == 403, "局域网不能切换计费来源")
        TaskService.loadModelConfig = ModelConfigStore.load
        let executors = TaskService.executors()["model"] as? [String: Any]
        check(executors?["model"] as? String == "gpt-6-luna" && executors?["host"] as? String == "codex", "能力报告不显示备用服务为活动模型")
        check(post(["baseURL": "", "model": "", "apiKey": ""]).0 == 200, "可以清空备用")
        check(ModelConfigStore.load().backend == .codex && ModelConfigStore.load().apiKey.isEmpty, "清空备用不撤销 Codex 选择")
        check(post(["backend": "api"]).0 == 400, "空备用不能切入 API")
        check(ModelConfigStore.load().backend == .codex, "API 校验失败不隐式回退")
        check(post(["backend": "api", "baseURL": backup.baseURL, "model": backup.model, "apiKey": backup.apiKey]).0 == 200, "手动选择有效备用")
        check(post(["baseURL": "", "model": "", "apiKey": ""]).0 == 200 && !ModelConfigStore.load().isConfigured, "API 后端清空后如实未配置")

        // --- 多服务商：存储迁移、条目身份、显式使用与凭证隔离 ---
        func saveProvider(_ provider: [String: Any], activate: Bool? = nil) -> (Int, [String: Any]) {
            var body: [String: Any] = ["action": "save-provider", "provider": provider]
            if let activate { body["activate"] = activate }
            return post(body)
        }
        func providerID(_ name: String) -> String {
            guard let provider = ModelConfigStore.load().providers.first(where: { $0.name == name }) else {
                preconditionFailure("测试未保存对应条目")
            }
            return provider.id
        }
        let firstOnly: [String: Any] = ["name": "首次仅保存", "baseURL": "https://first.example/v1", "model": "first-model", "apiKey": "fixture-first-key"]
        check(saveProvider(firstOnly, activate: false).0 == 200, "首次配置允许仅保存")
        check(ModelConfigStore.load().providers.count == 1 && ModelConfigStore.load().activeProviderID == nil && !ModelConfigStore.load().isConfigured, "首次仅保存也不隐式选中")
        check(post(["action": "remove-provider", "providerId": providerID("首次仅保存")]).0 == 200 && ModelConfigStore.load().providers.isEmpty, "移除未激活条目仍未配置")

        let legacyBytes = Data("{\"baseURL\":\"https://api.deepseek.com\",\"model\":\"legacy-model\",\"apiKey\":\"fixture-legacy-secret\",\"updatedAt\":7}".utf8)
        try legacyBytes.write(to: ModelConfigStore.file, options: .atomic)
        let legacyReply = post([:], method: "GET")
        let migrated = ModelConfigStore.load()
        let legacyView = legacyReply.1["config"] as? [String: Any]
        check(legacyReply.0 == 200 && migrated.activeProviderID == "legacy-api" && migrated.providers[0].name == "DeepSeek", "旧配置 GET 显示稳定迁移条目")
        let afterGet = try Data(contentsOf: ModelConfigStore.file)
        check(afterGet == legacyBytes, "GET 迁移只在内存发生，不重写旧文件")
        check(legacyView?["providers"] as? [[String: Any]] != nil && legacyView?["hasKey"] as? Bool == true, "迁移视图含条目与兼容脱敏字段")
        let aID = "legacy-api"
        let bValues: [String: Any] = ["name": "服务 B", "baseURL": "https://b.example/v1", "model": "model-b", "apiKey": "fixture-b-key"]
        check(saveProvider(bValues, activate: false).0 == 200, "新增第二家仅保存")
        let bID = providerID("服务 B")
        check(ModelConfigStore.load().activeProviderID == aID && ModelConfigStore.load().apiKey == "fixture-legacy-secret", "新增 B 不切离当前 A，旧凭证迁移保存后保留")
        let newStorageBytes = try Data(contentsOf: ModelConfigStore.file)
        let newStorage = try JSONSerialization.jsonObject(with: newStorageBytes) as? [String: Any]
        check(newStorage?["providers"] as? [[String: Any]] != nil && newStorage?["apiKey"] == nil, "保存写多条目新格式，凭证不重复放在顶层")
        check(saveProvider(["id": bID, "name": "我的服务 B", "baseURL": "https://b.example/compatible/v2", "model": "model-b-edited", "apiKey": ""], activate: false).0 == 200, "同 ID 同源空 Key 可沿用并编辑非活动项")
        check(ModelConfigStore.load().activeProviderID == aID && ModelConfigStore.load().model == "legacy-model" && ModelConfigStore.load().provider(id: bID)?.apiKey == "fixture-b-key", "编辑 B 不改活动 A 的模型或密钥")
        check(saveProvider(["id": aID, "name": "我的 DeepSeek", "model": "model-a-edited", "apiKey": ""], activate: false).0 == 200, "仅保存当前条目允许原地编辑")
        check(ModelConfigStore.load().activeProviderID == aID && ModelConfigStore.load().model == "model-a-edited" && ModelConfigStore.load().providers[0].name == "我的 DeepSeek", "当前条目更新不切别家，不覆盖自定义名称")
        for id in [bID, aID] {
            check(post(["action": "activate-provider", "providerId": id]).0 == 200, "显式切换服务商")
            let current = ModelConfigStore.load()
            check(current.backend == .api && current.activeProviderID == id && current.apiKey == current.provider(id: id)?.apiKey, "A→B→A 使用各自持久凭证")
        }
        check(post(["backend": "codex"]).0 == 200 && ModelConfigStore.load().providers.count == 2 && ModelConfigStore.load().activeProviderID == aID, "切 Codex 保留服务列表和 API 选择")
        let cValues: [String: Any] = ["name": "服务 C", "baseURL": "https://c.example/v1", "model": "model-c", "apiKey": "fixture-c-key"]
        check(saveProvider(cValues).0 == 200 && ModelConfigStore.load().backend == .codex && ModelConfigStore.load().activeProviderID == aID, "新增缺省 activate 为 false，不切 Codex")
        let cID = providerID("服务 C")
        let guarded = ModelConfigStore.load()
        let callsBeforeGuards = probeInvocations
        for key in ["", " \n\t"] {
            check(saveProvider(["id": bID, "baseURL": "https://other.example/v1", "apiKey": key], activate: false).0 == 400, "编辑原条目跨源空 Key 拒绝")
            check(post(["backend": "api", "providerId": bID, "baseURL": "https://other.example/v1", "apiKey": key], path: "/api/v1/model-test").0 == 400, "指定条目跨源空 Key 测试拒绝")
        }
        check(saveProvider(["name": "同地址新条目", "baseURL": guarded.baseURL, "model": "new-model"], activate: false).0 == 400, "新增即使同源也不能借其他 ID 的 Key")
        check(post(["backend": "api", "providerId": "", "baseURL": guarded.baseURL, "model": "new-model"], path: "/api/v1/model-test").0 == 400, "空 ID 新草稿不借当前 Key")
        check(post(["backend": "api", "providerId": "missing", "baseURL": guarded.baseURL, "model": "new-model", "apiKey": "fixture-new-key"], path: "/api/v1/model-test").0 == 400, "未知测试 ID 不回退当前条目")
        check(saveProvider(["id": "missing", "name": "未知 ID", "baseURL": "https://new.example/v1", "model": "m", "apiKey": "fixture-new-key"]).0 == 400, "未知编辑 ID 不冒充新建")
        check(saveProvider(["name": " \n", "baseURL": "https://new.example/v1", "model": "m", "apiKey": "fixture-new-key"]).0 == 400, "空白名称不能保存为完整配置")
        for invalidActivate in [0, 1] {
            check(post(["action": "save-provider", "provider": cValues, "activate": invalidActivate]).0 == 400, "JSON 数字不能当作显式启用布尔值")
        }
        check(post(["action": "unknown"]).0 == 400, "未知服务商操作拒绝")
        check(probeInvocations == callsBeforeGuards && ModelConfigStore.load() == guarded, "全部草稿拒绝保持配置且零模型请求")

        check(post(["backend": "api", "providerId": bID, "model": "probe-b", "apiKey": ""], path: "/api/v1/model-test").0 == 200 && observedProbe?.apiKey == "fixture-b-key" && observedProbe?.model == "probe-b", "测试非活动 B 只使用 B 的凭证与草稿模型")
        check(post(["backend": "api", "providerId": "", "baseURL": "https://new.example/v1", "model": "new-model", "apiKey": "fixture-new-key"], path: "/api/v1/model-test").0 == 200 && observedProbe?.apiKey == "fixture-new-key", "新草稿明确给 Key 才能测试")
        check(post(["backend": "api"], path: "/api/v1/model-test").0 == 200 && observedProbe?.apiKey == "fixture-legacy-secret", "旧测试省略 ID 仍使用选中 API")
        check(ModelConfigStore.load() == guarded, "所有允许的测试仍不改当前来源或存储")
        check(saveProvider(["id": bID, "baseURL": "https://new-b.example/v1", "apiKey": "fixture-b-replaced"], activate: false).0 == 200 && ModelConfigStore.load().provider(id: bID)?.apiKey == "fixture-b-replaced", "跨源明确新 Key 可编辑该条目")
        check(ModelConfigStore.load().backend == .codex && ModelConfigStore.load().activeProviderID == aID, "非活动项更换服务地址不切来源")
        let listView = ModelConfigStore.view(ModelConfigStore.load())
        let listJSON = String(data: try JSONSerialization.data(withJSONObject: listView), encoding: .utf8) ?? ""
        check(!listJSON.contains("fixture-legacy-secret") && !listJSON.contains("fixture-b-replaced") && !listJSON.contains("fixture-c-key"), "列表和兼容字段均不返回完整 Key")

        let dValues: [String: Any] = ["name": "服务 D", "baseURL": "https://d.example/v1", "model": "model-d", "apiKey": "fixture-d-key"]
        check(saveProvider(dValues, activate: true).0 == 200, "保存并使用显式切换新条目")
        let dID = providerID("服务 D")
        check(ModelConfigStore.load().backend == .api && ModelConfigStore.load().activeProviderID == dID && ModelConfigStore.load().apiKey == "fixture-d-key", "显式启用 D 才从 Codex 切 API")
        check(post(["action": "remove-provider", "providerId": bID]).0 == 200 && ModelConfigStore.load().activeProviderID == dID, "移除非活动 B 不影响 D")
        check(post(["action": "remove-provider", "providerId": dID]).0 == 200, "移除活动 D")
        let removedActive = ModelConfigStore.load()
        check(removedActive.backend == .api && removedActive.activeProviderID == nil && !removedActive.isConfigured && removedActive.providers.count == 2, "移除当前留未配置态，A/C 均保留且不自动选中")
        check(removedActive.baseURL.isEmpty && removedActive.model.isEmpty && removedActive.apiKey.isEmpty, "移除当前后的兼容字段不能借其他条目")
        var incomplete = removedActive
        incomplete.providers.append(.init(id: "incomplete", name: "不完整", baseURL: "https://incomplete.example/v1", model: "m", apiKey: ""))
        try ModelConfigStore.save(incomplete)
        let activationGuard = ModelConfigStore.load()
        check(post(["action": "activate-provider", "providerId": "incomplete"]).0 == 400 && ModelConfigStore.load() == activationGuard, "不完整条目不能激活，原未配置状态保留")
        check(post(["action": "activate-provider", "providerId": "missing"]).0 == 400 && ModelConfigStore.load() == activationGuard, "未知激活 ID 不猜其他条目")
        check(post(["action": "remove-provider", "providerId": "missing"]).0 == 400 && ModelConfigStore.load() == activationGuard, "未知移除 ID 不修改存储")
        check(post(["action": "activate-provider", "providerId": aID]).0 == 200 && post(["backend": "codex"]).0 == 200, "显式选择 A 后切 Codex")
        check(post(["action": "remove-provider", "providerId": aID]).0 == 200 && ModelConfigStore.load().backend == .codex && ModelConfigStore.load().isConfigured, "Codex 下移除选中 API 不撤销后端")
        check(ModelConfigStore.load().activeProviderID == nil && ModelConfigStore.load().provider(id: cID) != nil, "移除 Codex 备用也不猜其它 API")
        check(post(["action": "activate-provider", "providerId": cID]).0 == 200 && post(["backend": "codex"]).0 == 200, "显式选择 C 作为 Codex 备用")
        check(post(["baseURL": "", "model": "", "apiKey": ""]).0 == 200, "旧三空清空当前 C")
        check(ModelConfigStore.load().backend == .codex && ModelConfigStore.load().provider(id: cID) == nil && ModelConfigStore.load().provider(id: "incomplete") != nil, "旧清空只移除当前条目，保留其他条目与 Codex")
        try ModelConfigStore.save(ModelConfig())

        // --- 文本可用不等于工具闭环完成 ---
        let probeCalls: [[String: Any]] = [["id": "probe", "type": "function", "function": ["name": "read_page", "arguments": "{\"url\":\"https://example.invalid/pocketdesk-model-probe\"}"]]]
        for final in [ModelTurn(), ModelTurn(toolCalls: probeCalls), ModelTurn(content: "总结了模拟页面。")] {
            var phase = 0
            AgentHTTP.probeModel = { config, _, _, _, done in
                check(config.backend == .codex, "探针使用选择的 Codex 后端")
                phase += 1
                if phase == 1 { done(.success(ModelTurn(content: "可用"))) }
                else if phase == 2 { done(.success(ModelTurn(toolCalls: probeCalls, rawMessage: ["role": "assistant", "tool_calls": probeCalls]))) }
                else { done(.success(final)) }
            }
            let probe = post(["backend": "codex"], path: "/api/v1/model-test")
            let tool = probe.1["tool"] as? [String: Any]
            if final.content == nil { check(tool?["error"] as? String != nil && tool?["final"] == nil, "空响应或再次请求工具不能冒充闭环") }
            else { check(tool?["final"] as? String == final.content && tool?["error"] == nil, "真实最终文字才能完成闭环") }
            check(!ModelConfigStore.load().isConfigured, "测试不保存选择")
        }
        AgentHTTP.probeModel = ModelClient.send

        // --- 同一执行循环的计量 ---
        AgentRunner.canControl = { _ in true }
        AgentRunner.isCodexApp = { _ in false }
        AgentRunner.openPage = { _ in .success(()) }
        func run(_ responses: [Result<ModelTurn, ModelFailure>]) throws -> AgentRunner.Outcome {
            var index = 0
            AgentRunner.sendModel = { _, _, _, _, done in
                precondition(index < responses.count)
                let response = responses[index]; index += 1; done(response)
            }
            var task = try TaskStore.claim(subject: "model-routing-test", requestId: UUID().uuidString,
                                           text: "帮我处理这项测试工作", context: nil)
            task.status = .running
            try TaskStore.save(task)
            var result: AgentRunner.Outcome?
            AgentRunner.run(config: ModelConfig(backend: .codex), task: task) { result = $0 }
            precondition(result != nil && index == responses.count)
            return result!
        }
        let usage: [String: Any] = ["prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10,
                                    "provider": "codex", "model": "gpt-6-luna"]
        let answer = ModelTurn(content: "已完成测试。", rawMessage: ["role": "assistant", "content": "已完成测试。"], usage: usage)
        let first = try run([.success(answer)])
        check(!first.usage.unknown && first.usage.totalTokens == 10, "首轮不能被未知起点吞掉")
        check(first.usage.provider == "codex" && first.usage.model == "gpt-6-luna", "保留额度来源")
        let calls: [[String: Any]] = [["id": "test-call", "type": "function", "function": ["name": "open_page", "arguments": "{\"url\":\"https://example.test\"}"]]]
        let planned = ModelTurn(toolCalls: calls, rawMessage: ["role": "assistant", "tool_calls": calls], usage: usage)
        let second = try run([.success(planned), .success(answer)])
        check(!second.usage.unknown && second.usage.totalTokens == 20, "多轮准确累计")
        let missing = try run([.success(planned), .success(ModelTurn(content: "结果", rawMessage: ["role": "assistant", "content": "结果"]))])
        check(missing.usage.unknown, "缺失任一轮用量就不能声称完整")
        check(missing.usage.provider == "codex" && missing.usage.model == "gpt-6-luna", "未知计量仍保留实际后端")
        let failed = try run([.success(planned), .failure(ModelFailure(httpStatus: nil, message: "模拟超时"))])
        check(failed.usage.unknown && failed.usage.totalTokens == nil, "传输失败不拿部分计量冒充账单")
        check(failed.usage.provider == "codex", "失败仍能识别当前后端")
        let legacyUsage = try JSONDecoder().decode(TaskUsage.self, from: Data("{\"promptTokens\":1,\"completionTokens\":2,\"totalTokens\":3,\"unknown\":false}".utf8))
        check(legacyUsage.provider == nil && legacyUsage.model == nil, "旧用量记录不猜归属")
        print("model routing: \(checks) 项通过")
    }
}
