/**
 * [INPUT]: 真实 AgentModels/TaskStore 与隔离临时目录；仅 TargetStore 路径替身。
 * [OUTPUT]: 原子快照与执行领取、事件失败降级、旧索引恢复、完整输入幂等、清理墓碑与坏库拒写断言。
 * [POS]: 旧手机任务恢复的持久化底座验收，不调用模型或桌面 API。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum TargetStore { static let supportDirectory = FileManager.default.temporaryDirectory }

@main struct TaskLedgerTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String = "assertion failed") { precondition(value, message) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        TaskStore.resetCache(directory: dir)
        let text = String(repeating: "a", count: 64) + "X"
        let binding = PageBinding(browser: "Chrome", url: "https://example.com", title: "原网页", observedAt: 1)
        let first = try TaskStore.claim(subject: "owner", requestId: "original", text: text, context: binding)
        precondition(first.json()["requestId"] as? String == "original", "HTTP 回执必须保留原请求关联")
        func rejected(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("expected rejection") } catch { }
        }
        rejected { _ = try TaskStore.claim(subject: "owner", requestId: "original", text: String(repeating: "a", count: 64) + "Y", context: binding) }
        let otherBinding = PageBinding(browser: "Chrome", url: binding.url, title: "另一个标题", observedAt: 1)
        rejected { _ = try TaskStore.claim(subject: "owner", requestId: "original", text: text, context: otherBinding) }
        var supplemented = first; supplemented.text = "后续补充"; supplemented.status = .needsInput
        try TaskStore.save(supplemented); TaskStore.resetCache()
        let originalAgain = try TaskStore.claim(subject: "owner", requestId: "original", text: text, context: binding)
        precondition(originalAgain.id == first.id && originalAgain.text == "后续补充")
        rejected { _ = try TaskStore.claim(subject: "owner", requestId: "original", text: "后续补充", context: binding) }
        // 新快照自带台账，过时或损坏的旧 sidecar 不再影响查账。
        try Data("broken legacy index".utf8).write(to: TaskStore.dedupeFile)
        TaskStore.resetCache(); try TaskStore.checkReadable()
        precondition(TaskStore.task(subject: "owner", requestId: "original")?.id == first.id)
        let saved = try Data(contentsOf: TaskStore.snapshotFile)
        var snapshot = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        precondition(snapshot["storageVersion"] as? Int == 2 && snapshot["requestLedger"] != nil)
        // 模拟旧版：任务已写但索引漏写；首次 user 消息恢复，不以最新补充覆盖原始请求。
        snapshot.removeValue(forKey: "storageVersion"); snapshot.removeValue(forKey: "requestLedger")
        let legacy = try JSONSerialization.data(withJSONObject: snapshot)
        try legacy.write(to: TaskStore.snapshotFile); try Data("{}".utf8).write(to: TaskStore.dedupeFile)
        TaskStore.resetCache(); try TaskStore.checkReadable()
        precondition(TaskStore.task(subject: "owner", requestId: "original")?.id == first.id)
        check(try Data(contentsOf: TaskStore.snapshotFile) == legacy, "只读迁移不得改文件")
        check(try TaskStore.claim(subject: "owner", requestId: "original", text: text, context: binding).id == first.id)
        try TaskStore.save(supplemented); TaskStore.resetCache()
        try TaskStore.remove(id: first.id); TaskStore.resetCache()
        rejected { _ = try TaskStore.claim(subject: "owner", requestId: "original", text: text, context: binding) }
        var old = try TaskStore.claim(subject: "owner", requestId: "purged", text: "旧任务", context: nil)
        old.status = .succeeded; old.updatedAt = 0; try TaskStore.save(old)
        check(try TaskStore.purge(olderThan: 1) == 1); TaskStore.resetCache()
        rejected { _ = try TaskStore.claim(subject: "owner", requestId: "purged", text: "旧任务", context: nil) }
        precondition(TaskStore.all().isEmpty)
        // 未认识的版本、坏 JSON、缺台账都必须保持原字节，不能写一份新空库覆盖。
        let good = try Data(contentsOf: TaskStore.snapshotFile)
        var missingIndex = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        missingIndex["requestLedger"] = [String: Any]()
        for bad in [Data("{".utf8), Data("{\"schemaVersion\":99,\"tasks\":[]}".utf8), Data("{\"schemaVersion\":1,\"storageVersion\":2,\"tasks\":[]}".utf8), try JSONSerialization.data(withJSONObject: missingIndex)] {
            try bad.write(to: TaskStore.snapshotFile); TaskStore.resetCache()
            rejected { try TaskStore.checkReadable() }
            rejected { _ = try TaskStore.claim(subject: "owner", requestId: "new", text: "不得写", context: nil) }
            check(try Data(contentsOf: TaskStore.snapshotFile) == bad)
        }
        try good.write(to: TaskStore.snapshotFile); TaskStore.resetCache(); try TaskStore.checkReadable()
        // 原子写失败不会只在内存留下新请求，也不会改动先前台账。
        let backup = dir.appendingPathComponent("test-snapshot-backup")
        try FileManager.default.moveItem(at: TaskStore.snapshotFile, to: backup)
        try FileManager.default.createDirectory(at: TaskStore.snapshotFile, withIntermediateDirectories: false)
        rejected { _ = try TaskStore.claim(subject: "owner", requestId: "write-fail", text: "不应接收", context: nil) }
        precondition(TaskStore.task(subject: "owner", requestId: "write-fail") == nil)
        try FileManager.default.removeItem(at: TaskStore.snapshotFile)
        try FileManager.default.moveItem(at: backup, to: TaskStore.snapshotFile)
        TaskStore.resetCache(); check(try Data(contentsOf: TaskStore.snapshotFile) == good)
        rejected { _ = try TaskStore.claim(subject: "owner", requestId: "purged", text: "旧任务", context: nil) }
        let resultLock = NSLock()
        var taskIDs = Set<String>(), failures = 0
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                let task = try TaskStore.claim(subject: "owner", requestId: "concurrent", text: "只接收一次", context: nil)
                resultLock.lock(); taskIDs.insert(task.id); resultLock.unlock()
            } catch { resultLock.lock(); failures += 1; resultLock.unlock() }
        }
        TaskStore.resetCache()
        precondition(failures == 0 && taskIDs.count == 1 && TaskStore.all().count == 1)
        // 重复队列回调只能有一个持久领取者；重启仍不可再次启动。
        let executionID = taskIDs.first!
        var claims = 0
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                let claimed = try TaskStore.beginExecution(id: executionID, now: 100, softTimeout: 300, hardTimeout: 600)
                if let claimed {
                    precondition(claimed.status == .running && claimed.softDeadline == 400 && claimed.hardDeadline == 700)
                    resultLock.lock(); claims += 1; resultLock.unlock()
                }
            } catch { resultLock.lock(); failures += 1; resultLock.unlock() }
        }
        precondition(claims == 1 && failures == 0)
        TaskStore.resetCache()
        check(try TaskStore.beginExecution(id: executionID, now: 200, softTimeout: 300, hardTimeout: 600) == nil)
        for status in [TaskStatus.abandoned, .succeeded, .failed, .submitted, .needsInput, .verifying] {
            var task = try TaskStore.claim(subject: "test", requestId: status.rawValue, text: "不得启动", context: nil)
            task.status = status; try TaskStore.save(task)
            check(try TaskStore.beginExecution(id: task.id, now: 200, softTimeout: 300, hardTimeout: 600) == nil)
        }
        let awaiting = try TaskStore.claim(subject: "test", requestId: "start-write-failure", text: "先存再执行", context: nil)
        try FileManager.default.moveItem(at: TaskStore.snapshotFile, to: backup)
        try FileManager.default.createDirectory(at: TaskStore.snapshotFile, withIntermediateDirectories: false)
        rejected { _ = try TaskStore.beginExecution(id: awaiting.id, now: 200, softTimeout: 300, hardTimeout: 600) }
        precondition(TaskStore.task(id: awaiting.id)?.status == .accepted)
        try FileManager.default.removeItem(at: TaskStore.snapshotFile)
        try FileManager.default.moveItem(at: backup, to: TaskStore.snapshotFile)
        TaskStore.resetCache()
        precondition(TaskStore.task(id: awaiting.id)?.status == .accepted)
        // 日志不可写时，原子快照仍是权威；接收和运行修订必须可读取。
        let eventBackup = dir.appendingPathComponent("test-events-backup")
        try FileManager.default.moveItem(at: TaskStore.eventsFile, to: eventBackup)
        try FileManager.default.createDirectory(at: TaskStore.eventsFile, withIntermediateDirectories: false)
        let noEvent = try TaskStore.claim(subject: "test", requestId: "event-write-failure", text: "日志坏了仍查快照", context: nil)
        let started = try TaskStore.beginExecution(id: noEvent.id, now: 300, softTimeout: 300, hardTimeout: 600)!
        precondition(started.revision > noEvent.revision)
        TaskStore.resetCache()
        precondition(TaskStore.task(id: noEvent.id)?.status == .running)
        print("Task ledger：原子快照、全输入冲突、补充后原请求、旧索引恢复、清理墓碑、坏库拒写与写失败恢复通过")
        print("执行领取：16 路只有一次、重启不重领、已放弃不启动、快照写失败拒绝与事件失败降级通过")
    }
}
