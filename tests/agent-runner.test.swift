/**
 * [INPUT]: 注入 AgentRunner 的模型/打开/项目导航/派单与飞书 CLI 替身，TaskStore 使用临时目录；包含 WorkBuddy AX 状态与占位文本的兼容性样本。
 * [OUTPUT]: 飞书工具回归验证口述机器人称呼原词补查与单次回执收尾、mentions 字符串数组契约、群内真实 @ 的发送路由、无效提及与控制权失效拒绝。
 *           验证 Codex 真实口述的复合打开与派单、同批/跨轮接续、未派单不能口头成功，以及待选择后回放原目标、正文与条件；输出提示约束简洁中文且不暴露工具 JSON。
 *           验证 WorkBuddy/ZCode 指定项目打开的专属路由、遗漏纠正、实际列表续轮、普通打开与正文隔离及租约拒绝；复合打开/派单覆盖同批和跨轮接续、完整正文、遗漏项目拒绝和未派单不能成功； 验证派单回执直接收尾、待核对不报失败及同批后续调用不执行； 覆盖桌面动作参数/去重、输入选区与焦点保护；覆盖锁屏工具发现、执行回执、无效参数、租约与同批去重；验证直接执行无确认、工具串行、租约失效拦截、派单失败不冒充成功、目标匹配（含 Codex 包身份别名和歧义拒绝）、新建页面证据、正文深链编码及并发派单原子去重。
 * [POS]: Agent 工具循环的无桌面副作用回归，不联网、不打开真实应用、不发消息。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct AgentRunnerTests {
    static func tryReserve(_ id: String) -> Bool {
        do { return try TaskStore.reserveAppDispatch(id: id, label: "test") }
        catch { fatalError("Unexpected reservation failure: \(error)") }
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        TaskStore.resetCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfig(baseURL: "https://invalid.test", model: "test", apiKey: "test")
        // 使用已安装的真实 UU 包只读解析，不启动应用。
        if FileManager.default.fileExists(atPath: "/Applications/UURemote.app") {
            for name in ["UU远程", "UU 远程", "uu", "UURemote"] {
                assert(AppOperator.resolve(name)?.path == "/Applications/UURemote.app", name)
            }
            let custom = TargetConfig(id: "my-remote", name: "我的远程", bundleID: "com.netease.uuremote", path: "/Applications/UURemote.app")
            assert(AppOperator.resolve("我的 远程", configured: [custom])?.path == custom.path)
            assert(AppOperator.resolve("我的远程", configured: [custom, custom]) == nil)
        }
        assert(AppOperator.resolve("肯定不存在的应用-test-unknown") == nil)
        var opened: [String] = []
        AgentRunner.openPage = { opened.append($0); return .success(()) }
        AgentRunner.resolveApp = { ($0, "/Applications/" + $0 + ".app") }
        AgentRunner.openApp = { opened.append($0); return .success(()) }
        let savedResolve = AgentRunner.resolveApp
        let savedRead = AgentRunner.readBookmarks
        let savedOpenBookmark = AgentRunner.openBookmark
        let bookmark = ChromeBookmarks.Entry(id: "Default:9", name: " 个人工作台", folders: ["工作"], url: "https://example.com", profile: "Default")
        AgentRunner.readBookmarks = { [bookmark] }
        AgentRunner.openBookmark = { id, done in opened.append(id); done("已提交书签请求") }
        var targetResult = ""
        AgentRunner.openTarget("个人工作台") { targetResult = $0 }
        assert(opened == ["/Applications/个人工作台.app"], "同名应用优先于书签")
        AgentRunner.resolveApp = { _ in nil }
        AgentRunner.openTarget("个人工作台") { targetResult = $0 }
        assert(opened.last == "Default:9" && targetResult == "已提交书签请求", "无应用时按去空白名称打开书签")
        let beforeAmbiguous = opened.count
        AgentRunner.readBookmarks = { [bookmark, bookmark] }
        AgentRunner.openTarget("个人工作台") { targetResult = $0 }
        assert(opened.count == beforeAmbiguous && targetResult.contains("多个书签"), "多个候选不得自动打开")
        AgentRunner.resolveApp = savedResolve
        AgentRunner.readBookmarks = savedRead
        AgentRunner.openBookmark = savedOpenBookmark
        opened.removeAll()

        func run(_ tool: String, _ arguments: String, allowed: Bool = true, dispatchFailure: Bool = false, dispatchUnconfirmed: Bool = false, expectedMode: AgentConversationMode = .newTask, lockResult: Result<ExecutionFeedback, ShortcutError> = .success(.delivered("电脑已锁屏。")), extraLockCall: Bool = false, desktopResult: Result<ExecutionFeedback, ShortcutError> = .success(.delivered("已操作。")), fallbackOpen: Bool = false, fallbackWebsite: Bool = false) throws -> AgentRunner.Outcome {
            var task = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: "测试指令", context: nil)
            task.status = .running
            try TaskStore.save(task)
            var turns = 0
            var pageReads = 0
            var dispatched = false
            AgentRunner.canControl = { _ in allowed }
            AgentRunner.dispatchToApp = { app, text, _, mode, done in
                assert(app == "Codex" && text == "写测试" && mode == expectedMode)
                opened.append("dispatch")
                dispatched = true
                _ = try! TaskStore.reserveAppDispatch(id: task.id, label: "派单尝试")
                if dispatchFailure {
                    done(.init(state: .failed, detail: "输入框非空。"))
                } else if dispatchUnconfirmed {
                    done(.init(state: .unconfirmed, detail: "已尝试发送，接收待核实"))
                } else {
                    done(.init(state: .confirmed, detail: "已交给 Codex", targetName: "Codex", executionVisible: true))
                }
            }
            AgentRunner.desktopAction = { request, _, done in
                opened.append("desktop:" + request.action.rawValue)
                done(desktopResult)
            }
            AgentRunner.lockComputer = { _, done in
                opened.append("lock")
                done(lockResult)
            }
            AgentRunner.sendModel = { _, messages, _, _, done in
                turns += 1
                if turns == 1 {
                    let call: [String: Any] = ["id": "c1", "type": "function", "function": ["name": tool, "arguments": arguments]]
                    let calls = extraLockCall ? [call, call] : [call]
                    done(.success(ModelTurn(toolCalls: calls, rawMessage: ["role": "assistant", "tool_calls": calls])))
                } else if turns == 2 && (fallbackOpen || fallbackWebsite) {
                    let calls: [[String: Any]] = [["id": "c2", "type": "function", "function": ["name": fallbackWebsite ? "open_page" : "open_bookmark", "arguments": fallbackWebsite ? "{\"url\":\"https://platform.deepseek.com/\"}" : "{\"id\":\"Default:1390\"}"]]]
                    done(.success(ModelTurn(toolCalls: calls, rawMessage: ["role": "assistant", "tool_calls": calls])))
                } else {
                    assert(messages.last?["role"] as? String == "tool")
                    done(.success(ModelTurn(content: "已完成。", rawMessage: ["role": "assistant", "content": "已完成。"])))
                }
            }
            let finished = DispatchSemaphore(value: 0)
            var outcome: AgentRunner.Outcome?
            AgentRunner.run(config: config, task: task, readPage: { pageReads += 1; return .failure(.emptyPage) }) { outcome = $0; finished.signal() }
            assert(finished.wait(timeout: .now() + 5) == .success)
            assert(outcome != nil, "跑完必须有回执")
            if dispatched {
                assert(turns == 1, "派单后不应再请求模型，避免超时或重复调用改写结果")
                let transcript = TaskStore.task(id: task.id)?.transcript ?? []
                if extraLockCall {
                    assert(transcript.last?["content"] as? String == "本轮已结束，此操作未执行。")
                }
            }
            assert(TaskStore.task(id: task.id)?.status == .running, "工具执行不再挂起任务等确认")
            assert(pageReads == 0, "打开应用不得预读无关网页")
            if tool == "lock_computer", allowed, arguments == "{}" {
                assert(turns == 1, "锁屏后直接按回执结束，不再请求模型编造结果")
            }
            return outcome!
        }
        let lockTool = AgentRunner.tools.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "lock_computer" }
        let savedCleanChromeTabs = AgentRunner.cleanChromeTabs
        var cleanupCalls = 0
        AgentRunner.cleanChromeTabs = { _, done in cleanupCalls += 1; done(.sent("已关闭 3 个 Chrome 重复标签页。")) }
        let cleanup = try run("close_duplicate_chrome_tabs", "{}", extraLockCall: true)
        assert(cleanup.content == "已关闭 3 个 Chrome 重复标签页。" && cleanupCalls == 1, "回执直接收尾，同批调用不重放")
        _ = try run("close_duplicate_chrome_tabs", "{\"url\":\"https://example.com\"}")
        _ = try run("close_duplicate_chrome_tabs", "{}", allowed: false)
        assert(cleanupCalls == 1, "无效参数/租约失效不关闭")
        AgentRunner.cleanChromeTabs = { _, done in done(.failed("已确认关闭 1 个；清理已停止。")) }
        let partialCleanup = try run("close_duplicate_chrome_tabs", "{}")
        assert(partialCleanup.error == "已确认关闭 1 个；清理已停止。" && partialCleanup.content == nil)
        AgentRunner.cleanChromeTabs = savedCleanChromeTabs
        AgentRunner.resolveApp = { _ in nil }
        AgentRunner.readBookmarks = { [] }
        AgentRunner.openBookmark = { _, done in done("已向 Chrome 提交打开书签请求：API仪表盘") }
        let recoveredOpen = try run("open_target", "{\"app\":\"编程猫 API 的仪表盘\"}", fallbackOpen: true)
        assert(recoveredOpen.content != nil && recoveredOpen.error == nil, "首次查找失败后成功打开书签必须成功")
        let websiteRecovery = try run("open_target", "{\"app\":\"DeepSeek API平台\"}", fallbackWebsite: true)
        assert(websiteRecovery.error == nil && opened.contains("https://platform.deepseek.com/"), "无书签后网页打开应清除本地查找失败")
        let savedSearch = AgentRunner.searchWeb
        var queries: [String] = []
        AgentRunner.searchWeb = { query, done in queries.append(query); done("搜索候选：https://example.com") }
        _ = try run("search_web", "{\"query\":\"未收藏的网站 官网\"}", fallbackWebsite: true)
        assert(queries == ["未收藏的网站 官网"])
        _ = try run("search_web", "{\"query\":\"北京天气\"}", allowed: false)
        assert(queries.count == 1, "无控制权不执行联网搜索")
        AgentRunner.searchWeb = savedSearch
        let unrecoveredOpen = try run("open_target", "{\"app\":\"不存在\"}")
        assert(unrecoveredOpen.content == nil && unrecoveredOpen.error != nil, "没有成功回执时保留失败")
        let unrelatedFailure = try run("desktop_action", "{\"action\":\"list_windows\"}", desktopResult: .failure(.message("菜单操作失败")), fallbackOpen: true)
        assert(unrelatedFailure.error != nil, "打开成功不得掩盖其他桌面操作失败")
        // 项目打开只走注入替身；普通应用打开不能冒充已选中指定工作空间。
        let savedWorkspaceAction = AgentRunner.workspaceAction
        let savedOpenApp = AgentRunner.openApp
        let savedDispatchToApp = AgentRunner.dispatchToApp
        func runWorkspaceOpening(_ text: String, batches: [[(String, String)]], allowed: Bool = true,
                                 ambiguous: Bool = false, allowDispatch: Bool = false,
                                 unconfirmed: Bool = false) throws -> (outcome: AgentRunner.Outcome, apps: [String], requests: [AgentWorkspaceRequest], turns: Int, corrections: [String]) {
            var task = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: text, context: nil)
            task.status = .running
            try TaskStore.save(task)
            var apps: [String] = [], requests: [AgentWorkspaceRequest] = [], corrections: [String] = []
            var turns = 0
            AgentRunner.canControl = { _ in allowed }
            AgentRunner.resolveApp = { ($0, "/Applications/" + $0 + ".app") }
            AgentRunner.openApp = { apps.append($0); return .success(()) }
            AgentRunner.dispatchToApp = { _, _, _, _, _ in fatalError("指定工作空间不能落到通用派单") }
            AgentRunner.workspaceAction = { request, id, done in
                requests.append(request)
                if request.action == .sendTask {
                    assert(allowDispatch && tryReserve(id), "仅明确派单才占用一次发送")
                    done(.dispatched(.init(state: unconfirmed ? .unconfirmed : .confirmed, detail: unconfirmed ? "已尝试发送，接收待核实" : "已交给 WorkBuddy", targetName: "WorkBuddy")))
                } else if request.action == .listProjects { done(.listed("{\"projects\":[\"PocketDesk\",\"英语学习\"]}")) }
                else if ambiguous { done(.needsInput("项目名称重复，请先区分项目。")) }
                else { done(.opened("已打开指定工作空间：" + (request.project ?? ""))) }
            }
            AgentRunner.sendModel = { _, messages, _, _, done in
                turns += 1
                corrections += messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }
                if turns <= batches.count {
                    let calls = batches[turns - 1].enumerated().map { index, value in
                        ["id": "workspace-\(turns)-\(index)", "type": "function", "function": ["name": value.0, "arguments": value.1]] as [String: Any]
                    }
                    done(.success(ModelTurn(toolCalls: calls, rawMessage: ["role": "assistant", "tool_calls": calls])))
                } else { done(.success(ModelTurn(content: "已完成。", rawMessage: ["role": "assistant", "content": "已完成。"]))) }
            }
            let finished = DispatchSemaphore(value: 0)
            var outcome: AgentRunner.Outcome?
            AgentRunner.run(config: config, task: task, readPage: { fatalError("工作空间打开不得预读网页") }) { outcome = $0; finished.signal() }
            assert(finished.wait(timeout: .now() + 5) == .success)
            return (outcome!, apps, requests, turns, corrections)
        }
        let workspaceOpen = "{\"app\":\"WorkBuddy\",\"action\":\"open_project\",\"project\":\"PocketDesk\"}"
        for tool in ["open_app", "open_target"] {
            let omitted = try runWorkspaceOpening("打开 WorkBuddy 里的 PocketDesk 项目", batches: [[(tool, "{\"app\":\"WorkBuddy\"}")]])
            assert(omitted.apps.isEmpty && omitted.requests.isEmpty, "省略项目时零操作纠正")
            assert(omitted.outcome.content == nil && omitted.outcome.error?.contains("open_project") == true, "模型不能仅凭打开应用声称项目已打开")
            assert(omitted.corrections.contains { $0.contains("list_projects") }, "不猜项目名称，允许先读实际列表")
            let routed = try runWorkspaceOpening("打开 WorkBuddy 的 PocketDesk 工作空间", batches: [[(tool, "{\"app\":\"WorkBuddy\",\"project\":\"PocketDesk\"}")]])
            assert(routed.apps.isEmpty && routed.requests.count == 1 && routed.requests[0].action == .openProject && routed.requests[0].project == "PocketDesk")
            assert(routed.outcome.error == nil && routed.outcome.content?.contains("PocketDesk") == true && routed.turns == 1, "按专属打开回执直接收尾")
            let corrected = try runWorkspaceOpening("打开 WorkBuddy 里的 PocketDesk 项目", batches: [[(tool, "{\"app\":\"WorkBuddy\"}")], [("agent_workspace", workspaceOpen)]])
            assert(corrected.apps.isEmpty && corrected.requests.count == 1 && corrected.outcome.error == nil, "模型下一轮改正后可以完成项目打开")
            for project in ["\"\"", "17", "null"] {
                let invalid = try runWorkspaceOpening("打开 WorkBuddy 的 PocketDesk 项目", batches: [[(tool, "{\"app\":\"WorkBuddy\",\"project\":\(project)}")]])
                assert(invalid.apps.isEmpty && invalid.requests.isEmpty && invalid.outcome.error != nil, "无效项目不能退化为普通打开")
            }
            let denied = try runWorkspaceOpening("打开 WorkBuddy 的 PocketDesk 项目", batches: [[(tool, "{\"app\":\"WorkBuddy\",\"project\":\"PocketDesk\"}")]], allowed: false)
            assert(denied.apps.isEmpty && denied.requests.isEmpty && denied.outcome.error != nil, "无控制权不打开应用或项目")
        }
        let viaList = try runWorkspaceOpening("打开 WorkBuddy 里的 PocketDesk 项目", batches: [[("open_app", "{\"app\":\"WorkBuddy\"}")], [("agent_workspace", "{\"app\":\"WorkBuddy\",\"action\":\"list_projects\"}")], [("agent_workspace", workspaceOpen)]])
        assert(viaList.apps.isEmpty && viaList.requests.map(\.action) == [.listProjects, .openProject] && viaList.outcome.error == nil, "先查询真实项目再准确打开的续轮仍可用")
        let ambiguity = try runWorkspaceOpening("打开 WorkBuddy 的 PocketDesk 项目", batches: [[("open_app", "{\"app\":\"WorkBuddy\",\"project\":\"PocketDesk\"}")]], ambiguous: true)
        assert(ambiguity.outcome.needsInput && ambiguity.outcome.error == nil, "项目歧义交回用户选择，不猜第一项")
        let zcode = try runWorkspaceOpening("在 Z code 中打开 PocketDesk 项目", batches: [[("open_target", "{\"app\":\"Z code\",\"project\":\"PocketDesk\"}")]])
        assert(zcode.apps.isEmpty && zcode.requests.first?.appKey == "zcode" && zcode.requests.first?.project == "PocketDesk")
        let wrongApp = try runWorkspaceOpening("在 ZCode 中打开 PocketDesk 项目", batches: [[("open_app", "{\"app\":\"WorkBuddy\",\"project\":\"PocketDesk\"}")]])
        assert(wrongApp.apps.isEmpty && wrongApp.requests.isEmpty && wrongApp.outcome.error != nil, "项目名称相同也不能改变用户指定应用")
        for text in ["打开 WorkBuddy", "打开 WorkBuddy：看看 PocketDesk 项目为什么打不开", "打开 WorkBuddy\n解释 PocketDesk 项目的结构", "打开 WorkBuddy，解释什么是项目"] {
            for tool in ["open_app", "open_target"] {
                let ordinary = try runWorkspaceOpening(text, batches: [[(tool, "{\"app\":\"WorkBuddy\"}")]])
                assert(ordinary.apps == ["/Applications/WorkBuddy.app"] && ordinary.requests.isEmpty && ordinary.outcome.error == nil, "正文提及项目不改变普通应用打开")
            }
        }
        for text in ["打开 Workbody 里边的 PocketDesk 工作空间", "在 Z code 中打开 PocketDesk 项目", "Open the PocketDesk project in WorkBuddy", "Open ZCode's PocketDesk workspace"] {
            assert(AgentRunner.workspaceProjectOpeningApp(text) != nil)
        }
        assert(AgentRunner.workspaceProjectOpeningApp("WorkBuddy 的 PocketDesk 项目为什么打不开") == nil)
        let compound = "打开 WorkBuddy 的 PocketDesk 项目，让它去 GitHub 上拉取一下更新，看看有没有更新"
        let taskBody = "去 GitHub 上拉取一下更新，看看有没有更新\n保留本地改动，不要覆盖。"
        let sendData = try JSONSerialization.data(withJSONObject: ["app": "WorkBuddy", "action": "send_task", "project": "PocketDesk", "text": taskBody])
        let workspaceSend = String(data: sendData, encoding: .utf8)!
        assert(AgentRunner.workspaceOpeningNeedsDispatch(compound))
        assert(AgentRunner.workspaceOpeningNeedsDispatch("打开WorkBuddy的WorkBench项目，让它去GitHub上拉取一下更新，看看有没有更新"), "真实失败口述保留派单目标")
        for text in ["打开 WorkBuddy 的 PocketDesk 项目", "打开 WorkBuddy 的 PocketDesk 项目，不要让它执行任务", "打开 WorkBuddy：让它说明什么是项目"] {
            assert(!AgentRunner.workspaceOpeningNeedsDispatch(text), "打开、否定派单与正文提及不产生派单要求")
        }
        let sameBatch = try runWorkspaceOpening(compound, batches: [[("agent_workspace", workspaceOpen), ("agent_workspace", workspaceSend)]], allowDispatch: true)
        assert(sameBatch.requests.map(\.action) == [.openProject, .sendTask] && sameBatch.turns == 1, "打开不能封闭同批明确派单")
        assert(sameBatch.requests.last?.project == "PocketDesk" && sameBatch.requests.last?.text == taskBody, "派单保持项目和完整正文")
        assert(sameBatch.outcome.appDispatchReceipt?.state == .confirmed && sameBatch.outcome.error == nil)
        let nextRound = try runWorkspaceOpening(compound, batches: [[("agent_workspace", workspaceOpen)], [("agent_workspace", workspaceSend)]], allowDispatch: true)
        assert(nextRound.requests.map(\.action) == [.openProject, .sendTask] && nextRound.turns == 2, "打开事实回传后允许下一轮派单")
        assert(nextRound.corrections.contains { $0.contains("已打开指定工作空间") && $0.contains("send_task") }, "继续派单依据真实打开事实")
        assert(nextRound.outcome.appDispatchReceipt?.state == .confirmed && nextRound.requests.last?.text == taskBody)
        let unfinished = try runWorkspaceOpening(compound, batches: [[("agent_workspace", workspaceOpen)]])
        assert(unfinished.outcome.content == nil && unfinished.outcome.error?.hasPrefix("未派单") == true && unfinished.outcome.appDispatchReceipt == nil, "仅打开不能把复合目标报告成功")
        let noTools = try runWorkspaceOpening(compound, batches: [])
        assert(noTools.outcome.content == nil && noTools.outcome.error?.contains("任务还没发出") == true && noTools.outcome.appDispatchReceipt == nil, "模型口头成功不能代替派单")
        let onlyOpen = try runWorkspaceOpening("打开 WorkBuddy 的 PocketDesk 项目", batches: [[("agent_workspace", workspaceOpen), ("agent_workspace", workspaceSend)]])
        assert(onlyOpen.requests.map(\.action) == [.openProject] && onlyOpen.turns == 1 && onlyOpen.outcome.error == nil, "只打开仍直接收尾且不执行同批发送")
        let missingProjectData = try JSONSerialization.data(withJSONObject: ["app": "WorkBuddy", "text": taskBody, "mode": "new"])
        let missingProject = String(data: missingProjectData, encoding: .utf8)!
        let omittedProject = try runWorkspaceOpening(compound, batches: [[("dispatch_to_app", missingProject)]])
        assert(omittedProject.requests.isEmpty && omittedProject.outcome.error?.contains("遗漏项目") == true, "逗号后的派单不允许遗漏前面指定的空间")
        let correctedDispatch = try runWorkspaceOpening(compound, batches: [[("dispatch_to_app", missingProject)], [("agent_workspace", workspaceSend)]], allowDispatch: true)
        assert(correctedDispatch.requests.map(\.action) == [.sendTask] && correctedDispatch.outcome.appDispatchReceipt?.state == .confirmed, "遗漏项目允许模型正确续接而不降级通用派单")
        let missingWorkspaceData = try JSONSerialization.data(withJSONObject: ["app": "WorkBuddy", "action": "send_task", "text": taskBody])
        let missingWorkspace = String(data: missingWorkspaceData, encoding: .utf8)!
        let omittedWorkspace = try runWorkspaceOpening(compound, batches: [[("agent_workspace", missingWorkspace)]])
        assert(omittedWorkspace.requests.isEmpty && omittedWorkspace.outcome.error?.contains("遗漏项目") == true, "专属派单也不能把明确项目丢给默认空间")
        let correctedWorkspace = try runWorkspaceOpening(compound, batches: [[("agent_workspace", missingWorkspace)], [("agent_workspace", workspaceSend)]], allowDispatch: true)
        assert(correctedWorkspace.requests.map(\.action) == [.sendTask] && correctedWorkspace.requests.first?.project == "PocketDesk" && correctedWorkspace.requests.first?.text == taskBody && correctedWorkspace.outcome.appDispatchReceipt?.state == .confirmed, "专属派单遗漏项目零执行后可完整纠正")
        let unscoped = try runWorkspaceOpening("让 WorkBuddy 写测试", batches: [[("agent_workspace", missingWorkspace)]], allowDispatch: true)
        assert(unscoped.requests.count == 1 && unscoped.requests[0].project == nil && unscoped.outcome.appDispatchReceipt?.state == .confirmed, "用户没指定项目时保留无项目新任务能力")
        let uncertain = try runWorkspaceOpening(compound, batches: [[("agent_workspace", workspaceOpen), ("agent_workspace", workspaceSend), ("agent_workspace", workspaceSend)]], allowDispatch: true, unconfirmed: true)
        assert(uncertain.requests.map(\.action) == [.openProject, .sendTask] && uncertain.turns == 1 && uncertain.outcome.appDispatchReceipt?.state == .unconfirmed && uncertain.outcome.error == nil, "未知接收直接收尾且不重发")

        // ---------- Codex 复合打开、派单与候选补充 ----------
        func runCodexOpening(_ text: String, batches: [[String]], existingTask: AgentTask? = nil,
                             ambiguous: Bool = false, allowDispatch: Bool = false,
                             expectedHistory: [String] = []) throws -> (outcome: AgentRunner.Outcome, task: AgentTask, requests: [CodexActionRequest], turns: Int, corrections: [String]) {
            let savedModel = AgentRunner.sendModel, savedControl = AgentRunner.canControl
            let savedCodex = AgentRunner.codexAction, savedIdentity = AgentRunner.isCodexApp
            let savedOrdinaryOpen = AgentRunner.openApp, savedOrdinaryDispatch = AgentRunner.dispatchToApp
            defer {
                AgentRunner.sendModel = savedModel; AgentRunner.canControl = savedControl
                AgentRunner.codexAction = savedCodex; AgentRunner.isCodexApp = savedIdentity
                AgentRunner.openApp = savedOrdinaryOpen; AgentRunner.dispatchToApp = savedOrdinaryDispatch
            }
            var task = try existingTask ?? TaskStore.claim(subject: "codex-test", requestId: UUID().uuidString, text: text, context: nil)
            task.status = .running
            try TaskStore.save(task)
            var requests: [CodexActionRequest] = [], corrections: [String] = []
            var turns = 0
            AgentRunner.canControl = { _ in true }
            AgentRunner.isCodexApp = { _ in true }
            AgentRunner.openApp = { _ in fatalError("指定 Codex 项目不能落到普通应用打开") }
            AgentRunner.dispatchToApp = { _, _, _, _, _ in fatalError("指定 Codex 项目不能落到通用派单") }
            AgentRunner.codexAction = { request, id, done in
                requests.append(request)
                if ambiguous { done(.needsInput("找到两个项目，请选一个：\n1. PocketDesk\n2. voice-deck-mvp\n可以说项目名称或序号。")) }
                else if request.isSend {
                    assert(allowDispatch && tryReserve(id), "明确派单且没有发送占用才允许发送")
                    done(.dispatched(.init(state: .confirmed, detail: "已交给 Codex", targetName: "Codex")))
                } else { done(.opened("已打开 Codex 的 " + (request.project ?? "") + " 项目。")) }
            }
            AgentRunner.sendModel = { _, messages, _, _, done in
                turns += 1
                let system = messages.first?["content"] as? String ?? ""
                assert(!system.contains("Markdown 代码块围栏以外"), "中文回执不能被错误规则限制为代码块")
                assert(system.contains("中文") && (system.contains("简洁") || system.contains("简短")) && system.contains("JSON"),
                       "模型必须遵循简洁中文与不展示工具 JSON 的产品规范")
                if turns == 1 {
                    let userTexts = messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
                    assert(expectedHistory.allSatisfy(userTexts.contains), "候选补充仍向模型提供原指令与最新选择")
                }
                corrections += messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }
                if turns <= batches.count {
                    let calls = batches[turns - 1].enumerated().map { index, arguments in
                        ["id": "codex-\(task.attempt)-\(turns)-\(index)", "type": "function", "function": ["name": "codex_action", "arguments": arguments]] as [String: Any]
                    }
                    done(.success(ModelTurn(toolCalls: calls, rawMessage: ["role": "assistant", "tool_calls": calls])))
                } else { done(.success(ModelTurn(content: "已完成。", rawMessage: ["role": "assistant", "content": "已完成。"]))) }
            }
            let finished = DispatchSemaphore(value: 0)
            var outcome: AgentRunner.Outcome?
            AgentRunner.run(config: config, task: task, readPage: { fatalError("Codex 项目派单不读取无关网页") }) { outcome = $0; finished.signal() }
            assert(finished.wait(timeout: .now() + 5) == .success)
            return (outcome!, TaskStore.task(id: task.id)!, requests, turns, corrections)
        }
        let codexVoice = "帮我打开CodeX Pocket Desk项目，去看，让他去看一下GitHub上目前有哪些更新，如果有更新的话，可以拉取一下最新的版本"
        let codexBody = "去看一下 GitHub 上目前有哪些更新，如果有更新的话，可以拉取一下最新的版本"
        let codexOpen = "{\"action\":\"open_project\",\"project\":\"PocketDesk\"}"
        let codexSend = String(data: try JSONSerialization.data(withJSONObject: ["action": "send_project", "project": "PocketDesk", "text": codexBody]), encoding: .utf8)!
        assert(AgentRunner.codexOpeningNeedsDispatch(codexVoice), "真实口述中的打开和让他检查更新是同一复合目标")
        for text in ["打开 Codex 的 PocketDesk 项目", "打开 Codex 的 PocketDesk 项目，不要让它执行任务", "打开 Codex：让它说明什么是项目"] {
            assert(!AgentRunner.codexOpeningNeedsDispatch(text), "仅打开、否定派单与正文提及不产生派单要求")
        }
        let codexSameBatch = try runCodexOpening(codexVoice, batches: [[codexOpen, codexSend]], allowDispatch: true)
        assert(codexSameBatch.requests.map(\.action) == [.openProject, .sendProject] && codexSameBatch.turns == 1,
               "Codex 打开回执不能封闭同批明确派单")
        assert(codexSameBatch.requests.last?.project == "PocketDesk" && codexSameBatch.requests.last?.text == codexBody
               && codexSameBatch.outcome.appDispatchReceipt?.state == .confirmed, "Codex 派单保留完整项目和有更新才拉取的条件")
        let codexNextRound = try runCodexOpening(codexVoice, batches: [[codexOpen], [codexSend]], allowDispatch: true)
        assert(codexNextRound.requests.map(\.action) == [.openProject, .sendProject] && codexNextRound.turns == 2
               && codexNextRound.requests.last?.text == codexBody && codexNextRound.outcome.error == nil,
               "Codex 真实打开事实回传后允许下一轮完整派单")
        assert(codexNextRound.corrections.contains { $0.contains("已打开 Codex") && $0.contains("send_project") }, "下一轮必须依据真实打开回执继续专属派单")
        let codexUnfinished = try runCodexOpening(codexVoice, batches: [[codexOpen]])
        assert(codexUnfinished.outcome.content == nil && codexUnfinished.outcome.error != nil && codexUnfinished.outcome.appDispatchReceipt == nil,
               "只打开 Codex 项目不能冒充复合任务已完成")
        let codexNoTools = try runCodexOpening(codexVoice, batches: [])
        assert(codexNoTools.outcome.content == nil && codexNoTools.outcome.error != nil && codexNoTools.outcome.appDispatchReceipt == nil,
               "模型口头成功不能代替 Codex 派单回执")
        let codexOnlyOpen = try runCodexOpening("打开 Codex 的 PocketDesk 项目", batches: [[codexOpen, codexSend]])
        assert(codexOnlyOpen.requests.map(\.action) == [.openProject] && codexOnlyOpen.turns == 1 && codexOnlyOpen.outcome.error == nil,
               "仅打开 Codex 项目仍直接收尾且不执行同批发送")
        let codexChoice = try runCodexOpening(codexVoice, batches: [[codexSend]], ambiguous: true)
        assert(codexChoice.outcome.needsInput && codexChoice.outcome.error == nil && codexChoice.outcome.appDispatchReceipt == nil
               && codexChoice.outcome.content?.contains("1. PocketDesk") == true, "多候选以中文待选择结果收尾，不提前发送")
        let choiceTranscript = codexChoice.task.transcript!
        assert(choiceTranscript.contains { $0["role"] as? String == "user" && $0["content"] as? String == codexVoice }, "待选择 transcript 保留完整真实语音目标")
        let originalCall = choiceTranscript.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }.first!
        assert((originalCall["function"] as? [String: Any])?["arguments"] as? String == codexSend, "待选择 transcript 保留 send_project 和完整 GitHub 指令")
        var selectedTask = codexChoice.task
        selectedTask.text = "PocketDesk那个"; selectedTask.attempt += 1; selectedTask.revision += 1
        selectedTask.messages.append(TaskMessage(role: .user, text: selectedTask.text))
        selectedTask.transcript = choiceTranscript + [["role": "user", "content": selectedTask.text]]
        let codexResumed = try runCodexOpening(selectedTask.text, batches: [[codexSend]], existingTask: selectedTask,
                                             allowDispatch: true, expectedHistory: [codexVoice, selectedTask.text])
        assert(codexResumed.task.id == codexChoice.task.id && codexResumed.requests.map(\.action) == [.sendProject]
               && codexResumed.requests.last?.project == "PocketDesk" && codexResumed.requests.last?.text == codexBody
               && codexResumed.outcome.appDispatchReceipt?.state == .confirmed, "一句候选补充沿用原任务并实际派出完整原正文")

        AgentRunner.workspaceAction = savedWorkspaceAction
        AgentRunner.openApp = savedOpenApp
        AgentRunner.dispatchToApp = savedDispatchToApp
        AgentRunner.resolveApp = savedResolve
        AgentRunner.readBookmarks = savedRead
        AgentRunner.openBookmark = savedOpenBookmark
        opened.removeAll()
        assert(lockTool != nil, "模型必须能发现已有锁屏能力")
        let lockSuccess = try run("lock_computer", "{}", extraLockCall: true)
        assert(lockSuccess.content == "电脑已锁屏。" && lockSuccess.error == nil)
        assert(opened == ["lock"], "同批锁屏只能执行一次")
        opened.removeAll()
        let lockPending = try run("lock_computer", "{}", lockResult: .success(.sent("尚未确认锁屏")))
        assert(lockPending.content == nil && lockPending.error?.contains("待核对") == true)
        let lockFailure = try run("lock_computer", "{}", lockResult: .failure(.message("执行失败")))
        assert(lockFailure.content == nil && lockFailure.error?.contains("执行失败") == true)
        let countBeforeDenied = opened.count
        let lockDenied = try run("lock_computer", "{}", allowed: false)
        assert(lockDenied.error != nil && opened.count == countBeforeDenied)
        let lockArguments = try run("lock_computer", "{\"command\":\"anything\"}")
        assert(lockArguments.error != nil && opened.count == countBeforeDenied)
        opened.removeAll()
        // 队列内失去控制权必须在系统命令之前返回；此测试不会真正锁屏。
        let executor = InputExecutor(store: TargetStore())
        let denied = DispatchSemaphore(value: 0)
        executor.triggerShortcut(ShortcutConfig(id: "system.lock", label: "锁屏", hotkey: "", action: "system.lock"), authorized: { false }) { result in
            guard case .failure = result else { fatalError("失去控制权却执行了锁屏") }
            denied.signal()
        }
        assert(denied.wait(timeout: .now() + 5) == .success)
        for action in DesktopActionRequest.Action.allCases {
            let extra = action == .menuAction ? ",\"command\":\"refresh\"" : action == .arrangeWindow ? ",\"position\":\"left\"" : ""
            let outcome = try run("desktop_action", "{\"action\":\"\(action.rawValue)\"\(extra)}")
            assert(outcome.content != nil && outcome.error == nil)
        }
        let menuSent = try run("desktop_action", "{\"action\":\"menu_action\",\"command\":\"refresh\"}", desktopResult: .success(.sent("刷新操作已发出，结果待核验")))
        assert(menuSent.content?.contains("已发出") == true && menuSent.error == nil)
        let discoverTwice = try run("desktop_action", "{\"action\":\"list_actions\"}", extraLockCall: true)
        assert(discoverTwice.error == nil, "只读发现允许重复，不占用写动作去重")
        let desktopBefore = opened.count
        let desktopDenied = try run("desktop_action", "{\"action\":\"quit_app\"}", allowed: false)
        assert(desktopDenied.error != nil && opened.count == desktopBefore)
        let desktopInvalid = try run("desktop_action", "{\"action\":\"shell\"}")
        assert(desktopInvalid.error != nil && opened.count == desktopBefore)
        let desktopPending = try run("desktop_action", "{\"action\":\"close_window\"}", desktopResult: .success(.sent("可能有保存提示")))
        assert(desktopPending.content == nil && desktopPending.error?.contains("待核对") == true)
        let desktopDuplicate = try run("desktop_action", "{\"action\":\"close_window\"}", extraLockCall: true)
        assert(desktopDuplicate.error != nil)
        assert(opened.filter { $0 == "desktop:close_window" }.count == 3, "重复关闭不能再次调用执行器")
        opened.removeAll()
        assert(DesktopActionRequest.parse("{\"action\":\"clear_input\",\"command\":\"rm\"}") == nil)
        assert(DesktopActionRequest.parse("{\"action\":\"quit_app\",\"window\":\"A\"}") == nil)
        assert(DesktopActionRequest.parse("{\"action\":\"hide_app\",\"app\":\"  \"}") == nil)
        assert(DesktopActionRequest.uniqueWindowIndex("报告", titles: ["报告", "报告"]) == nil)
        assert(DesktopActionRequest.uniqueWindowIndex("报告", titles: ["报告一", "报告"]) == 1)
        assert(DesktopActionRequest.uniqueWindowIndex("报告", titles: ["报告一"]) == nil)
        var field = DraftSnapshot.end(of: "中文😀草稿")
        var deletes = 0
        let selected = AgentDesktopActions.edit(.selectAll, valid: { true }, read: { field }, selectAll: {
            field = DraftSnapshot(text: field.text, location: 0, length: field.text.utf16.count); return true
        }, delete: { deletes += 1; return true })
        guard case .success(let selectedFeedback) = selected else { fatalError("全选失败") }
        assert(selectedFeedback.outcome == .delivered && deletes == 0)
        let cleared = AgentDesktopActions.edit(.clearInput, valid: { true }, read: { field }, selectAll: { true }, delete: {
            deletes += 1; field = .end(of: ""); return true
        })
        guard case .success(let clearedFeedback) = cleared else { fatalError("清空失败") }
        assert(clearedFeedback.outcome == .delivered && deletes == 1)
        field = .end(of: "不能误删")
        let unselected = AgentDesktopActions.edit(.clearInput, valid: { true }, read: { field }, selectAll: { true }, delete: { deletes += 1; return true })
        guard case .success(let uncertain) = unselected else { fatalError("应报告未确认") }
        assert(uncertain.outcome == .sent && deletes == 1 && field.text == "不能误删")
        var focused = true
        let lostFocus = AgentDesktopActions.edit(.clearInput, valid: { focused }, read: { field }, selectAll: { focused = false; return true }, delete: { deletes += 1; return true })
        guard case .failure = lostFocus else { fatalError("焦点改变必须停止") }
        assert(deletes == 1)
        let unreadable = AgentDesktopActions.edit(.clearInput, valid: { true }, read: { nil }, selectAll: { fatalError("不可读时不能全选") }, delete: { fatalError("不可读时不能删除") })
        guard case .failure = unreadable else { fatalError("不可读时必须拒绝") }
        let check1 = try run("open_page", "{\"url\":\"https://example.com\"}").content != nil
        assert(check1)
        assert(opened == ["https://example.com"])
        let check2 = try run("open_app", "{\"app\":\"Codex\"}").content != nil
        assert(check2)
        assert(opened.last == "/Applications/Codex.app")
        let before = opened.count
        let check3 = try run("open_app", "{\"app\":\"Codex\"}", allowed: false).error != nil
        assert(check3)
        assert(opened.count == before, "失去租约不能调用执行器")
        let check4 = try run("dispatch_to_app", "{\"app\":\"Codex\",\"text\":\"写测试\"}").content != nil
        assert(check4)
        let check5 = try run("dispatch_to_app", "{\"app\":\"Codex\",\"text\":\"写测试\"}", dispatchFailure: true).content == nil
        assert(check5)
        let dispatchCount = opened.filter { $0 == "dispatch" }.count
        let uncertainDispatch = try run("dispatch_to_app", "{\"app\":\"Codex\",\"text\":\"写测试\"}", dispatchUnconfirmed: true, extraLockCall: true)
        assert(uncertainDispatch.needsInput == false && uncertainDispatch.error == nil && uncertainDispatch.content == "已尝试发送，接收待核实")
        assert(opened.filter { $0 == "dispatch" }.count == dispatchCount + 1, "待核对不重放同批派单")
        let confirmed = try run("dispatch_to_app", "{\"app\":\"Codex\",\"text\":\"写测试\"}", extraLockCall: true)
        assert(!confirmed.needsInput && confirmed.error == nil && confirmed.content == "已交给 Codex")
        let currentMode = try run("dispatch_to_app", "{\"app\":\"Codex\",\"text\":\"写测试\",\"mode\":\"current\"}", expectedMode: .current)
        assert(currentMode.content != nil)
        let invalidMode = try run("dispatch_to_app", "{\"app\":\"Codex\",\"text\":\"写测试\",\"mode\":\"invented\"}")
        assert(invalidMode.error != nil)
        FeishuMessaging.invoke = { _ in .success(["users": [], "has_more": false]) }
        let contactQuestion = try run("feishu_message", "{\"recipient\":\"张三\",\"text\":\"明天开会\"}")
        assert(contactQuestion.needsInput && contactQuestion.content != nil && contactQuestion.error == nil)
        // ==================== 飞书群提及的模型工具契约与真实路由 ====================
        let messagingTool = AgentRunner.tools.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "feishu_message" }!
        let messagingParameters = messagingTool["parameters"] as! [String: Any]
        let messagingProperties = messagingParameters["properties"] as! [String: Any]
        let mentionSchema = messagingProperties["mentions"] as! [String: Any]
        assert(mentionSchema["type"] as? String == "array")
        assert((mentionSchema["items"] as? [String: Any])?["type"] as? String == "string", "提及对象须为姓名或 open_id 字符串数组")
        var feishuCalls: [[String]] = []
        FeishuMessaging.invoke = { arguments in
            feishuCalls.append(arguments)
            if arguments.contains("+chat-search") {
                return .success(["chats": [["chat_id": "oc_project", "name": "研发群"]], "has_more": false, "truncations": []])
            }
            if arguments.contains("+chat-members-list") {
                return .success(["users": [["member_id": "ou_one", "name": "张三"]], "has_more": false, "truncations": []])
            }
            assert(arguments.contains("+messages-send"), "工具路由不得执行额外写操作")
            return .success(["message_id": "om_route"])
        }
        let groupMention = try run("feishu_message", "{\"kind\":\"group\",\"recipient\":\"研发群\",\"text\":\"明天开会\",\"mentions\":[\"张三\"]}", extraLockCall: true)
        assert(groupMention.content?.contains("研发群") == true && groupMention.error == nil && !groupMention.needsInput)
        let routedSends = feishuCalls.filter { $0.contains("+messages-send") }
        assert(routedSends.count == 1, "群提及发送直接收尾，同批重复调用不得发送两遍")
        let routedSend = routedSends[0]
        assert(routedSend.contains("--chat-id") && routedSend.contains("oc_project") && routedSend.contains("--msg-type"))
        let routedContent = routedSend[routedSend.firstIndex(of: "--content")! + 1].data(using: .utf8)!
        let routedPost = try JSONSerialization.jsonObject(with: routedContent) as! [String: Any]
        let routedRows = (routedPost["zh_cn"] as! [String: Any])["content"] as! [[[String: Any]]]
        assert(routedRows[0][0]["tag"] as? String == "at" && routedRows[0][0]["user_id"] as? String == "ou_one", "模型 mentions 必须真正传到群发送业务层")
        assert(routedRows[0].last?["text"] as? String == "明天开会")
        let beforeInvalidMentions = feishuCalls.count
        _ = try run("feishu_message", "{\"kind\":\"group\",\"recipient\":\"研发群\",\"text\":\"明天开会\",\"mentions\":\"张三\"}")
        _ = try run("feishu_message", "{\"kind\":\"group\",\"recipient\":\"研发群\",\"text\":\"明天开会\",\"mentions\":[1]}")
        _ = try run("feishu_message", "{\"kind\":\"group\",\"recipient\":\"研发群\",\"text\":\"明天开会\",\"mentions\":[\"张三\"]}", allowed: false)
        assert(feishuCalls.count == beforeInvalidMentions, "无效提及和无控制权不得查询或发消息")
        // ==================== 真实失败参数经模型工具循环补查并只收尾一次 ====================
        feishuCalls.removeAll()
        FeishuMessaging.invoke = { arguments in
            feishuCalls.append(arguments)
            if arguments.contains("+search-bot") {
                let query = arguments[arguments.firstIndex(of: "--query")! + 1]
                assert(query == "7号机器人" || query == "7号")
                return .success(["bots": query == "7号" ? [["open_id": "ou_seven", "name": "7号"]] : [], "has_more": false])
            }
            assert(arguments.contains("+messages-send") && arguments.contains("ou_seven"))
            assert(arguments[arguments.firstIndex(of: "--text")! + 1] == "测试消息")
            return .success(["message_id": "om_seven"])
        }
        let botDelivery = try run("feishu_message", "{\"kind\":\"bot\",\"recipient\":\"7号机器人\",\"text\":\"测试消息\"}", extraLockCall: true)
        assert(botDelivery.content == "已发送给7号" && botDelivery.error == nil && !botDelivery.needsInput)
        assert(feishuCalls.filter { $0.contains("+search-bot") }.count == 2)
        assert(feishuCalls.filter { $0.contains("+messages-send") }.count == 1, "补查不增加外发次数，同批后续工具不继续")
        let codex = TargetConfig(id: "codex", name: "Codex")
        let wechat = TargetConfig(id: "wechat", name: "微信")
        let renamedCodex = TargetConfig(id: "chatgpt", name: "ChatGPT", bundleID: "com.openai.codex", path: nil)
        assert(AgentAppDispatch.target(named: "Codex", in: [renamedCodex])?.id == "chatgpt")
        let originalChat = TargetConfig(id: "chatgpt", name: "ChatGPT", bundleID: "com.openai.chat", path: nil)
        assert(AgentAppDispatch.target(named: "Codex", in: [originalChat]) == nil)
        assert(AgentAppDispatch.target(named: "Codex", in: [codex, renamedCodex]) == nil)
        assert(AgentAppDispatch.target(named: "Codex", in: [codex]) != nil)
        assert(AgentAppDispatch.target(named: "Codex", in: [codex, codex]) == nil)
        assert(AgentAppDispatch.target(named: "微信", in: [wechat]) == nil)
        // 只读目标配置；已尝试的任务必须同步拒绝，不能排入激活或清空队列。
        let store = TargetStore()
        if let configured = store.targets.first(where: { AgentAppDispatch.supportedNames.contains($0.name.lowercased()) }) {
            var duplicate = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: "重复派单", context: nil)
            duplicate.status = .running
            duplicate.messages.append(TaskMessage(role: .tool, text: "已经尝试", toolName: "dispatch_to_app"))
            try TaskStore.save(duplicate)
            var reply: AppDispatchReceipt?
            AgentAppDispatch.send(app: configured.name, text: "不能发送", taskId: duplicate.id,
                store: store, executor: InputExecutor(store: store), authorized: { true }) { reply = $0 }
            assert(reply?.state == .unconfirmed && reply?.summary == "已尝试发送，接收待核实", "重复派单必须在桌面副作用之前同步拒绝")
        }
        // 新建页面必须有应用特定证据；旧会话同名标题或不可读输入框不能放行。
        assert(AgentAppProfile.canonicalName("Workbody") == "workbuddy")
        assert(AgentTaskComposer.accessibilityBool(NSNumber(value: 1)) == true)
        assert(AgentTaskComposer.accessibilityBool("1") == true)
        assert(AgentTaskComposer.accessibilityBool("true") == true)
        assert(AgentTaskComposer.accessibilityBool("0") == false)
        assert(AgentTaskComposer.accessibilityBool("false") == false)
        assert(AgentTaskComposer.accessibilityBool(nil) == nil)
        assert(AgentTaskComposer.accessibilityBool("selected") == nil)
        assert(AgentAppProfile.workbuddy.isEmptyComposer(value: "\u{FEFF}\n今天帮你做些什么？\n@ 引用对话文件，/ 调用技能与指令", placeholder: nil))
        assert(!AgentAppProfile.workbuddy.isEmptyComposer(value: "今天帮你做些什么？ @ 引用对话文件，/ 调用技能与指令\n查找视频", placeholder: nil))
        assert(AgentAppProfile.canonicalName("z code") == "zcode")
        assert(AgentAppProfile.workbuddy.isEmptyComposer(value: "\u{FEFF}今天帮你做些什么？ @ 引用对话文件，/ 调用技能与指令", placeholder: nil))
        assert(!AgentAppProfile.workbuddy.isEmptyComposer(value: "用户尚未提交的草稿", placeholder: nil))
        assert(!AgentAppProfile.zcode.isEmptyComposer(value: nil, placeholder: "向 ZCode 提问"))
        assert(AgentAppProfile.workbuddy.hasNewPageEvidence(labels: ["WorkBuddy, 我帮你"], selectedNewTab: true, placeholder: "", beforeLabels: []))
        assert(!AgentAppProfile.workbuddy.hasNewPageEvidence(labels: ["WorkBuddy, 我帮你"], selectedNewTab: false, placeholder: "", beforeLabels: []))
        assert(AgentAppProfile.zcode.hasNewPageEvidence(labels: ["选择项目"], selectedNewTab: false, placeholder: "向 ZCode 提问，使用 @ 添加上下文", beforeLabels: []))
        assert(!AgentAppProfile.zcode.hasNewPageEvidence(labels: ["新建任务"], selectedNewTab: false, placeholder: "向 ZCode 提问", beforeLabels: []))
        let colaLabels: Set<String> = ["新建会话", "新建会话 草稿 · /project-new"]
        assert(AgentAppProfile.cola.hasNewPageEvidence(labels: colaLabels, selectedNewTab: false, placeholder: "", beforeLabels: ["新建会话"]))
        assert(!AgentAppProfile.cola.hasNewPageEvidence(labels: colaLabels, selectedNewTab: false, placeholder: "", beforeLabels: colaLabels))
        // Cola 1.5.0：会话侧栏只有一个新建动作，产品侧栏标为“新建项目”、草稿会话名与旧侧栏按钮同名，
        // 所以标签本身分不出真假，只认空会话聊天区独有的欢迎句。
        assert(AgentAppProfile.cola.newButtonNames.contains("新建会话") && AgentAppProfile.cola.newButtonNames.contains("新建项目"))
        let colaEmptyChat: Set<String> = ["新建项目", "新建会话", "告诉 Cola，你想在这个项目里做点什么"]
        assert(AgentAppProfile.cola.hasNewPageEvidence(labels: colaEmptyChat, selectedNewTab: false, placeholder: "", beforeLabels: ["新建项目"]))
        assert(AgentAppProfile.cola.hasNewPageEvidence(labels: colaEmptyChat, selectedNewTab: false, placeholder: "", beforeLabels: ["新建会话", "新建项目"]))
        assert(AgentAppProfile.cola.hasNewPageEvidence(labels: ["Tell Cola what you'd like to do in this project"], selectedNewTab: false, placeholder: "", beforeLabels: []))
        assert(!AgentAppProfile.cola.hasNewPageEvidence(labels: ["新建项目", "新建会话"], selectedNewTab: false, placeholder: "", beforeLabels: ["新建项目", "新建会话"]))
        let prompt = "用 Computer Use 查看飞书群聊\n中文 & # ? + % 😀"
        let url = AgentAppProfile.codexURL(text: prompt)!
        assert(url.scheme == "codex" && url.host == "threads" && url.path == "/new")
        assert(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == prompt)
        let invalidType = try run("dispatch_to_app", "{\"app\":\"Codex\",\"text\":\"写测试\",\"mode\":false}")
        assert(invalidType.error != nil)
        // 并发占用只允许一个调用进入桌面副作用；重启读盘仍然拒绝重复。
        var reserved = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: "并发派单", context: nil)
        assert(tryReserve(reserved.id) == false, "未运行任务不能派单")
        reserved.status = .running
        try TaskStore.save(reserved)
        let counterLock = NSLock()
        var successes = 0
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if tryReserve(reserved.id) { counterLock.lock(); successes += 1; counterLock.unlock() }
        }
        assert(successes == 1)
        try TaskStore.save(reserved) // 旧快照不能抹掉不可重放证据。
        TaskStore.resetCache()
        assert(!tryReserve(reserved.id))
        assert(TaskStore.task(id: reserved.id)?.messages.filter { $0.toolName == "dispatch_to_app" }.count == 1)
        print("agent runner: direct execution / lease / dispatch / failure / target isolation passed")
    }
}
