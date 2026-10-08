/**
 * [INPUT]: Foundation 的串行调度队列；每个异步派单事务在结束时释放占用。
 * [OUTPUT]: 仅对应用投递阶段按 FIFO 排队，不限制模型任务或外部 Agent 的并发执行；重复释放不会提前启动下一项。
 * [POS]: AgentAppDispatch 的短事务调度器，不发送按键、不读取桌面、不持久化任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

final class AgentDispatchQueue {
    typealias Operation = (@escaping () -> Void) -> Void
    private let queue = DispatchQueue(label: "pocketdesk.agent-dispatch")
    private var pending: [Operation] = []
    private var active: UUID?

    func enqueue(_ operation: @escaping Operation) {
        queue.async {
            self.pending.append(operation)
            self.startNext()
        }
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let token = UUID()
        active = token
        let operation = pending.removeFirst()
        operation {
            self.queue.async {
                guard self.active == token else { return }
                self.active = nil
                self.startNext()
            }
        }
    }
}
