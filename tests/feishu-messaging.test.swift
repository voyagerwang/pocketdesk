/**
 * [INPUT]: 飞书业务适配、临时 TaskStore、固定联系人/机器人/群/成员 CLI 替身；--live 只读取当前用户资料。
 * [OUTPUT]: 验证个人/机器人/群发送、原词优先与空列表后的有界类型词查询、真实名称保护、准确同名及明确选择门禁；真正 @ 的 post 节点、正文冻结、查询完整性、本人身份、发送去重与租约失效。
 * [POS]: 飞书发送的隔离回归，任何测试都不向真实联系人发消息。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct FeishuMessagingTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        TaskStore.resetCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        func task() throws -> AgentTask {
            var task = try TaskStore.claim(subject: "test", requestId: UUID().uuidString, text: "给张三发消息", context: nil)
            task.status = .running
            try TaskStore.save(task); return task
        }
        let one: [String: Any] = ["users": [["open_id": "ou_one", "localized_name": "张三", "department": "产品部"]], "has_more": false]
        let two: [String: Any] = ["users": [["open_id": "ou_one", "localized_name": "张三", "department": "产品部"], ["open_id": "ou_two", "localized_name": "张三", "department": "研发部"]], "has_more": false]
        var calls: [[String]] = []
        var search = one
        var failSend = false
        FeishuMessaging.invoke = { args in
            calls.append(args)
            if args[0] == "contact" { return .success(search) }
            return failSend ? .failure(.init(message: "timeout")) : .success(["message_id": "om_test"])
        }
        let text = "第一行\n$(echo secret); --as bot"
        let first = try task()
        guard case .sent = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: first.id, authorized: { true }) else { fatalError("single match failed") }
        let send = calls.last!
        assert(send[send.firstIndex(of: "--text")! + 1] == text)
        assert(send[send.firstIndex(of: "--as")! + 1] == "user")
        assert(send.contains("--idempotency-key"))
        let count = calls.count
        _ = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: first.id, authorized: { true })
        assert(calls.count == count)
        search = two
        let ambiguous = try task()
        guard case .needsInput(let question) = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: ambiguous.id, authorized: { true }) else { fatalError("must ask") }
        assert(question.contains("研发部") && !question.contains("ou_"))
        guard case .failed = FeishuMessaging.perform(recipient: "张三", text: text, choice: "1", taskId: ambiguous.id, authorized: { true }) else { fatalError("model cannot choose without user turn") }
        var selected = TaskStore.task(id: ambiguous.id)!; selected.supplementCount = 1; try TaskStore.save(selected)
        guard case .sent = FeishuMessaging.perform(recipient: "张三", text: text, choice: "2", taskId: ambiguous.id, authorized: { true }) else { fatalError("choice failed") }
        assert(calls.last!.contains("ou_two"))
        search = one; failSend = true
        let failed = try task()
        guard case .failed = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: failed.id, authorized: { true }) else { fatalError("unknown must fail") }
        let attempts = calls.count
        _ = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: failed.id, authorized: { true })
        assert(calls.count == attempts)
        let denied = try task()
        _ = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: denied.id, authorized: { false })
        assert(calls.count == attempts)
        search = ["users": [], "has_more": false]
        guard case .needsInput = FeishuMessaging.perform(recipient: "张三", text: text, choice: nil, taskId: denied.id, authorized: { true }) else { fatalError("not found must ask") }
        if CommandLine.arguments.contains("--live") {
            guard case .success(let data) = FeishuCLI.run(["contact", "+search-user", "--user-ids", "me", "--as", "user", "--format", "json"]), !(data["users"] as? [[String: Any]] ?? []).isEmpty else { fatalError("existing CLI authorization unavailable") }
            print("existing CLI authorization: read-only self lookup passed")
        }
        try groupTests(task: task)
        try botTests(task: task)
        try recipientQueryTests(task: task)
        print("feishu: person / bot / group / recipient queries / exact fallback / real mentions / sequential choices / payload / truncation / idempotency / lease passed")
    }

    // ==================== 原名称优先，空结果才处理类型词 ====================
    static func recipientQueryTests(task: () throws -> AgentTask) throws {
        let originalInvoke = FeishuMessaging.invoke
        defer { FeishuMessaging.invoke = originalInvoke }
        let bot: [String: Any] = ["open_id": "ou_seven", "name": "7号"]
        let other: [String: Any] = ["open_id": "ou_other", "name": "7号助手"]
        let group: [String: Any] = ["chat_id": "oc_command", "name": "指挥部"]
        var replies: [String: [String: Any]] = [:]
        var calls: [[String]] = []
        var allowed = true
        var failQuery: String?
        var loseOnQuery: String?
        var abandonOnQuery: (query: String, taskId: String)?
        var failSend = false
        func value(_ option: String, _ args: [String]) -> String? {
            guard let index = args.firstIndex(of: option), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        func response(_ kind: String, _ entries: [[String: Any]], more: Bool = false,
                      truncations: [String] = []) -> [String: Any] {
            [kind == "bot" ? "bots" : kind == "group" ? "chats" : "users": entries,
             "has_more": more, "truncations": truncations]
        }
        func queries() -> [String] { calls.compactMap { value("--query", $0) } }
        func sends() -> [[String]] { calls.filter { $0.contains("+messages-send") } }
        func reset() {
            calls = []; replies = [:]; allowed = true; failQuery = nil
            loseOnQuery = nil; abandonOnQuery = nil; failSend = false
        }
        let body = "第一行\n测试消息 --as bot $(echo secret)"
        func perform(_ current: AgentTask, _ recipient: String, kind: String = "bot",
                     choice: String? = nil, text: String? = nil) -> FeishuMessaging.Outcome {
            FeishuMessaging.perform(recipient: recipient, text: text ?? body, choice: choice, taskId: current.id,
                                    kind: kind, authorized: { allowed })
        }
        FeishuMessaging.invoke = { args in
            calls.append(args)
            assert(value("--as", args) == "user")
            if let query = value("--query", args) {
                if loseOnQuery == query { allowed = false }
                if let pending = abandonOnQuery, pending.query == query {
                    var abandoned = TaskStore.task(id: pending.taskId)!
                    abandoned.status = .abandoned; try! TaskStore.save(abandoned)
                }
                if failQuery == query { return .failure(.init(message: "read failed")) }
                let kind = args.contains("+search-bot") ? "bot" : args.contains("+chat-search") ? "group" : "person"
                return .success(replies[query] ?? response(kind, []))
            }
            assert(args.contains("+messages-send"), "替身仅允许固定查询与模拟发送")
            return failSend ? .failure(.init(message: "timeout")) : .success(["message_id": "om_query"])
        }

        for recipient in ["7号机器人", "机器人7号", "飞书的 7号机器人", "飞书机器人7号"] {
            reset(); replies["7号"] = response("bot", [bot])
            let current = try task()
            guard case .sent = perform(current, recipient) else { fatalError("准确的7号补查应发送") }
            assert(queries() == [recipient, "7号"] && sends().count == 1)
            assert(value("--user-id", sends()[0]) == "ou_seven" && value("--text", sends()[0]) == body)
            let after = calls.count
            guard case .sent = perform(current, recipient) else { fatalError("已发送任务应复用回执") }
            assert(calls.count == after)
        }
        for recipient in ["飞书指挥部", "飞书的指挥部群聊", "指挥部群"] {
            reset(); replies["指挥部"] = response("group", [group])
            guard case .sent = perform(try task(), recipient, kind: "group") else { fatalError("准确群补查应发送") }
            assert(queries() == [recipient, "指挥部"] && value("--chat-id", sends()[0]) == "oc_command")
        }
        reset()
        replies["飞书指挥部"] = ["chats": NSNull(), "has_more": false, "page_token": "", "total": 0]
        replies["指挥部"] = response("group", [group])
        guard case .sent = perform(try task(), "飞书指挥部", kind: "group") else { fatalError("真实CLI的chats:null/total:0应允许补查") }
        assert(queries() == ["飞书指挥部", "指挥部"] && sends().count == 1)
        for malformed in [["chats": NSNull(), "has_more": false], ["chats": NSNull(), "has_more": false, "total": false],
                          ["chats": NSNull(), "has_more": false, "total": "0"], ["chats": NSNull(), "has_more": false, "total": 1],
                          ["chats": NSNull(), "has_more": 0, "total": 0], ["chats": NSNull(), "has_more": false, "total": 0, "truncations": "unknown"],
                          ["has_more": false, "total": 0]] as [[String: Any]] {
            reset(); replies["飞书指挥部"] = malformed; replies["指挥部"] = response("group", [group])
            guard case .needsInput = perform(try task(), "飞书指挥部", kind: "group") else { fatalError("未知的群空结果不能补查") }
            assert(queries() == ["飞书指挥部"] && sends().isEmpty)
        }
        // 原始真实名称含“飞书”“机器人”“群”时，不能先改名再发送。
        for (recipient, kind) in [("7号机器人", "bot"), ("飞书的机器人", "bot"), ("研发群", "group")] {
            reset()
            let entry: [String: Any] = [kind == "bot" ? "open_id" : "chat_id": kind == "bot" ? "ou_literal" : "oc_literal", "name": recipient]
            replies[recipient] = response(kind, [entry])
            guard case .sent = perform(try task(), recipient, kind: kind) else { fatalError("原名称结果应优先") }
            assert(queries() == [recipient] && sends().count == 1)
        }
        for (recipient, kind) in [("飞书张三", "person"), ("7号机器人", "person"), ("机器人", "bot"), ("飞书的机器人", "bot"), ("飞书群", "group"), ("编号机器人服务", "bot")] {
            reset()
            guard case .needsInput = perform(try task(), recipient, kind: kind) else { fatalError("不应删除姓名/内部词或查询空名称") }
            assert(queries() == [recipient] && sends().isEmpty)
        }
        // 字段缺失或无效 ID 的非空列表，不能当作原名称无结果。
        for malformed in [["has_more": false], response("bot", [["open_id": "invalid", "name": "7号"]])] {
            reset(); replies["7号机器人"] = malformed; replies["7号"] = response("bot", [bot])
            guard case .needsInput = perform(try task(), "7号机器人") else { fatalError("损坏结果不得补查") }
            assert(queries() == ["7号机器人"] && sends().isEmpty)
        }
        for incomplete in [response("bot", [bot, ["open_id": "invalid", "name": "7号"]]), response("bot", [bot, bot]),
                           ["bots": [bot], "has_more": 0], ["bots": [bot], "has_more": false, "truncations": "unknown"]] as [[String: Any]] {
            reset(); replies["7号"] = incomplete
            let current = try task()
            guard case .needsInput = perform(current, "7号机器人") else { fatalError("补查不能隐藏无法核对的候选或完整性字段") }
            assert(queries() == ["7号机器人", "7号"] && sends().isEmpty && TaskStore.task(id: current.id)?.feishuChoice == nil)
        }
        for (query, result) in [("7号机器人", response("bot", [], more: true)), ("7号机器人", response("bot", [], truncations: ["limit"])),
                                ("7号", response("bot", [bot], more: true)), ("7号", response("bot", [bot], truncations: ["limit"]))] {
            reset(); replies[query] = result
            guard case .needsInput = perform(try task(), "7号机器人") else { fatalError("不完整结果不得发送") }
            assert(queries().count == (query == "7号" ? 2 : 1) && sends().isEmpty)
        }
        for query in ["7号机器人", "7号"] {
            reset(); failQuery = query
            guard case .failed = perform(try task(), "7号机器人") else { fatalError("查询失败不得发送") }
            assert(queries().count == (query == "7号" ? 2 : 1) && sends().isEmpty)
        }
        // 补查只在唯一准确同名时自动发；其他候选留给用户选择，冻结原正文。
        for entries in [[other], [bot, other], [bot, ["open_id": "ou_second", "name": "7号"]]] {
            reset(); replies["7号"] = response("bot", entries)
            let current = try task()
            guard case .needsInput = perform(current, "7号机器人") else { fatalError("非准确或多候选应确认") }
            assert(sends().isEmpty && TaskStore.task(id: current.id)?.feishuChoice?.contacts.count == entries.count)
            var selected = TaskStore.task(id: current.id)!
            selected.supplementCount += 1; try TaskStore.save(selected)
            guard case .sent = perform(selected, "7号机器人", choice: "1", text: "模型改写") else { fatalError("明确选择应续接") }
            assert(queries().count == 2 && sends().count == 1 && value("--text", sends()[0]) == body)
            assert(TaskStore.task(id: current.id)?.feishuDelivery?.recipient == entries[0]["name"] as? String)
        }
        // 查询间失权或任务结束，第二次查询与发送都不得发生。
        reset(); loseOnQuery = "7号机器人"; replies["7号"] = response("bot", [bot])
        guard case .failed = perform(try task(), "7号机器人") else { fatalError("失权必须停止补查") }
        assert(queries() == ["7号机器人"] && sends().isEmpty)
        reset(); let abandoned = try task(); abandonOnQuery = ("7号机器人", abandoned.id)
        guard case .failed = perform(abandoned, "7号机器人") else { fatalError("已结束任务必须停止补查") }
        assert(queries() == ["7号机器人"] && sends().isEmpty)
        reset(); loseOnQuery = "7号"; replies["7号"] = response("bot", [bot])
        guard case .failed = perform(try task(), "7号机器人") else { fatalError("补查后失权不得发送") }
        assert(queries().count == 2 && sends().isEmpty)
        reset(); replies["7号"] = response("bot", [bot]); failSend = true
        let unknown = try task()
        guard case .failed = perform(unknown, "7号机器人") else { fatalError("发送超时必须待核实") }
        let afterUnknown = calls.count
        guard case .failed = perform(unknown, "7号机器人") else { fatalError("未知发送不得重放") }
        assert(calls.count == afterUnknown && sends().count == 1)
    }

    // ==================== 机器人收件者仍以本人身份发送 ====================
    static func botTests(task: () throws -> AgentTask) throws {
        let originalInvoke = FeishuMessaging.invoke
        defer { FeishuMessaging.invoke = originalInvoke }
        let one: [String: Any] = ["open_id": "ou_bot_one", "name": "YZ工作台", "description": "工作记录助手"]
        let two: [String: Any] = ["open_id": "ou_bot_two", "name": "YZ工作台", "description": "测试工作台"]
        var results: [String: Any] = ["bots": [one], "has_more": false, "truncations": []]
        var calls: [[String]] = []
        FeishuMessaging.invoke = { arguments in
            calls.append(arguments)
            if arguments.contains("+search-bot") { return .success(results) }
            assert(arguments.contains("+messages-send"), "机器人必须使用明确的查询入口，不能误查联系人或群聊")
            return .success(["message_id": "om_bot"])
        }
        func value(_ option: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        func sends() -> [[String]] { calls.filter { $0.contains("+messages-send") } }
        func perform(_ current: AgentTask, text: String, choice: String? = nil,
                     kind: String = "bot", mentions: [String] = []) -> FeishuMessaging.Outcome {
            FeishuMessaging.perform(recipient: "YZ工作台", text: text, choice: choice, taskId: current.id,
                                    kind: kind, mentions: mentions, authorized: { true })
        }
        let body = "保存今日记录\n--as bot $(echo secret)"
        let unique = try task()
        guard case .sent = perform(unique, text: body) else { fatalError("唯一机器人应发送") }
        assert(calls[0].first == "contact" && calls[0].contains("+search-bot"))
        assert(value("--query", in: calls[0]) == "YZ工作台")
        assert(value("--as", in: calls[0]) == "user", "查询机器人的身份仍为本人")
        assert(value("--user-id", in: sends().last!) == "ou_bot_one" && !sends().last!.contains("--chat-id"))
        assert(value("--as", in: sends().last!) == "user", "机器人是收件者，不能切换为机器人发送身份")
        assert(value("--text", in: sends().last!) == body && sends().last!.contains("--idempotency-key"))
        let afterUnique = calls.count
        guard case .sent = perform(unique, text: "重传") else { fatalError("已发送机器人应复用回执") }
        assert(calls.count == afterUnique, "同任务发送机器人仍不得重复发送")

        // ==================== 同名机器人选择冻结原正文与收件者类型 ====================
        results = ["bots": [one, two], "has_more": false, "truncations": []]
        let ambiguous = try task()
        guard case .needsInput(let question) = perform(ambiguous, text: body) else { fatalError("同名机器人必须等待选择") }
        assert(question.contains("工作记录助手") && question.contains("测试工作台") && !question.contains("ou_"))
        assert(TaskStore.task(id: ambiguous.id)?.feishuChoice?.kind == "bot")
        let beforeChoice = calls.count
        guard case .failed = perform(ambiguous, text: "模型改写", choice: "2") else { fatalError("同轮不能代替用户选择机器人") }
        assert(calls.count == beforeChoice)
        var follow = TaskStore.task(id: ambiguous.id)!
        follow.supplementCount += 1
        try TaskStore.save(follow)
        guard case .failed = perform(ambiguous, text: "模型改写", choice: "2", kind: "person") else { fatalError("补充不能把机器人改为联系人") }
        assert(calls.count == beforeChoice)
        guard case .sent = perform(ambiguous, text: "模型改写", choice: "2") else { fatalError("新轮次应按选择发送机器人") }
        assert(value("--user-id", in: sends().last!) == "ou_bot_two")
        assert(value("--text", in: sends().last!) == body, "机器人选择只决定收件者，冻结原正文不能被模型覆盖")
        assert(value("--as", in: sends().last!) == "user")

        let beforeMentions = calls.count
        guard case .failed = perform(try task(), text: body, mentions: ["张三"]) else { fatalError("机器人单聊不得携带群内提及") }
        assert(calls.count == beforeMentions, "机器人单聊提及必须在查询或发送前拒绝")
    }

    // ==================== 群消息与成员提及 ====================
    static func groupTests(task: () throws -> AgentTask) throws {
        let originalInvoke = FeishuMessaging.invoke
        defer { FeishuMessaging.invoke = originalInvoke }
        let group: [String: Any] = ["chat_id": "oc_project", "name": "研发群", "description": "产品研发"]
        let otherGroup: [String: Any] = ["chat_id": "oc_other", "name": "研发群", "description": "项目二组"]
        let a: [String: Any] = ["member_id": "ou_a", "name": "张三"]
        let a2: [String: Any] = ["member_id": "ou_a2", "name": "张三"]
        let b: [String: Any] = ["member_id": "ou_b", "name": "李四"]
        let b2: [String: Any] = ["member_id": "ou_b2", "name": "李四"]
        var chats: [String: Any] = ["chats": [group], "has_more": false, "truncations": []]
        var members: [String: Any] = ["users": [a, b], "has_more": false, "truncations": []]
        var calls: [[String]] = []
        var allowed = true
        var loseLeaseOn: String?
        FeishuMessaging.invoke = { arguments in
            calls.append(arguments)
            if arguments.contains("+chat-search") {
                if loseLeaseOn == "+chat-search" { allowed = false }
                return .success(chats)
            }
            if arguments.contains("+chat-members-list") {
                if loseLeaseOn == "+chat-members-list" { allowed = false }
                return .success(members)
            }
            if arguments.first == "contact" { return .success(["users": [], "has_more": false]) }
            assert(arguments.contains("+messages-send"), "替身不得执行其他写操作")
            return .success(["message_id": "om_group"])
        }
        func sends() -> [[String]] { calls.filter { $0.contains("+messages-send") } }
        func value(_ option: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        func payload(_ arguments: [String]) -> [[[String: Any]]] {
            assert(value("--msg-type", in: arguments) == "post", "提及必须发送飞书富文本消息")
            assert(value("--text", in: arguments) == nil, "post 不得同时带纯文本参数")
            guard let content = value("--content", in: arguments)?.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
                  let chinese = json["zh_cn"] as? [String: Any],
                  let rows = chinese["content"] as? [[[String: Any]]] else { fatalError("post JSON 不合法") }
            return rows
        }
        func supplement(_ id: String) throws {
            guard var current = TaskStore.task(id: id) else { fatalError("找不到待补充任务") }
            current.supplementCount += 1
            try TaskStore.save(current)
        }
        func perform(_ current: AgentTask, text: String, mentions: [String] = [], choice: String? = nil,
                     recipient: String = "研发群", kind: String = "group") -> FeishuMessaging.Outcome {
            FeishuMessaging.perform(recipient: recipient, text: text, choice: choice, taskId: current.id,
                                    kind: kind, mentions: mentions, authorized: { allowed })
        }
        func requireInput(_ result: FeishuMessaging.Outcome) -> String {
            guard case .needsInput(let question) = result else { fatalError("查询不明确必须等待用户补充") }
            return question
        }
        func requireFailed(_ result: FeishuMessaging.Outcome) {
            guard case .failed = result else { fatalError("未授权选择或租约失效必须失败") }
        }
        func requireSent(_ result: FeishuMessaging.Outcome) {
            guard case .sent = result else { fatalError("已唯一核实的群消息必须发送") }
        }

        let plain = try task()
        let plainText = "明天十点开会\n--as bot $(echo secret)"
        requireSent(perform(plain, text: plainText))
        assert(value("--chat-id", in: sends().last!) == "oc_project")
        assert(value("--text", in: sends().last!) == plainText, "无提及仍保留纯文本 argv 原文")
        assert(!calls.contains { $0.contains("+chat-members-list") }, "普通群消息不需要查成员")

        calls.removeAll()
        let mentionTask = try task()
        let body = "第一行😀\n<b>字面文本</b> $(echo secret)"
        requireSent(perform(mentionTask, text: body, mentions: ["张三", "李四"]))
        let memberArguments = calls.first { $0.contains("+chat-members-list") }!
        assert(value("--chat-id", in: memberArguments) == "oc_project")
        assert(value("--member-types", in: memberArguments) == "user")
        assert(value("--member-id-type", in: memberArguments) == "open_id")
        assert(memberArguments.contains("--page-all") && value("--page-limit", in: memberArguments) == "10")
        let mentionSend = sends().last!
        assert(value("--as", in: mentionSend) == "user" && mentionSend.contains("--idempotency-key"))
        let rows = payload(mentionSend)
        assert(rows.count == 2 && rows[0].count == 5)
        assert(rows[0][0]["tag"] as? String == "at" && rows[0][0]["user_id"] as? String == "ou_a")
        assert(rows[0][1]["tag"] as? String == "text" && rows[0][1]["text"] as? String == " ")
        assert(rows[0][2]["tag"] as? String == "at" && rows[0][2]["user_id"] as? String == "ou_b")
        assert(rows[0][3]["tag"] as? String == "text" && rows[0][3]["text"] as? String == " ")
        assert(rows[0][4]["tag"] as? String == "text" && rows[0][4]["text"] as? String == "第一行😀")
        assert(rows[1].count == 1 && rows[1][0]["tag"] as? String == "text" && rows[1][0]["text"] as? String == "<b>字面文本</b> $(echo secret)")
        let sentCount = sends().count
        requireSent(perform(mentionTask, text: "模型重传的正文", mentions: ["不存在"]))
        assert(sends().count == sentCount, "已发送任务不能重复发送")

        // ==================== 补充只能选择，不能重写发送请求 ====================
        chats = ["chats": [group, otherGroup], "has_more": false, "truncations": []]
        let groupChoice = try task()
        let originalText = "请张三核对原始正文"
        let question = requireInput(perform(groupChoice, text: originalText, mentions: ["张三"]))
        assert(question.contains("项目二组") && !question.contains("oc_"), "候选用用户可读信息区分")
        let beforeGroupChoice = sends().count
        requireFailed(perform(groupChoice, text: "模型改写", mentions: ["李四"], choice: "2"))
        assert(sends().count == beforeGroupChoice)
        try supplement(groupChoice.id)
        requireSent(perform(groupChoice, text: "模型改写", mentions: ["李四"], choice: "2", recipient: "另一群"))
        assert(value("--chat-id", in: sends().last!) == "oc_other")
        let selectedRows = payload(sends().last!)
        assert(selectedRows[0][0]["user_id"] as? String == "ou_a", "群选择保留原始提及对象")
        assert(selectedRows[0].last?["text"] as? String == originalText, "群选择保留原始正文")

        chats = ["chats": [group], "has_more": false, "truncations": []]
        members = ["users": [a, a2, b, b2], "has_more": false, "truncations": []]
        let sequential = try task()
        let beforeMemberChoices = sends().count
        let firstQuestion = requireInput(perform(sequential, text: body, mentions: ["张三", "李四"]))
        assert(firstQuestion.contains("张三"))
        requireFailed(perform(sequential, text: "修改", mentions: [], choice: "2"))
        try supplement(sequential.id)
        let secondQuestion = requireInput(perform(sequential, text: "修改", mentions: ["不存在"], choice: "2"))
        assert(secondQuestion.contains("李四"), "多名同名成员依次等待选择")
        assert(sends().count == beforeMemberChoices)
        requireFailed(perform(sequential, text: "修改", mentions: [], choice: "1"))
        try supplement(sequential.id)
        requireSent(perform(sequential, text: "修改", mentions: [], choice: "1"))
        let resolvedRows = payload(sends().last!)
        assert(resolvedRows[0][0]["user_id"] as? String == "ou_a2")
        assert(resolvedRows[0][2]["user_id"] as? String == "ou_b")
        assert(resolvedRows[0].last?["text"] as? String == "第一行😀", "成员选择不依赖模型重传正文")

        // ==================== 查询完整性与发送前租约 ====================
        let beforeRejected = sends().count
        for partial in [
            ["chats": [group], "has_more": true, "truncations": []] as [String: Any],
            ["chats": [group], "has_more": false, "truncations": ["page limit"]] as [String: Any],
            ["chats": [], "has_more": false, "truncations": []] as [String: Any]
        ] {
            chats = partial
            _ = requireInput(perform(try task(), text: body, mentions: ["张三"]))
        }
        chats = ["chats": [group], "has_more": false, "truncations": []]
        for partial in [
            ["users": [a], "has_more": true, "truncations": []] as [String: Any],
            ["users": [a], "has_more": false, "truncations": ["page limit"]] as [String: Any],
            ["users": [], "has_more": false, "truncations": []] as [String: Any]
        ] {
            members = partial
            _ = requireInput(perform(try task(), text: body, mentions: ["张三"]))
        }
        members = ["users": [a], "has_more": false, "truncations": []]
        _ = requireInput(perform(try task(), text: body, mentions: ["张"]))
        _ = requireInput(perform(try task(), text: body, mentions: ["ou_absent"]))
        requireFailed(perform(try task(), text: body, mentions: ["张三"], recipient: "李四", kind: "person"))
        assert(sends().count == beforeRejected, "查询截断、未找到、模糊姓名或单聊提及不得发送")
        requireFailed(perform(try task(), text: "<at user_id=\"all\">额外提及</at>", mentions: ["张三"]))
        requireFailed(perform(try task(), text: "<AT user_id=\"ou_other\">额外提及</AT>"))
        assert(sends().count == beforeRejected, "正文标记不能绕过群成员核验增加提及")
        requireSent(perform(try task(), text: body, mentions: ["ou_a"]))
        assert(payload(sends().last!)[0][0]["user_id"] as? String == "ou_a", "明确 open_id 仍须属于该群")
        for stage in ["+chat-search", "+chat-members-list"] {
            allowed = true
            loseLeaseOn = stage
            let beforeLease = sends().count
            requireFailed(perform(try task(), text: body, mentions: ["张三"]))
            assert(sends().count == beforeLease, "查询期间失去控制权不能发送")
        }
        loseLeaseOn = nil
        allowed = true
    }
}
