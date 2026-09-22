/**
 * [INPUT]: Foundation 的原子文件写入与 CryptoKit SHA256，消费 AgentModels 的任务与事件类型。
 * [OUTPUT]: tasks.json 同次原子保存任务和请求去重墓碑；events.jsonl 保持独立事件日志。
 *           旧 dedupe.json 仅迁移读取；完整输入判冲突，坏库拒写，原子领取执行，事件失败不推翻已落盘接收。
 * [POS]: Sources 的 Agent 持久化层；HTTP 层与 TaskService 都通过它读写，不允许两边各自声明权威。
 *        首版用文件化方案而非 SQLite：本项目由 install-app.sh 直接 swiftc 裸编、未链接 -lsqlite3，
 *        引入 SQLite 要改构建并手写 C API 封装，成本与收益不匹配（方案 §9 v1.1 修正）。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CryptoKit

enum TaskStoreError: LocalizedError {
    case writeFailed(String)
    /// 同一主体的同一 requestId 被复用于不同内容：宁可报冲突，也不能悄悄派第二个任务。
    case conflict(taskId: String)
    case retiredRequest

    var errorDescription: String? {
        switch self {
        case .writeFailed(let reason): return "任务写入失败：\(reason)"
        case .conflict(let taskId): return "该请求已用于另一个任务（\(taskId)），请刷新后重试。"
        case .retiredRequest: return "这个请求以前已被接收，任务记录已清理；不能用原编号重新执行。"
        }
    }
}

enum TaskStore {
    /// 任务目录。**可替换**：测试把整个存储指到临时目录，不去动用户真实的 ~/Library 数据。
    /// 三个文件路径都是计算属性，改了 directory 就一起跟着走，不会出现"目录换了、文件还在旧处"。
    static var directory = TargetStore.supportDirectory.appendingPathComponent("tasks", isDirectory: true)
    static var snapshotFile: URL { directory.appendingPathComponent("tasks.json") }
    static var eventsFile: URL { directory.appendingPathComponent("events.jsonl") }
    static var dedupeFile: URL { directory.appendingPathComponent("dedupe.json") }
    /// 单任务事件游标保留上限；超出要求手机刷新快照，不无限补取（方案 §9）。
    static let eventRetentionPerTask = 2000
    static let defaultRetentionDays = 30

    private static let lock = NSLock()
    private static var cached: [AgentTask]?
    private static var cachedSeq: Int = 0
    private static var dedupe: [String: [String: String]]?
    private static var storageFailure: String?

    /// 测试用：丢弃内存缓存并可选换目录。切目录后不清缓存会读到上一个目录的任务。
    static func resetCache(directory newDirectory: URL? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let newDirectory { directory = newDirectory }
        cached = nil
        cachedSeq = 0
        dedupe = nil
        storageFailure = nil
    }

    /// HTTP 读取坏库必须报错，不能用空列表或 404 冒充“从未接收”。
    static func checkReadable() throws {
        lock.lock(); defer { lock.unlock() }
        _ = loadLocked()
        try assertHealthyLocked()
    }

    // MARK: 快照

    static func all() -> [AgentTask] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    static func task(id: String) -> AgentTask? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().first { $0.id == id }
    }

    /// 按去重键找原任务——提交超时的回包丢了时靠它找回，不生成新 ID 盲重发。
    static func task(subject: String, requestId: String) -> AgentTask? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = dedupeLocked()[key(subject: subject, requestId: requestId)],
              let taskId = entry["taskId"] else { return nil }
        return loadLocked().first { $0.id == taskId && $0.subject == subject && $0.requestId == requestId }
    }

    /// 持久接受一个新任务。同键同内容返回原任务（幂等），同键不同内容报冲突。
    static func claim(subject: String, requestId: String, text: String, context: PageBinding?) throws -> AgentTask {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(subject: subject, requestId: requestId)
        var dedupeTable = dedupeLocked()
        try assertHealthyLocked()
        if let entry = dedupeTable[key], let taskId = entry["taskId"] {
            guard let existing = loadLocked().first(where: { $0.id == taskId }) else { throw TaskStoreError.retiredRequest }
            // 比较首次提交的完整摘要，不比较补充对话后可变的 task.text。
            let inputHash = try fingerprint(text: text, context: context)
            if existing.subject != subject || existing.requestId != requestId || entry["fingerprint"] != inputHash {
                throw TaskStoreError.conflict(taskId: taskId)
            }
            return existing
        }
        var task = AgentTask(subject: subject, requestId: requestId, text: text, context: context)
        task.messages.append(TaskMessage(role: .user, text: text))
        var tasks = loadLocked()
        tasks.append(task)
        dedupeTable[key] = ["taskId": task.id, "fingerprint": try fingerprint(text: text, context: context)]
        try persistLocked(tasks: tasks, dedupe: dedupeTable)
        // 接收以原子快照为准。事件是增量提示，写失败不能让已接收任务错过排队。
        try? appendEventLocked(TaskEvent(seq: nextSeqLocked(), taskId: task.id, kind: .status, status: .accepted))
        return task
    }

    /// 执行前先持久领取；未接收态、已放弃或重复回调都不能再次启动。
    static func beginExecution(id: String, now: Double, softTimeout: Double, hardTimeout: Double) throws -> AgentTask? {
        lock.lock(); defer { lock.unlock() }
        var tasks = loadLocked()
        try assertHealthyLocked()
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status == .accepted else { return nil }
        tasks[index].status = .running
        tasks[index].revision += 1
        tasks[index].updatedAt = now
        tasks[index].softDeadline = now + softTimeout
        tasks[index].hardDeadline = now + hardTimeout
        try persistLocked(tasks: tasks, dedupe: dedupeLocked())
        try? appendEventLocked(TaskEvent(seq: nextSeqLocked(), taskId: id, kind: .status, status: .running))
        return tasks[index]
    }

    /// 写入任务变更。revision 由调用方推进（乐观并发由 TaskService 校验）。
    static func save(_ task: AgentTask) throws {
        lock.lock(); defer { lock.unlock() }
        var tasks = loadLocked()
        try assertHealthyLocked()
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            throw TaskStoreError.writeFailed("任务 \(task.id) 不存在。")
        }
        guard task.subject == tasks[index].subject, task.requestId == tasks[index].requestId else {
            throw TaskStoreError.writeFailed("不能改写已接收任务的请求身份。")
        }
        // 派单占用是只增证据；并发状态保存不能用旧快照抹掉它而允许二次外发。
        var updated = task
        let messageIDs = Set(updated.messages.map(\.id))
        updated.messages += tasks[index].messages.filter { ["dispatch_to_app", "desktop_action"].contains($0.toolName ?? "") && !messageIDs.contains($0.id) }
        tasks[index] = updated
        try persistLocked(tasks: tasks, dedupe: dedupeLocked())
    }

    /// 在任何新建/输入副作用之前原子占用一次派单；并发调用和进程重启均不能自动重放。
    static func reserveAppDispatch(id: String, label: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var tasks = loadLocked()
        try assertHealthyLocked()
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status == .running,
              !tasks[index].messages.contains(where: { $0.toolName == "dispatch_to_app" }) else { return false }
        tasks[index].messages.append(TaskMessage(role: .tool, text: label, toolName: "dispatch_to_app"))
        try persistLocked(tasks: tasks, dedupe: dedupeLocked())
        return true
    }

    /// 同一任务的同一桌面动作只占用一次，避免重复关闭下一扇窗口或再次删掉新输入。
    static func reserveDesktopAction(id: String, request: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var tasks = loadLocked()
        try assertHealthyLocked()
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status == .running,
              !tasks[index].messages.contains(where: { $0.toolName == "desktop_action" && $0.text == request }) else { return false }
        tasks[index].messages.append(TaskMessage(role: .tool, text: request, toolName: "desktop_action"))
        try persistLocked(tasks: tasks, dedupe: dedupeLocked())
        return true
    }

    static func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var tasks = loadLocked()
        try assertHealthyLocked()
        tasks.removeAll { $0.id == id }
        try persistLocked(tasks: tasks, dedupe: dedupeLocked())
    }

    // MARK: 事件

    static func append(_ event: inout TaskEvent) throws {
        lock.lock(); defer { lock.unlock() }
        event.seq = nextSeqLocked()
        try appendEventLocked(event)
    }

    /// 增量补取。返回的 needRefresh 为真表示事件已被截断（超出保留上限），手机应改拉快照。
    static func events(taskId: String, after seq: Int, limit: Int = 500) -> (events: [TaskEvent], needRefresh: Bool) {
        lock.lock(); defer { lock.unlock() }
        let all = loadEventsLocked().filter { $0.taskId == taskId && $0.seq > seq }
        let needRefresh = all.count > eventRetentionPerTask
        let slice = needRefresh ? Array(all.suffix(limit)) : Array(all.prefix(limit))
        return (slice, needRefresh)
    }

    static func latestSeq() -> Int {
        lock.lock(); defer { lock.unlock() }
        return loadEventsLocked().last?.seq ?? 0
    }

    // MARK: 清理

    /// 清理超过保留期的任务与它的事件。用户可在控制台触发；不删除未完成任务。
    @discardableResult
    static func purge(olderThan days: Int = defaultRetentionDays, now: Date = Date()) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let tasks = loadLocked()
        try assertHealthyLocked()
        let stale = tasks.filter { !$0.status.isActive && $0.updatedAt < cutoff }
        guard !stale.isEmpty else { return 0 }
        let staleIds = Set(stale.map { $0.id })
        let kept = tasks.filter { !staleIds.contains($0.id) }
        // 正文与事件按保留期清理，请求编号墓碑永久保留，避免迟到重投变成新执行。
        try persistLocked(tasks: kept, dedupe: dedupeLocked())
        let events = loadEventsLocked().filter { !staleIds.contains($0.taskId) }
        try persistEventsLocked(events)
        return staleIds.count
    }

    // MARK: 内部：所有状态都必须持锁访问

    private static func key(subject: String, requestId: String) -> String { "\(subject)|\(requestId)" }

    private static func assertHealthyLocked() throws {
        if let storageFailure { throw TaskStoreError.writeFailed(storageFailure) }
    }

    private struct RequestInput: Encodable { let text: String; let context: PageBinding? }
    private static func fingerprint(text: String, context: PageBinding?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RequestInput(text: text, context: context))
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadLocked() -> [AgentTask] {
        if let cached { return cached }
        do {
            guard FileManager.default.fileExists(atPath: snapshotFile.path) else {
                if FileManager.default.fileExists(atPath: dedupeFile.path) || FileManager.default.fileExists(atPath: eventsFile.path) {
                    throw TaskStoreError.writeFailed("任务快照缺失但历史台账仍存在，请在电脑端核对备份；未创建空库。")
                }
                cached = []; dedupe = [:]; return []
            }
            let wrapper = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotFile))
            guard wrapper.schemaVersion == AgentTask.currentSchemaVersion,
                  wrapper.storageVersion == nil || wrapper.storageVersion == 2 else {
                throw TaskStoreError.writeFailed("任务存储版本不支持，请核对运行版本；未覆盖原文件。")
            }
            var table: [String: [String: String]]
            if let embedded = wrapper.requestLedger { table = embedded }
            else if wrapper.storageVersion == 2 {
                throw TaskStoreError.writeFailed("任务快照缺少请求台账，请核对备份；未重新执行。")
            } else if FileManager.default.fileExists(atPath: dedupeFile.path) {
                table = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: dedupeFile))
            } else { table = [:] }
            guard table.values.allSatisfy({ !($0["taskId"] ?? "").isEmpty }) else {
                throw TaskStoreError.writeFailed("请求台账损坏，请核对备份。")
            }
            var ids = Set<String>(), requests = Set<String>()
            for task in wrapper.tasks {
                let requestKey = key(subject: task.subject, requestId: task.requestId)
                guard ids.insert(task.id).inserted, requests.insert(requestKey).inserted,
                      table[requestKey] == nil || table[requestKey]?["taskId"] == task.id else {
                    throw TaskStoreError.writeFailed("任务快照与请求台账冲突，请核对备份。")
                }
                if wrapper.storageVersion == 2 {
                    guard table[requestKey]?["taskId"] == task.id,
                          table[requestKey]?["fingerprint"]?.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
                        throw TaskStoreError.writeFailed("原子快照与请求台账不完整，请核对备份。")
                    }
                } else {
                    // 旧双文件写入中断时，以已持久化的首次 user 消息补索引；不产生新任务或外发。
                    guard let original = task.messages.first(where: { $0.role == .user }) else {
                        throw TaskStoreError.writeFailed("旧任务缺少首次请求证据，不能猜测去重身份。")
                    }
                    table[requestKey] = ["taskId": task.id, "fingerprint": try fingerprint(text: original.text, context: task.context)]
                }
            }
            cached = wrapper.tasks; dedupe = table
            return wrapper.tasks
        } catch {
            storageFailure = "无法可靠读取任务存储，请在电脑端核对版本与备份；未覆盖原文件。"
            cached = []; dedupe = [:]; return []
        }
    }

    private static func dedupeLocked() -> [String: [String: String]] {
        _ = loadLocked()
        return dedupe ?? [:]
    }

    private static func loadEventsLocked() -> [TaskEvent] {
        guard let text = try? String(contentsOf: eventsFile, encoding: .utf8) else { return [] }
        var events: [TaskEvent] = []
        // 最后一行可能写了一半（进程被杀）；解析失败就跳过这一行，不整份丢弃。
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONDecoder().decode(TaskEvent.self, from: data) else { continue }
            events.append(event)
        }
        cachedSeq = events.last?.seq ?? 0
        return events
    }

    private static func nextSeqLocked() -> Int {
        if cachedSeq == 0 { _ = loadEventsLocked() }
        cachedSeq += 1
        return cachedSeq
    }

    private static func appendEventLocked(_ event: TaskEvent) throws {
        try ensureDirectory()
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8) else {
            throw TaskStoreError.writeFailed("事件序列化失败。")
        }
        let payload = line + "\n"
        if FileManager.default.fileExists(atPath: eventsFile.path) {
            guard let handle = try? FileHandle(forWritingTo: eventsFile) else {
                throw TaskStoreError.writeFailed("打不开事件日志。")
            }
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let bytes = payload.data(using: .utf8) { try handle.write(contentsOf: bytes) }
        } else {
            try payload.write(to: eventsFile, atomically: true, encoding: .utf8)
        }
        // 事件表不进内存缓存：始终从文件读，避免多进程写同一份日志时缓存与文件分叉。
        if event.seq > cachedSeq { cachedSeq = event.seq }
    }

    private static func persistEventsLocked(_ events: [TaskEvent]) throws {
        var text = ""
        for event in events {
            guard let data = try? JSONEncoder().encode(event),
                  let line = String(data: data, encoding: .utf8) else { continue }
            text += line + "\n"
        }
        try ensureDirectory()
        try text.write(to: eventsFile, atomically: true, encoding: .utf8)
        cachedSeq = events.last?.seq ?? 0
    }

    private static func persistLocked(tasks: [AgentTask], dedupe table: [String: [String: String]]) throws {
        try assertHealthyLocked()
        try ensureDirectory()
        let snapshot = Snapshot(schemaVersion: AgentTask.currentSchemaVersion, storageVersion: 2, tasks: tasks, requestLedger: table)
        guard let data = try? JSONEncoder().encode(snapshot) else {
            throw TaskStoreError.writeFailed("任务序列化失败。")
        }
        do {
            try data.write(to: snapshotFile, options: .atomic)
        } catch {
            // 写失败必须抛出去：静默吞掉会让手机以为任务已经接住了，实际什么都没落下。
            throw TaskStoreError.writeFailed(error.localizedDescription)
        }
        cached = tasks
        dedupe = table
    }

    private static func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw TaskStoreError.writeFailed("无法创建任务目录：\(error.localizedDescription)")
        }
    }

    private struct Snapshot: Codable {
        var schemaVersion: Int
        var storageVersion: Int?
        var tasks: [AgentTask]
        var requestLedger: [String: [String: String]]?
    }
}
