/**
 * [INPUT]: 依赖 Foundation，消费 ModelConfig/ModelClient 与 PageReader 的只读页面内容。
 * [OUTPUT]: 对外提供 AgentRunner.run——跑完一次「模型 ↔ 本地工具」循环，产出回答、用量与错误分类。
 * [POS]: Sources 的 Agent 执行层：**工具永远由 PocketDesk 本地执行**，模型只能发起 read_page 请求，
 *        拿到的结果由本文件回传，模型不能直接操作电脑（方案 §8.1）。
 *        M1 只开放只读工具；写入类工具一律不在这里出现，等 M2 的写入仲裁建立后再加。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum AgentRunner {
    /// 单次任务内的工具循环轮数上限。超过就带着已有内容收尾，不无限烧 token。
    static let maxToolRounds = 6
    static let requestTimeoutSeconds: Double = 90

    struct Outcome {
        var content: String?
        var usage: TaskUsage
        var error: String?
        /// 本次实际读到的页面，用来作为结果来源引用。
        var pages: [PageContent]
        var rounds: Int
        /// 页面漂移：提交时绑定的页面与执行时读到的不是同一页，必须如实告知。
        var drifted: Bool
    }

    // 只声明一个只读工具。工具集在这里写死在 PocketDesk 侧，
    // 不接受模型或请求体自定义工具（方案 §9：body 中不接受不受限制的工具定义）。
    static let tools: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": "read_page",
            "description": "读取用户电脑当前浏览器正在显示的网页，返回标题、网址与正文。只有用户明确提到网页、当前页面或需要页面内容时才调用。",
            "parameters": ["type": "object", "properties": [:], "required": []] as [String: Any],
        ] as [String: Any],
    ]]

    private static let systemPrompt = """
    你是 PocketDesk 的小精灵，运行在用户的 Mac 上，用户用手机和你对话。
    约束：
    - 只能依据工具返回的真实内容回答；工具没返回的内容不要编造，也不要凭常识杜撰页面细节。
    - 需要网页内容时调用 read_page，它返回用户电脑当前浏览器页面的标题、网址与正文。
    - 读不到内容就如实说明读不到，并说明可能的原因（前台不是浏览器、页面没加载完、没有辅助功能授权）。
    - 回答用中文，先给结论再给要点，控制长度，方便手机上读。
    - 不要输出 HTML、脚本或 Markdown 代码块围栏以外的内容。
    """

    /// 跑一次任务循环。回调可能在任意线程；调用方自行切队列。
    ///
    /// - Parameters:
    ///   - task: 已持久的任务，只读取 text/context，不在此处修改。
    ///   - readPage: 注入的页面读取实现，便于测试与后续替换成 tt-bridge。
    static func run(config: ModelConfig, task: AgentTask,
                    readPage: @escaping () -> Result<PageContent, PageReaderError> = { PageReader.currentPage() },
                    completion: @escaping (Outcome) -> Void) {
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        var pages: [PageContent] = []
        var drifted = false

        // 首个能力是「总结当前网页」，所以无条件先读一次：
        // 既给模型现成上下文，也用同一份结果做漂移校验，不读第二次。
        var userText = task.text
        switch readPage() {
        case .success(let page):
            pages.append(page)
            if let bound = task.context, page.binding.drifted(comparedTo: bound) { drifted = true }
            let body = page.text.count > 20000 ? String(page.text.prefix(20000)) : page.text
            userText += "\n\n【电脑当前网页】\n标题：\(page.binding.title)\n网址：\(page.binding.url)\n正文：\n\(body)"
        case .failure(let failure):
            // 读不到页面不直接判定任务失败：用户可能只是想问个普通问题。
            // 把原因写进上下文，让模型如实说明，而不是假装读过网页。
            userText += "\n\n【电脑当前网页】读取失败：\(failure.localizedDescription)"
        }
        messages.append(["role": "user", "content": userText])

        step(config: config, messages: messages, pages: pages, drifted: drifted, round: 0,
             accumulated: .none, readPage: readPage, completion: completion)
    }

    private static func step(config: ModelConfig, messages: [[String: Any]], pages: [PageContent],
                             drifted: Bool, round: Int, accumulated: TaskUsage,
                             readPage: @escaping () -> Result<PageContent, PageReaderError>,
                             completion: @escaping (Outcome) -> Void) {
        guard round < maxToolRounds else {
            completion(Outcome(content: nil, usage: accumulated, error: "工具调用轮数达到上限（\(maxToolRounds) 轮），已停止。", pages: pages, rounds: round, drifted: drifted))
            return
        }
        ModelClient.send(config: config, messages: messages, tools: tools, timeoutSeconds: requestTimeoutSeconds) { result in
            switch result {
            case .failure(let failure):
                completion(Outcome(content: nil, usage: accumulated, error: failure.message, pages: pages, rounds: round, drifted: drifted))
            case .success(let turn):
                let usage = merge(accumulated, TaskUsage.parse(turn.usage))
                var history = messages
                if let raw = turn.rawMessage { history.append(raw) }
                guard let calls = turn.toolCalls, !calls.isEmpty else {
                    guard let content = turn.content, !content.isEmpty else {
                        completion(Outcome(content: nil, usage: usage, error: "模型返回了空回答。", pages: pages, rounds: round, drifted: drifted))
                        return
                    }
                    completion(Outcome(content: content, usage: usage, error: nil, pages: pages, rounds: round, drifted: drifted))
                    return
                }
                var collected = pages
                for call in calls {
                    let callId = call["id"] as? String ?? ""
                    let name = (call["function"] as? [String: Any])?["name"] as? String ?? ""
                    let payload = Self.executeTool(name: name, readPage: readPage, pages: &collected)
                    history.append(["role": "tool", "tool_call_id": callId, "content": payload])
                }
                step(config: config, messages: history, pages: collected, drifted: drifted, round: round + 1,
                     accumulated: usage, readPage: readPage, completion: completion)
            }
        }
    }

    /// 本地执行工具。M1 只有 read_page 一个只读工具；未知工具名明确回错，不静默忽略。
    private static func executeTool(name: String, readPage: () -> Result<PageContent, PageReaderError>,
                                    pages: inout [PageContent]) -> String {
        guard name == "read_page" else {
            return "不支持的工具：\(name)。当前只有 read_page 可用。"
        }
        switch readPage() {
        case .success(let page):
            if !pages.contains(where: { $0.binding.url == page.binding.url && $0.binding.title == page.binding.title }) {
                pages.append(page)
            }
            var text = "标题：\(page.binding.title)\n网址：\(page.binding.url)\n正文：\n\(page.text)"
            if page.truncated { text += "\n（正文超出长度上限已截断）" }
            return text
        case .failure(let failure):
            return "读取失败：\(failure.localizedDescription)"
        }
    }

    /// 用量累加。任何一轮读不到就整体 unknown——半份用量冒充总数比不报更糟。
    private static func merge(_ a: TaskUsage, _ b: TaskUsage) -> TaskUsage {
        if a.unknown || b.unknown { return .none }
        let prompt = (a.promptTokens ?? 0) + (b.promptTokens ?? 0)
        let completion = (a.completionTokens ?? 0) + (b.completionTokens ?? 0)
        let total = (a.totalTokens ?? 0) + (b.totalTokens ?? 0)
        return TaskUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total, unknown: false)
    }
}
