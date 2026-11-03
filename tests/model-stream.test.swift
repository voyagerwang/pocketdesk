/**
 * [INPUT]: 真实 ModelClient 流式/整段解析与替身 URLProtocol、SpokenSummary 口播拆分、TaskUsage 缓存计量、AgentRunner 的提示词布局（模型替身 + 临时 TaskStore）。
 * [OUTPUT]: 验证 SSE 增量拼出 content/tool_calls/用量、口播行写完只通知一次、服务端拒收流式参数时退回整段一次、请求体键排序逐字节稳定；
 *           口播行从屏幕正文拆出单独交给语音；系统提示词逐字不变、会变的事实放在独立用户消息；缓存命中 token 解析与累计。
 * [POS]: tests 的模型适配层与前缀缓存回归；不联网、不调用真实模型、不执行任何电脑操作。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// 替身服务端：按请求体里有没有 stream 决定回 SSE 还是整段 JSON，或者直接 400。
final class MockModelServer: URLProtocol {
    static var rejectStream = false
    static var requests: [[String: Any]] = []
    static let lock = NSLock()
    static let sse: [String] = [
        #"data: {"choices":[{"delta":{"role":"assistant","content":"口播：明天两个"}}]}"#,
        #"data: {"choices":[{"delta":{"content":"日程，下午的撞了\n- 十点评审\n"}}]}"#,
        #"data: {"choices":[{"delta":{"content":"- 两点周会"}}]}"#,
        #"data: {"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":30,"total_tokens":1230,"prompt_cache_hit_tokens":1024,"prompt_cache_miss_tokens":176}}"#,
        "data: [DONE]",
    ]
    static let toolSSE: [String] = [
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"search_web","arguments":"{\"qu"}}]}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ery\":\"天气\"}"}}]}}]}"#,
        "data: [DONE]",
    ]
    static var nextTool = false
    /// 第一次请求直接死在 TLS 握手：模拟系统代理节点不通。
    static var failOnceTLS = false
    /// 真正发起过多少次请求（含死在 TLS 上的那次，它没有请求体可记）。
    static var attempts = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.attempts += 1; Self.lock.unlock()
        if Self.failOnceTLS {
            Self.failOnceTLS = false
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain,
                                                               code: NSURLErrorSecureConnectionFailed))
            return
        }
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        } else if let data = request.httpBody { body = data }
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        Self.lock.lock(); Self.requests.append(json); Self.lock.unlock()
        let streaming = json["stream"] as? Bool == true
        let url = request.url!
        if streaming && Self.rejectStream {
            respond(url, 400, "application/json", [Data(#"{"error":{"message":"unknown field stream_options"}}"#.utf8)]); return
        }
        if streaming {
            let lines = Self.nextTool ? Self.toolSSE : Self.sse
            // 故意把一行拆在两块之间，验证半行留到下一块再解析。
            let joined = lines.map { $0 + "\n\n" }.joined()
            let bytes = Data(joined.utf8)
            let cut = bytes.count / 3
            respond(url, 200, "text/event-stream", [bytes.prefix(cut), bytes.dropFirst(cut)])
        } else {
            let whole = #"{"choices":[{"message":{"role":"assistant","content":"整段回答"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12,"prompt_tokens_details":{"cached_tokens":8}}}"#
            respond(url, 200, "application/json", [Data(whole.utf8)])
        }
    }
    private func respond(_ url: URL, _ status: Int, _ type: String, _ chunks: [Data]) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: Data(chunk)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ModelStreamTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError(message) }
    }

    static func send(_ observer: ((String) -> Void)? = nil) -> Result<ModelTurn, ModelFailure> {
        let config = ModelConfig(baseURL: "https://model.example.test/v1", model: "example-chat", apiKey: "test-key")
        var result: Result<ModelTurn, ModelFailure>?
        let done = DispatchSemaphore(value: 0)
        ModelClient.setPartialObserver(observer)
        ModelClient.send(config: config, messages: [["role": "user", "content": "你好"]], tools: nil, timeoutSeconds: 5) {
            result = $0; done.signal()
        }
        ModelClient.setPartialObserver(nil)
        precondition(done.wait(timeout: .now() + 10) == .success, "请求没有按时结束")
        return result!
    }

    static func main() throws {
        // ---------- 口播行拆分 ----------
        let split = SpokenSummary.split("口播：明天两个日程，下午的撞了\n- 十点评审\n- 两点周会")
        check(split.spoken == "明天两个日程，下午的撞了" && split.display == "- 十点评审\n- 两点周会", "口播行拆出，屏幕只留正文")
        check(SpokenSummary.split("明天两个日程。\n口播: 两个日程").spoken == "两个日程", "写在最后一行的口播也认")
        check(SpokenSummary.split("就一句话。").spoken == nil && SpokenSummary.split("就一句话。").display == "就一句话。", "没有口播行原样返回")
        check(SpokenSummary.split("口播：只有这一句").display == "只有这一句", "只写了口播行时屏幕也显示它")
        let long = SpokenSummary.split("口播：" + String(repeating: "很", count: 100) + "\n正文")
        check(long.spoken == nil && long.display == "正文", "过长的口播不当总括念，但也不留在屏幕上")
        check(SpokenSummary.completedLine("口播：三件") == nil, "口播行没写完不提前念")
        check(SpokenSummary.completedLine("  口播：三件事都办好了\n正") == "三件事都办好了", "口播行写完就能念")
        check(SpokenSummary.completedLine("先说正文\n口播：x\n") == nil, "开头不是口播就不旁听")
        var fired: [String] = []
        let watch = SpokenSummary.watcher { fired.append($0) }
        for piece in ["口播", "口播：好", "口播：好了\n", "口播：好了\n正文"] { watch(piece) }
        check(fired == ["好了"], "流式观察者只通知一次")

        // ---------- 缓存命中计量 ----------
        let deepseek = TaskUsage.parse(["prompt_tokens": 100, "completion_tokens": 5, "prompt_cache_hit_tokens": 64])
        check(deepseek.cachedPromptTokens == 64, "DeepSeek 前缀缓存命中解析")
        let openai = TaskUsage.parse(["prompt_tokens": 100, "completion_tokens": 5, "prompt_tokens_details": ["cached_tokens": 32]])
        check(openai.cachedPromptTokens == 32, "OpenAI cached_tokens 解析")
        check(TaskUsage.parse(["prompt_tokens": 1]).cachedPromptTokens == nil, "没报缓存就是 nil，不编 0")
        check(deepseek.json()["cachedPromptTokens"] as? Int == 64, "缓存命中进入任务 JSON")

        // ---------- 请求体逐字节稳定 ----------
        let tools: [[String: Any]] = [["type": "function", "function": ["name": "b", "description": "x", "parameters": ["type": "object", "properties": ["z": ["type": "string"], "a": ["type": "string"]]]]]]
        let messages: [[String: Any]] = [["role": "system", "content": "静态"], ["role": "user", "content": "你好"]]
        let first = ModelClient.payload(model: "m", messages: messages, tools: tools, stream: true)
        let second = ModelClient.payload(model: "m", messages: messages, tools: tools, stream: true)
        check(first != nil && first == second, "同样的提示词与工具每次序列化逐字节相同")
        let text = String(decoding: first!, as: UTF8.self)
        check(text.contains("\"include_usage\":true") && text.contains("\"stream\":true"), "流式请求要求末块带用量")
        check(text.range(of: "\"a\"")!.lowerBound < text.range(of: "\"z\"")!.lowerBound, "键按字母序排列")

        // ---------- SSE 增量拼装 ----------
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockModelServer.self]
        ModelClient.sessionConfiguration = { configuration }
        let partialLock = NSLock()
        var partials: [String] = []
        var spoken: [String] = []
        let watcher = SpokenSummary.watcher { line in partialLock.lock(); spoken.append(line); partialLock.unlock() }
        let streamed = send { piece in partialLock.lock(); partials.append(piece); partialLock.unlock(); watcher(piece) }
        guard case .success(let turn) = streamed else { fatalError("流式请求失败：\(streamed)") }
        check(turn.content == "口播：明天两个日程，下午的撞了\n- 十点评审\n- 两点周会", "增量文字按顺序拼回完整回答")
        check(partials.count >= 2 && partials.last == turn.content, "每个增量都把累计文字交给观察者")
        check(spoken == ["明天两个日程，下午的撞了"], "口播行在流式中途写完即通知，只通知一次")
        let usage = TaskUsage.parse(turn.usage)
        check(usage.promptTokens == 1200 && usage.cachedPromptTokens == 1024, "末块用量与缓存命中保留")
        check(turn.usage?["provider"] as? String == "model.example.test", "用量带上来源")
        check((turn.rawMessage?["content"] as? String) == turn.content && turn.rawMessage?["reasoning_content"] == nil, "回放消息只含 content")
        MockModelServer.lock.lock(); let sent = MockModelServer.requests.last ?? [:]; MockModelServer.lock.unlock()
        check(sent["stream"] as? Bool == true, "默认走流式")

        MockModelServer.nextTool = true
        guard case .success(let toolTurn) = send() else { fatalError("工具流式失败") }
        MockModelServer.nextTool = false
        let call = toolTurn.toolCalls?.first
        let function = call?["function"] as? [String: Any]
        check(toolTurn.content == nil && call?["id"] as? String == "call-1" && function?["name"] as? String == "search_web"
              && function?["arguments"] as? String == "{\"query\":\"天气\"}", "分块到达的工具调用参数完整拼接")
        check((toolTurn.rawMessage?["tool_calls"] as? [[String: Any]])?.count == 1, "工具调用进入回放消息")

        // ---------- 服务端不认流式参数：同一请求退回整段一次 ----------
        MockModelServer.rejectStream = true
        MockModelServer.lock.lock(); let before = MockModelServer.requests.count; MockModelServer.lock.unlock()
        guard case .success(let whole) = send() else { fatalError("退回整段失败") }
        MockModelServer.rejectStream = false
        MockModelServer.lock.lock(); let after = Array(MockModelServer.requests.dropFirst(before)); MockModelServer.lock.unlock()
        check(whole.content == "整段回答" && after.count == 2 && after[1]["stream"] == nil, "400 后不带流式参数重发一次")
        check(TaskUsage.parse(whole.usage).cachedPromptTokens == 8, "整段回包的缓存命中也解析")

        // ---------- 系统代理节点挂了：TLS 被掐一次，绕开代理直连照常回答 ----------
        let directConfiguration = URLSessionConfiguration.ephemeral
        directConfiguration.protocolClasses = [MockModelServer.self]
        var directUsed = false
        ModelClient.directSessionConfiguration = { directUsed = true; return directConfiguration }
        MockModelServer.failOnceTLS = true
        MockModelServer.lock.lock(); let beforeTLS = MockModelServer.attempts; MockModelServer.lock.unlock()
        guard case .success(let retried) = send() else { fatalError("代理掐断 TLS 后没有直连重试") }
        check(directUsed, "失败后换用绕开系统代理的会话")
        check(retried.content?.contains("明天两个日程") == true, "直连重试拿回正常回答")
        MockModelServer.lock.lock(); let tlsCount = MockModelServer.attempts - beforeTLS; MockModelServer.lock.unlock()
        check(tlsCount == 2, "同一次请求先走系统代理，失败后直连重发一次")
        // 记住直连能通之后，下一块先直连，不再为挂掉的代理白等一次握手。
        MockModelServer.lock.lock(); let beforeRemembered = MockModelServer.attempts; MockModelServer.lock.unlock()
        guard case .success = send() else { fatalError("记住直连后请求失败") }
        MockModelServer.lock.lock(); let rememberedCount = MockModelServer.attempts - beforeRemembered; MockModelServer.lock.unlock()
        check(rememberedCount == 1, "直连验证过就记住，后面不再先撞代理")
        ModelClient.directSessionConfiguration = {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            return config
        }

        // ---------- 提示词布局：静态系统提示词 + 独立事实消息 + 用户原话；口播拆出 ----------
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pd-model-stream-" + UUID().uuidString)
        TaskStore.resetCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        AgentRunner.canControl = { _ in true }
        AgentRunner.resolveQuickApp = { _ in nil }
        AgentRunner.resolveApp = { _ in nil }
        AgentRunner.readBookmarks = { [] }
        AgentRunner.isCodexApp = { _ in false }
        var seen: [[String: Any]] = []
        AgentRunner.sendModel = { _, messages, _, _, done in
            seen = messages
            done(.success(ModelTurn(content: "口播：明天两个日程，下午的撞了\n- 十点评审\n- 两点周会",
                                    rawMessage: ["role": "assistant", "content": "口播：明天两个日程，下午的撞了\n- 十点评审\n- 两点周会"],
                                    usage: ["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12, "prompt_cache_hit_tokens": 6])))
        }
        var task = try TaskStore.claim(subject: "stream-" + UUID().uuidString, requestId: UUID().uuidString,
                                       text: "明天有什么日程", context: nil)
        task.status = .running; try TaskStore.save(task)
        var outcome: AgentRunner.Outcome?
        let finished = DispatchSemaphore(value: 0)
        AgentRunner.run(config: ModelConfig(baseURL: "https://model.example.test", model: "m", apiKey: "k"), task: task,
                        readPage: { .failure(.emptyPage) }) { outcome = $0; finished.signal() }
        precondition(finished.wait(timeout: .now() + 5) == .success, "执行没有按时结束")
        check(seen.first?["content"] as? String == AgentRunner.systemPrompt, "系统提示词逐字不变，前缀缓存才能命中")
        check((seen.dropFirst().first?["content"] as? String)?.hasPrefix(AgentRunner.factsMarker) == true
              && (seen.dropFirst().first?["content"] as? String)?.contains("当前本地时间") == true, "时间等会变的事实放在独立消息里")
        check(seen.last?["content"] as? String == "明天有什么日程", "用户原话单独一条，不被事实污染")
        check(outcome?.content == "- 十点评审\n- 两点周会" && outcome?.spoken == "明天两个日程，下午的撞了", "口播拆出给语音，屏幕只显示正文")
        check(outcome?.usage.cachedPromptTokens == 6, "任务用量累计缓存命中")

        print("Model stream tests passed: \(checks) checks")
    }
}
