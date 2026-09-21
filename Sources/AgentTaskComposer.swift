/**
 * [INPUT]: 依赖 AgentAppProfile、AppKit AX、TargetWindowLocator 与现有 PointerExecutor；控制租约约束每次界面动作。
 * [OUTPUT]: 准备并核验新任务撰写框，兼容 AX 数字/字符串状态并区分页面、空白框、歧义核验失败；返回精确 AX 绑定及是否已由 Codex 官方链接预填正文；预填任务点击唯一可用发送按钮，按绑定框清空或新增正文与执行信号核验；返回是否可见本次执行；失败区分发送前拒绝与发送后待核对，不降级到旧对话。
 * [POS]: 应用新建适配层；导航、聚焦及核验预填任务的语义提交，不清空旧草稿。Codex 使用官方 codex://threads/new?prompt=，其他应用点击真实语义入口。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

struct AgentComposerFailure: LocalizedError {
    let message: String
    var submissionAttempted: Bool = false
    var errorDescription: String? { message }
}

enum AgentTaskComposer {
    struct Prepared {
        let element: AXUIElement
        let prefilled: Bool
    }
    struct Node {
        let element: AXUIElement
        let role: String
        let label: String
        let value: String?
        let placeholder: String
        let selected: Bool
        let enabled: Bool
    }
    static let queue = DispatchQueue(label: "pocketdesk.agent-composer", qos: .userInitiated)

    static func prepare(profile: AgentAppProfile, target: TargetConfig, pid: pid_t, text: String,
                        pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                        completion: @escaping (Result<Prepared, AgentComposerFailure>) -> Void) {
        if profile == .codex {
            guard let url = AgentAppProfile.codexURL(text: text), let path = target.path else {
                completion(.failure(.init(message: "新建任务：Codex 应用路径不可用。"))); return
            }
            DispatchQueue.main.async {
                guard authorized() else { completion(.failure(.init(message: "新建任务：控制权已失效。"))); return }
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path),
                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    guard error == nil else {
                        completion(.failure(.init(message: "新建任务：Codex 新任务链接未能打开。"))); return
                    }
                    queue.async { verify(profile: profile, pid: pid, text: text, beforeLabels: [],
                                         pointer: pointer, authorized: authorized, completion: completion) }
                }
            }
            return
        }
        queue.async {
            guard valid(pid, authorized) else { completion(.failure(.init(message: "新建任务：目标已失去焦点或控制权。"))); return }
            _ = InputFocus.focusedElement(pid: pid)
            let before = nodes(pid: pid)
            let buttons = before.filter {
                ["AXButton", "AXRadioButton", "AXTab"].contains($0.role)
                    && profile.newButtonNames.contains($0.label) && $0.enabled
            }
            guard buttons.count == 1, let button = buttons.first else {
                completion(.failure(.init(message: "新建任务：未找到唯一的新建入口，请展开目标应用侧边栏后再试。"))); return
            }
            press(button.element, pid: pid, pointer: pointer, authorized: authorized) { success in
                guard success else { completion(.failure(.init(message: "新建任务：新建入口未能点击，未输入正文。"))); return }
                queue.async {
                    verify(profile: profile, pid: pid, text: text, beforeLabels: Set(before.map(\.label)),
                           pointer: pointer, authorized: authorized, completion: completion)
                }
            }
        }
    }

    /// 预填正文不等于已创建任务。点击可访问性发送入口，避免回车被当作换行或被页面吞掉。
    static func submitPrepared(pid: pid_t, prepared: Prepared, text: String,
                               pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                               completion: @escaping (Result<Bool, AgentComposerFailure>) -> Void) {
        queue.async {
            let names: Set<String> = ["发送", "发送消息", "提交", "创建任务", "Send", "Send message", "Submit", "Create task", "Send now"]
            var button: Node?
            for _ in 0..<12 {
                guard valid(pid, authorized), string(prepared.element, kAXValueAttribute) == text else {
                    completion(.failure(.init(message: "提交前正文或焦点已变化，保留草稿。"))); return
                }
                let candidates = nodes(pid: pid).filter { $0.role == "AXButton" && $0.enabled && names.contains($0.label) }
                if candidates.count == 1 { button = candidates[0]; break }
                Thread.sleep(forTimeInterval: 0.15)
            }
            guard let button else {
                completion(.failure(.init(message: "正文已填好，请在目标应用点发送。"))); return
            }
            let before = nodes(pid: pid)
            let beforeMessages = matchingMessages(before, text: text)
            let beforeRunning = hasRunningControl(before)
            press(button.element, pid: pid, pointer: pointer, authorized: authorized) { pressed in
                queue.async {
                    guard pressed else {
                        completion(.failure(.init(message: "发送按钮未能点击，正文保留。"))); return
                    }
                    for _ in 0..<40 {
                        guard valid(pid, authorized) else { break }
                        let snapshot = nodes(pid: pid)
                        // 原绑定框清空是强证据；重建后的框须同时出现本次正文，不能认旁边的空框。
                        let composers = snapshot.filter { $0.role == "AXTextArea" }
                        let originalCleared = composers.contains {
                            CFEqual($0.element, prepared.element) && $0.value.map { AgentAppProfile.clean($0).isEmpty } == true
                        }
                        let newMessage = matchingMessages(snapshot, text: text) > beforeMessages
                        let runningStarted = !beforeRunning && hasRunningControl(snapshot)
                        let emptyComposer = composers.contains { $0.value.map { AgentAppProfile.clean($0).isEmpty } == true }
                        if acceptsSubmission(originalCleared: originalCleared, newMessage: newMessage,
                                             emptyComposer: emptyComposer, runningStarted: runningStarted) {
                            completion(.success(newMessage && runningStarted)); return
                        }
                        Thread.sleep(forTimeInterval: 0.15)
                    }
                    completion(.failure(.init(message: "已尝试发送，接收待核实。", submissionAttempted: true)))
                }
            }
        }
    }

    /// 纯证据策略：旧执行按钮、陌生空框和 AX 读取失败均不足以确认本次提交。
    static func acceptsSubmission(originalCleared: Bool, newMessage: Bool,
                                  emptyComposer: Bool, runningStarted: Bool) -> Bool {
        originalCleared || (newMessage && (emptyComposer || runningStarted))
    }

    private static func matchingMessages(_ snapshot: [Node], text: String) -> Int {
        let expected = AgentAppProfile.clean(text)
        return snapshot.filter {
            $0.role == "AXStaticText" && AgentAppProfile.clean($0.value ?? $0.label) == expected
        }.count
    }

    private static func hasRunningControl(_ snapshot: [Node]) -> Bool {
        let names: Set<String> = ["停止", "停止生成", "停止响应", "Stop", "Stop generating", "Stop response"]
        return snapshot.contains { $0.role == "AXButton" && $0.enabled && names.contains($0.label) }
    }

    private static func verify(profile: AgentAppProfile, pid: pid_t, text: String, beforeLabels: Set<String>,
                               pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                               completion: @escaping (Result<Prepared, AgentComposerFailure>) -> Void) {
        // 只重复观察，不重复点击新建、写入或提交。
        var reason = "未能确认新任务页面与输入框，未输入正文。"
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard valid(pid, authorized) else { reason = "目标已失去焦点或控制权。"; break }
            let snapshot = nodes(pid: pid)
            let labels = Set(snapshot.map(\.label))
            if profile == .cola && labels.contains("请选择模型") {
                reason = "Cola 新会话尚未选择模型，请先在 Cola 选择模型，再明确要求继续当前会话。"
                break
            }
            let composers = snapshot.filter { node in
                guard node.role == "AXTextArea", node.enabled else { return false }
                if profile == .codex { return node.value == text }
                return profile.isEmptyComposer(value: node.value, placeholder: node.placeholder)
                    && profile.hasNewPageEvidence(labels: labels,
                        selectedNewTab: snapshot.contains { profile.newButtonNames.contains($0.label) && $0.selected },
                        placeholder: node.placeholder, beforeLabels: beforeLabels)
            }
            let inputs = snapshot.filter { $0.role == "AXTextArea" && $0.enabled }
            if snapshot.isEmpty {
                reason = "目标窗口的辅助功能内容尚未就绪，未输入正文。"
            } else if inputs.isEmpty {
                reason = "新建页面尚未出现可编辑输入框，未输入正文。"
            } else if composers.count > 1 {
                reason = "新建页面存在多个候选输入框，未输入正文。"
            } else if !inputs.contains(where: { profile == .codex ? $0.value == text : profile.isEmptyComposer(value: $0.value, placeholder: $0.placeholder) }) {
                reason = "输入框内容不可读或已有草稿，未输入正文。"
            } else {
                reason = "输入框已找到，但新建页签或欢迎页面尚未确认，未输入正文。"
            }
            if composers.count == 1, let composer = composers.first {
                press(composer.element, pid: pid, pointer: pointer, authorized: authorized) { success in
                    queue.async {
                        guard success, valid(pid, authorized),
                              let focused = InputFocus.focusedElement(pid: pid), CFEqual(focused, composer.element) else {
                            completion(.failure(.init(message: "新建任务页已打开，但未确认撰写框焦点；未提交。"))); return
                        }
                        completion(.success(.init(element: focused, prefilled: profile == .codex)))
                    }
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        completion(.failure(.init(message: "新建任务：" + reason)))
    }

    static func string(_ element: AXUIElement, _ key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ key: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return accessibilityBool(value)
    }

    /// Electron 控件的状态可能以 CFNumber 或 CFString 暴露；未知值不能当作 true。
    static func accessibilityBool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        guard let text = value as? String else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }

    private static func nodes(pid: pid_t) -> [Node] {
        guard let root = TargetWindowLocator.axWindowElement(pid: pid) else { return [] }
        var result: [Node] = [], remaining = 6000
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 32, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else { return }
            remaining -= 1
            let role = string(element, kAXRoleAttribute) ?? ""
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .compactMap { string(element, $0) }.first(where: { !$0.isEmpty })
                ?? (role == "AXStaticText" ? string(element, kAXValueAttribute) : nil) ?? ""
            result.append(Node(element: element, role: role, label: label,
                value: string(element, kAXValueAttribute), placeholder: string(element, "AXPlaceholderValue") ?? "",
                selected: bool(element, "AXSelected") == true || bool(element, kAXValueAttribute) == true,
                enabled: bool(element, kAXEnabledAttribute) != false))
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { return }
            for child in list { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return result
    }

    private static func valid(_ pid: pid_t, _ authorized: () -> Bool) -> Bool {
        authorized() && EnvironmentGate.blockReason() == nil && InputFocus.focusedApplicationPID() == pid
    }

    private static func press(_ element: AXUIElement, pid: pid_t, pointer: PointerExecutor?,
                              authorized: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard valid(pid, authorized) else { completion(false); return }
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            Thread.sleep(forTimeInterval: 0.15); completion(true); return
        }
        if string(element, kAXRoleAttribute) == "AXTextArea",
           AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            Thread.sleep(forTimeInterval: 0.15)
            if let current = InputFocus.focusedElement(pid: pid), CFEqual(current, element) { completion(true); return }
        }
        guard let pointer, let point = center(element), let window = TargetWindowLocator.resolve(pid: pid),
              PointerGeometry.isCursorSettled(at: point, window: window.rect,
                    screens: PointerGeometry.activeDisplayRects(), occluders: window.occluders), valid(pid, authorized) else {
            completion(false); return
        }
        pointer.click(at: point) { clicked in
            queue.asyncAfter(deadline: .now() + .milliseconds(150)) { completion(clicked && valid(pid, authorized)) }
        }
    }

    private static func center(_ element: AXUIElement) -> CGPoint? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
    }
}
