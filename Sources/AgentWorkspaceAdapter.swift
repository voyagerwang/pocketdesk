/**
 * [INPUT]: WorkBuddy/ZCode 项目动作协议、原生选择器与共享应用/输入执行器。
 * [OUTPUT]: 实时项目候选、空白新任务或指定项目派单回执。
 * [POS]: C 的原生项目能力入口；共用 FIFO、租约与原子派单记录，不改变应用权限/模型。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum AgentWorkspaceAdapter {
    enum Reply { case listed(String), opened(String), needsInput(String), failed(String), dispatched(AppDispatchReceipt) }
    static func execute(_ request: AgentWorkspaceRequest, taskId: String, store: TargetStore, executor: InputExecutor,
                        pointer: PointerExecutor?, authorized: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        guard authorized(), let target = AgentAppDispatch.target(named: request.appKey, in: store.targets),
              let profile = AgentAppProfile.resolve(target), AgentWorkspaceComposer.supported(profile) else {
            completion(.failed("未找到已配置的 WorkBuddy/ZCode 应用，或控制权已失效。")); return
        }
        if request.action == .sendTask {
            AgentAppDispatch.send(app: request.appKey, text: request.text!, taskId: taskId, project: request.project,
                store: store, executor: executor, pointer: pointer, authorized: authorized) { completion(.dispatched($0)) }
            return
        }
        AgentAppDispatch.dispatchQueue.enqueue { release in
            guard authorized(), TaskStore.task(id: taskId)?.status == .running else { release(); completion(.failed("排队期间控制权或任务状态已变化。")); return }
            InputActivity.shared.begin()
            let finish: (Reply) -> Void = { result in InputActivity.shared.end(); release(); completion(result) }
            executor.activate(target.id) { result in
                guard case .success(let activation) = result, let pid = activation.pid else { finish(.failed("目标应用未能激活。")); return }
                AgentWorkspaceComposer.prepare(profile: profile, target: target, pid: pid, project: request.project,
                    pointer: pointer, authorized: authorized) { result in
                    switch result {
                    case .failure(let error): finish(.needsInput(error.message))
                    case .success:
                        if request.action == .listProjects {
                            AgentWorkspaceComposer.readProjects(profile: profile, pid: pid, pointer: pointer, authorized: authorized) { result in
                                switch result {
                                case .failure(let error): finish(.failed(error.message))
                                case .success(let names):
                                    let payload: [String: Any] = ["app": profile.rawValue, "projects": names,
                                        "note": "当前原生项目菜单中的已有项目；只打开新建页和菜单，没有发送任务。"]
                                    let data = try? JSONSerialization.data(withJSONObject: payload)
                                    finish(.listed(data.flatMap { String(data: $0, encoding: .utf8) } ?? "项目列表编码失败。"))
                                }
                            }
                        } else {
                            let name = request.project.map { " · " + $0 } ?? ""
                            finish(.opened("已打开 " + target.name + name + " 的空白新任务页，输入框已就绪。"))
                        }
                    }
                }
            }
        }
    }
}
