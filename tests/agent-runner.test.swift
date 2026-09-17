/**
 * [INPUT]: 注入 AgentRunner 的模型/打开/派单替身，TaskStore 使用临时目录。
 * [OUTPUT]: 验证直接执行无确认、工具串行、租约失效拦截、派单失败不冒充成功、目标匹配（含 Codex 包身份别名和歧义拒绝）及重复派单在激活/清空之前被拒绝。
 * [POS]: Agent 工具循环的无桌面副作用回归，不联网、不打开真实应用、不发消息。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct AgentRunnerTests {
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

        func run(_ tool: String, _ arguments: String, allowed: Bool = true, dispatchFailure: Bool = false) throws -> AgentRunner.Outcome {
            var task = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: "测试指令", context: nil)
            task.status = .running
            try TaskStore.save(task)
            var turns = 0
            var pageReads = 0
            AgentRunner.canControl = { _ in allowed }
            AgentRunner.dispatchToApp = { app, text, _, done in
                assert(app == "Codex" && text == "写测试")
                opened.append("dispatch")
                done(dispatchFailure ? "未派单：输入框非空。" : "已提交到 Codex。")
            }
            AgentRunner.sendModel = { _, messages, _, _, done in
                turns += 1
                if turns == 1 {
                    let call: [String: Any] = ["id": "c1", "type": "function", "function": ["name": tool, "arguments": arguments]]
                    done(.success(ModelTurn(toolCalls: [call], rawMessage: ["role": "assistant", "tool_calls": [call]])))
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
            return outcome!
        }
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
        print("agent runner: direct execution / lease / dispatch / failure / target isolation passed")
    }
}
