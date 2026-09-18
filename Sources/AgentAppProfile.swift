/**
 * [INPUT]: 消费 TargetConfig 的应用身份与 Foundation 的包元数据。
 * [OUTPUT]: 提供 AgentConversationMode、AgentAppProfile 与新任务页面证据判断。
 * [POS]: 派单的纯策略层；应用名称只作别名，真实 bundle ID 决定适配器，界面动作由 AgentTaskComposer 执行。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum AgentConversationMode: String {
    case newTask = "new"
    case current = "current"
}

enum AgentAppProfile: String {
    case codex, workbuddy, cola, zcode, chatgpt

    static func canonicalName(_ name: String) -> String {
        let compact = name.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        return compact == "workbody" ? "workbuddy" : compact
    }

    static func resolve(_ target: TargetConfig) -> Self? {
        let bundle = target.path.flatMap { Bundle(path: $0)?.bundleIdentifier } ?? target.bundleID
        switch bundle {
        case "com.openai.codex": return .codex
        case "com.tencent.workbuddy.mac": return .workbuddy
        case "ai.colaos.desktop": return .cola
        case "dev.zcode.app": return .zcode
        case "com.openai.chat": return .chatgpt
        case nil: return Self(rawValue: canonicalName(target.name))
        default: return nil
        }
    }

    var newButtonNames: Set<String> {
        switch self {
        case .workbuddy, .zcode: return ["新建任务", "New task"]
        case .cola: return ["新建会话", "New session"]
        case .codex, .chatgpt: return ["新建任务", "新聊天", "New chat", "New task", "New thread"]
        }
    }

    // 除不可见占位字符外不删除正文；不拿整页内容或模糊包含匹配冒充空输入框。
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isEmptyComposer(value: String?, placeholder: String?) -> Bool {
        guard let value else { return false }
        let content = Self.clean(value)
        if content.isEmpty { return true }
        if self == .workbuddy {
            return content == "今天帮你做些什么？ @ 引用对话文件，/ 调用技能与指令"
        }
        return false
    }

    func hasNewPageEvidence(labels: Set<String>, selectedNewTab: Bool,
                            placeholder: String, beforeLabels: Set<String>) -> Bool {
        switch self {
        case .workbuddy:
            return selectedNewTab && labels.contains("WorkBuddy, 我帮你")
        case .zcode:
            return placeholder.hasPrefix("向 ZCode 提问") && labels.contains("选择项目")
        case .cola:
            return labels.contains("新建会话") && labels.subtracting(beforeLabels).contains {
                $0.hasPrefix("新建会话 草稿") || $0.hasPrefix("New session Draft")
            }
        case .chatgpt:
            return labels.contains("有什么可以帮忙的？") || labels.contains("What can I help with?")
        case .codex:
            return false // 官方深链用预填正文精确读回核验，不猜页面标题。
        }
    }

    static func codexURL(text: String) -> URL? {
        var url = URLComponents()
        url.scheme = "codex"; url.host = "threads"; url.path = "/new"
        url.queryItems = [URLQueryItem(name: "prompt", value: text)]
        return url.url
    }
}
