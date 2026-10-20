/**
 * [INPUT]: 依赖 Foundation，消费 TaskStore、AgentModels、RecipientOrder。
 * [OUTPUT]: 覆盖任务存储的幂等与冲突、事件单调与增量补取、清理、飞书与米家原子占用和跨快照/重载单调证据，以及接收者顺序的迁移语义；米家回执验证旧缓存兼容与任务结束后的事实补存。
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

        print("task store: 飞书原子占用与持久证据")

        do {
            var deliveryTask = try TaskStore.claim(subject: "s1", requestId: "feishu-delivery", text: "发飞书消息", context: nil)
            check(try !TaskStore.reserveFeishuDelivery(id: deliveryTask.id, recipient: "张三"), "未运行的任务不能占用飞书发送")
            deliveryTask.status = .running
            try TaskStore.save(deliveryTask)
            let beforeDelivery = deliveryTask
            let counterLock = NSLock()
            var deliveryReservations = 0
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                if (try? TaskStore.reserveFeishuDelivery(id: deliveryTask.id, recipient: "张三")) == true {
                    counterLock.lock(); deliveryReservations += 1; counterLock.unlock()
                }
            }
            check(deliveryReservations == 1, "并发发送仅一次原子占用成功")
            try TaskStore.save(beforeDelivery)
            check(TaskStore.task(id: deliveryTask.id)?.feishuDelivery?.recipient == "张三", "旧空快照不能抹掉飞书发送占用")
            TaskStore.resetCache()
            check(try !TaskStore.reserveFeishuDelivery(id: deliveryTask.id, recipient: "李四"), "重载后仍拒绝第二次飞书发送")
            var confirmed = TaskStore.task(id: deliveryTask.id)!
            let pendingDelivery = confirmed
            confirmed.feishuDelivery?.messageId = "om_confirmed"
            try TaskStore.save(confirmed)
            check(TaskStore.task(id: deliveryTask.id)?.feishuDelivery?.messageId == "om_confirmed", "发送占用可推进至真实消息回执")
            try TaskStore.save(pendingDelivery)
            try TaskStore.save(beforeDelivery)
            check(TaskStore.task(id: deliveryTask.id)?.feishuDelivery?.messageId == "om_confirmed", "旧 pending 与空快照不能覆盖已确认发送")
            confirmed.feishuDelivery = FeishuDelivery(recipient: "李四", messageId: "om_other")
            try TaskStore.save(confirmed)
            check(TaskStore.task(id: deliveryTask.id)?.feishuDelivery == FeishuDelivery(recipient: "张三", messageId: "om_confirmed"), "后续快照不能替换已确认的接收者和消息")

            var operationTask = try TaskStore.claim(subject: "s1", requestId: "feishu-operation", text: "飞书写操作", context: nil)
            check(try !TaskStore.reserveFeishuOperation(id: operationTask.id, key: "first"), "未运行的任务不能占用飞书写操作")
            operationTask.status = .running
            try TaskStore.save(operationTask)
            let beforeOperation = operationTask
            var operationReservations = 0
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                if (try? TaskStore.reserveFeishuOperation(id: operationTask.id, key: "first")) == true {
                    counterLock.lock(); operationReservations += 1; counterLock.unlock()
                }
            }
            check(operationReservations == 1, "并发相同写操作仅一次原子占用成功")
            try TaskStore.save(beforeOperation)
            check(TaskStore.task(id: operationTask.id)?.feishuOperations?["first"] == "pending", "旧空快照不能抹掉飞书写操作占用")
            TaskStore.resetCache()
            check(try !TaskStore.reserveFeishuOperation(id: operationTask.id, key: "first"), "重载后仍拒绝重放同一飞书写操作")
            var result = TaskStore.task(id: operationTask.id)!
            let pendingOperation = result
            result.feishuOperations?["first"] = "实际回执"
            try TaskStore.save(result)
            check(TaskStore.task(id: operationTask.id)?.feishuOperations?["first"] == "实际回执", "写操作占用可推进至真实回执")
            try TaskStore.save(pendingOperation)
            try TaskStore.save(beforeOperation)
            check(TaskStore.task(id: operationTask.id)?.feishuOperations?["first"] == "实际回执", "旧 pending 与空快照不能覆盖已完成操作")
            check(try TaskStore.reserveFeishuOperation(id: operationTask.id, key: "second"), "不同写操作可以独立占用")
            result.feishuOperations?["first"] = "另一个回执"
            try TaskStore.save(result)
            let operations = TaskStore.task(id: operationTask.id)?.feishuOperations
            check(operations?["first"] == "实际回执" && operations?["second"] == "pending", "旧快照保留已确认回执与其他操作占用")
        } catch {
            check(false, "飞书持久证据检查不应失败：\(error)")
        }

        print("task store: 米家原子占用与持久证据")

        do {
            var operationTask = try TaskStore.claim(subject: "s1", requestId: "mijia-operation", text: "米家设备写操作", context: nil)
            do {
                _ = try TaskStore.mijiaOperation(id: operationTask.id, key: "first")
                check(false, "未运行的任务不能占用米家操作")
            } catch { check(operationTask.mijiaOperations == nil, "未运行的任务不能占用米家操作") }
            operationTask.status = .running
            try TaskStore.save(operationTask)
            let beforeOperation = operationTask
            let counterLock = NSLock()
            var reservations = 0
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                do {
                    if try TaskStore.mijiaOperation(id: operationTask.id, key: "first") == nil {
                        counterLock.lock(); reservations += 1; counterLock.unlock()
                    }
                } catch { }
            }
            check(reservations == 1, "并发相同米家操作仅一次获得执行权")
            try TaskStore.save(beforeOperation)
            check(TaskStore.task(id: operationTask.id)?.mijiaOperations?["first"] == "pending", "旧空快照不能抹掉米家占用")
            TaskStore.resetCache()
            check(try TaskStore.mijiaOperation(id: operationTask.id, key: "first") == "pending", "重载后未知米家操作不重放")
            let pendingOperation = TaskStore.task(id: operationTask.id)!
            _ = try TaskStore.mijiaOperation(id: operationTask.id, key: "first", receipt: "实际设备回执")
            check(try TaskStore.mijiaOperation(id: operationTask.id, key: "first", receipt: "另一个回执") == "实际设备回执", "米家完成回执不可替换")
            try TaskStore.save(pendingOperation)
            try TaskStore.save(beforeOperation)
            check(TaskStore.task(id: operationTask.id)?.mijiaOperations?["first"] == "实际设备回执", "旧 pending 与空快照不能覆盖米家完成回执")
            check(try TaskStore.mijiaOperation(id: operationTask.id, key: "second") == nil, "不同米家操作可以独立占用")
            try TaskStore.save(pendingOperation)
            let operations = TaskStore.task(id: operationTask.id)?.mijiaOperations
            check(operations?["first"] == "实际设备回执" && operations?["second"] == "pending", "旧快照保留米家回执与其他占用")
            for (key, receipt) in [("unclaimed", "无占用回执"), ("second", ""), ("second", "pending")] {
                do {
                    _ = try TaskStore.mijiaOperation(id: operationTask.id, key: key, receipt: receipt)
                    check(false, "无占用或无效米家回执必须拒绝")
                } catch { check(true, "无占用或无效米家回执必须拒绝") }
            }
            var ended = TaskStore.task(id: operationTask.id)!
            ended.status = .abandoned
            try TaskStore.save(ended)
            _ = try TaskStore.mijiaOperation(id: operationTask.id, key: "second", receipt: "迟到设备回执")
            do {
                _ = try TaskStore.mijiaOperation(id: operationTask.id, key: "third")
                check(false, "任务结束后不能新占用米家操作")
            } catch { check(true, "任务结束后不能新占用米家操作") }
            TaskStore.resetCache()
            check(TaskStore.task(id: operationTask.id)?.mijiaOperations?["second"] == "迟到设备回执", "任务结束后真实米家回执仍能持久补存")
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ended)) as! [String: Any]
            legacy.removeValue(forKey: "mijiaOperations")
            let decoded = try JSONDecoder().decode(AgentTask.self, from: JSONSerialization.data(withJSONObject: legacy))
            check(decoded.mijiaOperations == nil, "旧任务缓存缺少米家字段仍可解码")
        } catch {
            check(false, "米家持久证据检查不应失败：\(error)")
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
            print("task store: 幂等/冲突/事件/清理/飞书证据/米家证据/顺序迁移 全部通过")
        } else {
            print("task store: \(failures) 项失败")
            exit(1)
        }
    }
}
