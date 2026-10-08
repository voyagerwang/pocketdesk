/** Cue 1.0.8：顶部菜单 → Create group chat → 选择已有 Cue → Create。
 新任务使用新群聊，不创建新 Agent；仅核验 Cue 的空框才写入，不清旧草稿。 */
import AppKit

extension AgentTaskComposer {
    static func isNewCueGroup(before: String?, after: String?) -> Bool {
        guard let before, let after, before != after else { return false }
        return isCueGroupURL(after)
    }

    static func isCueGroupURL(_ value: String?) -> Bool {
        guard let value, let url = URL(string: value),
              url.scheme == "cue", url.host == "desktop" else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count == 4 && parts.prefix(3).map(String.init) == ["app", "agents", "group"]
    }

    static func prepareCue(pid: pid_t, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                           completion: @escaping (Result<Prepared, AgentComposerFailure>) -> Void) {
        queue.async {
            guard valid(pid, authorized) else { completion(.failure(.init(message: "Cue 已失去焦点或控制权。"))); return }
            _ = InputFocus.focusedElement(pid: pid)
            let before = nodes(pid: pid)
            let beforeURL = before.compactMap(\.pageURL).first
            // 真实 AX 树顶部的第一个无名称弹出菜单是新建入口。
            guard let menu = before.first(where: { $0.role == "AXPopUpButton" && $0.label.isEmpty && $0.enabled }), beforeURL != nil else {
                completion(.failure(.init(message: "未确认 Cue 顶部新建菜单，原任务已保留。"))); return
            }
            press(menu.element, pid: pid, pointer: pointer, authorized: authorized) { opened in
                guard opened else { completion(.failure(.init(message: "Cue 新建菜单未能打开。"))); return }
                cueStep(pid: pid, label: "Create group chat", role: "AXStaticText", pointer: pointer, authorized: authorized) { chosen in
                    guard chosen else { completion(.failure(.init(message: "未找到 Cue 的 Create group chat 入口。"))); return }
                    queue.async {
                        let snapshot = nodes(pid: pid)
                        guard let start = snapshot.lastIndex(where: { $0.placeholder == "Search agents" || $0.label == "Search agents" }) else {
                            completion(.failure(.init(message: "未确认 Cue 新群聊对话框。"))); return
                        }
                        let choices = snapshot.dropFirst(start).filter { $0.role == "AXStaticText" && $0.label == "Cue" }
                        guard choices.count == 1, let cue = choices.first else {
                            completion(.failure(.init(message: "新群聊中未找到唯一 Cue 接收者。"))); return
                        }
                        press(cue.element, pid: pid, pointer: pointer, authorized: authorized) { selected in
                            guard selected else { completion(.failure(.init(message: "Cue 接收者未能选择。"))); return }
                            cueStep(pid: pid, label: "Create", role: "AXButton", pointer: pointer, authorized: authorized) { created in
                                guard created else { completion(.failure(.init(message: "Cue 新群聊未能创建，未发送任务。"))); return }
                                queue.async {
                                    for _cueObservation in 0..<30 {
                                        guard valid(pid, authorized) else { break }
                                        let fresh = nodes(pid: pid)
                                        let currentURL = fresh.compactMap(\.pageURL).first
                                        let inputs = cueInputs(fresh)
                                        if inputs.count != 1 || !isNewCueGroup(before: beforeURL, after: currentURL) {
                                            if _cueObservation == 29 {
                                                let areas = fresh.filter { $0.role == "AXTextArea" }
                                                ExecutionLog.shared.append(kind: "dispatch", label: "Cue 撰写框核验", outcome: .blocked,
                                                    detail: "新URL=\(isNewCueGroup(before: beforeURL, after: currentURL))；文本框=\(areas.count)；名称匹配=\(areas.filter { cueHint($0) }.count)；空框=\(areas.filter { AgentAppProfile.cue.isEmptyComposer(value: $0.value, placeholder: $0.placeholder) }.count)；可用=\(areas.filter { $0.enabled }.count)")
                                            }
                                        }
                                        if isNewCueGroup(before: beforeURL, after: currentURL), inputs.count == 1 {
                                            focusCue(inputs[0], pid: pid, pointer: pointer, authorized: authorized, completion: completion)
                                            return
                                        }
                                        Thread.sleep(forTimeInterval: 0.15)
                                    }
                                    completion(.failure(.init(message: "未核验 Cue 专属聊天与空白输入框，未发送任务。")))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Cue 的可访问名称实际来自 contenteditable 的占位 AXValue/StaticText，AXDescription 为空。
    static func cueComposerHint(label: String, placeholder: String, value: String? = nil, childHints: [String]) -> Bool {
        ([label, placeholder, value ?? ""] + childHints).contains { AgentAppProfile.clean($0) == "Message Cue" }
    }

    private static func cueHint(_ node: Node) -> Bool {
        var children: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(node.element, kAXChildrenAttribute as CFString, &children)
        let hints = read == .success ? (children as? [AXUIElement] ?? []).compactMap { child -> String? in
            guard string(child, kAXRoleAttribute) == "AXStaticText" else { return nil }
            return string(child, kAXValueAttribute) ?? string(child, kAXTitleAttribute)
        } : []
        return cueComposerHint(label: node.label, placeholder: node.placeholder, value: node.value, childHints: hints)
    }

    private static func cueInputs(_ snapshot: [Node]) -> [Node] {
        snapshot.filter { $0.role == "AXTextArea" && $0.enabled
            && cueHint($0)
            && AgentAppProfile.cue.isEmptyComposer(value: $0.value, placeholder: $0.placeholder) }
    }

    private static func focusCue(_ input: Node, pid: pid_t, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                                 completion: @escaping (Result<Prepared, AgentComposerFailure>) -> Void) {
        press(input.element, pid: pid, pointer: pointer, authorized: authorized) { focused in
            guard focused, let actual = InputFocus.focusedElement(pid: pid), CFEqual(actual, input.element) else {
                completion(.failure(.init(message: "Cue 聊天已定位，未确认输入焦点；未提交。"))); return
            }
            completion(.success(.init(element: actual, prefilled: false)))
        }
    }

    private static func cueStep(pid: pid_t, label: String, role: String, pointer: PointerExecutor?,
                                authorized: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        queue.async {
            for _ in 0..<15 {
                guard valid(pid, authorized) else { completion(false); return }
                let candidates = nodes(pid: pid).filter { $0.role == role && $0.label == label && $0.enabled }
                if candidates.count == 1 {
                    press(candidates[0].element, pid: pid, pointer: pointer, authorized: authorized, completion: completion)
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            completion(false)
        }
    }
}
