/**
 * [INPUT]: CodexActionRequest、按动作范围只读的本机 CodexCatalog 与注入的应用/输入执行器。
 * [OUTPUT]: 项目/任务列表、唯一目标导航或定向派单回执；多候选结束本轮等待选择，发送沿用原子去重。
 * [POS]: C 的 Codex 专属业务入口；与通用派单共用 FIFO，不建第二套键盘执行器。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

enum CodexAdapter {
    enum Reply {
        case listed(String), opened(String), needsInput(String), failed(String), dispatched(AppDispatchReceipt)
    }
    static func execute(_ request: CodexActionRequest, taskId: String, store: TargetStore, executor: InputExecutor,
                        pointer: PointerExecutor?, authorized: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard authorized() else { completion(.failed("控制权已失效，未执行 Codex 操作。")); return }
            do {
                let resolution: CodexSelection.Resolution
                if [.openDot, .sendDot].contains(request.action) { resolution = .destination(.dot) }
                else {
                    let includeChats = [.listTasks, .openTask, .sendTask].contains(request.action)
                    var snapshot = try CodexCatalog.load(includeChats: includeChats)
                    if request.unreadOnly == true, EnvironmentGate.blockReason() == nil,
                       let app = AgentDesktopActions.target("Codex", store: store),
                       InputFocus.focusedApplicationPID() == app.processIdentifier {
                        snapshot = .init(projects: snapshot.projects,
                            chats: CodexNavigator.visibleUnread(chats: snapshot.chats, pid: app.processIdentifier), truncated: snapshot.truncated)
                    }
                    resolution = try CodexSelection.resolve(request, snapshot: snapshot)
                }
                switch resolution {
                case .list(let value): completion(.listed(value))
                case .question(let value): completion(.needsInput(value))
                case .destination(let destination):
                    guard authorized() else { completion(.failed("控制权已失效，未打开 Codex。")); return }
                    if request.isSend {
                        AgentAppDispatch.send(app: "Codex", text: request.text!, taskId: taskId,
                            destination: destination, store: store, executor: executor, pointer: pointer,
                            authorized: authorized) { completion(.dispatched($0)) }
                    } else {
                        open(destination, taskId: taskId, store: store, executor: executor, pointer: pointer,
                             authorized: authorized, completion: completion)
                    }
                }
            } catch {
                if error.localizedDescription.contains("蓝点索引") { completion(.needsInput(error.localizedDescription)) }
                else { completion(.failed(error.localizedDescription)) }
            }
        }
    }
    private static func open(_ destination: CodexDestination, taskId: String, store: TargetStore, executor: InputExecutor,
                             pointer: PointerExecutor?, authorized: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        guard let target = AgentAppDispatch.target(named: "Codex", in: store.targets) else {
            completion(.failed("请先在 PocketDesk 控制台添加 Codex 应用。")); return
        }
        AgentAppDispatch.dispatchQueue.enqueue { release in
            guard authorized(), TaskStore.task(id: taskId)?.status == .running else {
                release(); completion(.failed("排队期间控制权或任务状态已变化。")); return
            }
            InputActivity.shared.begin()
            let finish: (Reply) -> Void = { reply in
                InputActivity.shared.end(); release(); completion(reply)
            }
            executor.activate(target.id) { activation in
                guard case .success(let activation) = activation, let pid = activation.pid else {
                    finish(.failed("Codex 未能激活。")); return
                }
                CodexNavigator.prepare(destination: destination, target: target, pid: pid, text: nil,
                    pointer: pointer, authorized: authorized) { result in
                    switch result {
                    case .failure(let error): finish(.failed(error.message))
                    case .success:
                        ExecutionLog.shared.append(kind: "codex", label: "打开 Codex 目标", outcome: .delivered, detail: destination.name)
                        finish(.opened("已打开 " + destination.name + "，输入框已就绪。"))
                    }
                }
            }
        }
    }
}
