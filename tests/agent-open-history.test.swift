/**
 * [INPUT]: 消费 AgentQuickOpen 的历史网址证据解析与 AgentRunner 打开路径；任务记录和模型/网页/应用/书签/租约全部使用隔离替身。
 * [OUTPUT]: 验证真实 C42 目标的准确名称复用、回执配对、主体与时效隔离、冲突和搜索地址拒绝、书签优先及零模型打开；--replay 只读真实任务并报告公开地址命中与解析耗时。
 * [POS]: tests 的小精灵历史打开回归；默认只写临时 TaskStore，不触发真实桌面或远程模型，回放模式不写生产任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct AgentOpenHistoryTests {
    static let text = "打开飞书开放平台创建应用页面"
    static let address = "https://open.feishu.cn/app"
    static let receipt = "已向默认浏览器提交打开网页请求。"
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func record(subject: String = "owner", url: String = address, marker: Any? = true,
                       now: TimeInterval) -> AgentTask {
        var arguments: [String: Any] = ["url": url]
        if let marker { arguments["completesTask"] = marker }
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!
        let call: [String: Any] = ["id": "c42", "type": "function", "function": ["name": "open_page", "arguments": encoded]]
        var task = AgentTask(subject: subject, requestId: UUID().uuidString, status: .succeeded,
                             createdAt: now - 60, updatedAt: now - 30, text: text, result: receipt)
        task.transcript = [["role": "system", "content": "替身执行约束"], ["role": "user", "content": text],
                           ["role": "assistant", "tool_calls": [call]],
                           ["role": "tool", "tool_call_id": "c42", "content": receipt]]
        return task
    }

    static func request(subject: String = "owner", text: String = AgentOpenHistoryTests.text) -> AgentTask {
        AgentTask(subject: subject, requestId: UUID().uuidString, status: .running, text: text)
    }

    static var context: PageBinding {
        PageBinding(browser: "Chrome", windowId: nil, tabId: nil,
                    url: "https://example.test/read", title: "替身网页", observedAt: 1)
    }

    // MARK: - 纯证据解析

    static func verifyHistory(now: TimeInterval) {
        let source = record(now: now)
        let current = request()
        func match(_ records: [AgentTask], task: AgentTask? = nil) -> String? {
            AgentQuickOpen.historicalURL(for: task ?? current, history: records, now: now)
        }
        check(match([source]) == address, "C42 的真实目标、显式完成标记与配对回执应命中")
        check(match([source, source]) == address, "同一地址多次成功不制造歧义")
        check(match([source, record(url: "https://example.test/other", now: now)]) == nil, "同名不同地址不能选最新")
        check(match([source, record(subject: "other-owner", url: "https://example.test/other", now: now)]) == address, "其它主体不能制造当前主体的歧义")
        check(match([record(subject: "other-owner", now: now)]) == nil, "不能使用其它主体的路由")

        for prefix in ["好，", "好的，", "嗯，"] {
            check(match([source], task: request(text: prefix + text)) == address, "有限确认前缀应识别：" + prefix)
        }
        check(AgentQuickOpen.target(in: "好，打开那个飞书开放平台创建应用页面") == "那个飞书开放平台创建应用页面", "目标里的那个必须保留")
        check(match([source], task: request(text: "好，打开那个飞书开放平台创建应用页面")) == nil, "不能模糊合并那个名称")
        check(AgentQuickOpen.target(in: "好的打开飞书开放平台创建应用页面") == nil, "确认前缀必须带明确分隔符")
        check(match([source], task: request(text: text + "，然后帮我创建应用")) == nil, "复合目标不能复用单开记录")

        for marker: Any? in [nil, false, "true", 1] {
            check(match([record(marker: marker, now: now)]) == nil, "缺失或非布尔真标记不能学习")
        }
        var unmarked = record(marker: nil, now: now)
        unmarked.text = "好，打开那个飞书开放平台创建应用页面"
        var unmarkedTranscript = unmarked.transcript!
        unmarkedTranscript[1]["content"] = unmarked.text
        unmarked.transcript = unmarkedTranscript
        check(match([unmarked], task: request(text: unmarked.text)) == nil, "同地址的上一条口述缺完成标记也不能学习")

        for status in [TaskStatus.failed, .running, .abandoned, .submitted] {
            var invalid = source; invalid.status = status
            check(match([invalid]) == nil, "非成功终态不能学习：" + status.rawValue)
        }
        var failed = source; failed.error = "模型失败"
        check(match([failed]) == nil, "残留失败证据不能学习")
        var expired = source; expired.updatedAt = now - Double(TaskStore.defaultRetentionDays + 1) * 86400
        check(match([expired]) == nil, "手动未清理的过期记录也必须拒绝")
        var future = source; future.updatedAt = now + 30
        check(match([future]) == nil, "未来时间戳不能提供历史证据")

        for url in ["https://www.bing.com/search?q=feishu", address + "#token", address + "?",
                    "https://user:secret@example.test/app", "file:///tmp/page.html"] {
            check(match([record(url: url, now: now)]) == nil, "搜索、查询、片段和非稳定地址不能学习")
        }
        var wrongID = source
        var wrongTranscript = wrongID.transcript!
        wrongTranscript[3]["tool_call_id"] = "another-call"
        wrongID.transcript = wrongTranscript
        check(match([wrongID]) == nil, "工具回执必须对应真实调用 ID")
        var rejected = source
        var rejectedTranscript = rejected.transcript!
        rejectedTranscript[3]["content"] = "未打开：系统拒绝"
        rejected.transcript = rejectedTranscript
        check(match([rejected]) == nil, "成功状态不能覆盖真实工具失败")
        var prose = source
        prose.transcript = [["role": "user", "content": text], ["role": "assistant", "content": "已打开官网"]]
        check(match([prose]) == nil, "模型文字不是执行回执")

        var resumed = source; resumed.attempt = 2
        check(match([resumed]) == nil, "历史补充轮次不能成为独立打开证据")
        resumed = source; resumed.supplementCount = 1
        check(match([resumed]) == nil, "历史补充次数不能被忽略")
        resumed = source; resumed.context = context
        check(match([resumed]) == nil, "带网页上下文的任务不能学习为简单名称")
        var extraUser = source
        var extended = extraUser.transcript!; extended.append(["role": "user", "content": "继续处理其它目标"])
        extraUser.transcript = extended
        check(match([extraUser]) == nil, "隐含续接历史不能学习")
        for option in 0...3 {
            var continuation = current
            if option == 0 { continuation.attempt = 2 }
            if option == 1 { continuation.supplementCount = 1 }
            if option == 2 { continuation.context = context }
            if option == 3 { continuation.transcript = [["role": "user", "content": text]] }
            check(match([source], task: continuation) == nil, "本次续接或页面上下文不能本地重开")
        }

        var discovered = source
        var discoveredTranscript = discovered.transcript!
        let search: [String: Any] = ["id": "search", "type": "function", "function": ["name": "search_web", "arguments": "{\"query\":\"飞书开放平台\"}"]]
        discoveredTranscript.insert(["role": "assistant", "tool_calls": [search]], at: 2)
        discoveredTranscript.insert(["role": "tool", "tool_call_id": "search", "content": "替身网站候选"], at: 3)
        discovered.transcript = discoveredTranscript
        check(match([discovered]) == address, "只读搜索后唯一真实打开仍可学习稳定地址")
        var multiple = source
        var multipleTranscript = multiple.transcript!
        var second = (multipleTranscript[2]["tool_calls"] as! [[String: Any]])[0]; second["id"] = "second"
        multipleTranscript.append(["role": "assistant", "tool_calls": [second]])
        multipleTranscript.append(["role": "tool", "tool_call_id": "second", "content": receipt])
        multiple.transcript = multipleTranscript
        check(match([multiple]) == nil, "同任务多次打开不能学成单一动作")
    }

    // MARK: - 执行器隔离回归

    final class Probe {
        var bookmarks: [ChromeBookmarks.Entry] = []
        var quickApp: (display: String, path: String)?
        var bookmarkReadFails = false
        var allowed = true
        var pageFails = false
        var pages: [String] = []
        var apps: [String] = []
        var openedBookmarks: [String] = []
        var modelCalls = 0

        func run(subject: String, text: String = AgentOpenHistoryTests.text,
                 adjust: (inout AgentTask) -> Void = { _ in }) throws -> AgentRunner.Outcome {
            AgentRunner.resolveQuickApp = { _ in self.quickApp }
            AgentRunner.resolveApp = { _ in nil }
            AgentRunner.isCodexApp = { _ in false }
            AgentRunner.readBookmarks = {
                if self.bookmarkReadFails { throw NSError(domain: "history-test", code: 1) }
                return self.bookmarks
            }
            AgentRunner.openPage = { url in
                self.pages.append(url)
                return self.pageFails ? .failure(NSError(domain: "history-test", code: 2)) : .success(())
            }
            AgentRunner.openApp = { path in self.apps.append(path); return .success(()) }
            AgentRunner.openBookmark = { id, done in self.openedBookmarks.append(id); done("已向 Chrome 提交打开书签请求：当前书签") }
            AgentRunner.canControl = { _ in self.allowed }
            AgentRunner.sendModel = { _, _, _, _, done in
                self.modelCalls += 1
                done(.success(ModelTurn(content: "模型继续理解目标。", rawMessage: ["role": "assistant", "content": "模型继续理解目标。"])))
            }
            var task = try TaskStore.claim(subject: subject, requestId: UUID().uuidString, text: text, context: nil)
            task.status = .running; adjust(&task); try TaskStore.save(task)
            let finished = DispatchSemaphore(value: 0)
            var outcome: AgentRunner.Outcome?
            AgentRunner.run(config: ModelConfig(baseURL: "https://invalid.test", model: "test", apiKey: "test"), task: task,
                            readPage: { .failure(.emptyPage) }) { result in outcome = result; finished.signal() }
            precondition(finished.wait(timeout: .now() + 5) == .success)
            return outcome!
        }
    }

    static func persist(_ source: AgentTask) throws {
        let claimed = try TaskStore.claim(subject: source.subject, requestId: source.requestId, text: source.text, context: source.context)
        var saved = source; saved.id = claimed.id; try TaskStore.save(saved)
    }

    static func verifyExecution(now: TimeInterval) throws {
        func prepare(_ label: String, url: String = address) throws -> String {
            let subject = "history-" + label
            try persist(record(subject: subject, url: url, now: now))
            return subject
        }
        let hit = Probe()
        let hitResult = try hit.run(subject: prepare("hit"), text: "好的，" + text)
        check(hit.pages == [address] && hit.modelCalls == 0, "真实 C42 同名重开必须零模型且只提交一次")
        check(hitResult.error == nil && hitResult.usage.totalTokens == 0 && !hitResult.usage.unknown, "本地回执和零模型用量必须真实")

        let missingChrome = Probe(); missingChrome.bookmarkReadFails = true
        _ = try missingChrome.run(subject: prepare("missing-chrome"))
        check(missingChrome.pages == [address] && missingChrome.modelCalls == 0, "无 Chrome 或书签读取失败仍可复用合格历史")

        let name = AgentQuickOpen.target(in: text)!
        let bookmark = ChromeBookmarks.Entry(id: "Default:current", name: name, folders: [], url: "https://example.test/current", profile: "Default")
        let currentBookmark = Probe(); currentBookmark.bookmarks = [bookmark]
        _ = try currentBookmark.run(subject: prepare("bookmark"))
        check(currentBookmark.openedBookmarks == [bookmark.id] && currentBookmark.pages.isEmpty && currentBookmark.modelCalls == 0, "当前准确书签优先于历史")
        let ambiguous = Probe(); ambiguous.bookmarks = [bookmark, bookmark]
        _ = try ambiguous.run(subject: prepare("ambiguous"))
        check(ambiguous.modelCalls == 1 && ambiguous.pages.isEmpty && ambiguous.openedBookmarks.isEmpty, "当前同名书签歧义不能被历史覆盖")

        let application = Probe(); application.quickApp = (name, "/Applications/Fixture.app")
        _ = try application.run(subject: prepare("app"))
        check(application.apps == ["/Applications/Fixture.app"] && application.pages.isEmpty && application.modelCalls == 0, "当前准确应用优先于历史")

        let conflictSubject = try prepare("conflict")
        try persist(record(subject: conflictSubject, url: "https://example.test/other", now: now))
        let conflict = Probe(); _ = try conflict.run(subject: conflictSubject)
        check(conflict.modelCalls == 1 && conflict.pages.isEmpty, "历史网址冲突交回模型而不猜地址")
        let lost = Probe(); lost.allowed = false
        let lostResult = try lost.run(subject: prepare("lost"))
        check(lost.pages.isEmpty && lost.modelCalls == 0 && lostResult.recovery?.kind == .prerequisite, "历史命中仍须执行时租约，失权零动作")
        let failure = Probe(); failure.pageFails = true
        let failureResult = try failure.run(subject: prepare("failure"))
        check(failure.pages == [address] && failure.modelCalls == 0 && failureResult.error != nil, "历史打开失败按真实回执结束，不回模型重开")
        let resumed = Probe()
        _ = try resumed.run(subject: prepare("resumed")) { task in
            task.attempt = 2; task.supplementCount = 1
            task.transcript = [["role": "user", "content": text], ["role": "assistant", "content": "前一轮回执"], ["role": "user", "content": "继续"]]
        }
        check(resumed.modelCalls == 1 && resumed.pages.isEmpty, "续接不能被同名历史改成独立重开")
    }

    // MARK: - 只读真实记录回放

    static func replay() {
        let history = TaskStore.all()
        let name = ChromeBookmarks.normalized(AgentQuickOpen.target(in: text)!)
        let candidates = history.filter { AgentQuickOpen.target(for: $0).map(ChromeBookmarks.normalized) == name }
        let subjects = Set(candidates.map(\.subject))
        let now = Date().timeIntervalSince1970
        let started = ProcessInfo.processInfo.systemUptime
        let matches = subjects.compactMap { AgentQuickOpen.historicalURL(for: request(subject: $0), history: history, now: now) }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let addresses = Set(matches)
        let publicAddress = addresses == Set([address]) ? address : "未找到唯一的 C42 公开地址"
        print("历史候选 \(candidates.count) 条，命中主体 \(matches.count) 个，解析 \(String(format: "%.3f", milliseconds)) ms，地址：\(publicAddress)")
    }

    static func main() throws {
        if CommandLine.arguments.contains("--replay") { replay(); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-open-history-" + UUID().uuidString)
        TaskStore.resetCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedModel = AgentRunner.sendModel, savedPage = AgentRunner.openPage, savedApp = AgentRunner.openApp
        let savedBookmark = AgentRunner.openBookmark, savedRead = AgentRunner.readBookmarks
        let savedQuick = AgentRunner.resolveQuickApp, savedResolve = AgentRunner.resolveApp
        let savedIdentity = AgentRunner.isCodexApp, savedControl = AgentRunner.canControl
        defer {
            AgentRunner.sendModel = savedModel; AgentRunner.openPage = savedPage; AgentRunner.openApp = savedApp
            AgentRunner.openBookmark = savedBookmark; AgentRunner.readBookmarks = savedRead
            AgentRunner.resolveQuickApp = savedQuick; AgentRunner.resolveApp = savedResolve
            AgentRunner.isCodexApp = savedIdentity; AgentRunner.canControl = savedControl
        }
        let now = Date().timeIntervalSince1970
        verifyHistory(now: now)
        try verifyExecution(now: now)
        print("历史打开回归通过：\(checks) 项；所有桌面和模型操作均为替身。")
    }
}
