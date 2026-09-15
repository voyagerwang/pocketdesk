/**
 * [INPUT]: 依赖 Foundation；不依赖 AX、Network 或任何运行时——本文件只描述任务事实的形状。
 * [OUTPUT]: 对外提供小精灵任务的类型：TaskStatus、TaskMessage、PageBinding、TaskUsage、
 *           AgentTask、TaskEvent，以及 AgentTask 与字典互转的 json/alternative 方法。
 * [POS]: Sources 的 Agent 领域模型层；HTTP 层只做字典与它的互转，任务语义不散落到路由里。
 *        与系统注入解耦：本文件可单独编译，供 tests 直接引用。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

// MARK: 状态

/// 任务状态。M1 只用到其中一部分，其余留给 M2 的写入与控制权仲裁。
///
/// `abandoned` 是 v1.1 的关键修正：M1 的 runtime 不支持真正的取消，
/// 用户点「放弃」只表示手机不再等待，**任务仍会在 Mac 上跑完**——
/// 因此它不能叫「已停止」。谎报停止会让人误以为电脑已经停下。
enum TaskStatus: String, Codable, CaseIterable {
    case accepted      // 已持久接收，尚未派发给 runtime
    case running       // 执行中
    case needsInput    // 待补充（模型反问或需要用户决定）
    case succeeded     // 已完成，有结果
    case failed        // 失败，有原因
    case abandoned     // 手机端放弃等待（Mac 上可能仍在跑）
    case verifying     // 结果待核对（断线恢复、超时后按 requestId 查账）

    /// 任务是否还在往前走——手机需要继续轮询的依据。
    var isActive: Bool {
        switch self {
        case .accepted, .running, .needsInput, .verifying: return true
        case .succeeded, .failed, .abandoned: return false
        }
    }

    /// 用户能否在同一任务上继续输入。
    var acceptsFollowUp: Bool {
        switch self {
        case .succeeded, .needsInput, .failed, .abandoned: return true
        case .accepted, .running, .verifying: return false
        }
    }

    var displayName: String {
        switch self {
        case .accepted: return "已接收"
        case .running: return "执行中"
        case .needsInput: return "待补充"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .abandoned: return "已放弃"
        case .verifying: return "结果待核对"
        }
    }
}

// MARK: 消息与来源

struct TaskMessage: Codable, Equatable {
    enum Role: String, Codable {
        case user, assistant, tool
    }
    var id: String
    var role: Role
    var text: String
    var at: Double
    /// tool 消息的工具名；user/assistant 为 nil。
    var toolName: String?

    init(id: String = UUID().uuidString, role: Role, text: String, at: Double = Date().timeIntervalSince1970, toolName: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
        self.toolName = toolName
    }
}

/// 结果引用的来源。产物只给可鉴权访问的链接（URL），不给 Mac 绝对路径。
struct TaskSource: Codable, Equatable {
    var title: String
    var url: String
    var domain: String?

    init(title: String, url: String, domain: String? = nil) {
        self.title = title
        self.url = url
        self.domain = domain
    }
}

/// 用量。读不到就整体为 unknown——不允许拿 0 冒充"用了 0 个 token"。
struct TaskUsage: Codable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var unknown: Bool

    static let none = TaskUsage(promptTokens: nil, completionTokens: nil, totalTokens: nil, unknown: true)

    init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?, unknown: Bool) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.unknown = unknown
    }

    /// 从 OpenAI 风格 usage 字典解析。字段缺失或类型不符时记 unknown，不猜。
    static func parse(_ raw: [String: Any]?) -> TaskUsage {
        guard let raw else { return .none }
        let int = { (key: String) -> Int? in
            if let value = raw[key] as? Int { return value }
            if let value = raw[key] as? Double { return Int(value) }
            if let value = raw[key] as? NSNumber { return value.intValue }
            return nil
        }
        let prompt = int("prompt_tokens")
        let completion = int("completion_tokens")
        let total = int("total_tokens") ?? (prompt.map { $0 + (completion ?? 0) })
        if prompt == nil && completion == nil && total == nil { return .none }
        return TaskUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total, unknown: false)
    }
}

// MARK: 网页绑定

/// 当前网页的绑定引用。
///
/// v1.1 修正：tabId 是**可选**的。自有 AX 方案拿不到标签页 ID，
/// 只有 tt-bridge 这类扩展才给得出；漂移校验因此以 URL + 标题为准。
struct PageBinding: Codable, Equatable {
    var browser: String
    var windowId: String?
    var tabId: String?
    var url: String
    var title: String
    var observedAt: Double

    /// 域名，用于卡片上显示"标题 · 域名"。
    var domain: String? {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 漂移判定：URL 或标题变了就算漂了（窗口/标签 ID 可能在重排后复用，不能单独作为凭据）。
    func drifted(comparedTo other: PageBinding?) -> Bool {
        guard let other else { return true }
        return url != other.url || title != other.title
    }
}

// MARK: 任务

struct AgentTask: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: String
    /// 提交去重键的主体部分（同一 requestId 由同一主体重复提交时返回原任务）。
    var subject: String
    var requestId: String
    var status: TaskStatus
    /// 每次状态或内容变更自增，动作接口用它做乐观并发。
    var revision: Int
    var createdAt: Double
    var updatedAt: Double
    /// 用户最新指令全文（追问时是最新一条，历史在 messages 里）。
    var text: String
    var context: PageBinding?
    var messages: [TaskMessage]
    var result: String?
    var sources: [TaskSource]
    var usage: TaskUsage
    var error: String?
    var attempt: Int
    /// supplement 轮数上限由 TaskService 的策略常量控制。
    var supplementCount: Int
    /// 软/硬超时到点的时刻，供轮询侧提示与停止等待。
    var softDeadline: Double?
    var hardDeadline: Double?

    init(schemaVersion: Int = AgentTask.currentSchemaVersion,
         id: String = UUID().uuidString,
         subject: String,
         requestId: String,
         status: TaskStatus = .accepted,
         revision: Int = 1,
         createdAt: Double = Date().timeIntervalSince1970,
         updatedAt: Double = Date().timeIntervalSince1970,
         text: String,
         context: PageBinding? = nil,
         messages: [TaskMessage] = [],
         result: String? = nil,
         sources: [TaskSource] = [],
         usage: TaskUsage = .none,
         error: String? = nil,
         attempt: Int = 1,
         supplementCount: Int = 0,
         softDeadline: Double? = nil,
         hardDeadline: Double? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.subject = subject
        self.requestId = requestId
        self.status = status
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = text
        self.context = context
        self.messages = messages
        self.result = result
        self.sources = sources
        self.usage = usage
        self.error = error
        self.attempt = attempt
        self.supplementCount = supplementCount
        self.softDeadline = softDeadline
        self.hardDeadline = hardDeadline
    }

    // MARK: 字典互转

    /// 转给 HTTP 层的字典。用量在 unknown 时回 null，不编造数字。
    func json() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "status": status.rawValue,
            "statusText": status.displayName,
            "revision": revision,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "text": text,
            "usage": usage.unknown ? NSNull() : (usage.json() as Any),
            "attempt": attempt,
            "supplementCount": supplementCount,
            "canFollowUp": status.acceptsFollowUp,
        ]
        if let result { dict["result"] = result }
        if let error { dict["error"] = error }
        if let softDeadline { dict["softDeadline"] = softDeadline }
        if let hardDeadline { dict["hardDeadline"] = hardDeadline }
        dict["messages"] = messages.map { message -> [String: Any] in
            var item: [String: Any] = ["id": message.id, "role": message.role.rawValue, "text": message.text, "at": message.at]
            if let toolName = message.toolName { item["toolName"] = toolName }
            return item
        }
        if !sources.isEmpty {
            dict["sources"] = sources.map { source -> [String: Any] in
                var item: [String: Any] = ["title": source.title, "url": source.url]
                if let domain = source.domain { item["domain"] = domain }
                return item
            }
        }
        if let context {
            var binding: [String: Any] = ["browser": context.browser, "url": context.url, "title": context.title, "observedAt": context.observedAt]
            if let windowId = context.windowId { binding["windowId"] = windowId }
            if let tabId = context.tabId { binding["tabId"] = tabId }
            if let domain = context.domain { binding["domain"] = domain }
            dict["context"] = binding
        }
        return dict
    }

    static func decode(from dict: [String: Any]) -> AgentTask? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(AgentTask.self, from: data)
    }
}

extension TaskUsage {
    func json() -> [String: Any] {
        var dict: [String: Any] = ["unknown": unknown]
        if let promptTokens { dict["promptTokens"] = promptTokens }
        if let completionTokens { dict["completionTokens"] = completionTokens }
        if let totalTokens { dict["totalTokens"] = totalTokens }
        return dict
    }
}

// MARK: 事件

/// 单调事件序列里的一条。手机按 seq 增量补取，缺口时回退到刷新快照。
struct TaskEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case status
        case assistant
        case tool
        case error
        case usage
    }
    var seq: Int
    var taskId: String
    var at: Double
    var kind: Kind
    var status: TaskStatus?
    var text: String?

    init(seq: Int, taskId: String, kind: Kind, status: TaskStatus? = nil, text: String? = nil,
         at: Double = Date().timeIntervalSince1970) {
        self.seq = seq
        self.taskId = taskId
        self.kind = kind
        self.status = status
        self.text = text
        self.at = at
    }

    func json() -> [String: Any] {
        var dict: [String: Any] = ["seq": seq, "taskId": taskId, "at": at, "kind": kind.rawValue]
        if let status { dict["status"] = status.rawValue }
        if let text { dict["text"] = text }
        return dict
    }
}
