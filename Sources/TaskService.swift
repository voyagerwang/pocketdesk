/**
 * [INPUT]: 依赖 Foundation，消费 TaskStore、AgentRunner、ModelConfigStore、PageReader。
 * [OUTPUT]: 提交幂等查账并保存执行控制会话；对外提供任务生命周期：submit/supplement/abandon/snapshot、当前网页绑定查询、执行器能力报告。
 * [POS]: Sources 的 Agent 服务层：唯一决定任务状态如何流转的地方，HTTP 层不做状态判断。
 *        首版串行执行一个活动任务；飞书候选选择通过 needsInput 续接，状态里没有「已停止」这种会骗人的说法。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum TaskServiceError: LocalizedError {
    case emptyText
    case textTooLarge(limit: Int)
    case notConfigured
    case busy(taskId: String)
    case notFound
    case notFollowUp(status: TaskStatus)
    case supplementLimitReached(Int)
    case revisionMismatch

    var errorDescription: String? {
        switch self {
        case .emptyText: return "请先输入内容再发送。"
        case .textTooLarge(let limit): return "内容超过 \(limit / 1024) KiB，请精简后再发。"
        case .notConfigured: return "还没有配置模型服务：请在这台 Mac 的控制台「小精灵 · 模型服务」里填好并测试通过。"
        case .busy(let taskId): return "已有任务在执行中（\(taskId)），请先等它结束或放弃它。"
        case .notFound: return "找不到这个任务。"
        case .notFollowUp(let status): return "任务当前状态是「\(status.displayName)」，暂时不能做这个操作。"
        case .supplementLimitReached(let limit): return "这个任务已经补充 \(limit) 轮，请开一个新任务。"
        case .revisionMismatch: return "任务已被更新，请刷新后再操作。"
        }
    }
}

enum TaskService {
    /// 轮询与超时默认值（方案 §9 v1.1）：集中在这里，控制台与设置面板都从同一处取。
    static let pollIntervalSeconds: Double = 2
    static let pollBackoffFactor: Double = 1.5
    static let pollMaxIntervalSeconds: Double = 10
    static let softTimeoutSeconds: Double = 300
    static let hardTimeoutSeconds: Double = 600
    static let supplementLimit = 5
    static let maxInputBytes = 16 * 1024

    private static let queue = DispatchQueue(label: "dev.voicedeck.agent.tasks")
    private static var activeTaskId: String?
    private static let submissionLock = NSLock()

    /// 当前主体是否仍有任务在推进。
    /// 用按主体扫描替代不可靠的 activeTaskId 内存标记：execute 的串行队列会让
    /// activeTaskId 在异步 run 启动后立即被 defer 清空，单看它无法拦住并发提交。
    private static func blockingActiveTask(excluding taskId: String? = nil, subject: String) -> AgentTask? {
        TaskStore.all().first { $0.subject == subject && $0.status.isActive && (taskId == nil || $0.id != taskId) }
    }

    // MARK: 提交与执行

    static func submit(subject: String, requestId: String, text: String, context: PageBinding?, controlSession: String? = nil) throws -> AgentTask {
        submissionLock.lock(); defer { submissionLock.unlock() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskServiceError.emptyText }
        guard trimmed.utf8.count <= maxInputBytes else { throw TaskServiceError.textTooLarge(limit: maxInputBytes) }
        guard ModelConfigStore.load().isConfigured else { throw TaskServiceError.notConfigured }
        // 同一请求重试直接查账，不能重新排入执行队列。
        if let existing = TaskStore.task(subject: subject, requestId: requestId) {
            guard existing.text == trimmed && existing.context == context else { throw TaskServiceError.revisionMismatch }
            return existing
        }
        if let blocking = blockingActiveTask(subject: subject) {
            throw TaskServiceError.busy(taskId: blocking.id)
        }
        var task = try TaskStore.claim(subject: subject, requestId: requestId, text: trimmed, context: context)
        task.controlSession = controlSession
        try TaskStore.save(task)
        queue.async { execute(taskId: task.id) }
        return task
    }

    /// 追问/补充：沿用同一 taskId，历史消息一起回放，不读取错误页面。
    static func supplement(taskId: String, text: String, expectedRevision: Int?) throws -> AgentTask {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskServiceError.emptyText }
        guard trimmed.utf8.count <= maxInputBytes else { throw TaskServiceError.textTooLarge(limit: maxInputBytes) }
        guard var task = TaskStore.task(id: taskId) else { throw TaskServiceError.notFound }
        if let expectedRevision, expectedRevision != task.revision { throw TaskServiceError.revisionMismatch }
        guard task.status.acceptsFollowUp else { throw TaskServiceError.notFollowUp(status: task.status) }
        guard task.supplementCount < supplementLimit else { throw TaskServiceError.supplementLimitReached(supplementLimit) }
        guard ModelConfigStore.load().isConfigured else { throw TaskServiceError.notConfigured }
        if let blocking = blockingActiveTask(excluding: taskId, subject: task.subject) {
            throw TaskServiceError.busy(taskId: blocking.id)
        }
        let now = Date().timeIntervalSince1970
        task.text = trimmed
        task.status = .accepted
        task.revision += 1
        task.updatedAt = now
        task.supplementCount += 1
        task.attempt += 1
        task.error = nil
        task.softDeadline = now + softTimeoutSeconds
        task.hardDeadline = now + hardTimeoutSeconds
        task.messages.append(TaskMessage(role: .user, text: trimmed))
        if var transcript = task.transcript {
            transcript.append(["role": "user", "content": trimmed])
            task.transcript = transcript
        }
        try TaskStore.save(task)
        var event = TaskEvent(seq: 0, taskId: taskId, kind: .status, status: .accepted)
        try? TaskStore.append(&event)
        queue.async { execute(taskId: taskId) }
        return task
    }

    /// 手机放弃等待。**这不是取消**（方案 §7 v1.1）：runtime 不支持真正的中断，
    /// 已派发的请求仍会在 Mac 上跑完。取名 abandoned 就是为了避免谎报「已停止」。
    static func abandon(taskId: String) throws -> AgentTask {
        guard var task = TaskStore.task(id: taskId) else { throw TaskServiceError.notFound }
        task.status = .abandoned
        task.revision += 1
        task.updatedAt = Date().timeIntervalSince1970
        try TaskStore.save(task)
        var event = TaskEvent(seq: 0, taskId: taskId, kind: .status, status: .abandoned,
                              text: "手机已不再等待这个任务；Mac 上的这次调用可能仍会跑完。")
        try? TaskStore.append(&event)
        if activeTaskId == taskId { activeTaskId = nil }
        return task
    }

    static func snapshot(taskId: String) -> AgentTask? { TaskStore.task(id: taskId) }

    /// 当前网页绑定（只回标题/网址，不回正文——正文不该原样搬到手机上）。
    static func currentPageBinding() -> PageBinding? {
        guard case .success(let page) = PageReader.currentPage(maxCharacters: 512) else { return nil }
        return page.binding
    }

    // MARK: 能力报告

    /// 执行器可用性。手机据此决定能不能用小精灵，以及该提示什么。
    static func executors() -> [String: Any] {
        let config = ModelConfigStore.load()
        let modelConfigured = config.isConfigured
        let trusted = PageReader.isTrusted
        return [
            "agent": ["available": modelConfigured,
                      "capabilities": ["read_page", "open_page", "open_app", "dispatch_to_app", "feishu_message", "feishu_help", "feishu_execute"],
                      "writes": true],
            "browser": ["available": trusted,
                        "adapter": "ax",
                        "capabilities": ["read_page", "open_page", "open_app", "dispatch_to_app", "feishu_message", "feishu_help", "feishu_execute"],
                        "writes": true],
            "model": ["configured": modelConfigured,
                      "model": config.model,
                      "host": ModelConfigStore.endpoint(for: config.baseURL)?.host ?? ""],
            "limits": ["maxInputBytes": maxInputBytes,
                       "supplementLimit": supplementLimit,
                       "softTimeoutSeconds": softTimeoutSeconds,
                       "hardTimeoutSeconds": hardTimeoutSeconds,
                       "pollIntervalSeconds": pollIntervalSeconds,
                       "pollMaxIntervalSeconds": pollMaxIntervalSeconds],
        ]
    }

    // MARK: 执行

    private static func execute(taskId: String) {
        activeTaskId = taskId
        defer { if activeTaskId == taskId { activeTaskId = nil } }
        guard var task = TaskStore.task(id: taskId) else { return }
        guard let config = Optional(ModelConfigStore.load()), config.isConfigured else {
            finish(task, status: .failed, error: TaskServiceError.notConfigured.localizedDescription)
            return
        }
        let now = Date().timeIntervalSince1970
        task.status = .running
        task.revision += 1
        task.updatedAt = now
        task.softDeadline = now + softTimeoutSeconds
        task.hardDeadline = now + hardTimeoutSeconds
        try? TaskStore.save(task)
        var started = TaskEvent(seq: 0, taskId: taskId, kind: .status, status: .running)
        try? TaskStore.append(&started)

        // 硬超时由 URLSession 的单次超时兜底（AgentRunner 每轮 90s、最多 6 轮），
        // 这里不再起额外计时器：起一个又取消不掉的计时器等于制造假象。
        AgentRunner.run(config: config, task: task) { outcome in
            guard var updated = TaskStore.task(id: taskId), updated.status == .running else { return }
            updated.revision += 1
            updated.updatedAt = Date().timeIntervalSince1970
            updated.usage = outcome.usage
            updated.messages.append(TaskMessage(role: .assistant, text: outcome.content ?? outcome.error ?? ""))
            if let content = outcome.content {
                updated.status = outcome.needsInput ? .needsInput : .succeeded
                updated.result = content
                updated.error = nil
                // 漂移如实标注：读到的页面和提交时绑定的不是同一页，必须让人知道。
                if outcome.drifted { updated.result = "注意：读取的页面与你提交时看到的不同，本次读的是「\(outcome.pages.first?.binding.title ?? "未知标题")」。\n\n" + content }
            } else {
                updated.status = .failed
                updated.error = outcome.error ?? "未知错误。"
            }
            updated.sources = outcome.pages.map { TaskSource(title: $0.binding.title, url: $0.binding.url, domain: $0.binding.domain) }
            try? TaskStore.save(updated)
            var event = TaskEvent(seq: 0, taskId: taskId, kind: outcome.content == nil ? .error : .status,
                                  status: updated.status, text: outcome.content ?? outcome.error)
            try? TaskStore.append(&event)
        }
    }

    private static func finish(_ task: AgentTask, status: TaskStatus, error: String) {
        var updated = task
        updated.status = status
        updated.error = error
        updated.revision += 1
        updated.updatedAt = Date().timeIntervalSince1970
        try? TaskStore.save(updated)
        var event = TaskEvent(seq: 0, taskId: task.id, kind: .error, status: status, text: error)
        try? TaskStore.append(&event)
    }
}
