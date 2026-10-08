/**
 * [INPUT]: WorkBuddy/ZCode 专属动作 JSON 与当前项目菜单候选。
 * [OUTPUT]: 固定 list/new/open/send 协议与准确名称匹配；空正文、多候选和操作项不冒充项目。
 * [POS]: 原生项目适配的纯策略，不读桌面或执行输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

struct AgentWorkspaceRequest: Codable {
    enum Action: String, Codable, CaseIterable {
        case listProjects = "list_projects", newTask = "new_task", openProject = "open_project", sendTask = "send_task"
    }
    let app: String
    let action: Action
    var project: String?
    var text: String?
    var appKey: String { Self.appKey(app)! }
    static func appKey(_ value: String) -> String? {
        let key = value.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        if key == "workbuddy" || key == "workbody" { return "workbuddy" }
        return key == "zcode" ? key : nil
    }
    static func parse(_ text: String) -> Self? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["app", "action", "project", "text"]),
              let request = try? JSONDecoder().decode(Self.self, from: data), appKey(request.app) != nil,
              request.project == nil || (!request.project!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.project!.count <= 500),
              request.action == .openProject ? request.project != nil : true,
              request.action != .listProjects || request.project == nil,
              request.action == .sendTask
                ? (request.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && (request.text?.utf16.count ?? 0) <= 8000)
                : request.text == nil else { return nil }
        return request
    }
    static let tool: [String: Any] = ["type": "function", "function": [
        "name": "agent_workspace",
        "description": "WorkBuddy（Workbody）和 ZCode 的专属项目/新任务动作。list_projects 打开原生新建页的项目选择器读取实际已有项目；new_task 只打开空白新任务页，可指定 project；open_project 在已有项目/工作空间打开空白新任务页；send_task 新建并发送正文，可指定 project。项目按原生菜单准确名称选择，多候选等用户选。不会创建目录、改模型/权限/分支或覆盖旧草稿。只打开不发送；有派任务/发送要求才 send_task。",
        "parameters": ["type": "object", "properties": [
            "app": ["type": "string", "enum": ["WorkBuddy", "Workbody", "ZCode", "Z code"]],
            "action": ["type": "string", "enum": Action.allCases.map(\.rawValue)],
            "project": ["type": "string", "description": "原生选择器中的已有项目/工作空间准确名称"],
            "text": ["type": "string", "description": "仅 send_task 使用，保留用户正文和约束"]
        ], "required": ["app", "action"], "additionalProperties": false]
    ]]
}

enum AgentWorkspacePolicy {
    static let excluded: Set<String> = ["打开文件夹", "打开本地文件夹", "新建工作空间", "远程连接", "不在项目中工作", "Open folder", "Open local folder", "New workspace", "Remote connection", "No project"]
    static func matches(_ query: String, labels: [String]) -> [Int] {
        func key(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let query = key(query)
        return labels.indices.filter { !excluded.contains(labels[$0]) && key(labels[$0]) == query }
    }
    static func uniqueSelected(_ project: String, labels: [String], values: [String?]) -> Bool {
        let indices = matches(project, labels: labels)
        return indices.count == 1 && values.indices.contains(indices[0]) && ["1", "true"].contains(values[indices[0]] ?? "")
    }
}
