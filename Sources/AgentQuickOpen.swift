/**
 * [INPUT]: 消费 AgentTask 的初次输入边界、TaskStore 的同主体成功任务、AppOperator 准确解析、ChromeBookmarks 实时名称与 AgentRunner 注入的打开执行器和控制租约。
 * [OUTPUT]: 识别完整单句打开候选及有限确认前缀；明确网址、准确应用、唯一准确书签与近30天有真实成功回执的唯一历史网址免模型执行；冲突/复合/补充输入交还模型。
 * [POS]: Sources 的 AgentRunner 快速打开分支；当前应用与书签优先，历史只复用显式完成的稳定网址；复用已有执行器和 TaskStore，不维护第二套应用别名或网站地址，不读取无关网页。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CoreFoundation
import Foundation

enum AgentQuickOpen {
    static let completionParameter = ["type": "boolean", "description": "仅此次打开已满足用户全部目标时为 true，如打开百度；打开百度查天气、打开飞书查看消息等还有后续动作必须 false。缺省 false，成功回执才可完成任务。"]

    static func completesTask(_ arguments: String) -> Bool {
        guard let data = arguments.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flag = values["completesTask"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
        return flag.boolValue
    }

    static func target(for task: AgentTask) -> String? {
        guard task.attempt == 1, task.supplementCount == 0, task.context == nil else { return nil }
        return target(in: task.text)
    }

    /// 只产生保守的打开候选；本机准确目标或模型明确完成声明才可收尾。
    static func target(in text: String) -> String? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(?:(?:好的|好|嗯)\\s*[，,]\\s*)?(?:(?:请(?:你)?|帮我|麻烦(?:你)?)\\s*)?(?:打开|启动)(?:一下)?\\s*(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input) else { return nil }
        var target = String(input[range]).trimmingCharacters(in: .whitespaces)
        // 网址中的 ASCII 标点可能属于查询/路径，不做口语后缀清洗。
        if target.lowercased().hasPrefix("http://") || target.lowercased().hasPrefix("https://") {
            return url(target) == nil ? nil : target
        }
        target = target.trimmingCharacters(in: CharacterSet(charactersIn: "。！!"))
        for suffix in ["一下", "吧", "呀", "啊"] where target.hasSuffix(suffix) {
            target.removeLast(suffix.count)
            break
        }
        target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, target.count <= 80,
              target.rangeOfCharacter(from: CharacterSet(charactersIn: "，,；;：:\n\r。！？!?、\"“”")) == nil,
              !["然后", "并", "再", "同时", "和", "以及", "或者", "不要", "别", "吗", "么", "能否", "可以", "怎么", "如何", "搜索", "总结", "查找", "项目", "工作空间", "工作区", "任务", "对话", "聊天"].contains(where: target.contains)
        else { return nil }
        return target
    }

    static func url(_ target: String) -> String? {
        guard target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: target), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              target.rangeOfCharacter(from: CharacterSet(charactersIn: "，；、。！？“”")) == nil,
              !target.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { return nil }
        return url.absoluteString
    }

    // MARK: - 历史打开证据

    /// 只复用同一主体的准确名称；不同地址是歧义，不用最新记录覆盖旧证据。
    static func historicalURL(for task: AgentTask, history: [AgentTask], now: TimeInterval) -> String? {
        guard task.transcript?.isEmpty != false, let target = target(for: task), url(target) == nil else { return nil }
        let name = ChromeBookmarks.normalized(target)
        let cutoff = now - Double(TaskStore.defaultRetentionDays) * 86400
        var addresses = Set<String>()
        for record in history {
            guard record.subject == task.subject, record.status == .succeeded, record.error == nil,
                  record.updatedAt >= cutoff, record.updatedAt <= now,
                  record.sources.isEmpty, record.appDispatchReceipt == nil,
                  let previousTarget = self.target(for: record), ChromeBookmarks.normalized(previousTarget) == name,
                  let address = completedPageURL(record) else { continue }
            addresses.insert(address)
            if addresses.count > 1 { return nil }
        }
        return addresses.count == 1 ? addresses.first : nil
    }

    /// 工具请求与回执按调用 ID 配对；助手文案不能证明网页真的被提交打开。
    private static func completedPageURL(_ task: AgentTask) -> String? {
        guard let transcript = task.transcript else { return nil }
        let inputs = transcript.filter { $0["role"] as? String == "user" }
        guard inputs.count == 1, inputs.first?["content"] as? String == task.text else { return nil }
        var receipts: [String: String] = [:]
        for message in transcript where message["role"] as? String == "tool" {
            guard let id = message["tool_call_id"] as? String, !id.isEmpty,
                  let payload = message["content"] as? String, receipts[id] == nil else { return nil }
            receipts[id] = payload
        }
        var callIDs = Set<String>()
        var address: String?
        for message in transcript where message["role"] as? String == "assistant" {
            guard let calls = message["tool_calls"] as? [[String: Any]] else { continue }
            for call in calls {
                guard let id = call["id"] as? String, !id.isEmpty, callIDs.insert(id).inserted,
                      let payload = receipts[id], let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { return nil }
                switch name {
                case "search_web", "search_bookmarks": break
                case "open_target":
                    guard payload.hasPrefix("未打开") || payload.hasPrefix("未执行") else { return nil }
                case "open_page":
                    guard address == nil, calls.count == 1,
                          let arguments = function["arguments"] as? String, completesTask(arguments),
                          payload.hasPrefix("已向默认浏览器提交打开网页请求"),
                          let data = arguments.data(using: .utf8),
                          let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let raw = values["url"] as? String, let stable = stableURL(raw) else { return nil }
                    address = stable
                default: return nil
                }
            }
        }
        guard callIDs.count == receipts.count else { return nil }
        return address
    }

    /// 搜索结果页、签名地址和登录回调可能过期；不把查询与片段地址学成名称路由。
    private static func stableURL(_ raw: String) -> String? {
        guard let address = url(raw), var components = URLComponents(string: address),
              components.query == nil, components.fragment == nil else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.url?.absoluteString
    }
}

extension AgentRunner {
    private enum QuickOpening {
        case page(String), app(display: String, path: String), bookmark(String)
    }

    /// 返回 false 表示没有确定目标，原模型循环继续；一旦动手不再回退重开。
    static func tryQuickOpening(task: AgentTask, completion: @escaping (Outcome) -> Void) -> Bool {
        guard task.transcript?.isEmpty != false, let target = AgentQuickOpen.target(for: task) else { return false }
        let opening: QuickOpening
        if let url = AgentQuickOpen.url(target) {
            opening = .page(url)
        } else if let app = resolveQuickApp(target) {
            opening = .app(display: app.display, path: app.path)
        } else {
            guard !isLocalCodexName(target) else { return false }
            let entries = (try? readBookmarks()) ?? []
            let exact = entries.filter { $0.url != nil && ChromeBookmarks.normalized($0.name) == ChromeBookmarks.normalized(target) }
            if exact.count > 1 { return false }
            if let bookmark = exact.first {
                opening = .bookmark(bookmark.id)
            } else if let address = AgentQuickOpen.historicalURL(for: task, history: TaskStore.all(), now: Date().timeIntervalSince1970) {
                opening = .page(address)
            } else { return false }
        }
        func finish(_ payload: String, error: Bool = false, prerequisite: Bool = false) {
            if var current = TaskStore.task(id: task.id), current.status == .running, current.attempt == task.attempt {
                current.transcript = [["role": "user", "content": task.text], ["role": "assistant", "content": payload]]
                try? TaskStore.save(current)
            }
            completion(Outcome(content: error ? nil : payload,
                usage: TaskUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0, unknown: false),
                error: error ? payload : nil, pages: [], rounds: 0, drifted: false,
                recovery: error ? .init(kind: prerequisite ? .prerequisite : .executionFailure) : nil))
        }
        guard let current = TaskStore.task(id: task.id), current.status == .running, current.attempt == task.attempt else {
            finish("任务已结束，不再执行打开操作。", error: true); return true
        }
        guard canControl(task.id) else {
            finish("未执行：手机控制权已失效，请重新连接后下达指令。", error: true, prerequisite: true); return true
        }
        switch opening {
        case .page(let url):
            switch openPage(url) {
            case .success: finish("已向默认浏览器提交打开网页请求。")
            case .failure(let error): finish("未打开：" + error.localizedDescription, error: true)
            }
        case .app(let display, let path):
            switch openApp(path) {
            case .success: finish("已向系统提交打开应用请求：" + display)
            case .failure(let error): finish("未打开：" + error.localizedDescription, error: true)
            }
        case .bookmark(let id):
            openBookmark(id) { payload in finish(payload, error: !payload.hasPrefix("已向")) }
        }
        return true
    }
}
