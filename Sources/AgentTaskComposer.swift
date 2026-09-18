/**
 * [INPUT]: 依赖 AgentAppProfile、AppKit AX、TargetWindowLocator 与现有 PointerExecutor；控制租约约束每次界面动作。
 * [OUTPUT]: 准备并核验新任务撰写框，返回精确 AX 绑定及是否已由 Codex 官方链接预填正文；预填任务点击唯一可用发送按钮并观察正文清空；失败说明阶段，不降级到旧对话。
 * [POS]: 应用新建适配层；导航、聚焦及核验预填任务的语义提交，不清空旧草稿。Codex 使用官方 codex://threads/new?prompt=，其他应用点击真实语义入口。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

struct AgentComposerFailure: LocalizedError {
    let message: String
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
                               completion: @escaping (Result<Void, AgentComposerFailure>) -> Void) {
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
                completion(.failure(.init(message: "正文已填入，但未找到唯一可用的发送按钮，请在目标应用发送。"))); return
            }
            press(button.element, pid: pid, pointer: pointer, authorized: authorized) { pressed in
                queue.async {
                    guard pressed else {
                        completion(.failure(.init(message: "发送按钮未能点击，正文保留。"))); return
                    }
                    for _ in 0..<15 {
                        guard valid(pid, authorized) else { break }
                        // 只认当前页面空撰写框，旧元素失效不能冒充已提交；不自动重复点击。
                        let composers = nodes(pid: pid).filter { $0.role == "AXTextArea" && $0.enabled }
                        if composers.count == 1, let value = composers[0].value, AgentAppProfile.clean(value).isEmpty {
                            completion(.success(())); return
                        }
                        Thread.sleep(forTimeInterval: 0.15)
                    }
                    completion(.failure(.init(message: "发送按钮已点击，但未确认正文已提交；请查看目标应用，不会重复发送。")))
                }
            }
        }
    }

    private static func verify(profile: AgentAppProfile, pid: pid_t, text: String, beforeLabels: Set<String>,
                               pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                               completion: @escaping (Result<Prepared, AgentComposerFailure>) -> Void) {
        // 只重复观察，不重复点击新建、写入或提交。
        var reason = "未能确认新任务页面与输入框，未输入正文。"
        for _ in 0..<12 {
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
        return (value as? NSNumber)?.boolValue
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
