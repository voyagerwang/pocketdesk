/**
 * [INPUT]: 依赖 Foundation 的 JSONSerialization/JSONEncoder 与 CoreFoundation 的严格 JSON 布尔识别，消费 ModelConfigStore 的后端、多 API 服务商与凭证同源边界，以及统一 ModelClient。
 * [OUTPUT]: 异步语义接续提交与补充票据；展示上报核验控制租约并绑定连接身份；建任务时传递控制会话以便执行核验；对外提供 AgentHTTP.handle——本机模型配置支持逐条保存、显式启用与移除；测试草稿按指定 ID 隔离凭证，新条目不借旧 Key，旧单条 POST 仍兼容。
 * [POS]: Sources 的 Agent 路由层；Server 只做一行委托，避免它继续膨胀越过 800 行红线。
 *        这些端点**只允许回环访问**（本机控制台），与手机侧的任务接口（M1 的 /api/v1/tasks/…）分开：
 *        任务接口面向配对手机、必须带 Bearer；本文件的管理端点面向本机浏览器，靠回环判定。
 *        两者都不允许局域网匿名调用。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreFoundation

enum AgentHTTP {
    static let managedPaths: Set<String> = ["/api/v1/model-config", "/api/v1/model-test"]
    static var probeModel = ModelClient.send
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

    private static func providerString(_ field: String, in json: [String: Any]) throws -> String? {
        guard let raw = json[field] else { return nil }
        guard let value = raw as? String else { throw ModelConfigError.invalidProvider }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只合并指定条目；现代表单的空 Key 沿用同 ID 同源凭证，旧 top-level 草稿仍以显式空串表示清空。
    private static func providerDraft(_ json: [String: Any], saved: APIProviderConfig?, id: String,
                                      keepEmptyKey: Bool, requireName: Bool, validate: Bool = true) throws -> APIProviderConfig {
        let baseURL = try providerString("baseURL", in: json) ?? saved?.baseURL ?? ""
        let model = try providerString("model", in: json) ?? saved?.model ?? ""
        let name = try providerString("name", in: json) ?? saved?.name ?? (requireName ? "" : ModelConfigStore.providerName(for: baseURL))
        let suppliedKey = try providerString("apiKey", in: json)
        var key = saved?.apiKey ?? ""
        if let suppliedKey, !keepEmptyKey || !suppliedKey.isEmpty { key = suppliedKey }
        let draft = APIProviderConfig(id: id, name: name, baseURL: baseURL, model: model, apiKey: key)
        if validate && ModelConfigStore.endpoint(for: baseURL) == nil { throw ModelConfigError.badScheme(baseURL) }
        if let saved, !saved.apiKey.isEmpty, !baseURL.isEmpty, baseURL != saved.baseURL,
           !ModelConfigStore.credentialOriginMatches(saved.baseURL, baseURL), (suppliedKey ?? "").isEmpty {
            throw ModelConfigError.newOriginNeedsKey
        }
        if validate { try ModelConfigStore.validateProvider(draft) }
        return draft
    }

    /// 新操作只改指定条目；仅 activate=true 或 activate-provider 才改变使用来源。
    private static func providerAction(_ json: [String: Any], saved: ModelConfig) throws -> ModelConfig {
        var draft = saved
        switch json["action"] as? String {
        case "save-provider":
            guard let values = json["provider"] as? [String: Any] else { throw ModelConfigError.invalidProvider }
            let suppliedID = try providerString("id", in: values) ?? ""
            let existing = suppliedID.isEmpty ? nil : saved.provider(id: suppliedID)
            if !suppliedID.isEmpty && existing == nil { throw ModelConfigError.providerNotFound }
            let id = suppliedID.isEmpty ? UUID().uuidString.lowercased() : suppliedID
            let provider = try providerDraft(values, saved: existing, id: id, keepEmptyKey: true, requireName: true)
            var activate = false
            if let raw = json["activate"] {
                guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw ModelConfigError.invalidProvider }
                activate = value.boolValue
            }
            draft.replaceProvider(provider)
            if activate { draft.activeProviderID = id; draft.backend = .api }
        case "activate-provider", "remove-provider":
            guard let id = try providerString("providerId", in: json), let provider = saved.provider(id: id) else {
                throw ModelConfigError.providerNotFound
            }
            if json["action"] as? String == "activate-provider" {
                try ModelConfigStore.validateProvider(provider)
                draft.activeProviderID = id
                draft.backend = .api
            } else { draft.removeProvider(id: id) }
        default: throw ModelConfigError.invalidProviderAction
        }
        return draft
    }

    /// 测试按 providerId 合并；显式空 ID 是无凭证新草稿。旧请求仅改当前 API，不触碰其余服务商。
    private static func modelConfigDraft(_ json: [String: Any], saved: ModelConfig,
                                         allowClearingBackup: Bool) throws -> ModelConfig {
        if json["action"] != nil { throw ModelConfigError.invalidProviderAction }
        var draft = saved
        if let raw = json["backend"] {
            guard let value = raw as? String, let backend = ModelBackend(rawValue: value) else { throw ModelConfigError.invalidBackend }
            draft.backend = backend
        }
        if json["providerId"] != nil {
            guard draft.backend == .api, let id = try providerString("providerId", in: json) else { throw ModelConfigError.invalidProvider }
            let existing = id.isEmpty ? nil : saved.provider(id: id)
            if !id.isEmpty && existing == nil { throw ModelConfigError.providerNotFound }
            let provider = try providerDraft(json, saved: existing, id: id.isEmpty ? UUID().uuidString.lowercased() : id,
                                             keepEmptyKey: true, requireName: false)
            draft.replaceProvider(provider)
            draft.activeProviderID = provider.id
            return draft
        }
        let clearing = try providerString("baseURL", in: json) == ""
            && providerString("model", in: json) == "" && providerString("apiKey", in: json) == ""
        if allowClearingBackup && clearing {
            if let id = draft.activeProviderID { draft.removeProvider(id: id) }
            return draft
        }
        let hasAPIFields = ["baseURL", "model", "apiKey"].contains { json[$0] != nil }
        if draft.backend == .codex && !hasAPIFields { return draft }
        let id = saved.activeProvider?.id ?? (saved.provider(id: ModelConfig.legacyProviderID) == nil
            ? ModelConfig.legacyProviderID : UUID().uuidString.lowercased())
        let provider = try providerDraft(json, saved: saved.activeProvider, id: id,
                                         keepEmptyKey: false, requireName: false, validate: draft.backend == .api)
        draft.replaceProvider(provider)
        draft.activeProviderID = id
        return draft
    }

    private static func saveConfig(body: Data, respond: (Int, [String: Any]) -> Void) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let draft: ModelConfig
        do {
            let saved = ModelConfigStore.load()
            if json["action"] != nil { draft = try providerAction(json, saved: saved) }
            else { draft = try modelConfigDraft(json, saved: saved, allowClearingBackup: true) }
        } catch {
            respond(400, ["error": error.localizedDescription])
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
        let config: ModelConfig
        do {
            config = try modelConfigDraft(json, saved: ModelConfigStore.load(), allowClearingBackup: false)
        } catch {
            respond(400, ["error": error.localizedDescription])
            return
        }
        let host = config.activeHost

        let started = Date()
        probeModel(config, [["role": "user", "content": "只回复两个字：可用"]], nil, 60) { first in
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
        var messages: [[String: Any]] = [["role": "user", "content": "用 read_page 读取 https://example.invalid/pocketdesk-model-probe，然后用一句话总结；这是模拟工具验证，不要打开浏览器。"]]
        let started = Date()
        probeModel(config, messages, probeTools, 60) { first in
            switch first {
            case .failure(let failure):
                queue.async {
                    respond(200, ["ok": true, "host": host, "content": content, "usage": usage ?? [:],
                                  "latencyMs": textMs, "model": config.activeModel, "backend": config.backend.rawValue,
                                  "tool": ["supported": false, "error": failure.message]])
                }
            case .success(let turn):
                guard let calls = turn.toolCalls, calls.count == 1, let call = calls.first,
                      (call["function"] as? [String: Any])?["name"] as? String == "read_page" else {
                    queue.async {
                        respond(200, ["ok": true, "host": host, "content": content, "usage": usage ?? [:],
                                      "latencyMs": textMs, "model": config.activeModel, "backend": config.backend.rawValue,
                                      "tool": ["supported": false, "note": "模型没有发起工具调用：该模型或服务端可能不支持 function calling。"]])
                    }
                    return
                }
                if let raw = turn.rawMessage { messages.append(raw) }
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": fakePage])
                let name = (call["function"] as? [String: Any])?["name"] as? String ?? ""
                probeModel(config, messages, probeTools, 60) { second in
                    let totalMs = textMs + Int(Date().timeIntervalSince(started) * 1000)
                    switch second {
                    case .failure(let failure):
                        queue.async {
                            respond(200, ["ok": true, "host": host, "content": content, "usage": usage ?? [:],
                                          "latencyMs": totalMs, "model": config.activeModel, "backend": config.backend.rawValue,
                                          "tool": ["supported": true, "name": name, "error": failure.message]])
                        }
                    case .success(let final):
                        queue.async {
                            guard let answer = final.content, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  final.toolCalls?.isEmpty != false else {
                                respond(200, ["ok": true, "host": host, "content": content, "usage": usage ?? [:],
                                              "latencyMs": totalMs, "model": config.activeModel, "backend": config.backend.rawValue,
                                              "tool": ["supported": true, "name": name, "error": "工具结果已回传，但模型没有返回最终文字答复；闭环尚未完成。"]])
                                return
                            }
                            respond(200, ["ok": true, "host": host, "content": content, "usage": usage ?? [:],
                                          "latencyMs": totalMs, "model": config.activeModel, "backend": config.backend.rawValue, "checkedAt": Date().timeIntervalSince1970,
                                          "tool": ["supported": true, "name": name, "final": answer]])
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

    private static func submit(json: [String: Any], respond: @escaping (Int, [String: Any]) -> Void) {
        guard let requestId = json["requestId"] as? String, !requestId.isEmpty else {
            respond(400, ["error": "缺少 requestId：提交超时后要靠它找回原任务。"])
            return
        }
        guard let text = json["text"] as? String else {
            respond(400, ["error": "缺少正文。"])
            return
        }
        TaskService.send(subject: subject, requestId: requestId, text: text,
                         context: pageBinding(from: json["context"]), controlSession: json["controlSession"] as? String,
                         previousTaskId: json["previousTaskId"] as? String) { result in
            switch result {
            case .success(let task): respond(200, ["task": task.json()])
            case .failure(let error): respond(statusFor(error), ["error": error.localizedDescription])
            }
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
                                                         expectedRevision: json["expectedRevision"] as? Int,
                                                         requestId: json["requestId"] as? String, controlSession: json["controlSession"] as? String)
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
            case .supplementLimitReached, .revisionMismatch: return 409
            default: return 400
            }
        }
        return 400
    }
}
