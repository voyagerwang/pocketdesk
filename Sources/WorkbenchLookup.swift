/**
 * [INPUT]: 工作台只读查询 API、AgentRunner 任务和控制租约。
 * [OUTPUT]: 日程/随手记/知识库检索与分段正文读取；始终 GET，不创建业务内容。
 * [POS]: PocketDesk 查询适配；日期、分页、ID/版本凭证固定映射，不让模型指定路径。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md。
 */
import Foundation
import CoreFoundation

enum WorkbenchLookup {
    static let kinds = ["tasks", "events", "notes", "knowledge"]
    static let names = kinds.map { "search_workbench_" + $0 } + ["read_workbench_task", "read_workbench_event", "read_workbench_note", "read_workbench_knowledge"]
    static let tools: [[String: Any]] = names.map { name in
        let search = name.hasPrefix("search_")
        let knowledge = name.hasSuffix("knowledge")
        let tasks = name.hasSuffix("tasks") || name.hasSuffix("task")
        let events = name.hasSuffix("events") || name.hasSuffix("event")
        let label = knowledge ? "知识库" : tasks ? "待办" : events ? "日程" : "随手记"
        var properties: [String: Any] = [:]
        var required: [String] = []
        let description: String
        if search {
            properties["query"] = ["type": "string", "description": "提炼内容关键词，不含查询指令；不填则列出最近记录（日程按日期范围）"]
            properties["limit"] = ["type": "integer", "minimum": 1, "maximum": 20]
            if !knowledge { properties["offset"] = ["type": "integer", "minimum": 0, "description": "分页使用上一页 nextOffset"] }
            if events || tasks {
                for key in ["from", "to"] { properties[key] = ["type": "string", "description": "本机日期 YYYY-MM-DD，起止日均包含；用户说今天/明天时 from 和 to 都填对应日期"] }
            }
            description = "查询个人工作台已有的" + label + "。" + (events ? "支持日期范围（不填为今天起7天）、标题/地点/正文关键词，包含跨日重叠日程。" : tasks ? "支持计划日期/截止时间范围、标题/正文关键词；只返回未删除的待办。" : knowledge ? "复用本地资料与知识版本检索；结果含片段与 readGrant，可继续读正文。未命中不等于未收录，未抓取正文不能冒充已读。" : "搜索标题、正文和标签；不填关键词列出最近记录。") + "返回有界结果，分页或摘要不等于全部内容；不联网、不创建内容。"
        } else {
            let key = knowledge ? "readGrant" : "id"
            properties[key] = ["type": "string", "description": knowledge ? "必须原样使用知识库搜索返回的 readGrant；过期重新搜索" : "必须使用检索结果的真实记录 ID，不按名称猜 ID"]
            required = [key]
            properties["offset"] = ["type": "integer", "minimum": 0, "description": "首段为0；续读用返回的 range.to"]
            properties["limit"] = ["type": "integer", "minimum": 1, "maximum": 12000]
            description = "读取个人工作台已有" + label + "的正文。仅使用检索返回的 ID 或版本凭证；返回范围与是否截断，未读全文不称已完整阅读。知识整理结果与原文按 content_kind 区分。"
        }
        return ["type": "function", "function": ["name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]]
    }
    private static let queue = DispatchQueue(label: "PocketDesk.workbench.lookup")
    static var request = WorkbenchContent.http
    static func path(name: String, arguments: String) throws -> String {
        guard names.contains(name), let data = arguments.data(using: .utf8), data.count <= 8000,
              let values = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = tools.first(where: { ($0["function"] as? [String: Any])?["name"] as? String == name }),
              let function = tool["function"] as? [String: Any], let schema = function["parameters"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any], Set(values.keys).isSubset(of: Set(properties.keys)) else {
            throw WorkbenchContent.Failure(message: "查询参数无效。")
        }
        for key in schema["required"] as? [String] ?? [] {
            guard let value = values[key] as? String, !value.isEmpty else { throw WorkbenchContent.Failure(message: "请先检索，再用结果中的记录标识读取。") }
        }
        var items: [URLQueryItem] = []
        for key in values.keys.sorted() {
            let value = values[key]!
            if value is NSNull { continue }
            let text: String
            if ["offset", "limit"].contains(key) {
                let max = key == "limit" ? (name.hasPrefix("read_") ? 12000 : 20) : (name.hasPrefix("read_") ? 10000000 : 10000)
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= (key == "limit" ? 1 : 0), number.doubleValue <= Double(max) else { throw WorkbenchContent.Failure(message: "查询分页参数无效。") }
                text = number.stringValue
            } else {
                guard let string = value as? String else { throw WorkbenchContent.Failure(message: "查询参数类型无效。") }
                text = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if ["from", "to"].contains(key), !WorkbenchContent.validDate(text, day: true) { throw WorkbenchContent.Failure(message: "日期需为准确的 YYYY-MM-DD。") }
                if key == "query", text.count > 200 { throw WorkbenchContent.Failure(message: "请缩短查询关键词。") }
                if key == "id", text.range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) == nil { throw WorkbenchContent.Failure(message: "记录 ID 无效。") }
                if key == "readGrant", UUID(uuidString: text) == nil { throw WorkbenchContent.Failure(message: "读取凭证无效，请重新检索。") }
            }
            items.append(URLQueryItem(name: key, value: text))
        }
        var components = URLComponents()
        if name.hasPrefix("search_workbench_") { components.path = "/api/pocketdesk/lookup/" + name.replacingOccurrences(of: "search_workbench_", with: "") }
        else {
            components.path = "/api/pocketdesk/lookup/read"
            items.append(URLQueryItem(name: "kind", value: name.replacingOccurrences(of: "read_workbench_", with: "")))
        }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let path = components.string else { throw WorkbenchContent.Failure(message: "查询地址编码失败。") }
        return path
    }
    static func execute(name: String, arguments: String, taskId: String, authorized: @escaping () -> Bool,
                        completion: @escaping (Result<String, WorkbenchContent.Failure>) -> Void) {
        queue.async { completion(perform(name: name, arguments: arguments, taskId: taskId, authorized: authorized)) }
    }
    static func perform(name: String, arguments: String, taskId: String, authorized: () -> Bool) -> Result<String, WorkbenchContent.Failure> {
        do {
            let path = try path(name: name, arguments: arguments)
            guard authorized(), TaskStore.task(id: taskId)?.status == .running else { throw WorkbenchContent.Failure(message: "查询未执行：控制权已失效或任务已结束。") }
            let health = try request("GET", "/api/health", nil).get()
            guard health["name"] as? String == "workbench", health["ok"] as? Bool == true else { throw WorkbenchContent.Failure(message: "本机工作台服务不可用。") }
            guard authorized(), TaskStore.task(id: taskId)?.status == .running else { throw WorkbenchContent.Failure(message: "查询未执行：控制权已失效。") }
            let result = try request("GET", path, nil).get()
            guard result["source"] as? String == "personal_workbench", name.hasPrefix("read_") ? result["document"] is [String: Any] : result["results"] is [Any] else {
                throw WorkbenchContent.Failure(message: "工作台查询回执格式异常，不能判定为未找到。")
            }
            return .success(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        } catch { return .failure((error as? WorkbenchContent.Failure) ?? .init(message: "工作台查询参数或回执无效。")) }
    }
}
