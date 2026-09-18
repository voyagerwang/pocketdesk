/**
 * [INPUT]: 依赖 Foundation 的 FileManager/JSONEncoder/FileHandle，消费 AgentModels 的任务与事件类型。
 * [OUTPUT]: 对外提供任务与事件的唯一权威存储：整体快照 tasks.json（原子写）、append-only 事件日志
 *           events.jsonl、requestId 去重表 dedupe.json；以及幂等接受 claim 与派单/桌面动作副作用前的原子占用。
 * [POS]: Sources 的 Agent 持久化层；HTTP 层与 TaskService 都通过它读写，不允许两边各自声明权威。
 *        首版用文件化方案而非 SQLite：本项目由 install-app.sh 直接 swiftc 裸编、未链接 -lsqlite3，
 *        引入 SQLite 要改构建并手写 C API 封装，成本与收益不匹配（方案 §9 v1.1 修正）。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum TaskStoreError: LocalizedError {
    case writeFailed(String)
    /// 同一主体的同一 requestId 被复用于不同内容：宁可报冲突，也不能悄悄派第二个任务。
    case conflict(taskId: String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let reason): return "任务写入失败：\(reason)"
        case .conflict(let taskId): return "该请求已用于另一个任务（\(taskId)），请刷新后重试。"
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
    private static var dedupe: [String: [String: Any]]?

    /// 测试用：丢弃内存缓存并可选换目录。切目录后不清缓存会读到上一个目录的任务。
    static func resetCache(directory newDirectory: URL? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let newDirectory { directory = newDirectory }
        cached = nil
        cachedSeq = 0
        dedupe = nil
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
              let taskId = entry["taskId"] as? String else { return nil }
        return loadLocked().first { $0.id == taskId }
    }

    /// 持久接受一个新任务。同键同内容返回原任务（幂等），同键不同内容报冲突。
    static func claim(subject: String, requestId: String, text: String, context: PageBinding?) throws -> AgentTask {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(subject: subject, requestId: requestId)
        var dedupeTable = dedupeLocked()
        if let entry = dedupeTable[key],
           let taskId = entry["taskId"] as? String,
           let existing = loadLocked().first(where: { $0.id == taskId }) {
            // 同键不同内容：内容指纹不一致就是冲突，不改原文也不另建任务。
            if entry["fingerprint"] as? String != Self.fingerprint(text: text, url: context?.url) {
                throw TaskStoreError.conflict(taskId: taskId)
            }
            return existing
        }
        var task = AgentTask(subject: subject, requestId: requestId, text: text, context: context)
        task.messages.append(TaskMessage(role: .user, text: text))
        var tasks = loadLocked()
        tasks.append(task)
        dedupeTable[key] = ["taskId": task.id, "fingerprint": Self.fingerprint(text: text, url: context?.url)]
        try persistLocked(tasks: tasks, dedupe: dedupeTable)
        try appendEventLocked(TaskEvent(seq: nextSeqLocked(), taskId: task.id, kind: .status, status: .accepted))
        return task
    }

    /// 写入任务变更。revision 由调用方推进（乐观并发由 TaskService 校验）。
    static func save(_ task: AgentTask) throws {
        lock.lock(); defer { lock.unlock() }
        var tasks = loadLocked()
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            throw TaskStoreError.writeFailed("任务 \(task.id) 不存在。")
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
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status == .running,
              !tasks[index].messages.contains(where: { $0.toolName == "desktop_action" && $0.text == request }) else { return false }
        tasks[index].messages.append(TaskMessage(role: .tool, text: request, toolName: "desktop_action"))
        try persistLocked(tasks: tasks, dedupe: dedupeLocked())
        return true
    }

    static func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var tasks = loadLocked()
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
        let stale = tasks.filter { !$0.status.isActive && $0.updatedAt < cutoff }
        guard !stale.isEmpty else { return 0 }
        let staleIds = Set(stale.map { $0.id })
        let kept = tasks.filter { !staleIds.contains($0.id) }
        var table = dedupeLocked()
        for id in staleIds {
            if let match = table.first(where: { ($0.value["taskId"] as? String) == id }) { table.removeValue(forKey: match.key) }
        }
        try persistLocked(tasks: kept, dedupe: table)
        let events = loadEventsLocked().filter { !staleIds.contains($0.taskId) }
        try persistEventsLocked(events)
        return staleIds.count
    }

    // MARK: 内部：所有状态都必须持锁访问

    private static func key(subject: String, requestId: String) -> String { "\(subject)|\(requestId)" }

    /// 内容指纹：不存全文（去重表会被读进内存），用长度 + 前缀足以区分"同键换内容"。
    private static func fingerprint(text: String, url: String?) -> String {
        "\(text.utf8.count)-\(url?.utf8.count ?? 0)-\(text.prefix(64))-\(url?.prefix(64) ?? "")"
    }

    private static func loadLocked() -> [AgentTask] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: snapshotFile),
              let wrapper = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            cached = []; return []
        }
        // schema 不认识就整体弃用并留备份：猜着解析会把半懂的字段写回去，比丢数据更危险。
        guard wrapper.schemaVersion == AgentTask.currentSchemaVersion else {
            try? FileManager.default.copyItem(at: snapshotFile, to: snapshotFile.appendingPathExtension("bak"))
            cached = []; return []
        }
        cached = wrapper.tasks
        return wrapper.tasks
    }

    private static func dedupeLocked() -> [String: [String: Any]] {
        if let dedupe { return dedupe }
        guard let data = try? Data(contentsOf: dedupeFile),
              let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else {
            dedupe = [:]; return [:]
        }
        dedupe = table
        return table
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
            handle.seekToEndOfFile()
            if let bytes = payload.data(using: .utf8) { handle.write(bytes) }
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

    private static func persistLocked(tasks: [AgentTask], dedupe table: [String: [String: Any]]) throws {
        try ensureDirectory()
        let snapshot = Snapshot(schemaVersion: AgentTask.currentSchemaVersion, tasks: tasks)
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
        if let dedupeData = try? JSONSerialization.data(withJSONObject: table) {
            try? dedupeData.write(to: dedupeFile, options: .atomic)
            dedupe = table
        }
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
        var tasks: [AgentTask]
    }
}
