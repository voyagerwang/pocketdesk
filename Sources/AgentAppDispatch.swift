/**
 * [INPUT]: 依赖 AgentAppProfile 的身份/模式、AgentTaskComposer 的新任务页证据和 TaskStore 原子派单占用； 依赖已配置 TargetStore、共享 InputExecutor、InputFocus、TargetWindowLocator、PointerGeometry 与共享 PointerExecutor；控制租约保护聚焦与投递。
 * [OUTPUT]: 以真实包身份兼容 Codex 安装为 ChatGPT.app 的接收者别名； 提供 AgentAppDispatch.send：默认创建独立新任务、仅显式 current 才沿用当前对话；核验页面及输入框后提交任务，返回投递证据并持久保存成功接续目标。
 * [POS]: Agent 工具与现有输入事务之间的适配层；不创建第二套键盘执行器，不操作聊天联系人。
 *        新任务禁止盲清空，页面证据不成立就停止；副作用前落幂等记录，不确定结果不重试。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

enum AgentAppDispatch {
    // 已明确支持派单的 Agent 名称；普通聊天应用不能借这个入口向未知联系人发消息。
    static let supportedNames: Set<String> = ["cola", "codex", "zcode", "workbuddy", "chatgpt"]

    static func target(named name: String, in targets: [TargetConfig]) -> TargetConfig? {
        let key = AgentAppProfile.canonicalName(name)
        guard supportedNames.contains(key) else { return nil }
        let matches = targets.filter { target in
            AgentAppProfile.canonicalName(target.name) == key || AgentAppProfile.canonicalName(target.id) == key
                || AgentAppProfile.resolve(target)?.rawValue == key
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static let lock = NSLock()
    private static var busy = false

    static func send(app: String, text: String, taskId: String, mode: AgentConversationMode = .newTask,
                     store: TargetStore, executor: InputExecutor, pointer: PointerExecutor? = nil,
                     authorized: @escaping () -> Bool, completion: @escaping (String) -> Void) {
        guard let target = target(named: app, in: store.targets), let profile = AgentAppProfile.resolve(target) else {
            completion("未派单：未找到已配置的 Agent 应用，请在电脑控制台添加。"); return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 8000 else {
            completion("未派单：任务正文为空或超过 8000 字符限制。"); return
        }
        guard authorized() else { completion("未派单：控制权已失效。"); return }
        guard let task = TaskStore.task(id: taskId),
              !task.messages.contains(where: { $0.toolName == "dispatch_to_app" }) else {
            completion("本任务已经尝试派单，请查看目标应用；不会重复提交。"); return
        }
        lock.lock()
        guard !busy else { lock.unlock(); completion("未派单：另一个应用派单尚未结束，请稍后重新下达指令。"); return }
        busy = true
        lock.unlock()
        InputActivity.shared.begin()
        let finish: (String) -> Void = { result in
            lock.lock(); busy = false; lock.unlock()
            InputActivity.shared.end()
            ExecutionLog.shared.append(kind: "dispatch", label: "Agent 派单 · " + mode.rawValue,
                outcome: result.hasPrefix("已向") ? .sent : .blocked, detail: result)
            completion(result)
        }
        do {
            guard try TaskStore.reserveAppDispatch(id: taskId, label: "派单尝试：\(target.name) · \(mode.rawValue)") else {
                finish("本任务已经尝试派单或不再执行，不会重复创建或提交。"); return
            }
        } catch { finish("未派单：无法保存派单记录，未操作目标应用。"); return }
        executor.activate(target.id) { result in
            guard case .success(let activation) = result, let pid = activation.pid else {
                finish("未派单：激活应用失败。"); return
            }
            let prepared: (Result<AgentTaskComposer.Prepared, AgentComposerFailure>) -> Void = { result in
                switch result {
                case .failure(let error): finish("未派单：" + error.message)
                case .success(let composer):
                    submit(target: target, pid: pid, text: text, taskId: taskId, mode: mode,
                           composer: composer, executor: executor, pointer: pointer, authorized: authorized, completion: finish)
                }
            }
            if mode == .newTask {
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

    private static func submit(target: TargetConfig, pid: pid_t, text: String, taskId: String,
                               mode: AgentConversationMode, composer: AgentTaskComposer.Prepared,
                               executor: InputExecutor, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                               completion: @escaping (String) -> Void) {
        let stillValid: () -> Bool = {
            guard authorized(), InputFocus.focusedApplicationPID() == pid,
                  let current = InputFocus.focusedElement(pid: pid) else { return false }
            return CFEqual(current, composer.element)
        }
        guard stillValid() else { completion("未派单：提交前焦点或控制权已变化。"); return }
        let committed: () -> Void = {
            guard var task = TaskStore.task(id: taskId) else { completion("结果待核对：提交已发出，任务记录不可用。"); return }
            task.handoffTargetId = target.id
            task.handoffTargetName = target.name
            do { try TaskStore.save(task) }
            catch { completion("结果待核对：提交已发出，接续记录保存失败。"); return }
            completion("已向\(target.name)的\(mode == .newTask ? "新任务" : "当前对话")发出提交；不代表该 Agent 已接收或完成，请在电脑查看。")
        }
        if composer.prefilled {
            AgentTaskComposer.submitPrepared(pid: pid, prepared: composer, text: text, pointer: pointer, authorized: authorized) { result in
                switch result {
                case .success: committed()
                case .failure(let error): completion("派单未确认，请查看电脑，不能自动重试：" + error.localizedDescription)
                }
            }
            return
        }
        // 新建页已核验空白，绝不清空旧对话；仅明确继续当前对话沿用原有替换行为。
        if mode == .current && !executor.clearComposerForAgentDispatch() {
            completion("未派单：当前输入框清空按键未能发出。"); return
        }
        let payload: [String: Any] = ["draftId": "agent-" + taskId, "targetId": target.id, "text": text, "submit": true]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let command = try? JSONDecoder().decode(LiveInputCommand.self, from: data) else {
            completion("未派单：指令格式无效。"); return
        }
        executor.mirror(command, authorized: stillValid, preflight: {
            guard stillValid() else { return false }
            guard mode == .newTask else { return true }
            guard let profile = AgentAppProfile.resolve(target) else { return false }
            return profile.isEmptyComposer(value: AgentTaskComposer.string(composer.element, kAXValueAttribute), placeholder: nil)
        }) { result in
            switch result {
            case .success(let receipt):
                if receipt.committed { committed() } else { completion("结果待核对：" + receipt.note) }
            case .failure(let error): completion("派单未确认，请查看电脑，不能自动重试：" + error.message)
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
