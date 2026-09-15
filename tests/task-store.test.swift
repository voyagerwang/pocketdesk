/**
 * [INPUT]: 依赖 Foundation，消费 TaskStore、AgentModels、RecipientOrder。
 * [OUTPUT]: 覆盖任务存储的幂等与冲突、事件单调与增量补取、清理，以及接收者顺序的迁移语义。
 * [POS]: tests 的 Agent 持久化测试；把存储指到临时目录，不碰用户真实数据。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct TaskStoreTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { print("  ok - \(label)") } else { failures += 1; print("  FAIL - \(label)") }
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pd-task-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        TaskStore.resetCache(directory: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        print("task store: 幂等与冲突")

        let binding = PageBinding(browser: "Chrome", url: "https://example.com/a", title: "示例页", observedAt: Date().timeIntervalSince1970)

        do {
            let first = try TaskStore.claim(subject: "s1", requestId: "req-1", text: "总结这一页", context: binding)
            check(first.status == .accepted, "新任务初始状态是已接收")
            check(first.messages.count == 1 && first.messages[0].role == .user, "接受时写入一条 user 消息")

            // 幂等：同键同内容必须回到同一个任务，绝不派第二个。
            let again = try TaskStore.claim(subject: "s1", requestId: "req-1", text: "总结这一页", context: binding)
            check(again.id == first.id, "同 requestId 同内容返回同一任务")

            // 不同主体互不影响：去重键是主体 + requestId。
            let other = try TaskStore.claim(subject: "s2", requestId: "req-1", text: "总结这一页", context: binding)
            check(other.id != first.id, "不同主体的同 requestId 是不同任务")

            do {
                _ = try TaskStore.claim(subject: "s1", requestId: "req-1", text: "换一个问题", context: nil)
                check(false, "同 requestId 不同内容应报冲突")
            } catch TaskStoreError.conflict(let taskId) {
                check(taskId == first.id, "同 requestId 不同内容报冲突并指回原任务")
            }
        } catch {
            check(false, "claim 不应抛出：\(error)")
        }

        print("task store: 事件单调与增量补取")

        do {
            var e1 = TaskEvent(seq: 0, taskId: "t-1", kind: .status, status: .running)
            var e2 = TaskEvent(seq: 0, taskId: "t-1", kind: .status, status: .succeeded)
            var e3 = TaskEvent(seq: 0, taskId: "t-2", kind: .status, status: .running)
            try TaskStore.append(&e1); try TaskStore.append(&e2); try TaskStore.append(&e3)
            check(e1.seq < e2.seq && e2.seq < e3.seq, "seq 严格单调递增")

            let all = TaskStore.events(taskId: "t-1", after: 0)
            check(all.events.count == 2, "按 taskId 过滤事件")
            let after = TaskStore.events(taskId: "t-1", after: e1.seq)
            check(after.events.count == 1 && after.events[0].seq == e2.seq, "after 游标只回更新的事件")
            check(after.needRefresh == false, "未超上限时不要求刷新快照")

            // 重开后仍能从文件恢复连续的 seq——seq 不能因为进程重启回到 0 造成事件覆盖。
            TaskStore.resetCache()
            var e4 = TaskEvent(seq: 0, taskId: "t-1", kind: .status, status: .failed)
            try TaskStore.append(&e4)
            check(e4.seq > e3.seq, "重新加载后 seq 接着往上走")
        } catch {
            check(false, "事件写入不应失败：\(error)")
        }

        print("task store: 变更与清理")

        do {
            let task = try TaskStore.claim(subject: "s1", requestId: "req-2", text: "第二问", context: nil)
            var updated = task
            updated.status = .succeeded
            updated.result = "答案"
            try TaskStore.save(updated)
            check(TaskStore.task(id: task.id)?.result == "答案", "保存后可读回结果")

            // 清理只动已结束且过期的任务；活动任务不能被删——删了等于让人以为任务从没存在过。
            var active = try TaskStore.claim(subject: "s1", requestId: "req-3", text: "还在跑", context: nil)
            active.status = .running
            active.updatedAt = Date().timeIntervalSince1970 - 90 * 86400
            try TaskStore.save(active)
            _ = try? TaskStore.purge(olderThan: 30)
            check(TaskStore.task(id: active.id) != nil, "清理不会删掉活动任务")
        } catch {
            check(false, "保存不应失败：\(error)")
        }

        print("recipient order: 迁移与清理")

        let t1 = TargetConfig(id: "app-1", name: "A", bundleID: "com.a", path: nil)
        let t2 = TargetConfig(id: "app-2", name: "B", bundleID: "com.b", path: nil)

        let migrated = RecipientOrder.normalized([], targets: [t1, t2])
        check(migrated.first == RecipientOrder.sprite, "首次迁移把小精灵放在第一位")
        check(migrated == [RecipientOrder.sprite, "app-1", "app-2"], "应用原相对顺序保持不变")

        // 用户把小精灵挪到后面：之后每次读取都必须尊重，不能重新置顶。
        let moved = RecipientOrder.normalized(["app-1", RecipientOrder.sprite, "app-2"], targets: [t1, t2])
        check(moved == ["app-1", RecipientOrder.sprite, "app-2"], "用户排好的顺序不被重新置顶")

        // 旧数据里没有小精灵时补到首位；已删除的应用引用清掉；新增应用追加到末尾。
        let legacy = RecipientOrder.normalized(["app-9", "app-2"], targets: [t1, t2])
        check(legacy == [RecipientOrder.sprite, "app-2", "app-1"], "清掉已删除引用、补齐小精灵与新增应用")

        let dup = RecipientOrder.normalized([RecipientOrder.sprite, RecipientOrder.sprite, "app-1", "app-1"], targets: [t1])
        check(dup == [RecipientOrder.sprite, "app-1"], "重复引用去重")

        print("agent models: 状态与绑定语义")

        check(TaskStatus.running.isActive && !TaskStatus.succeeded.isActive, "活动状态判定")
        check(TaskStatus.succeeded.acceptsFollowUp && !TaskStatus.running.acceptsFollowUp, "追问只在终态允许")
        let drifted = PageBinding(browser: "Chrome", url: "https://example.com/b", title: "另一页", observedAt: 0)
        check(binding.drifted(comparedTo: drifted), "URL 变了判定为漂移")
        check(!binding.drifted(comparedTo: binding), "同一页面不判漂移")
        check(TaskUsage.parse(nil).unknown, "读不到用量记为 unknown")
        check(TaskUsage.parse(["prompt_tokens": 3, "completion_tokens": 4]).totalTokens == 7, "usage 解析与合计")

        if failures == 0 {
            print("task store: 幂等/冲突/事件/清理/顺序迁移 全部通过")
        } else {
            print("task store: \(failures) 项失败")
            exit(1)
        }
    }
}
