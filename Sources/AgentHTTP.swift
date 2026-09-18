/**
 * [INPUT]: 依赖 Foundation 的 JSONSerialization/JSONEncoder，消费 ModelConfigStore 与 ModelClient。
 * [OUTPUT]: 展示上报核验控制租约并绑定连接身份；建任务时传递控制会话以便执行核验；对外提供 AgentHTTP.handle——承接 /api/v1 下「本机管理类」端点：模型服务配置的读写与连通性实测。
 * [POS]: Sources 的 Agent 路由层；Server 只做一行委托，避免它继续膨胀越过 800 行红线。
 *        这些端点**只允许回环访问**（本机控制台），与手机侧的任务接口（M1 的 /api/v1/tasks/…）分开：
 *        任务接口面向配对手机、必须带 Bearer；本文件的管理端点面向本机浏览器，靠回环判定。
 *        两者都不允许局域网匿名调用。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum AgentHTTP {
    static let managedPaths: Set<String> = ["/api/v1/model-config", "/api/v1/model-test"]
    /// 桌面反馈面板的展示会话；由 main.swift 装配注入。HTTP 层只转写协议，不做展示决策。
    static var spriteSession: SpriteSession?
    static var spriteAuthorized: (String) -> Bool = { _ in false }

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

    /// 任务类路径：**含回环在内**都要求 Bearer。回环豁免会让本机任意进程读到全部任务正文。
    /// 小精灵展示会话同权：观看者或失效租约不能改桌面展示。
    static func requiresBearer(_ path: String) -> Bool {
        path.hasPrefix("/api/v1/tasks") || path.hasPrefix("/api/v1/sprite")
            || path == "/api/v1/executors" || path == "/api/v1/context/page"
    }

    /// 返回 true 表示已接管该路径（调用方不要继续走 404）。
    static func handle(method: String, path: String, body: Data, fromLoopback: Bool,
                       authorization: String?, query: String = "",
                       queue: DispatchQueue,
                       respond: @escaping (Int, [String: Any]) -> Void) -> Bool {
        if requiresBearer(path) {
            handleTaskRoutes(method: method, path: path, body: body, query: query,
                             authorization: authorization, respond: respond)
            return true
        }
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

    // MARK: 任务接口（M1，全部要求 Bearer）

    /// 配对主体：由当前 token 派生，换 token 后旧任务不再可见。
    private static var subject: String { String(Auth.token.prefix(8)) }

    private static func handleTaskRoutes(method: String, path: String, body: Data, query: String,
                                         authorization: String?,
                                         respond: @escaping (Int, [String: Any]) -> Void) {
        guard Auth.verify(authorizationHeader: authorization) else {
            respond(401, ["error": "未授权：任务接口需要配对 token。"])
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        switch (method, path) {
        case ("GET", "/api/v1/executors"):
            respond(200, ["executors": TaskService.executors()])
        case ("GET", "/api/v1/context/page"):
            guard let binding = TaskService.currentPageBinding() else {
                respond(200, ["page": NSNull()])
                return
            }
            respond(200, ["page": ["browser": binding.browser, "url": binding.url, "title": binding.title,
                                   "domain": binding.domain ?? "", "observedAt": binding.observedAt]])
        case ("POST", "/api/v1/tasks"):
            submit(json: json, respond: respond)
        case ("POST", "/api/v1/sprite/session"):
            spriteAction(json: json, respond: respond)
        case ("GET", "/api/v1/sprite/state"):
            spriteState(respond: respond)
        case ("GET", "/api/v1/tasks"):
            list(query: query, respond: respond)
        case ("GET", let target) where target.hasPrefix("/api/v1/tasks/by-request/"):
            let requestId = String(target.dropFirst("/api/v1/tasks/by-request/".count))
            guard let task = TaskStore.task(subject: subject, requestId: requestId) else {
                respond(404, ["error": "这个请求没有对应任务。"])
                return
            }
            respond(200, ["task": task.json()])
        case ("GET", let target) where target.hasSuffix("/events"):
            let taskId = String(target.dropFirst("/api/v1/tasks/".count).dropLast("/events".count))
            events(taskId: taskId, query: query, respond: respond)
        case ("POST", let target) where target.hasSuffix("/actions"):
            let taskId = String(target.dropFirst("/api/v1/tasks/".count).dropLast("/actions".count))
            performAction(taskId: taskId, json: json, respond: respond)
        case ("GET", let target) where target.hasPrefix("/api/v1/tasks/"):
            let taskId = String(target.dropFirst("/api/v1/tasks/".count))
            guard let task = TaskStore.task(id: taskId), task.subject == subject else {
                respond(404, ["error": "找不到这个任务。"])
                return
            }
            respond(200, ["task": task.json()])
        default:
            respond(405, ["error": "不支持的方法。"])
        }
    }

    private static func submit(json: [String: Any], respond: (Int, [String: Any]) -> Void) {
        guard let requestId = json["requestId"] as? String, !requestId.isEmpty else {
            respond(400, ["error": "缺少 requestId：提交超时后要靠它找回原任务。"])
            return
        }
        guard let text = json["text"] as? String else {
            respond(400, ["error": "缺少正文。"])
            return
        }
        do {
            let task = try TaskService.submit(subject: subject, requestId: requestId, text: text,
                                              context: pageBinding(from: json["context"]), controlSession: json["controlSession"] as? String)
            respond(200, ["task": task.json()])
        } catch {
            respond(statusFor(error), ["error": error.localizedDescription])
        }
    }

    private static func performAction(taskId: String, json: [String: Any], respond: (Int, [String: Any]) -> Void) {
        guard let name = json["action"] as? String else {
            respond(400, ["error": "缺少动作名。"])
            return
        }
        guard let task = TaskStore.task(id: taskId), task.subject == subject else {
            respond(404, ["error": "找不到这个任务。"])
            return
        }
        _ = task
        do {
            switch name {
            case "supplement":
                let updated = try TaskService.supplement(taskId: taskId, text: json["text"] as? String ?? "",
                                                         expectedRevision: json["expectedRevision"] as? Int)
                respond(200, ["task": updated.json()])
            case "cancel":
                let updated = try TaskService.abandon(taskId: taskId)
                // 不叫「已停止」：runtime 不支持真中断，已派发的调用仍会跑完（方案 §7）。
                respond(200, ["task": updated.json(),
                              "note": "手机不再等待这个任务；Mac 上已发出的这次调用可能仍会跑完。"])
            default:
                respond(400, ["error": "不支持的动作：\(name)"])
            }
        } catch {
            respond(statusFor(error), ["error": error.localizedDescription])
        }
    }

    // MARK: 小精灵展示会话（桌面反馈）

    /// 手机 → Mac 的展示上报。只改展示状态：草稿不执行、不注入任何应用，与任务事务完全隔离。
    private static func spriteAction(json: [String: Any], respond: (Int, [String: Any]) -> Void) {
        guard let session = spriteSession else {
            respond(503, ["error": "桌面反馈面板未启用。"])
            return
        }
        guard let action = json["action"] as? String else {
            respond(400, ["error": "缺少 action。"])
            return
        }
        guard let controller = json["session"] as? String, spriteAuthorized(controller) else {
            respond(409, ["error": "控制权已变化，请先接管控制。"])
            return
        }
        session.bind(controller: controller)
        let generation = json["generation"] as? Int ?? 0
        let seq = json["seq"] as? Int ?? 0
        let version = json["version"] as? Int ?? 0
        switch action {
        case "select":
            session.select(generation: generation, seq: seq)
        case "deselect":
            session.deselect(generation: generation, seq: seq)
        case "draft":
            session.draft(generation: generation, seq: seq, version: version,
                          text: json["text"] as? String ?? "")
        case "heartbeat":
            break
        case "clear":
            session.clear(generation: generation, seq: seq, version: version)
        case "submitting":
            session.submitting(version: version, text: json["text"] as? String ?? "",
                               requestId: json["requestId"] as? String ?? "")
        case "submitted":
            session.submitted(version: version, taskId: json["taskId"] as? String, requestId: json["requestId"] as? String ?? "")
        case "submit-failed":
            session.submitFailed(version: version, requestId: json["requestId"] as? String ?? "")
        default:
            respond(400, ["error": "不支持的 action：\(action)"])
            return
        }
        session.touch()
        spriteState(respond: respond)
    }

    /// 快照回显：手机重连时同步当前展示状态，不回放按键。
    private static func spriteState(respond: (Int, [String: Any]) -> Void) {
        guard let session = spriteSession else {
            respond(503, ["error": "桌面反馈面板未启用。"])
            return
        }
        let snapshot = session.current
        respond(200, ["state": [
            "selected": snapshot.selected,
            "generation": snapshot.generation,
            "seq": snapshot.seq,
            "draftVersion": snapshot.draftVersion,
            "draft": snapshot.draft,
            "submitting": snapshot.submitting,
            "taskId": snapshot.lastTaskId ?? "",
        ] as [String: Any]])
    }

    private static func events(taskId: String, query: String, respond: (Int, [String: Any]) -> Void) {
        guard let task = TaskStore.task(id: taskId), task.subject == subject else {
            respond(404, ["error": "找不到这个任务。"])
            return
        }
        _ = task
        let after = Int(queryValue("after", in: query) ?? "") ?? 0
        let result = TaskStore.events(taskId: taskId, after: after)
        respond(200, ["events": result.events.map { $0.json() },
                      "needRefresh": result.needRefresh,
                      "latestSeq": TaskStore.latestSeq()])
    }

    private static func list(query: String, respond: (Int, [String: Any]) -> Void) {
        let mine = TaskStore.all().filter { $0.subject == subject }.sorted { $0.updatedAt > $1.updatedAt }
        let cursor = Int(queryValue("cursor", in: query) ?? "") ?? 0
        let page = Array(mine.dropFirst(cursor).prefix(20))
        let next = cursor + page.count
        respond(200, ["tasks": page.map { summary($0) },
                      "nextCursor": next < mine.count ? next : NSNull()])
    }

    /// 历史摘要：**不返回正文**（方案 §9：分页摘要不回全部正文）。
    private static func summary(_ task: AgentTask) -> [String: Any] {
        let head = String(task.text.prefix(80))
        return ["id": task.id, "status": task.status.rawValue, "statusText": task.status.displayName,
                "preview": head, "createdAt": task.createdAt, "updatedAt": task.updatedAt,
                "hasResult": task.result != nil]
    }

    private static func pageBinding(from value: Any?) -> PageBinding? {
        guard let dict = value as? [String: Any], let url = dict["url"] as? String, !url.isEmpty else { return nil }
        return PageBinding(browser: dict["browser"] as? String ?? "",
                           windowId: dict["windowId"] as? String,
                           tabId: dict["tabId"] as? String,
                           url: url,
                           title: dict["title"] as? String ?? "",
                           observedAt: (dict["observedAt"] as? Double) ?? Date().timeIntervalSince1970)
    }

    private static func queryValue(_ name: String, in rawPath: String) -> String? {
        guard let queryPart = rawPath.components(separatedBy: "?").dropFirst().first else { return nil }
        for pair in queryPart.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.first == name, parts.count > 1 { return parts[1].removingPercentEncoding ?? parts[1] }
        }
        return nil
    }

    /// 业务错误到状态码：冲突类一律 409，让手机能区分"重试"与"改内容再来"。
    private static func statusFor(_ error: Error) -> Int {
        if error is TaskStoreError { return 409 }
        if let service = error as? TaskServiceError {
            switch service {
            case .busy, .supplementLimitReached, .revisionMismatch: return 409
            default: return 400
            }
        }
        return 400
    }
}
