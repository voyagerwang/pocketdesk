/**
 * [INPUT]: 工作台回环 HTTP API、已授权任务和 TaskStore 的持久操作回执。
 * [OUTPUT]: 待办/本地日程/知识库存档/随手记创建，按 ID 读回核验；未知结果禁止重放。
 * [POS]: PocketDesk 本地业务适配；地址、路径与请求头不交给模型控制。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md。
 */
import Foundation
import CryptoKit

private final class WorkbenchNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum WorkbenchContent {
    static let kinds = ["task", "event", "knowledge", "note"]
    static let tools: [[String: Any]] = kinds.map { kind in
        let label = ["task": "待办", "event": "本地日程", "knowledge": "知识库文档", "note": "随手记"][kind]!
        var properties: [String: Any] = ["title": ["type": "string"], "content": ["type": "string", "description": "完整正文，不省略用户要求保存的内容"]]
        var required = ["title", "content"]
        var detail = ""
        if kind == "task" {
            for field in ["dueAt", "remindAt"] { properties[field] = ["type": "string", "description": "可选，电脑本地 YYYY-MM-DDTHH:mm，无此要求则省略"] }
            properties["plannedDate"] = ["type": "string", "description": "可选，计划执行日期 YYYY-MM-DD"]
            detail = "不支持指定项目；不把日程当待办。"
        } else if kind == "event" {
            for field in ["startAt", "endAt"] { properties[field] = ["type": "string", "description": "电脑本地 YYYY-MM-DDTHH:mm；必须从用户明确时间解析，缺少则先询问"] }
            properties["allDay"] = ["type": "boolean", "description": "可选；全天日程从当天零点到结束日次日零点"]
            properties["location"] = ["type": "string"]
            required += ["startAt", "endAt"]
            detail = "只创建本地日程，不发送外部邀请，不支持周期日程。"
        } else {
            properties["tags"] = ["type": "array", "items": ["type": "string"]]
            detail = "保存已提供或已读到的正文，不自动抓取链接全文，不指定目录。"
        }
        return ["type": "function", "function": [
            "name": "create_workbench_" + kind,
            "description": "在本机个人工作台创建一条" + label + "，不是飞书。仅用户明确要求保存或创建时使用，不用于查询或仅起草。" + detail,
            "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        ]]
    }
    struct Failure: Error { let message: String }
    struct Spec { let kind: String; let label: String; let path: String; let body: [String: Any]; let expected: [String: Any] }
    private static let queue = DispatchQueue(label: "PocketDesk.workbench.content")
    // 可注入传输用于隔离测试；生产固定回环，无 cookies、代理或重定向。
    static var request: (String, String, [String: Any]?) -> Result<[String: Any], Failure> = http

    static func validDate(_ value: String, day: Bool = false) -> Bool {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = day ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"; format.isLenient = false
        guard let date = format.date(from: value) else { return false }
        return format.string(from: date) == value
    }
    static func parse(_ arguments: String) throws -> Spec {
        guard let data = arguments.data(using: .utf8), data.count <= 550_000,
              var value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = value["kind"] as? String, let rawTitle = value["title"] as? String,
              let content = value["content"] as? String, content.utf8.count <= 512_000 else { throw Failure(message: "内容参数无效或过长。") }
        // 兼容模型为可选字段输出 null/空字符串；未知字段和有值的跨类型字段仍拒绝。
        let optional: Set<String> = ["startAt", "endAt", "allDay", "location", "dueAt", "plannedDate", "remindAt", "tags"]
        guard Set(value.keys).isSubset(of: optional.union(["kind", "title", "content"])) else { throw Failure(message: "包含不支持的字段，未创建。") }
        for name in optional {
            if value[name] is NSNull || (value[name] as? String) == "" { value.removeValue(forKey: name) }
        }
        if kind != "event", (value["allDay"] as? Bool) == false { value.removeValue(forKey: "allDay") }
        if kind == "event" || kind == "task", (value["tags"] as? [String])?.isEmpty == true { value.removeValue(forKey: "tags") }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 500 else { throw Failure(message: "请提供标题（最多 500 字）。") }
        let extra: Set<String>
        let path: String; let label: String
        var body: [String: Any] = ["title": title]; var expected: [String: Any] = ["title": title]
        switch kind {
        case "task":
            path = "/api/tasks"; label = "待办"; extra = ["dueAt", "plannedDate", "remindAt"]
            body["notes"] = content; expected["notes"] = content
            for (input, output) in [("dueAt", "due_at"), ("plannedDate", "planned_date"), ("remindAt", "remind_at")] {
                if let raw = value[input] {
                    guard let text = raw as? String, validDate(text, day: input == "plannedDate") else { throw Failure(message: "请补充准确的待办日期或时间。") }
                    body[input] = text; expected[output] = text
                }
            }
        case "event":
            path = "/api/events"; label = "日程"; extra = ["startAt", "endAt", "allDay", "location"]
            guard let start = value["startAt"] as? String, let end = value["endAt"] as? String,
                  validDate(start), validDate(end), end > start else { throw Failure(message: "请补充日程的起止时间，结束时间需晚于开始时间。") }
            if let raw = value["allDay"], !(raw is Bool) { throw Failure(message: "全天标记无效。") }
            if let raw = value["location"], !(raw is String) { throw Failure(message: "日程地点无效。") }
            let allDay = value["allDay"] as? Bool ?? false
            if allDay && (!start.hasSuffix("T00:00") || !end.hasSuffix("T00:00")) { throw Failure(message: "全天日程需从当天零点到结束日次日零点。") }
            body.merge(["startAt": start, "endAt": end, "allDay": allDay, "location": value["location"] as? String ?? "", "detail": content]) { _, new in new }
            expected.merge(["start_at": start, "end_at": end, "is_all_day": allDay ? 1 : 0, "location": value["location"] as? String ?? "", "detail": content]) { _, new in new }
        case "knowledge", "note":
            path = kind == "note" ? "/api/notes" : "/api/knowledge/archives"; label = kind == "note" ? "随手记" : "知识库文档"; extra = ["tags"]
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure(message: "请提供要保存的正文。") }
            if let raw = value["tags"] {
                guard let tags = raw as? [String], tags.count <= 30, tags.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 50 }) else { throw Failure(message: "标签格式无效。") }
                body["tags"] = tags
            }
            body["content"] = content; expected["content"] = content
        default: throw Failure(message: "请选择待办、日程、知识库或随手记。")
        }
        guard Set(value.keys).isSubset(of: extra.union(["kind", "title", "content"])) else { throw Failure(message: "包含该内容类型不支持的字段，未创建。") }
        return Spec(kind: kind, label: label, path: path, body: body, expected: expected)
    }
    static func execute(toolName: String, arguments: String, taskId: String, authorized: @escaping () -> Bool,
                        completion: @escaping (AgentRunner.ToolOutcome) -> Void) {
        let kind = String(toolName.dropFirst("create_workbench_".count))
        guard kinds.contains(kind), let data = arguments.data(using: .utf8),
              var values = try? JSONSerialization.jsonObject(with: data) as? [String: Any], values["kind"] == nil else {
            completion(.failed("未执行：工作台创建参数无效。")); return
        }
        values["kind"] = kind
        guard let encoded = try? JSONSerialization.data(withJSONObject: values), let text = String(data: encoded, encoding: .utf8) else {
            completion(.failed("未执行：工作台创建参数无效。")); return
        }
        execute(arguments: text, taskId: taskId, authorized: authorized, completion: completion)
    }
    static func execute(arguments: String, taskId: String, authorized: @escaping () -> Bool,
                        completion: @escaping (AgentRunner.ToolOutcome) -> Void) {
        queue.async { completion(perform(arguments: arguments, taskId: taskId, authorized: authorized)) }
    }
    static func perform(arguments: String, taskId: String, authorized: () -> Bool) -> AgentRunner.ToolOutcome {
        let spec: Spec
        do { spec = try parse(arguments) } catch { return .needsInput((error as? Failure)?.message ?? "内容参数无效。") }
        guard authorized(), TaskStore.task(id: taskId)?.status == .running else { return .failed("未执行：控制权已失效或任务已结束。") }
        let data = try! JSONSerialization.data(withJSONObject: ["kind": spec.kind, "body": spec.body], options: [.sortedKeys])
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let previous = TaskStore.task(id: taskId)?.workbenchOperations?[key] {
            return previous == "pending" ? .failed("结果待核对：此前创建可能已保存，不会重复创建，请查看个人工作台。") : .sent(previous)
        }
        switch request("GET", "/api/health", nil) {
        case .failure(let error): return .failed("未执行：" + error.message)
        case .success(let result):
            guard result["name"] as? String == "workbench", result["ok"] as? Bool == true else { return .failed("未执行：本机 8787 端口不是可用的个人工作台服务。") }
        }
        guard authorized() else { return .failed("未执行：控制权已失效。") }
        do {
            if let previous = try TaskStore.workbenchOperation(id: taskId, key: key) {
                return previous == "pending" ? .failed("结果待核对：不会重复创建，请查看个人工作台。") : .sent(previous)
            }
        } catch { return .failed("未执行：无法保存创建记录。") }
        var body = spec.body
        if spec.kind == "event" { body["requestId"] = taskId + ":" + key }
        let created: [String: Any]
        switch request("POST", spec.path, body) {
        case .failure(let error): return .failed("创建未核实：" + error.message + " 不会自动重试，请查看个人工作台。")
        case .success(let result): created = result
        }
        guard let number = created["id"] as? NSNumber, number.int64Value > 0 else { return .failed("创建未核实：工作台未返回有效 ID，不会重复创建。") }
        let id = number.stringValue
        guard case .success(let saved) = request("GET", spec.path + "/" + id, nil),
              (saved["id"] as? NSNumber)?.stringValue == id,
              spec.expected.allSatisfy({ key, value in
                  guard let actual = saved[key] else { return false }
                  return NSDictionary(dictionary: ["v": value]).isEqual(to: ["v": actual])
              }) else { return .failed("创建结果待核对：工作台已返回 ID \(id)，但读回内容未通过核验，不会重复创建。") }
        let receipt = "已在个人工作台创建\(spec.label)「\(spec.body["title"] as! String)」（ID：\(id)）。"
        do { _ = try TaskStore.workbenchOperation(id: taskId, key: key, receipt: receipt) }
        catch { return .failed("内容已在个人工作台保存（ID：\(id)），但本机回执保存失败，请勿重复创建。") }
        return .sent(receipt)
    }
    static func http(_ method: String, _ path: String, _ body: [String: Any]?) -> Result<[String: Any], Failure> {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: WorkbenchNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8787" + path)!)
        req.httpMethod = method; req.timeoutInterval = 15
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Failure> = .failure(Failure(message: "个人工作台请求超时。"))
        let task = session.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil, let response = response as? HTTPURLResponse, let data else {
                result = .failure(Failure(message: "无法连接个人工作台，请确认本机服务已启动。")); return
            }
            guard (200..<300).contains(response.statusCode) else {
                result = .failure(Failure(message: response.statusCode == 401 ? "个人工作台需要访问授权；当前本地连接未授权。" : "个人工作台返回 HTTP \(response.statusCode)。")); return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(Failure(message: "个人工作台返回格式异常。")); return
            }
            result = .success(object)
        }
        task.resume(); semaphore.wait()
        return result
    }
}
