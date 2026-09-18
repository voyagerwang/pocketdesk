/**
 * [INPUT]: 依赖 Foundation 与 AgentModels 的 AgentTask/TaskStatus；消费 SpriteSession 快照。
 * [OUTPUT]: 提供 SpriteFeedback 桌面反馈协调层：合并展示会话与任务事实（taskProvider 注入），
 *           仅恢复活动或本会话任务，以任务身份与修订跟踪最新问题，显式重选驱动唤醒；project 纯函数产出 ViewModel（明确交互阶段/原版表情 ID/阶段标题/正文/提交及活动任务忙碌态/历史轮次/连接状态）；自适应轮询（活动期 1s/静默期 5s）。
 * [POS]: Sources 桌面反馈的协调层；不执行工具、不修改任务状态机、不写任务存储；
 *        只读 TaskStore 事实（由 main.swift 注入 provider），UI 一律经主线程面板呈现。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

final class SpriteFeedback {

    // MARK: 视图模型（纯值，测试可直接构造）

    struct Round: Equatable {
        var question: String
        var answer: String?
        var taskId: String?
        var finished = false
    }

    enum Phase {
        case idle, drafting, submitting, working, waiting, succeeded, handedOff, failed, abandoned
    }

    struct ViewModel: Equatable {
        var phase: Phase = .idle
        /// 任务身份让连续两次成功各庆祝一次；重复轮询不重播。
        var taskId = ""
        /// 上方浮层只呈现当前阶段的内容，已提交原话不充当执行进度。
        var displayText: String {
            switch phase {
            case .drafting: return draft
            case .waiting, .succeeded, .handedOff, .failed, .abandoned: return answer ?? ""
            default: return ""
            }
        }
        var headline: String {
            phase == .idle || phase == .drafting ? "" : statusLine
        }

        /// 显示意图：手机已选中小精灵。面板再叠加前台/锁屏事实决定是否真的可见。
        var visible = false
        var presentationRevision = 0
        /// 待发送草稿（标签「待发送」）；提交中保留展示。
        var draft = ""
        var submitting = false
        /// 本轮问题与回答。
        var question: String?
        var answer: String?
        /// 状态行文案与忙碌动效。
        var statusLine = ""
        var busy = false
        /// 原版组件表情 ID；状态事实决定表情，唤醒瞬间由展示层覆盖为开心。
        var emotion = "02"
        /// 手机输入连接状态：断线时面板必须标明，不再假装实时同步。
        var phoneConnected = true
        var hasHistory = false
    }

    /// 面板最小接口：协调层不直接持有 AppKit 类型，测试可注入替身。
    /// 线程约定：apply 必须在主线程调用（本项目为 swiftc Swift 5 模式，靠调用纪律保证）。
    protocol Panel: AnyObject {
        func apply(_ viewModel: ViewModel)
    }

    // MARK: 装配

    private let session: SpriteSession
    private let subject: String
    /// 任务事实来源（main.swift 注入 TaskStore 只读投影；测试注入内存替身）。
    var taskProvider: (() -> AgentTask?)?
    weak var panel: Panel?

    private var rounds: [Round] = []
    private var lastSeenRevision = 0
    private var lastSeenTaskId: String?
    private var timer: Timer?
    private static let activeInterval: TimeInterval = 1
    private static let idleInterval: TimeInterval = 5
    /// 手机上报静默多久算输入断开。
    static let phoneOfflineAfter: TimeInterval = 15

    init(session: SpriteSession, subject: String) {
        self.session = session
        self.subject = subject
    }

    /// 主线程启动轮询与会话订阅。重复调用无害。
    func start() {
        guard timer == nil else { return }
        if let current = currentTask() { restoreIfNeeded(current) }
        refresh()
        schedule(nextInterval())
        // 会话事件从后台队列到达：统一派回主线程再动 timer/面板。
        session.onChange = { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    /// 历史终态仍留在任务存储；新展示会话不把上一轮结果当默认欢迎语。
    private func currentTask() -> AgentTask? {
        guard let task = taskProvider?() else { return nil }
        return task.status.isActive || task.status == .needsInput || task.id == session.current.lastTaskId ? task : nil
    }

    // MARK: 轮询（活动期/静默期）

    private func nextInterval() -> TimeInterval {
        let snapshot = session.current
        let busy = snapshot.selected || snapshot.submitting
            || taskProvider?().map({ $0.status.isActive }) == true
        return busy ? Self.activeInterval : Self.idleInterval
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            let changed = self.pollTask()
            self.refresh()
            self.schedule(changed ? Self.activeInterval : self.nextInterval())
        }
    }

    /// 读任务事实；revision 变化才记账。返回是否产生了值得密切跟進的变化。
    @discardableResult
    private func pollTask() -> Bool {
        guard let task = currentTask(), task.id != lastSeenTaskId || task.revision != lastSeenRevision else { return false }
        lastSeenTaskId = task.id
        lastSeenRevision = task.revision
        merge(task: task)
        return task.status.isActive
    }

    // MARK: 轮次记账

    /// 恢复：重选/重启后没有本地轮次时，用该主体最近一个任务播种，保证恢复出正确内容。
    private func restoreIfNeeded(_ task: AgentTask?) {
        guard rounds.isEmpty, let task else { return }
        merge(task: task)
    }

    private func merge(task: AgentTask) {
        // taskId 标识任务，supplement 的最新正文标识当前问题；执行中不能复用旧追问。
        let answer: String?
        switch task.status {
        case .succeeded, .needsInput: answer = task.result ?? task.error
        case .failed: answer = task.error ?? "未知错误。"
        case .abandoned: answer = task.result ?? task.error ?? "手机已放弃等待；Mac 上的执行可能仍会完成。"
        case .accepted, .running, .verifying: answer = nil
        }
        let round = Round(question: task.text, answer: answer, taskId: task.id, finished: !task.status.isActive)
        if let index = rounds.lastIndex(where: { $0.taskId == task.id }) { rounds[index] = round }
        else { rounds.append(round) }
    }

    // MARK: 投影

    /// 重算投影并投递面板。主线程同步投递（测试无 runloop 也能驱动）；后台到达的会话事件先派回主线程。
    func refresh() {
        pollTask()
        adoptSessionSubmit()
        let viewModel = Self.project(session: session.current, task: currentTask(),
                                     rounds: rounds.filter { $0.taskId == currentTask()?.id || $0.taskId == session.current.lastTaskId }, now: Date().timeIntervalSince1970)
        guard let panel else { return }
        if Thread.isMainThread { panel.apply(viewModel) }
        else { DispatchQueue.main.async { panel.apply(viewModel) } }
    }

    /// 提交回执到达（lastTaskId 更新）时给本轮记账；去重防止重复追加。
    private func adoptSessionSubmit() {
        let snapshot = session.current
        guard let taskId = snapshot.lastTaskId, !snapshot.submittedText.isEmpty,
              !rounds.contains(where: { $0.taskId == taskId }) else { return }
        rounds.append(Round(question: snapshot.submittedText, answer: nil, taskId: taskId))
    }

    /// 纯函数投影：展示会话 + 任务事实 → 面板内容。不触碰任何存储与 UI。
    static func project(session: SpriteSession.Snapshot, task: AgentTask?, rounds: [Round],
                        now: TimeInterval) -> ViewModel {
        var viewModel = ViewModel()
        viewModel.visible = session.selected
        viewModel.presentationRevision = session.presentationRevision
        viewModel.draft = session.draft
        viewModel.submitting = session.submitting
        viewModel.taskId = task?.id ?? session.lastTaskId ?? ""
        viewModel.phoneConnected = session.lastReportAt == 0
            || now - session.lastReportAt <= phoneOfflineAfter

        // 本轮 = 已认领 taskId 的最后一轮；未认领用提交时正文。
        var current = rounds.last
        if let task, let index = rounds.lastIndex(where: { $0.taskId == task.id }) {
            current = rounds[index]
        }
        viewModel.question = current?.question ?? (session.submitting ? session.submittedText : nil)
        // 终态任务尚未被记入轮次（回执未到/重选恢复）时，回答直接取任务事实，绝不静默丢结果。
        if session.submitting {
            viewModel.question = session.submittedText
            viewModel.answer = nil
        } else if let task {
            viewModel.question = task.text
            viewModel.answer = task.status == .failed ? (task.error ?? task.result)
                : task.status == .needsInput || !task.status.isActive ? (task.result ?? task.error) : nil
        } else { viewModel.answer = current?.answer }
        viewModel.hasHistory = rounds.count > 1

        // 接收/执行事实优先于留存草稿；新草稿只有在任务不忙时才进入输入态。
        if session.submitting {
            viewModel.phase = .submitting
            viewModel.statusLine = "正在提交…"
            viewModel.busy = true
            viewModel.emotion = "31"
        } else if let task, [.accepted, .running, .verifying].contains(task.status) {
            viewModel.phase = .working
            viewModel.busy = true
            switch task.status {
            case .accepted:
                viewModel.statusLine = "已接收，准备执行"
                viewModel.emotion = "31"
            case .verifying:
                viewModel.statusLine = "结果待核对"
                viewModel.emotion = "30"
            default:
                // tool 消息是已返回的步骤，不能将它误报为此刻正在执行的动作。
                viewModel.statusLine = "执行中"
                viewModel.emotion = "32"
            }
        } else if !session.draft.isEmpty {
            viewModel.phase = .drafting
            viewModel.statusLine = "待发送"
            viewModel.emotion = "35"
        } else if let task {
            switch task.status {
            case .needsInput:
                viewModel.phase = .waiting
                viewModel.statusLine = "等你补充"
                viewModel.emotion = "11"
            case .succeeded:
                if let name = task.handoffTargetName, task.handoffRequested != nil || task.handoffTargetId != nil {
                    viewModel.phase = .handedOff
                    viewModel.statusLine = "已交给 \(name)"
                    viewModel.emotion = "19"
                } else {
                    viewModel.phase = .succeeded
                    viewModel.statusLine = "已完成"
                    viewModel.emotion = "33"
                }
            case .failed:
                viewModel.phase = .failed
                viewModel.statusLine = "未完成"
                viewModel.emotion = "11"
            case .abandoned:
                viewModel.phase = .abandoned
                viewModel.statusLine = "已放弃等待；Mac 上可能仍在执行"
                viewModel.emotion = "11"
            default: break
            }
        } else if let current, !current.finished {
            // API 已确认接收但任务快照尚未到达，不能退回听写态或静默待机。
            viewModel.phase = .working
            viewModel.statusLine = "已接收，准备执行"
            viewModel.busy = true
            viewModel.emotion = "31"
        }
        return viewModel
    }
}
