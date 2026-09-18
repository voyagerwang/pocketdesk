/**
 * [INPUT]: 注入 AgentRunner 的模型/打开/派单替身，TaskStore 使用临时目录。
 * [OUTPUT]: 覆盖桌面动作参数/去重、输入选区与焦点保护；覆盖锁屏工具发现、执行回执、无效参数、租约与同批去重；验证直接执行无确认、工具串行、租约失效拦截、派单失败不冒充成功、目标匹配（含 Codex 包身份别名和歧义拒绝）、新建页面证据、正文深链编码及并发派单原子去重。
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

        func run(_ tool: String, _ arguments: String, allowed: Bool = true, dispatchFailure: Bool = false, expectedMode: AgentConversationMode = .newTask, lockResult: Result<ExecutionFeedback, ShortcutError> = .success(.delivered("电脑已锁屏。")), extraLockCall: Bool = false, desktopResult: Result<ExecutionFeedback, ShortcutError> = .success(.delivered("已操作。"))) throws -> AgentRunner.Outcome {
            var task = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: "测试指令", context: nil)
            task.status = .running
            try TaskStore.save(task)
            var turns = 0
            var pageReads = 0
            AgentRunner.canControl = { _ in allowed }
            AgentRunner.dispatchToApp = { app, text, _, mode, done in
                assert(app == "Codex" && text == "写测试" && mode == expectedMode)
                opened.append("dispatch")
                done(dispatchFailure ? "未派单：输入框非空。" : "已提交到 Codex。")
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
            assert(TaskStore.task(id: task.id)?.status == .running, "工具执行不再挂起任务等确认")
            assert(pageReads == 0, "打开应用不得预读无关网页")
            if tool == "lock_computer", allowed, arguments == "{}" {
                assert(turns == 1, "锁屏后直接按回执结束，不再请求模型编造结果")
            }
            return outcome!
        }
        let lockTool = AgentRunner.tools.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "lock_computer" }
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
        let currentMode = try run("dispatch_to_app", "{\"app\":\"Codex\",\"text\":\"写测试\",\"mode\":\"current\"}", expectedMode: .current)
        assert(currentMode.content != nil)
        let invalidMode = try run("dispatch_to_app", "{\"app\":\"Codex\",\"text\":\"写测试\",\"mode\":\"invented\"}")
        assert(invalidMode.error != nil)
        FeishuMessaging.invoke = { _ in .success(["users": [], "has_more": false]) }
        let contactQuestion = try run("feishu_message", "{\"recipient\":\"张三\",\"text\":\"明天开会\"}")
        assert(contactQuestion.needsInput && contactQuestion.content != nil && contactQuestion.error == nil)
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
            var reply: String?
            AgentAppDispatch.send(app: configured.name, text: "不能发送", taskId: duplicate.id,
                store: store, executor: InputExecutor(store: store), authorized: { true }) { reply = $0 }
            assert(reply?.hasPrefix("本任务已经尝试派单") == true, "重复派单必须在桌面副作用之前同步拒绝")
        }
        // 新建页面必须有应用特定证据；旧会话同名标题或不可读输入框不能放行。
        assert(AgentAppProfile.canonicalName("Workbody") == "workbuddy")
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
