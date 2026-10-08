/**
 * [INPUT]: 依赖 AgentAppProfile、AppKit AX、TargetWindowLocator 与现有 PointerExecutor；控制租约约束每次界面动作。
 * [OUTPUT]: 保留控件完整 AX 标签并提供有界读取诊断，Codex 预填页优先读取撰写区；WorkBuddy/ZCode 原生项目导航的菜单分区与输入局部读取、提交前项目重核验和新页接收证据；Cue 专属空框/URL 与原生发送核验；暴露受控 AX 导航给 Codex 专属适配，并在发送前持续校验目标与焦点；发送动作后无法确认时进入待核对。准备并核验新任务撰写框，兼容 AX 数字/字符串状态并区分页面、空白框、歧义核验失败；返回精确 AX 绑定及是否已由 Codex 官方链接预填正文；预填任务点击唯一可用发送按钮，按绑定框清空或新增正文与执行信号核验；返回是否可见本次执行；失败区分发送前拒绝与发送后待核对，不降级到旧对话。
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
        var element: AXUIElement
        let prefilled: Bool
        var validateTarget: (() -> Bool)? = nil
        var validateTargetAfterSubmit: Bool = true
        var contextName: String? = nil
        var refreshBeforeSubmit: ((@escaping (Result<AXUIElement, AgentComposerFailure>) -> Void) -> Void)? = nil
    }
    struct Node {
        let element: AXUIElement
        let role: String
        let label: String
        let value: String?
        let placeholder: String
        let selected: Bool
        let enabled: Bool
        var help: String = ""
        var pageURL: String? = nil
        var routeSelected: Bool = false
        var inMenu: Bool = false
        var accessibleNames: [String] = []
    }
    static let queue = DispatchQueue(label: "pocketdesk.agent-composer", qos: .userInitiated)

    static func prepare(profile: AgentAppProfile, target: TargetConfig, pid: pid_t, text: String,
                        pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                        completion: @escaping (Result<Prepared, AgentComposerFailure>) -> Void) {
        if profile == .cue {
            prepareCue(pid: pid, pointer: pointer, authorized: authorized, completion: completion)
            return
        }
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
            let before = nodes(pid: pid, prioritizeEditor: AgentWorkspaceComposer.supported(profile))
            if AgentWorkspaceComposer.supported(profile) {
                let labels = Set(before.map(\.label))
                let emptyNew = before.filter {
                    $0.role == "AXTextArea" && $0.enabled && profile.isEmptyComposer(value: $0.value, placeholder: $0.placeholder)
                        && profile.hasNewPageEvidence(labels: labels,
                            selectedNewTab: before.contains { profile.newButtonNames.contains($0.label) && $0.selected },
                            placeholder: $0.placeholder, beforeLabels: [])
                }
                if emptyNew.count == 1, let composer = emptyNew.first {
                    press(composer.element, pid: pid, pointer: pointer, authorized: authorized) { focused in
                        guard focused, valid(pid, authorized), let current = InputFocus.focusedElement(pid: pid), CFEqual(current, composer.element) else {
                            completion(.failure(.init(message: authorized() ? "空白新任务页的输入焦点未核实。" : "控制连接已失效，请重新连接后重试。"))); return
                        }
                        completion(.success(.init(element: current, prefilled: false)))
                    }
                    return
                }
            }
            let buttons = before.filter {
                ["AXButton", "AXRadioButton", "AXTab"].contains($0.role)
                    && profile.newButtonNames.contains($0.label) && $0.enabled
            }
            guard buttons.count == 1, let button = buttons.first else {
                if AgentWorkspaceComposer.supported(profile) {
                    ExecutionLog.shared.append(kind: "workspace", label: "新建入口核验", outcome: .blocked,
                        detail: "\(profile.rawValue): nodes=\(before.count), newButtons=\(buttons.count), editors=\(before.filter { $0.role == "AXTextArea" }.count)")
                }
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
                               profile: AgentAppProfile? = nil,
                               pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                               completion: @escaping (Result<Bool, AgentComposerFailure>) -> Void) {
        if let refresh = prepared.refreshBeforeSubmit {
            refresh { result in
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let editor):
                    var ready = prepared; ready.element = editor; ready.refreshBeforeSubmit = nil
                    submitPrepared(pid: pid, prepared: ready, text: text, profile: profile, pointer: pointer, authorized: authorized, completion: completion)
                }
            }
            return
        }
        queue.async {
            let names: Set<String> = ["发送", "发送消息", "提交", "创建任务", "Send", "Send message", "Submit", "Create task", "Send now"]
            let prioritizeEditor = prepared.prefilled || profile == .codex || profile.map(AgentWorkspaceComposer.supported) == true
            var button: Node?
            for _ in 0..<12 {
                guard valid(pid, authorized), prepared.validateTarget?() != false,
                      let focused = InputFocus.focusedElement(pid: pid), CFEqual(focused, prepared.element),
                      preparedTextMatches(value: string(prepared.element, kAXValueAttribute), text: text, profile: profile) else {
                    completion(.failure(.init(message: "提交前正文或焦点已变化，保留草稿。"))); return
                }
                let snapshot = nodes(pid: pid, prioritizeEditor: prioritizeEditor)
                let candidates: [Node]
                if profile == .cue, let index = snapshot.firstIndex(where: { CFEqual($0.element, prepared.element) }) {
                    candidates = Array(snapshot.dropFirst(index + 1).prefix(8)).filter { $0.role == "AXButton" && $0.enabled && $0.label.isEmpty }
                } else {
                    candidates = snapshot.filter { node in
                        node.role == "AXButton" && node.enabled
                            && (node.accessibleNames + [node.label]).contains(where: names.contains)
                    }
                }
                if profile == .cue {
                    // 实机正文非空后右侧依次是麦克风和发送，两者均无 AX 名称。
                    // 仅接受该唯一按钮对与右侧几何顺序，不能把麦克风误认成发送。
                    if candidates.count == 2, let left = center(candidates[0].element), let right = center(candidates[1].element),
                       cueSendPair(candidateCount: candidates.count, left: left, right: right) {
                        button = candidates[1]; break
                    }
                } else if candidates.count == 1 { button = candidates[0]; break }
                Thread.sleep(forTimeInterval: 0.15)
            }
            guard let button else {
                completion(.failure(.init(message: "正文已填好，请在目标应用点发送。"))); return
            }
            let before = nodes(pid: pid, prioritizeEditor: prioritizeEditor)
            let beforeMessages = matchingMessages(before, text: text)
            let beforeRunning = hasRunningControl(before)
            // 快照读取可能耗时；真正点击前再次核对项目、焦点和正文。
            guard valid(pid, authorized), prepared.validateTarget?() != false,
                  let focused = InputFocus.focusedElement(pid: pid), CFEqual(focused, prepared.element),
                  preparedTextMatches(value: string(prepared.element, kAXValueAttribute), text: text, profile: profile) else {
                completion(.failure(.init(message: "发送前目标或正文已变化；未发送，草稿已保留。"))); return
            }
            press(button.element, pid: pid, pointer: pointer, authorized: authorized) { pressed in
                queue.async {
                    guard pressed else {
                        completion(.failure(.init(message: "发送动作结果待核对，请查看目标应用。", submissionAttempted: true))); return
                    }
                    for _ in 0..<40 {
                        guard valid(pid, authorized), !prepared.validateTargetAfterSubmit || prepared.validateTarget?() != false else { break }
                        let snapshot = nodes(pid: pid, prioritizeEditor: prioritizeEditor)
                        // 原绑定框清空是强证据；重建后的框须同时出现本次正文，不能认旁边的空框。
                        let composers = snapshot.filter { $0.role == "AXTextArea" }
                        let originalCleared = composers.contains {
                            CFEqual($0.element, prepared.element) && isClearedComposer(value: $0.value, profile: profile)
                        }
                        let newMessage = matchingMessages(snapshot, text: text) > beforeMessages
                        let runningStarted = !beforeRunning && hasRunningControl(snapshot)
                        let emptyComposer = composers.contains { isClearedComposer(value: $0.value, profile: profile) }
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

    static func cueSendPair(candidateCount: Int, left: CGPoint, right: CGPoint) -> Bool {
        candidateCount == 2 && right.x > left.x && abs(right.y - left.y) < 20
    }

    static func preparedTextMatches(value: String?, text: String, profile: AgentAppProfile?) -> Bool {
        guard let value else { return false }
        return [.cue, .workbuddy, .zcode].contains(profile) ? AgentAppProfile.clean(value) == AgentAppProfile.clean(text) : value == text
    }

    static func isClearedComposer(value: String?, profile: AgentAppProfile?) -> Bool {
        if let profile, [.cue, .workbuddy, .zcode].contains(profile) { return profile.isEmptyComposer(value: value, placeholder: nil) }
        return value.map { AgentAppProfile.clean($0).isEmpty } == true
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
            let snapshot = nodes(pid: pid, prioritizeEditor: profile == .codex || AgentWorkspaceComposer.supported(profile))
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

    static func nodes(pid: pid_t, prioritizeEditor: Bool = false,
                      onScan: ((Int, Bool) -> Void)? = nil) -> [Node] {
        guard let root = TargetWindowLocator.axWindowElement(pid: pid) else { onScan?(0, true); return [] }
        var result: [Node] = [], remaining = 6000
        var deadline = ProcessInfo.processInfo.systemUptime + 2
        var truncated = false
        var visited: [CFHashCode: [AXUIElement]] = [:]
        var complete: [CFHashCode: [AXUIElement]] = [:]
        func walk(_ element: AXUIElement, depth: Int, inMenu: Bool = false) {
            guard depth < 32, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; return }
            let hash = CFHash(element)
            if complete[hash]?.contains(where: { CFEqual($0, element) }) == true { return }
            let known = visited[hash]?.contains(where: { CFEqual($0, element) }) == true
            remaining -= 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if !known {
            visited[hash, default: []].append(element)
            let accessibleNames = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .compactMap { string(element, $0) }.filter { !$0.isEmpty }
            let label = accessibleNames.first
                ?? (role == "AXStaticText" ? string(element, kAXValueAttribute) : nil) ?? ""
            result.append(Node(element: element, role: role, label: label,
                value: string(element, kAXValueAttribute), placeholder: string(element, "AXPlaceholderValue") ?? "",
                selected: isSelected(element),
                enabled: bool(element, kAXEnabledAttribute) != false, help: string(element, kAXHelpAttribute) ?? "", pageURL: pageURL(element),
                routeSelected: isCurrentRoute(element), inMenu: inMenu, accessibleNames: accessibleNames))
            } else if inMenu, let index = result.firstIndex(where: { CFEqual($0.element, element) }) {
                result[index].inMenu = true
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { return }
            for child in list { walk(child, depth: depth + 1, inMenu: inMenu || role == "AXMenu") }
            if remaining > 0, ProcessInfo.processInfo.systemUptime < deadline { complete[hash, default: []].append(element) }
        }
        if prioritizeEditor, let focused = InputFocus.focusedElement(pid: pid) {
            // 大侧边栏可能耗尽全窗遍历预算；先读取真实焦点和其局部输入/菜单分区。
            walk(focused, depth: 0)
            var local = focused
            for _ in 0..<4 {
                if string(local, kAXRoleAttribute) == "AXMenu" { break }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(local, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                let candidate = parent as! AXUIElement
                let role = string(candidate, kAXRoleAttribute) ?? ""
                if ["AXWebArea", "AXWindow", "AXApplication"].contains(role) { break }
                local = candidate
            }
            deadline = ProcessInfo.processInfo.systemUptime + 2
            walk(local, depth: 0)
            deadline = ProcessInfo.processInfo.systemUptime + 2
        }
        walk(root, depth: 0)
        onScan?(result.count, truncated)
        return result
    }

    static func valid(_ pid: pid_t, _ authorized: () -> Bool) -> Bool {
        authorized() && EnvironmentGate.blockReason() == nil && InputFocus.focusedApplicationPID() == pid
    }

    private static func pageURL(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        return (value as? URL)?.absoluteString ?? value as? String
    }

    static func isSelected(_ element: AXUIElement) -> Bool {
        bool(element, "AXSelected") == true || bool(element, kAXValueAttribute) == true
            || ["page", "true"].contains(string(element, "AXARIACurrent") ?? "")
    }

    /// 正文或普通按钮的 AXValue=true 不是当前路由；旧新建页兼容和专属目标核验分开。
    static func isCurrentRoute(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        guard ["AXButton", "AXLink", "AXRow", "AXRadioButton", "AXTab"].contains(role) else { return false }
        return bool(element, "AXSelected") == true
            || ["page", "true"].contains(string(element, "AXARIACurrent") ?? "")
            || (["AXRadioButton", "AXTab"].contains(role) && bool(element, kAXValueAttribute) == true)
    }

    static func press(_ element: AXUIElement, pid: pid_t, pointer: PointerExecutor?,
                              authorized: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard valid(pid, authorized) else { completion(false); return }
        // 编辑器的 AXPress 可能只返回成功而不取得键盘焦点；编辑器必须走聚焦属性及真实点击核验。
        if string(element, kAXRoleAttribute) != "AXTextArea",
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
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

    static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func center(_ element: AXUIElement) -> CGPoint? {
        frame(element).map { CGPoint(x: $0.midX, y: $0.midY) }
    }
}
