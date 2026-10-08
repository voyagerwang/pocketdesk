/**
 * [INPUT]: 依赖 AgentAppProfile 的身份/模式、AgentTaskComposer 的新任务页证据和 TaskStore 原子派单占用； 依赖已配置 TargetStore、共享 InputExecutor、InputFocus、TargetWindowLocator、PointerGeometry 与共享 PointerExecutor；控制租约保护聚焦与投递。
 * [OUTPUT]: 支持 WorkBuddy/ZCode 指定项目新建，先填后点语义发送按钮；Cue 按真实包身份注册并向新群聊提交任务；支持已解析 Codex 项目/旧任务/DOT 目标，共用 FIFO 与原子派单；保留目标草稿并核对精确绑定后提交。以真实包身份兼容 Codex 安装为 ChatGPT.app 的接收者别名； 提供 AgentAppDispatch.send：默认创建独立新任务、仅显式 current 才沿用当前对话；核验页面及输入框后提交任务，返回结构化 AppDispatchReceipt，区分发送前失败与发送后待核对，并持久保存成功接续目标。
 * [POS]: Agent 工具与现有输入事务之间的适配层；不创建第二套键盘执行器，不操作聊天联系人。
 *        新任务禁止盲清空，页面证据不成立就停止；投递事务 FIFO 排队，任务执行不互斥；副作用前落幂等记录，不确定结果不重试。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

enum AgentAppDispatch {
    // 已明确支持派单的 Agent 名称；普通聊天应用不能借这个入口向未知联系人发消息。
    static let supportedNames: Set<String> = ["cola", "codex", "zcode", "workbuddy", "chatgpt", "cue"]

    static func target(named name: String, in targets: [TargetConfig]) -> TargetConfig? {
        let key = AgentAppProfile.canonicalName(name)
        guard supportedNames.contains(key) else { return nil }
        let matches = targets.filter { target in
            AgentAppProfile.canonicalName(target.name) == key || AgentAppProfile.canonicalName(target.id) == key
                || AgentAppProfile.resolve(target)?.rawValue == key
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static let dispatchQueue = AgentDispatchQueue()

    static func send(app: String, text: String, taskId: String, mode: AgentConversationMode = .newTask,
                     destination: CodexDestination? = nil,
                     project: String? = nil,
                     store: TargetStore, executor: InputExecutor, pointer: PointerExecutor? = nil,
                     authorized: @escaping () -> Bool, completion: @escaping (AppDispatchReceipt) -> Void) {
        if AgentAppProfile.canonicalName(app) == "cue", target(named: app, in: store.targets) == nil,
           !store.targets.contains(where: { AgentAppProfile.resolve($0) == .cue }),
           let installed = AppOperator.resolve("Cue"), Bundle(path: installed.path)?.bundleIdentifier == "ai.manus.agents" {
            store.save(store.targets + [.init(id: "cue", name: "Cue", bundleID: "ai.manus.agents", path: installed.path)])
        }
        guard let target = target(named: app, in: store.targets), let profile = AgentAppProfile.resolve(target) else {
            completion(.init(state: .failed, detail: "未找到已配置的 Agent 应用，请在电脑控制台添加。")); return
        }
        guard destination == nil || profile == .codex else {
            completion(.init(state: .failed, detail: "指定项目、任务或 DOT 仅适用于 Codex。")); return
        }
        guard project == nil || (destination == nil && mode == .newTask && AgentWorkspaceComposer.supported(profile)) else {
            completion(.init(state: .failed, detail: "项目定向只支持 WorkBuddy/ZCode 的新任务。")); return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 8000 else {
            completion(.init(state: .failed, detail: "任务正文为空或超过 8000 字符限制。")); return
        }
        guard authorized() else { completion(.init(state: .failed, detail: "控制权已失效。")); return }
        guard let task = TaskStore.task(id: taskId),
              !TaskStore.hasBlockedAppDispatch(task) else {
            completion(.init(state: .unconfirmed, detail: "本任务已经尝试派单，请查看目标应用；不会重复提交。")); return
        }
        dispatchQueue.enqueue { release in
            guard authorized(), TaskStore.task(id: taskId)?.status == .running else {
                release(); completion(.init(state: .failed, detail: "排队期间任务已结束或控制权失效，未操作目标应用。")); return
            }
            InputActivity.shared.begin()
            let finish: (AppDispatchReceipt) -> Void = { original in
                var result = original
                if result.submissionAttempted == nil, result.state == .failed || result.state == .needsInput {
                    result.submissionAttempted = false
                }
                InputActivity.shared.end()
                ExecutionLog.shared.append(kind: "dispatch", label: "Agent 派单 · " + mode.rawValue,
                    outcome: result.state == .confirmed ? .delivered : result.state == .unconfirmed ? .sent : .blocked, detail: result.detail)
                release()
                completion(result)
            }
            do {
                guard try TaskStore.reserveAppDispatch(id: taskId, label: "派单尝试：\(target.name) · \(mode.rawValue)") else {
                    finish(.init(state: .unconfirmed, detail: "本任务已经尝试派单或不再执行，不会重复创建或提交。")); return
                }
            } catch { finish(.init(state: .failed, detail: "无法保存派单记录，未操作目标应用。")); return }
            executor.activate(target.id) { result in
                guard case .success(let activation) = result, let pid = activation.pid else {
                    finish(.init(state: .failed, detail: "激活应用失败。")); return
                }
                let prepared: (Result<AgentTaskComposer.Prepared, AgentComposerFailure>) -> Void = { result in
                    switch result {
                    case .failure(let error): finish(.init(state: .needsInput, detail: error.message))
                    case .success(let composer):
                        submit(target: target, pid: pid, text: text, taskId: taskId, mode: mode,
                               composer: composer, destination: destination, executor: executor, pointer: pointer, authorized: authorized, completion: finish)
                    }
                }
                if let destination {
                    CodexNavigator.prepare(destination: destination, target: target, pid: pid, text: text,
                        pointer: pointer, authorized: authorized, completion: prepared)
                } else if mode == .newTask && AgentWorkspaceComposer.supported(profile) {
                    AgentWorkspaceComposer.prepare(profile: profile, target: target, pid: pid, project: project,
                        pointer: pointer, authorized: authorized, completion: prepared)
                } else if mode == .newTask {
                    AgentTaskComposer.prepare(profile: profile, target: target, pid: pid, text: text,
                        pointer: pointer, authorized: authorized, completion: prepared)
                } else {
                    prepareInputFocus(pid: pid, pointer: pointer, authorized: authorized) { focused in
                        guard focused, let element = InputFocus.focusedElement(pid: pid) else {
                            prepared(.failure(.init(message: "继续当前对话：未确认目标输入框。"))); return
                        }
                        prepared(.success(.init(element: element, prefilled: false)))
                    }
                }
            }
        }
    }

    private static func submit(target: TargetConfig, pid: pid_t, text: String, taskId: String,
                               mode: AgentConversationMode, composer: AgentTaskComposer.Prepared,
                               destination: CodexDestination?,
                               executor: InputExecutor, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                               completion: @escaping (AppDispatchReceipt) -> Void) {
        let stillValid: () -> Bool = {
            guard authorized(), composer.validateTarget?() != false, InputFocus.focusedApplicationPID() == pid,
                  let current = InputFocus.focusedElement(pid: pid) else { return false }
            return CFEqual(current, composer.element)
        }
        guard stillValid() else { completion(.init(state: .failed, detail: "提交前焦点或控制权已变化。")); return }
        let committed: (Bool) -> Void = { executionVisible in
            guard var task = TaskStore.task(id: taskId) else { completion(.init(state: .unconfirmed, detail: "提交已发出，任务记录不可用。")); return }
            task.handoffTargetId = target.id
            task.handoffTargetName = target.name
            do { try TaskStore.save(task) }
            catch { completion(.init(state: .unconfirmed, detail: "提交已发出，接续记录保存失败。")); return }
            let name = destination?.name ?? (target.name + (composer.contextName.map { " · " + $0 } ?? ""))
            completion(.init(state: .confirmed, detail: "已交给 " + name, targetName: name, executionVisible: executionVisible))
        }
        if composer.prefilled {
            AgentTaskComposer.submitPrepared(pid: pid, prepared: composer, text: text, pointer: pointer, authorized: authorized) { result in
                switch result {
                case .success(let executionVisible): committed(executionVisible)
                case .failure(let error):
                    completion(.init(state: error.submissionAttempted ? .unconfirmed : .needsInput, detail: error.message, targetName: target.name))
                }
            }
            return
        }
        if destination != nil {
            // 旧任务/DOT 的空框只填一次，然后走同一语义发送与接收核验；绝不清空用户草稿。
            guard AgentTaskComposer.string(composer.element, kAXValueAttribute).map({ AgentAppProfile.clean($0).isEmpty }) == true,
                  let data = try? JSONSerialization.data(withJSONObject: ["draftId": "codex-" + taskId, "targetId": target.id, "text": text, "submit": false]),
                  let command = try? JSONDecoder().decode(LiveInputCommand.self, from: data) else {
                completion(.init(state: .needsInput, detail: "目标输入框已有草稿或不可读，未覆盖。")); return
            }
            executor.mirror(command, authorized: stillValid, preflight: {
                stillValid() && AgentTaskComposer.string(composer.element, kAXValueAttribute).map { AgentAppProfile.clean($0).isEmpty } == true
            }) { result in
                guard case .success = result, stillValid(), AgentTaskComposer.string(composer.element, kAXValueAttribute) == text else {
                    completion(.init(state: .needsInput, detail: "正文未能准确填入目标输入框，未发送。")); return
                }
                AgentTaskComposer.submitPrepared(pid: pid, prepared: composer, text: text, pointer: pointer, authorized: authorized) { result in
                    switch result {
                    case .success(let visible): committed(visible)
                    case .failure(let error): completion(.init(state: error.submissionAttempted ? .unconfirmed : .needsInput, detail: error.message, targetName: destination?.name))
                    }
                }
            }
            return
        }
        // 新建页已核验空白，绝不清空旧对话；仅明确继续当前对话沿用原有替换行为。
        if mode == .current && !executor.clearComposerForAgentDispatch() {
            completion(.init(state: .failed, detail: "当前输入框清空按键未能发出。")); return
        }
        let profile = AgentAppProfile.resolve(target)
        let semanticSend = [.cue, .workbuddy, .zcode].contains(profile)
        let payload: [String: Any] = ["draftId": "agent-" + taskId + "-" + String(TaskStore.task(id: taskId)?.attempt ?? 1), "targetId": target.id, "text": text, "submit": !semanticSend]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let command = try? JSONDecoder().decode(LiveInputCommand.self, from: data) else {
            completion(.init(state: .failed, detail: "指令格式无效。")); return
        }
        executor.mirror(command, authorized: stillValid, preflight: {
            guard stillValid() else { return false }
            guard mode == .newTask else { return true }
            guard let profile = AgentAppProfile.resolve(target) else { return false }
            return profile.isEmptyComposer(value: AgentTaskComposer.string(composer.element, kAXValueAttribute), placeholder: nil)
        }) { result in
            switch result {
            case .success(let receipt):
                if semanticSend {
                    AgentTaskComposer.submitPrepared(pid: pid, prepared: composer, text: text, profile: profile, pointer: pointer, authorized: authorized) { result in
                        switch result {
                        case .success(let visible): committed(visible)
                        case .failure(let error): completion(.init(state: error.submissionAttempted ? .unconfirmed : .needsInput, detail: error.message, targetName: target.name, submissionAttempted: error.submissionAttempted))
                        }
                    }
                    return
                }
                if receipt.committed { committed(false) } else { completion(.init(state: .unconfirmed, detail: receipt.note, targetName: target.name)) }
            case .failure(let error):
                // 语义发送应用此时只写草稿，尚未调用发送；保留真实失败边界供用户续接。
                completion(.init(state: semanticSend ? .needsInput : .unconfirmed, detail: error.message,
                    targetName: target.name, submissionAttempted: semanticSend ? false : nil))
            }
        }
    }


    /// 优先沿用已有焦点；AX 设置无效时才真实点击已识别且可见的输入框，不猜窗口底部坐标。
    private static func prepareInputFocus(pid: pid_t, pointer: PointerExecutor?,
                                          authorized: @escaping () -> Bool,
                                          completion: @escaping (Bool) -> Void) {
        guard authorized(), InputFocus.focusedApplicationPID() == pid else { completion(false); return }
        if InputFocus.ensureEditableFocus(pid: pid) == .editable { completion(true); return }
        guard let pointer else { completion(false); return }
        let anchor = CGEvent(source: nil)?.location
        // Electron 的辅助功能树可能在激活后才生成；触发已有的有界等待再读取一次。
        _ = InputFocus.focusedElement(pid: pid)
        guard let point = TargetWindowLocator.findInputBoxCenter(pid: pid, includeSearchFields: false),
              let window = TargetWindowLocator.resolve(pid: pid),
              PointerGeometry.isCursorSettled(at: point, window: window.rect,
                  screens: PointerGeometry.activeDisplayRects(), occluders: window.occluders),
              authorized(), InputFocus.focusedApplicationPID() == pid else { completion(false); return }
        if let anchor, let current = CGEvent(source: nil)?.location,
           hypot(current.x - anchor.x, current.y - anchor.y) > 3 { completion(false); return }
        pointer.click(at: point) { clicked in
            guard clicked else { completion(false); return }
            // 点击回调只证明鼠标事件已发出，给应用一拍处理事件后再核验，未确认绝不清空或输入。
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(150)) {
                let focused = authorized() && InputFocus.focusedApplicationPID() == pid
                    && InputFocus.probeFocus(pid: pid).verdict == .editable
                ExecutionLog.shared.append(kind: "focus", label: "派单聚焦输入框",
                    outcome: focused ? .delivered : .blocked,
                    detail: focused ? "已点击并确认目标输入框焦点。" : "点击后未确认目标输入框焦点，未派单。")
                completion(focused)
            }
        }
    }
}
