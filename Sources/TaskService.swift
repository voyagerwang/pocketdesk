/**
 * [INPUT]: 依赖 Foundation，消费 TaskStore、AgentRunner、ModelConfigStore、PageReader。
 * [OUTPUT]: 失败输入按语义同任务/新任务/澄清接续并保留历史；支持独立任务并发，逐任务防重入；保存结构化派单回执，未核实提交以 submitted 结束而非要求补充；提交幂等查账并保存执行控制会话；对外提供任务生命周期：submit/supplement/abandon/snapshot、当前网页绑定查询、执行器能力报告。
 * [POS]: Sources 的 Agent 服务层：唯一决定任务状态如何流转的地方，HTTP 层不做状态判断。
 *        独立任务不互相阻塞；飞书候选选择通过 needsInput 续接，状态里没有「已停止」这种会骗人的说法。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum TaskServiceError: LocalizedError {
    case emptyText
    case textTooLarge(limit: Int)
    case notConfigured
    case notFound
    case notFollowUp(status: TaskStatus)
    case supplementLimitReached(Int)
    case revisionMismatch

    var errorDescription: String? {
        switch self {
        case .emptyText: return "请先输入内容再发送。"
        case .textTooLarge(let limit): return "内容超过 \(limit / 1024) KiB，请精简后再发。"
        case .notConfigured: return "还没有配置模型服务：请在这台 Mac 的控制台「小精灵 · 模型服务」里填好并测试通过。"
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
    private static var executing = Set<String>()
    static var loadModelConfig = ModelConfigStore.load
    static var classifyInput = TaskContinuation.classify
    static var runAgent: (ModelConfig, AgentTask, @escaping (AgentRunner.Outcome) -> Void) -> Void = { config, task, done in
        AgentRunner.run(config: config, task: task, completion: done)
    }
    private static let submissionLock = NSLock()

    // MARK: 提交与执行

    static func submit(subject: String, requestId: String, text: String, context: PageBinding?, controlSession: String? = nil, originalInputText: String? = nil) throws -> AgentTask {
        submissionLock.lock(); defer { submissionLock.unlock() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskServiceError.emptyText }
        guard trimmed.utf8.count <= maxInputBytes else { throw TaskServiceError.textTooLarge(limit: maxInputBytes) }
        guard loadModelConfig().isConfigured else { throw TaskServiceError.notConfigured }
        // 同一请求重试直接查账，不能重新排入执行队列。
        if let existing = TaskStore.task(subject: subject, requestId: requestId) {
            guard existing.text == trimmed && existing.context == context else { throw TaskServiceError.revisionMismatch }
            return existing
        }
        var task = try TaskStore.claim(subject: subject, requestId: requestId, text: trimmed, context: context)
        if let originalInputText { task.inputRequestTexts = (task.inputRequestTexts ?? [:]).merging([requestId: originalInputText]) { existing, _ in existing } }
        task.controlSession = controlSession
        try TaskStore.save(task)
        queue.async { execute(taskId: task.id) }
        return task
    }

    /// 追问/补充：沿用同一 taskId，历史消息一起回放，不读取错误页面。
    static func supplement(taskId: String, text: String, expectedRevision: Int?, requestId: String? = nil, controlSession: String? = nil) throws -> AgentTask {
        submissionLock.lock(); defer { submissionLock.unlock() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskServiceError.emptyText }
        guard trimmed.utf8.count <= maxInputBytes else { throw TaskServiceError.textTooLarge(limit: maxInputBytes) }
        guard var task = TaskStore.task(id: taskId) else { throw TaskServiceError.notFound }
        if let requestId, let previous = task.inputRequestTexts?[requestId] {
            guard previous == trimmed else { throw TaskStoreError.conflict(taskId: taskId) }
            return task
        }
        if let expectedRevision, expectedRevision != task.revision { throw TaskServiceError.revisionMismatch }
        guard !executing.contains(taskId) else { throw TaskServiceError.notFollowUp(status: .running) }
        guard task.status.acceptsFollowUp else { throw TaskServiceError.notFollowUp(status: task.status) }
        guard task.supplementCount < supplementLimit else { throw TaskServiceError.supplementLimitReached(supplementLimit) }
        guard loadModelConfig().isConfigured else { throw TaskServiceError.notConfigured }
        let now = Date().timeIntervalSince1970
        if task.appDispatchReceipt?.submissionAttempted == false
            || (task.safeDispatchRetryAttempt == task.attempt && !TaskStore.hasBlockedAppDispatch(task)) {
            task.safeDispatchRetryAttempt = task.attempt + 1
        }
        task.text = trimmed
        task.pendingInputRelation = false
        if let controlSession { task.controlSession = controlSession }
        if let requestId { task.inputRequestTexts = (task.inputRequestTexts ?? [:]).merging([requestId: trimmed]) { existing, _ in existing } }
        task.status = .accepted
        task.revision += 1
        task.updatedAt = now
        task.supplementCount += 1
        task.attempt += 1
        task.error = nil
        task.result = nil
        task.appDispatchReceipt = nil
        task.softDeadline = now + softTimeoutSeconds
        task.hardDeadline = now + hardTimeoutSeconds
        task.messages.append(TaskMessage(role: .user, text: trimmed))
        if var transcript = task.transcript {
            transcript.append(["role": "user", "content": trimmed])
            task.transcript = transcript
        } else {
            // 模型配置等首轮失败可能没有 transcript，仍携带完整原话与补充。
            task.text = task.messages.filter { $0.role == .user }.map(\.text).joined(separator: "\n")
        }
        try TaskStore.save(task)
        var event = TaskEvent(seq: 0, taskId: taskId, kind: .status, status: .accepted)
        try? TaskStore.append(&event)
        queue.async { execute(taskId: taskId) }
        return task
    }

    /// 手机和耳机共用：失败后自然补充不要求用户重复整段；分类不执行任何工具。
    static func send(subject: String, requestId: String, text: String, context: PageBinding?,
                     controlSession: String?, previousTaskId: String?,
                     completion: @escaping (Result<AgentTask, Error>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.failure(TaskServiceError.emptyText)); return }
        guard trimmed.utf8.count <= maxInputBytes else { completion(.failure(TaskServiceError.textTooLarge(limit: maxInputBytes))); return }
        if let existing = TaskStore.task(subject: subject, requestId: requestId) {
            guard (existing.inputRequestTexts?[requestId] ?? existing.messages.first(where: { $0.role == .user })?.text) == trimmed,
                  existing.requestId != requestId || existing.context == context else {
                completion(.failure(TaskStoreError.conflict(taskId: existing.id))); return
            }
            completion(.success(existing)); return
        }
        guard let previousTaskId, let previous = TaskStore.task(id: previousTaskId),
              TaskContinuation.isCandidate(previous, subject: subject) else {
            do { completion(.success(try submit(subject: subject, requestId: requestId, text: trimmed, context: context, controlSession: controlSession))) }
            catch { completion(.failure(error)) }
            return
        }
        let config = loadModelConfig()
        guard config.isConfigured else {
            do { completion(.success(try rememberContinuationQuestion(previous: previous, text: trimmed, requestId: requestId,
                question: "模型服务尚未配置；原任务和这句补充都已保留。配置好后可直接说“继续”。"))) }
            catch { completion(.failure(error)) }
            return
        }
        classifyInput(config, previous, trimmed) { decision in
            do {
                switch decision {
                case .same:
                    completion(.success(try supplement(taskId: previous.id, text: trimmed, expectedRevision: previous.revision,
                        requestId: requestId, controlSession: controlSession)))
                case .new, .newPending:
                    let pending = decision == .newPending && previous.pendingInputRelation == true
                        ? previous.messages.last(where: { $0.role == .user })?.text : nil
                    let newText = pending.map { $0 + "\n" + trimmed } ?? trimmed
                    completion(.success(try submit(subject: subject, requestId: requestId, text: newText, context: context, controlSession: controlSession, originalInputText: trimmed)))
                case .unclear, .unavailable:
                    completion(.success(try rememberContinuationQuestion(previous: previous, text: trimmed, requestId: requestId,
                        question: decision == .unavailable ? "暂时连不上模型，原任务和这句补充都已保留。连接恢复后可直接说“继续”。" : Self.continuationQuestion)))
                }
            } catch { completion(.failure(error)) }
        }
    }

    private static let continuationQuestion = "你这句是在补充刚才的任务吗？原任务和这句补充都已保留；可以说“是，继续”或“不是，是新任务”。"
    private static func rememberContinuationQuestion(previous: AgentTask, text: String, requestId: String, question: String) throws -> AgentTask {
        submissionLock.lock(); defer { submissionLock.unlock() }
        guard var current = TaskStore.task(id: previous.id), current.revision == previous.revision else { throw TaskServiceError.revisionMismatch }
        current.messages.append(TaskMessage(role: .user, text: text))
        current.messages.append(TaskMessage(role: .assistant, text: question))
        if var transcript = current.transcript {
            transcript += [["role": "user", "content": text], ["role": "assistant", "content": question]]
            current.transcript = transcript
        }
        current.inputRequestTexts = (current.inputRequestTexts ?? [:]).merging([requestId: text]) { existing, _ in existing }
        current.status = .needsInput; current.result = question; current.error = nil; current.pendingInputRelation = true
        current.revision += 1; current.updatedAt = Date().timeIntervalSince1970
        try TaskStore.save(current)
        var event = TaskEvent(seq: 0, taskId: current.id, kind: .status, status: .needsInput, text: question)
        try? TaskStore.append(&event)
        return current
    }

    /// 手机放弃等待。**这不是取消**（方案 §7 v1.1）：runtime 不支持真正的中断，
    /// 已派发的请求仍会在 Mac 上跑完。取名 abandoned 就是为了避免谎报「已停止」。
    static func abandon(taskId: String) throws -> AgentTask {
        submissionLock.lock(); defer { submissionLock.unlock() }
        guard var task = TaskStore.task(id: taskId) else { throw TaskServiceError.notFound }
        task.status = .abandoned
        task.revision += 1
        task.updatedAt = Date().timeIntervalSince1970
        try TaskStore.save(task)
        var event = TaskEvent(seq: 0, taskId: taskId, kind: .status, status: .abandoned,
                              text: "手机已不再等待这个任务；Mac 上的这次调用可能仍会跑完。")
        try? TaskStore.append(&event)
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
        let config = loadModelConfig()
        let modelConfigured = config.isConfigured
        let trusted = PageReader.isTrusted
        return [
            "agent": ["available": modelConfigured,
                      "capabilities": ["read_page", "open_page", "open_app", "dispatch_to_app", "codex_action", "agent_workspace", "feishu_message", "feishu_help", "feishu_execute"],
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
        submissionLock.lock()
        guard var task = TaskStore.task(id: taskId), task.status == .accepted, !executing.contains(taskId) else {
            submissionLock.unlock(); return
        }
        guard let config = Optional(loadModelConfig()), config.isConfigured else {
            finish(task, status: .failed, error: TaskServiceError.notConfigured.localizedDescription)
            submissionLock.unlock()
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
        executing.insert(taskId)
        submissionLock.unlock()
        runAgent(config, task) { outcome in
            submissionLock.lock(); defer { submissionLock.unlock() }
            executing.remove(taskId)
            guard var updated = TaskStore.task(id: taskId), updated.status == .running, updated.attempt == task.attempt else { return }
            updated.revision += 1
            updated.updatedAt = Date().timeIntervalSince1970
            updated.usage = outcome.usage
            updated.appDispatchReceipt = outcome.appDispatchReceipt
            updated.messages.append(TaskMessage(role: .assistant, text: outcome.content ?? outcome.error ?? ""))
            if let content = outcome.content {
                // 前次发送前失败仍未解决，本轮只有解释/追问时保持可接续，不能冒充任务完成。
                let unresolvedDispatch = updated.safeDispatchRetryAttempt == updated.attempt
                    && !TaskStore.hasBlockedAppDispatch(updated) && outcome.appDispatchReceipt == nil
                updated.status = outcome.appDispatchReceipt?.taskStatus ?? (outcome.needsInput || unresolvedDispatch ? .needsInput : .succeeded)
                updated.result = content
                updated.error = updated.status == .failed ? content : nil
                // 漂移如实标注：读到的页面和提交时绑定的不是同一页，必须让人知道。
                if outcome.drifted { updated.result = "注意：读取的页面与你提交时看到的不同，本次读的是「\(outcome.pages.first?.binding.title ?? "未知标题")」。\n\n" + content }
            } else {
                updated.status = .failed
                updated.error = outcome.error ?? "未知错误。"
            }
            updated.sources = outcome.pages.map { TaskSource(title: $0.binding.title, url: $0.binding.url, domain: $0.binding.domain) }
            try? TaskStore.save(updated)
            var event = TaskEvent(seq: 0, taskId: taskId, kind: updated.status == .failed ? .error : .status,
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
