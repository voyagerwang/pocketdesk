/**
 * [INPUT]: 依赖 Foundation；不依赖 AppKit/网络——只描述手机展示会话的事实形状。
 * [OUTPUT]: 提供 SpriteSession 展示会话状态机：选择/草稿/提交三代际+序号去重（latest-only）、
 *           绑定服务端控制连接、提交身份核验与显式展示修订；迟到输入与旧会话不能复活；快照 Snapshot 与 onChange 通知（锁外投递）。
 * [POS]: Sources 桌面反馈的展示会话层；不执行工具、不修改任务状态机、不触碰任何输入通道。
 *        手机断线由 lastReportAt 表达，由协调层换算成连接状态；正文不进日志。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

final class SpriteSession {
    struct Snapshot: Equatable {
        /// 手机是否显式选中小精灵（桌面反馈窗的唯一显示意图来源）。
        var selected = false
        var presentationRevision = 0
        /// 接收者选择代际：只增不减；旧代际的任何事件都不能覆盖新代际。
        var generation = 0
        /// 会话内事件序号：单调递增，迟到帧直接丢弃（latest-only）。
        var seq = 0
        /// 草稿版本：每次草稿修订自增；提交与清空都携带版本做匹配。
        var draftVersion = 0
        /// 当前展示草稿（完整正文，非差量）。
        var draft = ""
        var submitting = false
        /// 提交时的草稿版本；submitted/清空只匹配这个版本，避免清掉提交后新输入的草稿。
        var submittingVersion = 0
        var submittedText = ""
        var submittedAt: TimeInterval = 0
        var lastTaskId: String?
        var lastRequestId: String?
        /// 最近一次上报时间；协调层据此判断手机输入连接状态。
        var lastReportAt: TimeInterval = 0
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var controller: String?
    /// 变更通知：在锁外、按序投递到串行队列，消费方（协调层）绝不在存储锁内做 UI。
    private let notifyQueue = DispatchQueue(label: "pocketdesk.sprite-session.notify")
    var onChange: ((Snapshot) -> Void)?

    var current: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    // MARK: 控制连接

    /// 调用方先核验当前控制租约；新 WebSocket 连接有新身份，刷新后可从零开始计数。
    func bind(controller id: String) {
        _ = commit { state in
            guard self.controller != id else { return false }
            self.controller = id
            let revision = state.presentationRevision
            state = Snapshot()
            state.presentationRevision = revision
            return true
        }
    }

    // MARK: 选择意图

    /// 手机显式选中小精灵。同代际/新代际重复点选只展开，不清草稿、不新建任务。
    @discardableResult
    func select(generation: Int, seq: Int? = nil) -> Snapshot {
        commit { state in
            guard generation >= state.generation, seq == nil || seq! > state.seq else { return false }
            if let seq { state.seq = seq }
            if !state.selected || generation > state.generation { state.presentationRevision += 1 }
            state.generation = generation
            state.selected = true
            return true
        }
    }

    /// 手机切走（选普通应用/恢复跟随）。旧代际的 deselect 不能取消更新的选择。
    /// 提交在途事实不动：submitted/submitFailed 与选择无关，都会送达。
    @discardableResult
    func deselect(generation: Int, seq: Int? = nil) -> Snapshot {
        commit { state in
            guard generation >= state.generation, seq == nil || seq! > state.seq else { return false }
            if let seq { state.seq = seq }
            state.generation = generation
            state.selected = false
            return true
        }
    }

    // MARK: 草稿

    /// 草稿修订：完整正文替换（手机听写/键入都按整稿送达）。
    /// 只有已选中的会话才接受草稿；序号不大于已见序号的帧按迟到丢弃。
    @discardableResult
    func draft(generation: Int, seq: Int, version: Int, text: String) -> Snapshot {
        commit { state in
            guard state.selected, generation == state.generation, seq > state.seq, version >= state.draftVersion else { return false }
            state.generation = max(state.generation, generation)
            state.seq = seq
            state.draftVersion = max(state.draftVersion, version)
            state.draft = text
            return true
        }
    }

    /// 显式清空（用户在手机清空输入）。只清与当前草稿一致的版本，不误删更新的输入。
    @discardableResult
    func clear(generation: Int, seq: Int, version: Int) -> Snapshot {
        commit { state in
            guard state.selected, generation >= state.generation, seq > state.seq else { return false }
            state.seq = seq
            guard version >= state.draftVersion else { return true }   // 迟到的清空不动新草稿
            state.draft = ""
            state.draftVersion = max(state.draftVersion, version)
            return true
        }
    }

    // MARK: 提交

    /// 请求在途。草稿保留展示，绝不提前写"已接收"。
    @discardableResult
    func submitting(version: Int, text: String, requestId: String) -> Snapshot {
        commit { state in
            guard state.selected, version > state.submittingVersion else { return false }
            state.submitting = true
            state.submittingVersion = version
            state.submittedText = text
            state.submittedAt = Date().timeIntervalSince1970
            state.lastRequestId = requestId
            return true
        }
    }

    /// 服务端确认持久接收。只有匹配提交版本的清空才生效——用户在提交收尾间隙新输入的草稿绝不能被抹掉。
    @discardableResult
    func submitted(version: Int, taskId: String?, requestId: String? = nil) -> Snapshot {
        commit { state in
            guard state.submitting, version == state.submittingVersion,
                  requestId == nil || requestId == state.lastRequestId else { return false }
            state.submitting = false
            if let taskId, !taskId.isEmpty { state.lastTaskId = taskId }
            guard version >= state.submittingVersion, version >= state.draftVersion else { return true }
            state.draft = ""
            return true
        }
    }

    /// 提交失败：正文保留，展示失败。
    @discardableResult
    func submitFailed(version: Int, requestId: String? = nil) -> Snapshot {
        commit { state in
            guard state.submitting, version == state.submittingVersion,
                  requestId == nil || requestId == state.lastRequestId else { return false }
            state.submitting = false
            return true
        }
    }

    // MARK: 连接状态

    /// 心跳：任何上报都刷新 lastReportAt，协调层据此判断输入连接状态。
    @discardableResult
    func touch() -> Snapshot {
        commit { state in
            state.lastReportAt = Date().timeIntervalSince1970
            return true
        }
    }

    // MARK: 内部

    /// 所有变更的唯一入口：持锁修改，锁外投递通知。返回变更后的快照（无论是否被接受）。
    private func commit(_ mutate: (inout Snapshot) -> Bool) -> Snapshot {
        let changed: Bool
        let snapshot: Snapshot
        lock.lock()
        changed = mutate(&state)
        snapshot = state
        lock.unlock()
        if changed, let onChange {
            notifyQueue.async { onChange(snapshot) }
        }
        return snapshot
    }
}
