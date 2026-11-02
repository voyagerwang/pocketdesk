/**
 * [INPUT]: 依赖 Foundation 的 URLSession/JSONSerialization、ModelConfig 后端选择及 CodexModelClient 的登录额度规划能力。
 * [OUTPUT]: 对外提供统一 ModelClient.send；Codex 与 API 都返回 content、tool_calls 与带来源的 usage，失败不自动跨后端重试。API 默认流式（SSE 增量拼装 content 与 tool_calls、末块用量），经线程旁路把累计文字交给观察者；请求体键排序以稳定命中服务端前缀缓存；服务端拒收流式参数（400）时同一请求退回整段一次。
 * [POS]: Sources 的模型适配层最薄的一层：只翻译协议，不持有任何工具执行权。
 *        工具由 PocketDesk 本地执行后作为结果回传，模型永远不能直接操作电脑。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

struct ModelTurn {
    var content: String?
    var toolCalls: [[String: Any]]?
    /// 原样保留 assistant 消息，供多轮续接时原样回放（含 tool_calls 的结构不能自己重造）。
    var rawMessage: [String: Any]?
    var usage: [String: Any]?
}

struct ModelFailure: Error {
    var httpStatus: Int?
    var message: String
}

enum ModelClient {
    // MARK: - 流式文字旁路
    //
    // 模型回答是边生成边到的；桌面语音想在第一行“口播”写完时就开口，而不是等整段回答收完。
    // sendModel 的签名被大量测试替身固定住了，所以旁路观察者不进参数：调用方在同一线程上
    // 先 setPartialObserver 再同步调用 send，send 入口当场取走，之后的流式片段都交给它。
    private final class PartialBox { let call: (String) -> Void; init(_ call: @escaping (String) -> Void) { self.call = call } }
    private static let partialKey = "PocketDesk.ModelClient.partialObserver"
    static func setPartialObserver(_ observer: ((String) -> Void)?) {
        if let observer { Thread.current.threadDictionary[partialKey] = PartialBox(observer) }
        else { Thread.current.threadDictionary.removeObject(forKey: partialKey) }
    }
    private static func takePartialObserver() -> ((String) -> Void)? {
        (Thread.current.threadDictionary[partialKey] as? PartialBox)?.call
    }
    /// 关掉就退回整段等待（排障用）；服务端不认流式参数时本次请求也会自动退回一次。
    static var streamingEnabled = true
    /// 每次请求的会话配置；回归测试换成挂了替身 URLProtocol 的配置，不联网。
    static var sessionConfiguration: () -> URLSessionConfiguration = { .ephemeral }

    /// 单次请求。回调不在主线程；调用方自行切回自己的队列。
    /// 错误只回传服务端摘要，不回显用户上下文或含凭据的请求头。
    static func send(config: ModelConfig,
                     messages: [[String: Any]],
                     tools: [[String: Any]]?,
                     timeoutSeconds: Double = 60,
                     completion: @escaping (Result<ModelTurn, ModelFailure>) -> Void) {
        let partial = takePartialObserver()
        if config.backend == .codex {
            CodexModelClient.send(config: config, messages: messages, tools: tools,
                                  timeoutSeconds: timeoutSeconds, completion: completion)
            return
        }
        guard let url = ModelConfigStore.endpoint(for: config.baseURL) else {
            completion(.failure(ModelFailure(httpStatus: nil, message: "Base URL 不合法：必须是 http(s) 且带主机名。")))
            return
        }
        request(config: config, url: url, messages: messages, tools: tools, timeoutSeconds: timeoutSeconds,
                stream: streamingEnabled, partial: partial, completion: completion)
    }

    /// 请求体逐字节稳定：键排序后，同样的系统提示词与工具定义每次序列化都一样，服务端前缀缓存才能命中。
    static func payload(model: String, messages: [[String: Any]], tools: [[String: Any]]?, stream: Bool) -> Data? {
        var body: [String: Any] = ["model": model, "messages": messages, "temperature": 0]
        if let tools { body["tools"] = tools }
        if stream {
            body["stream"] = true
            // 流式默认不带用量；要求最后一块附上，计量与缓存命中才不丢。
            body["stream_options"] = ["include_usage": true]
        }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func request(config: ModelConfig, url: URL, messages: [[String: Any]], tools: [[String: Any]]?,
                                timeoutSeconds: Double, stream: Bool, partial: ((String) -> Void)?,
                                completion: @escaping (Result<ModelTurn, ModelFailure>) -> Void) {
        guard let body = payload(model: config.model, messages: messages, tools: tools, stream: stream) else {
            completion(.failure(ModelFailure(httpStatus: nil, message: "请求体序列化失败。")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept") }
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let provider = url.host ?? "api"
        let finish: (Result<ModelTurn, ModelFailure>) -> Void = { result in
            // 服务端不认 stream/stream_options（400）时，这一请求根本没推理，退回整段模式重发一次是安全的。
            if stream, case .failure(let failure) = result, failure.httpStatus == 400 {
                Self.request(config: config, url: url, messages: messages, tools: tools, timeoutSeconds: timeoutSeconds,
                             stream: false, partial: nil, completion: completion)
                return
            }
            guard case .success(var turn) = result else { completion(result); return }
            if turn.usage != nil {
                turn.usage?["provider"] = provider
                turn.usage?["model"] = config.activeModel
            }
            completion(.success(turn))
        }
        let reader = StreamReader(partial: partial, completion: finish)
        let session = URLSession(configuration: sessionConfiguration(), delegate: reader, delegateQueue: nil)
        session.dataTask(with: request).resume()
        session.finishTasksAndInvalidate()
    }

    /// 同时吃两种回包：text/event-stream 的增量块，或服务端忽略 stream 时的整段 JSON。
    private final class StreamReader: NSObject, URLSessionDataDelegate {
        private let partial: ((String) -> Void)?
        private let completion: (Result<ModelTurn, ModelFailure>) -> Void
        private var status: Int?
        private var eventStream = false
        private var raw = Data()
        private var pending = Data()
        private var content = ""
        private var calls: [Int: [String: Any]] = [:]
        private var usage: [String: Any]?
        private var sawEvent = false
        private var done = false

        init(partial: ((String) -> Void)?, completion: @escaping (Result<ModelTurn, ModelFailure>) -> Void) {
            self.partial = partial
            self.completion = completion
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let http = response as? HTTPURLResponse
            status = http?.statusCode
            let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            eventStream = (200..<300).contains(status ?? 0) && type.contains("text/event-stream")
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard eventStream else { raw.append(data); if raw.count > 8 << 20 { raw.removeAll() }; return }
            pending.append(data)
            // 按行切 SSE；半行留到下一块。
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                consume(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        private func consume(_ line: String) {
            guard line.hasPrefix("data:") else { return }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            sawEvent = true
            if let value = json["usage"] as? [String: Any] { usage = value }
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { return }
            if let text = delta["content"] as? String, !text.isEmpty {
                content += text
                partial?(content)
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = (call["index"] as? Int) ?? (call["index"] as? NSNumber)?.intValue ?? calls.count
                var entry = calls[index] ?? ["type": "function", "function": ["name": "", "arguments": ""]]
                if let id = call["id"] as? String, !id.isEmpty { entry["id"] = id }
                if let type = call["type"] as? String, !type.isEmpty { entry["type"] = type }
                var function = entry["function"] as? [String: String] ?? ["name": "", "arguments": ""]
                if let piece = call["function"] as? [String: Any] {
                    if let name = piece["name"] as? String { function["name", default: ""] += name }
                    if let arguments = piece["arguments"] as? String { function["arguments", default: ""] += arguments }
                }
                entry["function"] = function
                calls[index] = entry
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !done else { return }
            done = true
            if let error { completion(.failure(ModelFailure(httpStatus: nil, message: ModelClient.describe(error)))); return }
            if eventStream {
                if !pending.isEmpty { consume(String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard sawEvent else {
                    completion(.failure(ModelFailure(httpStatus: status, message: "流式响应没有任何有效数据块。")))
                    return
                }
                var turn = ModelTurn()
                turn.content = content.isEmpty ? nil : content
                let ordered = calls.keys.sorted().compactMap { calls[$0] }
                turn.toolCalls = ordered.isEmpty ? nil : ordered
                // 只回放 content/tool_calls；推理模型的 reasoning_content 不能回传给下一轮。
                var message: [String: Any] = ["role": "assistant", "content": content.isEmpty ? NSNull() : content]
                if !ordered.isEmpty { message["tool_calls"] = ordered }
                turn.rawMessage = message
                turn.usage = usage
                completion(.success(turn))
                return
            }
            completion(ModelClient.parseWhole(raw, status: status))
        }
    }

    /// 整段 JSON 回包（未开流式，或服务端忽略了 stream）。
    static func parseWhole(_ data: Data, status: Int?) -> Result<ModelTurn, ModelFailure> {
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status ?? 0) else {
            return .failure(ModelFailure(httpStatus: status, message: serverMessage(from: text, status: status)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(ModelFailure(httpStatus: status, message: "响应不是合法 JSON：\(text.prefix(200))"))
        }
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            return .failure(ModelFailure(httpStatus: status, message: "响应缺少 choices：\(text.prefix(200))"))
        }
        let message = first["message"] as? [String: Any]
        var turn = ModelTurn()
        turn.content = (message?["content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        turn.toolCalls = message?["tool_calls"] as? [[String: Any]]
        turn.rawMessage = message
        turn.usage = json["usage"] as? [String: Any]
        return .success(turn)
    }

    fileprivate static func describe(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorTimedOut: return "请求超时：模型服务没有在设定时间内响应，检查网络与 Base URL。"
        case NSURLErrorCannotConnectToHost: return "连不上服务：检查 Base URL 与端口，以及服务是否已启动。"
        case NSURLErrorCannotFindHost: return "找不到主机：Base URL 的域名无法解析。"
        case NSURLErrorNotConnectedToInternet: return "Mac 当前没有可用网络。"
        default: return ns.localizedDescription
        }
    }

    fileprivate static func serverMessage(from text: String, status: Int?) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return "HTTP \(status.map(String.init) ?? "?")：\(message)"
        }
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let message = json["error"] as? String {
            return "HTTP \(status.map(String.init) ?? "?")：\(message)"
        }
        // 401/403 一律归到鉴权，不把整段 HTML（反向代理的登录页之类）塞给控制台。
        if status == 401 || status == 403 { return "HTTP \(status!)：API Key 被拒绝或没有该模型的权限。" }
        return "HTTP \(status.map(String.init) ?? "?")：\(text.prefix(200))"
    }
}
