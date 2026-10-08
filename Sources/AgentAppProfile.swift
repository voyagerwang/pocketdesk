/**
 * [INPUT]: 消费 TargetConfig 的应用身份与 Foundation 的包元数据。
 * [OUTPUT]: Cue 身份与原生任务语义；提供项目路径预填与已有任务 ID 的官方 Codex 深链；提供 AgentConversationMode、AgentAppProfile 与新任务页面证据判断；兼容 WorkBuddy 旧版及 5.7.6 空框提示的 AX 空白差异，非占位草稿仍拒绝。
 * [POS]: 派单的纯策略层；应用名称只作别名，真实 bundle ID 决定适配器，界面动作由 AgentTaskComposer 执行。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum AgentConversationMode: String {
    case newTask = "new"
    case current = "current"
}

enum AgentAppProfile: String {
    case codex, workbuddy, cola, zcode, chatgpt, cue

    static func canonicalName(_ name: String) -> String {
        let compact = name.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        if compact == "workbody" { return "workbuddy" }
        return compact == "coe" ? "cue" : compact
    }

    static func resolve(_ target: TargetConfig) -> Self? {
        let bundle = target.path.flatMap { Bundle(path: $0)?.bundleIdentifier } ?? target.bundleID
        switch bundle {
        case "com.openai.codex": return .codex
        case "com.tencent.workbuddy.mac": return .workbuddy
        case "ai.colaos.desktop": return .cola
        case "dev.zcode.app": return .zcode
        case "com.openai.chat": return .chatgpt
        case "ai.manus.agents": return .cue
        case nil: return Self(rawValue: canonicalName(target.name))
        default: return nil
        }
    }

    var newButtonNames: Set<String> {
        switch self {
        case .workbuddy, .zcode: return ["新建任务", "New task"]
        case .cola: return ["新建会话", "New session"]
        case .cue: return ["Create group chat"]
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
        // Cue 1.0.8 的空白 contenteditable 将完整占位文字暴露为 AXValue。
        if self == .cue { return content == "Message Cue" }
        if self == .workbuddy {
            // 5.7.6 的 contenteditable 仍将提示文字暴露为 AXValue，且 ?/@、/ 后
            // 的空白与旧版不同。只允许两种已核验的完整提示，不用包含匹配吞掉草稿。
            let knownHints = [
                "今天帮你做些什么？@引用对话文件，/调用技能与指令",
                "今天帮你做些什么？@添加上下文，/调用技能与指令",
            ]
            return knownHints.contains(content.filter { !$0.isWhitespace })
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
        case .cue:
            return false // Cue 必须核验新群聊 URL，旧页面同名标题不足以证明新建。
        }
    }

    static func codexURL(text: String, projectPath: String? = nil) -> URL? {
        if let projectPath, !projectPath.hasPrefix("/") || projectPath.contains("\0") { return nil }
        var url = URLComponents()
        url.scheme = "codex"; url.host = "threads"; url.path = "/new"
        url.queryItems = [URLQueryItem(name: "prompt", value: text)]
        if let projectPath { url.queryItems?.append(URLQueryItem(name: "path", value: projectPath)) }
        return url.url
    }

    static func codexThreadURL(id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        var url = URLComponents()
        url.scheme = "codex"; url.host = "threads"; url.path = "/" + id
        return url.url
    }
}
