/**
 * [INPUT]: 依赖已配置 TargetStore、共享 InputExecutor、InputFocus、TargetWindowLocator、PointerGeometry 与共享 PointerExecutor；控制租约保护聚焦与投递。
 * [OUTPUT]: 以真实包身份兼容 Codex 安装为 ChatGPT.app 的接收者别名； 提供 AgentAppDispatch.send：在已配置 Agent 的当前对话中恢复输入焦点、清空输入框、写入并提交任务，返回投递证据并持久保存成功接续目标。
 * [POS]: Agent 工具与现有输入事务之间的适配层；不创建第二套键盘执行器，不操作聊天联系人。
 *        派单前先 Cmd+A + Delete 清空输入框再写入：不依赖「AXValue 为空」这条判据，
 *        因为 Chromium 应用（WorkBuddy 等）的 AXValue 读到的是会变化的占位提示，该判据恒为假。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

enum AgentAppDispatch {
    // 已明确支持派单的 Agent 名称；普通聊天应用不能借这个入口向未知联系人发消息。
    static let supportedNames: Set<String> = ["cola", "codex", "zcode", "workbuddy", "chatgpt"]

    static func target(named name: String, in targets: [TargetConfig]) -> TargetConfig? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedNames.contains(key) else { return nil }
        // Codex 可安装为 ChatGPT.app；真实包身份优先于用户可改的名称。
        let matches = targets.filter { target in
            if target.name.lowercased() == key || target.id.lowercased() == key { return true }
            let installedID = target.path.flatMap { Bundle(path: $0)?.bundleIdentifier }
            return key == "codex" && (installedID ?? target.bundleID) == "com.openai.codex"
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func send(app: String, text: String, taskId: String, store: TargetStore,
                     executor: InputExecutor, pointer: PointerExecutor? = nil, authorized: @escaping () -> Bool,
                     completion: @escaping (String) -> Void) {
        guard let target = target(named: app, in: store.targets) else {
            completion("未派单：请先在电脑控制台添加该 Agent，使用配置中的名称。目前仅支持 Cola、Codex、ZCode、WorkBuddy、ChatGPT；不支持联系人发信。")
            return
        }
        guard text.utf16.count <= 8000 else { completion("未派单：任务正文超过 8000 字符限制。"); return }
        guard authorized() else { completion("未派单：控制权已失效。"); return }
        guard let task = TaskStore.task(id: taskId),
              !task.messages.contains(where: { $0.toolName == "dispatch_to_app" }) else {
            completion("本任务已经尝试派单，请查看目标应用；不会重复提交。"); return
        }
        executor.activate(target.id) { result in
            guard case .success(let activation) = result, let pid = activation.pid else {
                completion("未派单：应用未能激活。"); return
            }
            prepareInputFocus(pid: pid, pointer: pointer, authorized: authorized) { focused in
                guard focused else {
                    completion("未派单：未能定位并聚焦目标输入框，请在目标应用点一下任务输入框后重新下达指令。"); return
                }
                guard authorized(), InputFocus.focusedApplicationPID() == pid,
                      InputFocus.probeFocus(pid: pid).verdict == .editable,
                      let element = InputFocus.focusedElement(pid: pid) else {
                    completion("未派单：目标应用不在前台或没有可输入的输入框。"); return
                }
                // 投递开始前持久标记。不确定结果也不能让模型再自动提交一次。
                guard var task = TaskStore.task(id: taskId),
                      !task.messages.contains(where: { $0.toolName == "dispatch_to_app" }) else {
                    completion("本任务已经尝试派单，请查看目标应用；不会重复提交。"); return
                }
                task.messages.append(TaskMessage(role: .tool, text: "派单尝试：" + target.name, toolName: "dispatch_to_app"))
                do { try TaskStore.save(task) } catch { completion("未派单：无法保存投递记录。"); return }
                // 刻意不校验「输入框必须为空」：WorkBuddy 等 Chromium 应用的 AXValue 读到的是**占位提示**
                // （「今天帮你做些什么？ @ 引用对话文件，/ 调用技能与指令」之类，且每次读都不一样），
                // 空框时也永远非空，这条判据在这些应用上恒为假、派单会被永久拒绝。
                // 改为先 Cmd+A + Delete 清空再写入：结果可预期，且清空对空框是无害空操作。
                guard executor.clearComposerForAgentDispatch() else {
                    completion("未派单：清空目标输入框的按键未能发出。"); return
                }
                let payload: [String: Any] = ["draftId": "agent-" + taskId, "targetId": target.id,
                                               "text": text, "submit": true]
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let command = try? JSONDecoder().decode(LiveInputCommand.self, from: data) else {
                    completion("未派单：指令格式无效。"); return
                }
                executor.mirror(command, authorized: {
                    // 输入框已在上一步清空，这里只守住「控制权仍有效 + 焦点没跑掉」。
                    // 不再重复判空：Chromium 应用的 AXValue 判不出空，重复判只会把派单再挡死一次。
                    guard authorized(), InputFocus.focusedApplicationPID() == pid,
                          let current = InputFocus.focusedElement(pid: pid), CFEqual(current, element) else { return false }
                    return true
                }) { result in
                    switch result {
                    case .success(let receipt):
                        if receipt.committed, var current = TaskStore.task(id: taskId) {
                            current.handoffTargetId = target.id
                            current.handoffTargetName = target.name
                            do { try TaskStore.save(current) }
                            catch { completion("结果待核对：任务已提交，接续记录保存失败，请查看电脑。"); return }
                        }
                        completion(receipt.committed
                            ? "已向\(target.name)提交任务；不代表该 Agent 已完成，结果请在电脑查看。"
                            : "结果待核对：" + receipt.note)
                    case .failure(let failure):
                        completion("派单未确认，请查看电脑，不能自动重试：" + failure.message)
                    }
                }
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
