/**
 * [INPUT]: 依赖 Foundation 的 JSONSerialization/JSONEncoder，消费 ModelConfigStore 与 ModelClient。
 * [OUTPUT]: 对外提供 AgentHTTP.handle——承接 /api/v1 下「本机管理类」端点：模型服务配置的读写与连通性实测。
 * [POS]: Sources 的 Agent 路由层；Server 只做一行委托，避免它继续膨胀越过 800 行红线。
 *        这些端点**只允许回环访问**（本机控制台），与手机侧的任务接口（M1 的 /api/v1/tasks/…）分开：
 *        任务接口面向配对手机、必须带 Bearer；本文件的管理端点面向本机浏览器，靠回环判定。
 *        两者都不允许局域网匿名调用。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum AgentHTTP {
    static let managedPaths: Set<String> = ["/api/v1/model-config", "/api/v1/model-test"]

    // 工具声明与探针回传的假页面：只验证「模型会不会发起工具调用、能否消化工具结果」，
    // 不调用任何真实浏览器或桌面能力——工具执行权在 M1 才接进来。
    private static let probeTools: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": "read_page",
            "description": "读取当前网页的标题与正文",
            "parameters": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]],
        ] as [String: Any],
    ]]
    private static let fakePage = "标题：PocketDesk 使用说明\n正文：PocketDesk 把手机变成电脑的输入端与控制台，支持实时输入、触控板与画面查看。"

    /// 返回 true 表示已接管该路径（调用方不要继续走 404）。
    static func handle(method: String, path: String, body: Data, fromLoopback: Bool,
                       queue: DispatchQueue,
                       respond: @escaping (Int, [String: Any]) -> Void) -> Bool {
        guard managedPaths.contains(path) else { return false }
        guard fromLoopback else {
            respond(403, ["error": "模型服务配置只允许在这台 Mac 上修改。"])
            return true
        }
        switch (method, path) {
        case ("GET", "/api/v1/model-config"):
            respond(200, ["config": ModelConfigStore.view(ModelConfigStore.load())])
        case ("POST", "/api/v1/model-config"):
            saveConfig(body: body, respond: respond)
        case ("POST", "/api/v1/model-test"):
            probe(body: body, queue: queue, respond: respond)
        default:
            respond(405, ["error": "不支持的方法。"])
        }
        return true
    }

    // MARK: 配置读写

    private static func saveConfig(body: Data, respond: (Int, [String: Any]) -> Void) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let baseURL = (json["baseURL"] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (json["model"] as? String)?.trimmingCharacters(in: .whitespaces)
        let apiKey = (json["apiKey"] as? String)?.trimmingCharacters(in: .whitespaces)

        var draft = ModelConfigStore.load()
        if let baseURL { draft.baseURL = baseURL }
        if let model { draft.model = model }
        // Key 显式传空串代表清空；不传（nil）才代表沿用旧值。
        if let apiKey { draft.apiKey = apiKey }

        // 三项全空 = 用户要清空配置。这里不能用 try? 吞掉失败：
        // 写失败却回「已清空」就是假成功，用户会以为 Key 已经从这台机器上消失了。
        if draft.baseURL.isEmpty && draft.model.isEmpty && draft.apiKey.isEmpty {
            do {
                try ModelConfigStore.save(ModelConfig())
                respond(200, ["config": ModelConfigStore.view(ModelConfigStore.load())])
            } catch {
                respond(500, ["error": "清空失败：\(error.localizedDescription)"])
            }
            return
        }
        if !draft.baseURL.isEmpty, ModelConfigStore.endpoint(for: draft.baseURL) == nil {
            respond(400, ["error": ModelConfigError.badScheme(draft.baseURL).localizedDescription ?? "Base URL 不合法。"])
            return
        }
        if draft.model.isEmpty {
            respond(400, ["error": ModelConfigError.emptyModel.localizedDescription ?? "请填写模型名。"])
            return
        }
        if draft.apiKey.isEmpty {
            respond(400, ["error": ModelConfigError.emptyKey.localizedDescription ?? "请填写 API Key。"])
            return
        }
        do {
            try ModelConfigStore.save(draft)
            // 回包用重新读回的那份：updatedAt 由 save 写入，直接回 draft 会漏掉它。
            respond(200, ["config": ModelConfigStore.view(ModelConfigStore.load())])
        } catch {
            respond(500, ["error": "保存失败：\(error.localizedDescription)"])
        }
    }

    // MARK: 连通性实测（M0-A）

    /// 用页面当前填的值试跑（不落盘），两步：①纯文本 ②工具调用闭环。
    /// 结果如实回传：超时/鉴权失败/不支持工具调用都原样报出来，不粉饰成「可用」。
    private static func probe(body: Data, queue: DispatchQueue, respond: @escaping (Int, [String: Any]) -> Void) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        var config = ModelConfigStore.load()
        if let value = json["baseURL"] as? String, !value.isEmpty { config.baseURL = value.trimmingCharacters(in: .whitespaces) }
        if let value = json["model"] as? String, !value.isEmpty { config.model = value.trimmingCharacters(in: .whitespaces) }
        if let value = json["apiKey"] as? String, !value.isEmpty { config.apiKey = value.trimmingCharacters(in: .whitespaces) }

        guard config.isConfigured else {
            respond(400, ["error": "请先填好 Base URL、模型名与 API Key 再测试。"])
            return
        }
        guard let host = ModelConfigStore.endpoint(for: config.baseURL)?.host else {
            respond(400, ["error": ModelConfigError.badScheme(config.baseURL).localizedDescription ?? "Base URL 不合法。"])
            return
        }

        let started = Date()
        ModelClient.send(config: config, messages: [["role": "user", "content": "只回复两个字：可用"]], tools: nil) { first in
            let textMs = Int(Date().timeIntervalSince(started) * 1000)
            switch first {
            case .failure(let failure):
                queue.async {
                    respond(200, ["ok": false, "host": host, "error": failure.message,
                                  "httpStatus": failure.httpStatus ?? 0, "latencyMs": textMs])
                }
            case .success(let turn):
                guard let content = turn.content, !content.isEmpty else {
                    queue.async {
                        respond(200, ["ok": false, "host": host, "latencyMs": textMs,
                                      "error": "服务返回 200 但没有文本内容，可能是响应格式不兼容。"])
                    }
                    return
                }
                probeToolCall(config: config, host: host, content: content, usage: turn.usage, textMs: textMs, queue: queue, respond: respond)
            }
        }
    }

    private static func probeToolCall(config: ModelConfig, host: String, content: String,
                                      usage: [String: Any]?, textMs: Int,
                                      queue: DispatchQueue, respond: @escaping (Int, [String: Any]) -> Void) {
        var messages: [[String: Any]] = [["role": "user", "content": "用 read_page 读取当前网页，然后用一句话总结。"]]
        let started = Date()
        ModelClient.send(config: config, messages: messages, tools: probeTools) { first in
            switch first {
            case .failure(let failure):
                queue.async {
                    respond(200, ["ok": true, "host": host, "content": content, "usage": usage ?? [:],
                                  "latencyMs": textMs, "model": config.model,
                                  "tool": ["supported": false, "error": failure.message]])
                }
            case .success(let turn):
                guard let call = turn.toolCalls?.first else {
                    queue.async {
                        respond(200, ["ok": true, "host": host, "content": content, "usage": usage ?? [:],
                                      "latencyMs": textMs, "model": config.model,
                                      "tool": ["supported": false, "note": "模型没有发起工具调用：该模型或服务端可能不支持 function calling。"]])
                    }
                    return
                }
                if let raw = turn.rawMessage { messages.append(raw) }
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": fakePage])
                let name = (call["function"] as? [String: Any])?["name"] as? String ?? ""
                ModelClient.send(config: config, messages: messages, tools: probeTools) { second in
                    let totalMs = textMs + Int(Date().timeIntervalSince(started) * 1000)
                    switch second {
                    case .failure(let failure):
                        queue.async {
                            respond(200, ["ok": true, "host": host, "content": content, "usage": usage ?? [:],
                                          "latencyMs": totalMs, "model": config.model,
                                          "tool": ["supported": true, "name": name, "error": failure.message]])
                        }
                    case .success(let final):
                        queue.async {
                            respond(200, ["ok": true, "host": host, "content": content, "usage": usage ?? [:],
                                          "latencyMs": totalMs, "model": config.model, "checkedAt": Date().timeIntervalSince1970,
                                          "tool": ["supported": true, "name": name, "final": final.content ?? ""]])
                        }
                    }
                }
            }
        }
    }
}
