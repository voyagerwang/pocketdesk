/**
 * [INPUT]: 依赖 Foundation 的 URLSession/JSONSerialization，消费 ModelConfig 的配置。
 * [OUTPUT]: 对外提供 ModelClient.send——对 OpenAI 兼容 /chat/completions 发一次请求，
 *           解析出 content、tool_calls 与 usage；失败给出 HTTP 状态与服务端原文摘要。
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
    /// 单次请求。回调不在主线程；调用方自行切回自己的队列。
    /// 错误报文只回传服务端响应体摘要，**绝不回显请求体**（里面有 API Key）。
    static func send(config: ModelConfig,
                     messages: [[String: Any]],
                     tools: [[String: Any]]?,
                     timeoutSeconds: Double = 60,
                     completion: @escaping (Result<ModelTurn, ModelFailure>) -> Void) {
        guard let url = ModelConfigStore.endpoint(for: config.baseURL) else {
            completion(.failure(ModelFailure(httpStatus: nil, message: "Base URL 不合法：必须是 http(s) 且带主机名。")))
            return
        }
        var body: [String: Any] = ["model": config.model, "messages": messages, "temperature": 0]
        if let tools { body["tools"] = tools }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(ModelFailure(httpStatus: nil, message: "请求体序列化失败。")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(ModelFailure(httpStatus: nil, message: describe(error))))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard (200..<300).contains(status ?? 0) else {
                completion(.failure(ModelFailure(httpStatus: status, message: Self.serverMessage(from: text, status: status))))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(ModelFailure(httpStatus: status, message: "响应不是合法 JSON：\(text.prefix(200))")))
                return
            }
            guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
                completion(.failure(ModelFailure(httpStatus: status, message: "响应缺少 choices：\(text.prefix(200))")))
                return
            }
            let message = first["message"] as? [String: Any]
            var turn = ModelTurn()
            turn.content = (message?["content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            turn.toolCalls = message?["tool_calls"] as? [[String: Any]]
            turn.rawMessage = message
            turn.usage = json["usage"] as? [String: Any]
            completion(.success(turn))
        }.resume()
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorTimedOut: return "请求超时：模型服务没有在设定时间内响应，检查网络与 Base URL。"
        case NSURLErrorCannotConnectToHost: return "连不上服务：检查 Base URL 与端口，以及服务是否已启动。"
        case NSURLErrorCannotFindHost: return "找不到主机：Base URL 的域名无法解析。"
        case NSURLErrorNotConnectedToInternet: return "Mac 当前没有可用网络。"
        default: return ns.localizedDescription
        }
    }

    private static func serverMessage(from text: String, status: Int?) -> String {
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
