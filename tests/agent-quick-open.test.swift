/**
 * [INPUT]: 消费 AgentQuickOpen/AgentRunner 的完整打开意图与真实回执边界；注入模型、应用/网页/书签执行器及控制租约，TaskStore 只写临时目录。
 * [OUTPUT]: 验证准确目标零模型执行、未知目标只省最终模型往返；歧义、复合、补充、恢复与网页上下文保持普通循环，失败或失权不冒充打开成功。
 * [POS]: tests 的小精灵打开延迟回归；模型和桌面操作全部替身，准确应用解析只读取配置与安装目录，不打开应用、不联网、不发消息。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct AgentQuickOpenTests {
    // MARK: - 隔离替身

    final class Probe {
        var quickApps: [String: (display: String, path: String)] = [:]
        var modelApps: [String: (display: String, path: String)] = [:]
        var bookmarks: [ChromeBookmarks.Entry] = []
        var modelResponses: [ModelTurn] = [AgentQuickOpenTests.answer("模型继续理解此请求。")]
        var modelInputs: [[[String: Any]]] = []
        var quickLookups: [String] = []
        var openedPages: [String] = []
        var openedApps: [String] = []
        var openedBookmarks: [String] = []
        var bookmarkReads = 0
        var pageReads = 0
        var controlChecks = 0
        var allowed = true
        var pageFailure: Error?
        var appFailure: Error?
        var bookmarkPayload = "已向 Chrome 提交打开书签请求：测试书签"
        var bookmarkReadFailure: Error?

        var modelCalls: Int { modelInputs.count }
        var actions: Int { openedPages.count + openedApps.count + openedBookmarks.count }

        func install() {
            AgentRunner.resolveQuickApp = { name in
                self.quickLookups.append(name)
                return self.quickApps[AppOperator.normalized(name)]
            }
            AgentRunner.resolveApp = { self.modelApps[AppOperator.normalized($0)] }
            AgentRunner.isCodexApp = { _ in false }
            AgentRunner.readBookmarks = {
                self.bookmarkReads += 1
                if let error = self.bookmarkReadFailure { throw error }
                return self.bookmarks
            }
            AgentRunner.openPage = { url in
                self.openedPages.append(url)
                if let error = self.pageFailure { return .failure(error) }
                return .success(())
            }
            AgentRunner.openApp = { path in
                self.openedApps.append(path)
                if let error = self.appFailure { return .failure(error) }
                return .success(())
            }
            AgentRunner.openBookmark = { id, done in
                self.openedBookmarks.append(id)
                done(self.bookmarkPayload)
            }
            AgentRunner.canControl = { _ in
                self.controlChecks += 1
                return self.allowed
            }
            AgentRunner.sendModel = { _, messages, _, _, done in
                let index = self.modelInputs.count
                self.modelInputs.append(messages)
                assert(index < self.modelResponses.count, "替身模型不应收到未安排的额外请求")
                guard index < self.modelResponses.count else {
                    done(.failure(ModelFailure(httpStatus: nil, message: "额外模型请求")))
                    return
                }
                done(.success(self.modelResponses[index]))
            }
        }

        func run(_ text: String, context: PageBinding? = nil,
                 adjust: (inout AgentTask) -> Void = { _ in }) throws -> (task: AgentTask, outcome: AgentRunner.Outcome) {
            install()
            var task = try TaskStore.claim(subject: "quick-open-test", requestId: UUID().uuidString, text: text, context: context)
            task.status = .running
            adjust(&task)
            try TaskStore.save(task)
            let completed = DispatchSemaphore(value: 0)
            var outcome: AgentRunner.Outcome?
            AgentRunner.run(config: ModelConfig(baseURL: "https://invalid.test", model: "test", apiKey: "test"),
                            task: task, readPage: {
                self.pageReads += 1
                return .success(PageContent(binding: AgentQuickOpenTests.pageBinding, text: "替身网页正文", truncated: false))
            }) { result in
                outcome = result
                completed.signal()
            }
            assert(completed.wait(timeout: .now() + 5) == .success, "任务必须按回执结束")
            guard let outcome else { fatalError("任务未返回回执") }
            return (task, outcome)
        }
    }

    static var pageBinding: PageBinding {
        PageBinding(browser: "Chrome", windowId: nil, tabId: nil,
                    url: "https://example.test/read", title: "替身页面", observedAt: 1)
    }

    static func answer(_ text: String) -> ModelTurn {
        ModelTurn(content: text, rawMessage: ["role": "assistant", "content": text],
                  usage: ["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12])
    }

    static func calls(_ values: [(String, String)]) -> ModelTurn {
        let tools = values.enumerated().map { index, item in
            ["id": "call-\(index)", "type": "function", "function": ["name": item.0, "arguments": item.1]] as [String: Any]
        }
        return ModelTurn(toolCalls: tools, rawMessage: ["role": "assistant", "tool_calls": tools],
                         usage: ["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12])
    }

    static func bookmark(_ name: String, id: String = "Default:1", url: String? = "https://example.test/bookmark") -> ChromeBookmarks.Entry {
        ChromeBookmarks.Entry(id: id, name: name, folders: ["工作"], url: url, profile: "Default")
    }

    static func failure(_ detail: String) -> NSError {
        NSError(domain: "AgentQuickOpenTests", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    static func assertNoActions(_ probe: Probe, _ message: String) {
        assert(probe.actions == 0, message)
    }

    static func assertQuickSuccess(_ probe: Probe, _ result: (task: AgentTask, outcome: AgentRunner.Outcome)) {
        assert(probe.modelCalls == 0 && probe.actions == 1, "准确单动作只执行一次，不请求模型")
        assert(probe.pageReads == 0, "打开目标不预读无关页面")
        assert(result.outcome.content?.hasPrefix("已向") == true && result.outcome.error == nil, "只按系统收到请求的事实汇报")
        assert(result.outcome.rounds == 0 && !result.outcome.usage.unknown && result.outcome.usage.totalTokens == 0)
        let transcript = TaskStore.task(id: result.task.id)?.transcript ?? []
        assert(transcript.count == 2 && transcript.first?["role"] as? String == "user")
        assert(transcript.last?["content"] as? String == result.outcome.content, "直接回执也必须持久化")
    }

    // MARK: - 意图必须完整

    static func verifySyntax() {
        let accepted: [(String, String)] = [
            ("打开计算器", "计算器"), ("请打开计算器。", "计算器"),
            ("请你打开一下计算器吧", "计算器"), ("帮我打开个人工作台呀", "个人工作台"),
            ("麻烦你启动计算器一下", "计算器"), ("  启动  Chrome!  ", "Chrome")
        ]
        for (input, expected) in accepted {
            assert(AgentQuickOpen.target(in: input) == expected, "完整打开意图应被识别：\(input)")
        }
        let rejected = [
            "", "打开", "打开   ", "请不要打开计算器", "别打开计算器", "打开计算器吗",
            "打开计算器？", "打开计算器可以吗", "能否打开计算器", "打开计算器怎么用",
            "打开计算器然后搜索天气", "打开计算器并总结", "打开计算器和终端", "打开计算器或者终端",
            "打开计算器，读一下页面", "打开计算器;读取页面", "打开计算器\n读一下页面",
            "打开CodeX的PocketDesk项目", "打开WorkBuddy工作空间", "打开WorkBuddy工作区",
            "打开Codex新任务", "打开微信聊天", "打开计算器再关闭", "打开计算器不要计算",
            "打开https://user:secret@example.test/", "打开file:///tmp/test.html",
            "打开https://example.test/然后 总结网页", "打开https://example.test/。"
        ]
        for input in rejected {
            assert(AgentQuickOpen.target(in: input) == nil, "复合/否定/疑问/项目请求不得短路：\(input)")
        }
        for invalid in ["javascript:alert(1)", "file:///tmp/test.html", "https:///", "https://user:secret@example.test/", "https://example.test/a b"] {
            assert(AgentQuickOpen.url(invalid) == nil, "网址快路径必须保留地址边界")
        }
        assert(AgentQuickOpen.completesTask("{\"completesTask\":true}"))
        for invalid in ["{}", "{\"completesTask\":false}", "{\"completesTask\":1}", "{\"completesTask\":\"true\"}", "invalid"] {
            assert(!AgentQuickOpen.completesTask(invalid), "只有 JSON boolean true 能声明打开满足完整任务")
        }
    }

    // MARK: - 确定目标免模型

    static func verifyAccurateTargets() throws {
        // ASCII 标点是网址的一部分，不能当作口语后缀删除。
        let url = "https://example.test/path!;item,:value?q=a,b&next=https%3A%2F%2Fexample.test%2F&flag=!#part?"
        let webpage = Probe()
        let webpageResult = try webpage.run("帮我打开" + url)
        assertQuickSuccess(webpage, webpageResult)
        assert(webpage.openedPages == [url], "路径、查询、片段与结尾问号必须完整保留")
        assert(webpage.quickLookups.isEmpty && webpage.bookmarkReads == 0)

        let application = Probe()
        application.quickApps["计算器"] = ("计算器", "/Applications/FakeCalculator.app")
        application.bookmarks = [bookmark("计算器")]
        let applicationResult = try application.run("请打开计算器。")
        assertQuickSuccess(application, applicationResult)
        assert(application.openedApps == ["/Applications/FakeCalculator.app"] && application.bookmarkReads == 0,
               "准确应用优先于同名书签，沿用既有解析器")

        let savedBookmark = Probe()
        savedBookmark.bookmarks = [bookmark("  CAFÉ  "), bookmark("其他书签", id: "Default:2")]
        let bookmarkResult = try savedBookmark.run("打开Cafe\u{301}")
        assertQuickSuccess(savedBookmark, bookmarkResult)
        assert(savedBookmark.openedBookmarks == ["Default:1"], "唯一准确书签须按 Unicode、首尾空白与大小写归一")

        let localBookmark = Probe()
        localBookmark.bookmarks = [bookmark("本地说明", url: "file:///tmp/fake-guide.html")]
        assertQuickSuccess(localBookmark, try localBookmark.run("打开本地说明"))
    }

    // MARK: - 不确定目标继续模型

    static func verifyFallbackTargets() throws {
        let ambiguous = Probe()
        ambiguous.bookmarks = [bookmark("个人工作台"), bookmark("个人工作台", id: "Profile 1:1")]
        let ambiguousResult = try ambiguous.run("打开个人工作台")
        assert(ambiguous.modelCalls == 1 && ambiguousResult.outcome.content == "模型继续理解此请求。")
        assertNoActions(ambiguous, "准确同名书签不能猜选")

        let partial = Probe()
        partial.bookmarks = [bookmark("个人工作台管理")]
        _ = try partial.run("打开个人工作台")
        assert(partial.modelCalls == 1)
        assertNoActions(partial, "部分名称即便只有一个候选，也不能免模型猜选")

        let folder = Probe()
        folder.bookmarks = [bookmark("工作", url: nil)]
        _ = try folder.run("打开工作")
        assert(folder.modelCalls == 1)
        assertNoActions(folder, "书签文件夹不是打开地址")

        let unavailable = Probe()
        unavailable.bookmarkReadFailure = failure("书签不可读")
        _ = try unavailable.run("打开未知网站")
        assert(unavailable.modelCalls == 1)
        assertNoActions(unavailable, "读取书签失败交还模型理解")

        let unknown = Probe()
        unknown.modelResponses = [calls([("open_page", "{\"url\":\"https://example.test/unknown\",\"completesTask\":true}")])]
        let unknownResult = try unknown.run("打开未知网站")
        assert(unknown.modelCalls == 1 && unknown.openedPages == ["https://example.test/unknown"])
        assert(unknownResult.outcome.content == "已向默认浏览器提交打开网页请求。" && unknownResult.outcome.error == nil,
               "模型解析未知网站后按成功回执结束，省掉最终总结请求")
        assert(TaskStore.task(id: unknownResult.task.id)?.transcript?.last?["role"] as? String == "tool")

        let namedApp = Probe()
        namedApp.modelApps["部分应用名称"] = ("完整应用名称", "/Applications/FakePartial.app")
        namedApp.modelResponses = [calls([("open_app", "{\"app\":\"部分应用名称\",\"completesTask\":true}")])]
        let namedResult = try namedApp.run("打开部分应用名称")
        assert(namedApp.modelCalls == 1 && namedApp.openedApps == ["/Applications/FakePartial.app"])
        assert(namedResult.outcome.error == nil, "模型理解的部分应用名称仍可使用普通解析器")

        let modelBookmark = Probe()
        modelBookmark.bookmarks = [bookmark("实际网站入口")]
        modelBookmark.modelResponses = [calls([("open_bookmark", "{\"id\":\"Default:1\",\"completesTask\":true}")])]
        let modelBookmarkResult = try modelBookmark.run("打开未知网站")
        assert(modelBookmark.modelCalls == 1 && modelBookmark.openedBookmarks == ["Default:1"] && modelBookmarkResult.outcome.error == nil,
               "模型选择准确书签后可按已确认打开回执收尾")

        let modelTarget = Probe()
        modelTarget.modelApps["完整应用名称"] = ("完整应用名称", "/Applications/FakeTarget.app")
        modelTarget.modelResponses = [calls([("open_target", "{\"app\":\"完整应用名称\",\"completesTask\":true}")])]
        let modelTargetResult = try modelTarget.run("打开未知网站")
        assert(modelTarget.modelCalls == 1 && modelTarget.openedApps == ["/Applications/FakeTarget.app"] && modelTargetResult.outcome.error == nil,
               "通用目标打开与其他打开工具共用完成声明契约")

        for marker in ["", ",\"completesTask\":false", ",\"completesTask\":\"true\""] {
            let incomplete = Probe()
            incomplete.modelResponses = [calls([("open_page", "{\"url\":\"https://example.test/unknown\"" + marker + "}")]),
                                         answer("模型仍须确认任务的完整目标。")]
            let incompleteResult = try incomplete.run("打开未知网站")
            assert(incomplete.modelCalls == 2 && incomplete.openedPages.count == 1,
                   "缺失、false 或字符串 true 都不能授权提前收尾")
            assert(incompleteResult.outcome.content == "模型仍须确认任务的完整目标。")
        }
    }

    // MARK: - 失败与控制租约如实收尾

    static func verifyFailures() throws {
        let webpage = Probe()
        webpage.pageFailure = failure("系统拒绝网页请求")
        let webpageResult = try webpage.run("打开https://example.test/failure")
        assert(webpage.modelCalls == 0 && webpage.openedPages.count == 1)
        assert(webpageResult.outcome.content == nil && webpageResult.outcome.error?.contains("系统拒绝网页请求") == true)

        let application = Probe()
        application.quickApps["计算器"] = ("计算器", "/Applications/FakeCalculator.app")
        application.appFailure = failure("系统拒绝应用请求")
        let appResult = try application.run("打开计算器")
        assert(application.modelCalls == 0 && application.openedApps.count == 1)
        assert(appResult.outcome.content == nil && appResult.outcome.error?.contains("系统拒绝应用请求") == true)

        for payload in ["未打开：书签已删除。", "结果待核对：没有打开确认。"] {
            let failedBookmark = Probe()
            failedBookmark.bookmarks = [bookmark("个人工作台")]
            failedBookmark.bookmarkPayload = payload
            let result = try failedBookmark.run("打开个人工作台")
            assert(failedBookmark.modelCalls == 0 && failedBookmark.openedBookmarks.count == 1)
            assert(result.outcome.content == nil && result.outcome.error == payload)
        }

        let modelFailure = Probe()
        modelFailure.pageFailure = failure("模型找到地址，但系统拒绝打开")
        modelFailure.modelResponses = [calls([("open_page", "{\"url\":\"https://example.test/unknown\",\"completesTask\":true}")]), answer("已打开。")]
        let failedResult = try modelFailure.run("打开未知网站")
        assert(modelFailure.modelCalls == 2 && modelFailure.openedPages.count == 1, "失败不得直接成功收尾或自动重复打开")
        assert(failedResult.outcome.content == nil && failedResult.outcome.error?.contains("系统拒绝打开") == true,
               "模型声称成功不能覆盖执行器失败")

        let expired = Probe()
        expired.allowed = false
        let expiredResult = try expired.run("打开https://example.test/expired")
        assert(expired.modelCalls == 0 && expired.controlChecks == 1)
        assertNoActions(expired, "控制租约失效不得打开")
        assert(expiredResult.outcome.content == nil && expiredResult.outcome.error?.contains("控制权已失效") == true)

        let ended = Probe()
        let endedResult = try ended.run("打开https://example.test/ended") { $0.status = .succeeded }
        assert(ended.modelCalls == 0 && endedResult.outcome.error != nil)
        assertNoActions(ended, "任务结束后不得打开")
    }

    // MARK: - 保留复合动作、补充和上下文

    static func verifyContinuation() throws {
        let composite = Probe()
        composite.quickApps["计算器"] = ("计算器", "/Applications/FakeCalculator.app")
        composite.modelResponses = [calls([("open_page", "{\"url\":\"https://example.test/read\",\"completesTask\":true}")]),
                                    calls([("read_page", "{}")]), answer("根据替身网页正文完成总结。")]
        let compositeResult = try composite.run("打开计算器，然后读一下网页并总结")
        assert(composite.modelCalls == 3 && composite.pageReads == 1 && composite.openedPages.count == 1)
        assert(compositeResult.outcome.content == "根据替身网页正文完成总结。", "复合任务不能在首个打开成功后结束")
        assert(composite.modelInputs.last?.contains { ($0["content"] as? String)?.contains("替身网页正文") == true } == true)

        let impliedRead = Probe()
        impliedRead.modelResponses = [calls([("open_page", "{\"url\":\"https://example.test/weather\"}")]),
                                     calls([("read_page", "{}")]), answer("根据读取结果回答天气。")]
        let impliedResult = try impliedRead.run("打开百度查天气")
        assert(impliedRead.modelCalls == 3 && impliedRead.pageReads == 1 && impliedRead.openedPages.count == 1,
               "单句中的后续目标不能仅按打开语法提前结束")
        assert(impliedResult.outcome.content == "根据读取结果回答天气。")

        let sameBatch = Probe()
        sameBatch.modelResponses = [calls([("open_page", "{\"url\":\"https://example.test/read\",\"completesTask\":true}"), ("read_page", "{}")]),
                                   answer("同批打开与读取已完成。")]
        let sameBatchResult = try sameBatch.run("打开未知网站")
        assert(sameBatch.modelCalls == 2 && sameBatch.pageReads == 1 && sameBatch.openedPages.count == 1)
        assert(sameBatchResult.outcome.content == "同批打开与读取已完成。", "多个工具调用不能省略同批后续读页")

        for boundary in ["attempt", "supplementCount", "transcript"] {
            let resumed = Probe()
            resumed.quickApps["计算器"] = ("计算器", "/Applications/FakeCalculator.app")
            resumed.modelResponses = [calls([("open_page", "{\"url\":\"https://example.test/resumed\",\"completesTask\":true}")]), answer("已处理补充或恢复的上下文。")]
            let resumedResult = try resumed.run("打开计算器", adjust: { task in
                if boundary == "attempt" { task.attempt = 2 }
                if boundary == "supplementCount" { task.supplementCount = 1 }
                if boundary == "transcript" {
                    task.transcript = [["role": "user", "content": "上轮要求保留的信息"], ["role": "assistant", "content": "上轮待继续"]]
                }
            })
            assert(resumed.modelCalls == 2 && resumed.openedApps.isEmpty && resumed.openedPages.count == 1,
                   "\(boundary) 边界既不能走零模型快路径，也不能在模型打开后提前截断")
            assert(resumedResult.outcome.content == "已处理补充或恢复的上下文。")
            if boundary == "transcript" {
                assert(resumed.modelInputs.first?.contains { $0["content"] as? String == "上轮要求保留的信息" } == true,
                       "恢复路径须保留原 transcript")
            }
        }

        let contextual = Probe()
        contextual.quickApps["计算器"] = ("计算器", "/Applications/FakeCalculator.app")
        contextual.modelResponses = [calls([("open_page", "{\"url\":\"https://example.test/contextual\",\"completesTask\":true}")]), answer("结合提交时网页资料完成处理。")]
        let contextualResult = try contextual.run("打开计算器", context: pageBinding)
        assert(contextual.modelCalls == 2 && contextual.pageReads == 1 && contextual.openedApps.isEmpty)
        assert(contextualResult.outcome.content == "结合提交时网页资料完成处理。", "绑定页面的请求必须保持完整模型上下文")
    }

    // MARK: - 准确应用解析不接受部分名称

    static func verifyExactApplicationResolution(in directory: URL) throws {
        let app = directory.appendingPathComponent("UniqueQuickOpenFixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let name = "UniqueQuickOpenFixture-" + UUID().uuidString
        let configured = TargetConfig(id: "quick-open-fixture", name: name, bundleID: nil, path: app.path)
        assert(AppOperator.resolve(name, configured: [configured], exactOnly: true)?.path == app.path,
               "准确配置名保留既有解析能力")
        assert(AppOperator.resolve(String(name.dropLast(3)), configured: [configured], exactOnly: true) == nil,
               "部分配置名不能成为准确打开目标")
        assert(AppOperator.resolve("UniqueQuickOpenFixture", configured: [configured], exactOnly: true) == nil,
               "仅部分应用路径名不能命中配置目标")
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pocketdesk-quick-open-" + UUID().uuidString)
        TaskStore.resetCache(directory: directory.appendingPathComponent("tasks", isDirectory: true))
        let savedQuickResolver = AgentRunner.resolveQuickApp
        let savedResolver = AgentRunner.resolveApp
        let savedReadBookmarks = AgentRunner.readBookmarks
        let savedOpenPage = AgentRunner.openPage
        let savedOpenApp = AgentRunner.openApp
        let savedOpenBookmark = AgentRunner.openBookmark
        let savedModel = AgentRunner.sendModel
        let savedControl = AgentRunner.canControl
        let savedCodexIdentity = AgentRunner.isCodexApp
        defer {
            AgentRunner.resolveQuickApp = savedQuickResolver
            AgentRunner.resolveApp = savedResolver
            AgentRunner.readBookmarks = savedReadBookmarks
            AgentRunner.openPage = savedOpenPage
            AgentRunner.openApp = savedOpenApp
            AgentRunner.openBookmark = savedOpenBookmark
            AgentRunner.sendModel = savedModel
            AgentRunner.canControl = savedControl
            AgentRunner.isCodexApp = savedCodexIdentity
            try? FileManager.default.removeItem(at: directory)
        }
        verifySyntax()
        try verifyAccurateTargets()
        try verifyFallbackTargets()
        try verifyFailures()
        try verifyContinuation()
        try verifyExactApplicationResolution(in: directory)
        print("小精灵快速打开隔离回归通过。")
    }
}
