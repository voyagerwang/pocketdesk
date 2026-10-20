/**
 * [INPUT]: CLI 帮助/执行替身、临时 TaskStore 与 npm/原生启动器夹具，--live 仅查询现有授权和一页群列表。
 * [OUTPUT]: 通用业务域、去重/确认、参数与身份边界，以及后台系统 PATH 下选择独立原生入口和准确分类启动失败的隔离断言。
 * [POS]: 飞书通用入口与进程边界回归；启动器夹具只返回合成数据，不产生真实消息或业务写入。
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
        try verifyCLIContract(directory)
        try verifyBackgroundLauncher(directory)
        print("gateway: discovery / arguments / identity / dedupe / confirmation / group / CLI auth / background launcher passed")
    }

    static func verifyCLIContract(_ directory: URL) throws {
        // ==================== 进程边界只读替身，不接触真实钥匙串 ====================
        let executable = directory.appendingPathComponent("fixture-cli")
        let resultFile = directory.appendingPathComponent("fixture-result.json")
        try "#!/bin/sh\nif [ \"$PD_FEISHU_TEST_EXIT\" = \"0\" ]; then /bin/cat \"$PD_FEISHU_TEST_RESULT\"; else /bin/cat \"$PD_FEISHU_TEST_RESULT\" >&2; fi\nexit \"$PD_FEISHU_TEST_EXIT\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let keys = ["LARK_CLI_PATH", "PD_FEISHU_TEST_RESULT", "PD_FEISHU_TEST_EXIT"]
        let saved = keys.map { key in getenv(key).map { String(cString: $0) } }
        defer {
            for (index, key) in keys.enumerated() {
                if let value = saved[index] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setenv("LARK_CLI_PATH", executable.path, 1)
        setenv("PD_FEISHU_TEST_RESULT", resultFile.path, 1)
        setenv("PD_FEISHU_TEST_EXIT", "0", 1)
        func write(_ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: resultFile)
        }
        try write(["verified": true, "identity": "bot", "identities": ["bot": ["verified": true],
            "user": ["status": "missing", "available": false, "tokenStatus": "expired"]]])
        guard case .success(let unavailable) = FeishuCLI.capabilities() else { fatalError("auth fixture") }
        assert(unavailable["verified"] as? Bool == false && unavailable["tokenStatus"] as? String == "expired", "机器人可用不能冒充本人登录")
        try write(["verified": true, "identity": "user", "identities": ["user": ["verified": true, "available": true,
            "status": "ready", "tokenStatus": "valid", "scope": "im:message"]]])
        guard case .success(let ready) = FeishuCLI.capabilities() else { fatalError("ready fixture") }
        assert(ready["verified"] as? Bool == true)
        setenv("PD_FEISHU_TEST_EXIT", "3", 1)
        try write(["ok": false, "identity": "user", "error": ["type": "authentication", "subtype": "token_missing", "message": "need_user_authorization"]])
        guard case .failure(let expired) = FeishuCLI.run(["im", "+messages-send"]) else { fatalError("expired user must fail") }
        assert(expired.message.contains("本人登录已失效"))
        try write(["ok": false, "identity": "user", "error": ["type": "network", "subtype": "connect", "message": "request failed"]])
        guard case .failure(let network) = FeishuCLI.run(["contact", "+search-user"]) else { fatalError("network failure must fail") }
        assert(network.message.contains("无法连接飞书服务"), "网络失败不能被归因为本人登录或联系人权限")
    }

    static func verifyBackgroundLauncher(_ directory: URL) throws {
        // ==================== 模拟后台 App 的最小 PATH，不依赖终端 Node ====================
        let files = FileManager.default
        let keys = ["LARK_CLI_PATH", "PATH"]
        let saved = keys.map { key in getenv(key).map { String(cString: $0) } }
        defer {
            for (index, key) in keys.enumerated() {
                if let value = saved[index] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        func script(_ url: URL, _ body: String, executable: Bool = true) throws {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
        let success = "#!/bin/sh\n/bin/echo '{\"ok\":true,\"identity\":\"user\",\"data\":{\"launcher\":\"native\"}}'\n"
        let custom = directory.appendingPathComponent("custom-native-cli")
        try script(custom, success)
        setenv("LARK_CLI_PATH", custom.path, 1)
        assert(FeishuCLI.executable() == custom.path, "自定义原生入口必须保持兼容")
        guard case .success(let customResult) = FeishuCLI.run(["contact", "+search-user"]) else { fatalError("custom native launcher") }
        assert(customResult["launcher"] as? String == "native")
        assert(FeishuCLI.resolveExecutable("") == nil)
        assert(FeishuCLI.resolveExecutable(directory.appendingPathComponent("missing-cli").path) == nil)
        let unavailable = directory.appendingPathComponent("non-executable-cli")
        try script(unavailable, success, executable: false)
        assert(FeishuCLI.resolveExecutable(unavailable.path) == nil)

        let package = directory.appendingPathComponent("npm/node_modules/@larksuite/cli")
        let scripts = package.appendingPathComponent("scripts")
        let nativeDirectory = package.appendingPathComponent("bin")
        let npmBin = directory.appendingPathComponent("npm/bin")
        for path in [scripts, nativeDirectory, npmBin] { try files.createDirectory(at: path, withIntermediateDirectories: true) }
        let wrapper = scripts.appendingPathComponent("run.js")
        let native = nativeDirectory.appendingPathComponent("lark-cli")
        let symlink = npmBin.appendingPathComponent("lark-cli")
        try script(wrapper, "#!/usr/bin/env node\nthrow new Error('npm wrapper must not execute');\n")
        try script(native, success)
        try files.createSymbolicLink(atPath: symlink.path, withDestinationPath: "../node_modules/@larksuite/cli/scripts/run.js")
        setenv("LARK_CLI_PATH", symlink.path, 1)
        assert(FeishuCLI.resolveExecutable(symlink.path) == native.path, "npm symlink 应优先使用同包独立原生入口")
        assert(FeishuCLI.resolveExecutable(wrapper.path) == native.path, "直接指定 npm wrapper 也应选择同包原生入口")
        assert(FeishuCLI.executable() == native.path)
        guard case .success(let backgroundResult) = FeishuCLI.run(["contact", "+search-user"]) else { fatalError("background native launcher") }
        assert(backgroundResult["launcher"] as? String == "native", "系统 PATH 中没有 Node 也必须正常调用 CLI")

        // ==================== 原生入口不可用时保留原候选，准确报告启动故障 ====================
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: native.path)
        assert(FeishuCLI.resolveExecutable(symlink.path) == symlink.path, "不可执行的原生文件不能覆盖可执行 wrapper")
        try files.removeItem(at: native)
        assert(FeishuCLI.executable() == symlink.path, "原生入口缺失时应保留自定义入口")
        guard case .failure(let missingNode) = FeishuCLI.run(["contact", "+search-user"]) else { fatalError("missing node must fail") }
        assert(missingNode.message.contains("Node"), "Node 缺失必须给出具体中文运行环境诊断")
        assert(missingNode.message.contains("飞书") && !missingNode.message.contains("结果无法核对"))

        // ==================== 无结构证据的响应仍失败，不把未知响应当作完成 ====================
        let malformed = directory.appendingPathComponent("malformed-cli")
        try script(malformed, "#!/bin/sh\n/bin/echo 'not-json'\n")
        setenv("LARK_CLI_PATH", malformed.path, 1)
        guard case .failure(let unknown) = FeishuCLI.run(["contact", "+search-user"]) else { fatalError("non-JSON result must fail") }
        assert(unknown.message.contains("结果无法核对"))
    }
}
