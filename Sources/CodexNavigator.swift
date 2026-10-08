/**
 * [INPUT]: 已解析本机 Codex 目标、官方深链、AgentTaskComposer 的 AX/焦点/语义点击能力与控制租约。
 * [OUTPUT]: 定向打开项目/任务/Your dot 后的准确空白或预填撰写框；优先读取撰写区，兼容新页项目按钮的完整标签/局部裸名并记录核验阶段诊断，旧任务绑定选中路由。
 * [POS]: 原生导航适配器；仅在用户调用 C 时运行，不用猜坐标或私有写接口。DOT 与蓝点语义仍待实机验收。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

enum CodexNavigator {
    static let dotNames: Set<String> = ["Your dot", "Your.dot", "Your Dot", "你的 dot", "你的 Dot"]

    /// 列表颜色本身不是 AX 证据，只接受可访问性明确给出的未读语义。
    static func isUnreadLabel(_ label: String, title: String) -> Bool {
        [title + ", Unread", title + ", unread", title + "，未读", title + " 未读",
         "Unread, " + title, "未读，" + title].contains(label)
    }
    static func visibleUnread(chats: [CodexCatalog.Chat], pid: pid_t) -> [CodexCatalog.Chat] {
        let nodes = AgentTaskComposer.nodes(pid: pid)
        // 只把可见的明确未读项标为 yes；不可见的不能当作 no。
        return chats.map { chat in
            let unique = chats.filter { $0.title == chat.title }.count == 1
            let unread = unique && nodes.contains {
                isUnreadLabel($0.label, title: chat.title) || ($0.label == chat.title && ["Unread", "unread", "未读"].contains($0.help))
            }
            return .init(id: chat.id, title: chat.title, cwd: chat.cwd, projectId: chat.projectId,
                         unread: unread ? true : chat.unread)
        }
    }
    static func matches(_ destination: CodexDestination, pid: pid_t) -> Bool {
        matches(destination, nodes: AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true))
    }
    private static func matches(_ destination: CodexDestination, nodes: [AgentTaskComposer.Node]) -> Bool {
        // 新聊天项目按钮没有 AXSelected，default/hero 也没有完整前缀标签。
        // 裸名须同时满足撰写区容器与几何关联，普通正文/侧栏同名仍不能确认目标。
        if case .project = destination {
            return !projectSelectors(destination, nodes: nodes).isEmpty
        }
        return CodexSelection.identityMatches(destination, labels: Set(nodes.map(\.label)),
                                              selected: Set(nodes.filter(\.routeSelected).map(\.label)))
    }

    private struct ProjectSelector {
        let node: AgentTaskComposer.Node
        let matchedLabel: String
        let composerScoped: Bool
    }
    private static func names(_ node: AgentTaskComposer.Node) -> [String] {
        Array(Set(node.accessibleNames + [node.label, node.help])).filter { !$0.isEmpty }
    }
    private static func projectSelectors(_ destination: CodexDestination,
                                         nodes: [AgentTaskComposer.Node]) -> [ProjectSelector] {
        guard case .project = destination else { return [] }
        let editors = nodes.filter { $0.role == "AXTextArea" && $0.enabled }
        let editor = editors.count == 1 ? editors.first : nil
        // 先用更强的完整标签。home 页可同时出现标题裸名和带标签的页脚按钮；
        // 不能把兼容的裸名候选反过来制造歧义。
        let explicit: [ProjectSelector] = nodes.compactMap { node in
            guard node.enabled, ["AXButton", "AXPopUpButton"].contains(node.role) else { return nil }
            let labels = names(node)
            if let label = CodexSelection.projectSelectorLabel(destination, role: node.role, labels: labels) {
                return ProjectSelector(node: node, matchedLabel: label, composerScoped: false)
            }
            return nil
        }
        if !explicit.isEmpty { return explicit }
        return nodes.compactMap { node in
            guard node.enabled, ["AXButton", "AXPopUpButton"].contains(node.role) else { return nil }
            let labels = names(node)
            guard let label = CodexSelection.projectSelectorLabel(destination, role: node.role, labels: labels, composerScoped: true),
                  let editor, sharesComposerScope(control: node.element, editor: editor.element) else { return nil }
            return ProjectSelector(node: node, matchedLabel: label, composerScoped: true)
        }
    }
    private static func sharesComposerScope(control: AXUIElement, editor: AXUIElement) -> Bool {
        let controlFrame = AgentTaskComposer.frame(control), editorFrame = AgentTaskComposer.frame(editor)
        guard CodexSelection.isComposerControl(frame: controlFrame, editorFrame: editorFrame) else { return false }
        // 只接受共同的局部容器；整页 WebArea/Window/Application 不算关联。
        // 深度界限只约束读取成本，不能单凭“上移几层”宣布身份成立。
        func containers(_ element: AXUIElement) -> [AXUIElement] {
            var current = element, result: [AXUIElement] = []
            for _ in 0..<8 {
                var raw: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &raw) == .success,
                      let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
                current = raw as! AXUIElement
                let role = AgentTaskComposer.string(current, kAXRoleAttribute) ?? ""
                if ["AXWebArea", "AXWindow", "AXApplication"].contains(role) { break }
                if ["AXGroup", "AXToolbar", "AXLayoutArea", "AXScrollArea"].contains(role) { result.append(current) }
            }
            return result
        }
        let controlContainers = containers(control)
        return containers(editor).contains { container in
            controlContainers.contains { CFEqual($0, container) }
                && CodexSelection.isComposerContainer(frame: AgentTaskComposer.frame(container),
                    editorFrame: editorFrame, controlFrame: controlFrame)
        }
    }

    static func prepare(destination: CodexDestination, target: TargetConfig, pid: pid_t, text: String?,
                        pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                        completion: @escaping (Result<AgentTaskComposer.Prepared, AgentComposerFailure>) -> Void) {
        let observe = {
            AgentTaskComposer.queue.async {
                verify(destination: destination, pid: pid, text: text, pointer: pointer,
                       authorized: authorized, completion: completion)
            }
        }
        switch destination {
        case .dot:
            AgentTaskComposer.queue.async {
                guard AgentTaskComposer.valid(pid, authorized) else {
                    completion(.failure(.init(message: "Codex 已失去焦点或控制权。"))); return
                }
                _ = InputFocus.focusedElement(pid: pid)
                let nodes = AgentTaskComposer.nodes(pid: pid)
                if matches(destination, pid: pid) { observe(); return }
                let entries = nodes.filter { dotNames.contains($0.label) && $0.enabled && ["AXButton", "AXLink", "AXRow", "AXRadioButton", "AXTab"].contains($0.role) }
                guard entries.count == 1, let entry = entries.first else {
                    completion(.failure(.init(message: "没有找到唯一的 Your dot 入口，请展开 Codex 侧边栏并确认 dot 已创建。"))); return
                }
                AgentTaskComposer.press(entry.element, pid: pid, pointer: pointer, authorized: authorized) { pressed in
                    if pressed { observe() }
                    else { completion(.failure(.init(message: "Your dot 入口未能打开，未输入正文。"))) }
                }
            }
        case .project(let project, let path, _):
            var isDirectory: ObjCBool = false
            guard project.paths.contains(path), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let url = AgentAppProfile.codexURL(text: text ?? "", projectPath: path) else {
                completion(.failure(.init(message: "项目目录已不存在或不是目录，未新建任务。"))); return
            }
            open(url, target: target, authorized: authorized, completion: completion, observe: observe)
        case .task(let chat, _):
            guard let url = AgentAppProfile.codexThreadURL(id: chat.id) else {
                completion(.failure(.init(message: "Codex 任务 ID 无效。"))); return
            }
            open(url, target: target, authorized: authorized, completion: completion, observe: observe)
        }
    }
    private static func open(_ url: URL, target: TargetConfig, authorized: @escaping () -> Bool,
                             completion: @escaping (Result<AgentTaskComposer.Prepared, AgentComposerFailure>) -> Void,
                             observe: @escaping () -> Void) {
        guard let path = target.path else { completion(.failure(.init(message: "Codex 应用路径不可用。"))); return }
        DispatchQueue.main.async {
            guard authorized(), EnvironmentGate.blockReason() == nil else {
                completion(.failure(.init(message: "控制权或解锁状态已变化，未打开 Codex 目标。"))); return
            }
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error == nil else { completion(.failure(.init(message: "Codex 目标链接未能打开。"))); return }
                observe()
            }
        }
    }
    private static func verify(destination: CodexDestination, pid: pid_t, text: String?, pointer: PointerExecutor?,
                               authorized: @escaping () -> Bool,
                               completion: @escaping (Result<AgentTaskComposer.Prepared, AgentComposerFailure>) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        var reason = "未能核对 Codex 目标页；请在目标页重新下达指令。"
        var diagnostic = "未取得页面快照"
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard AgentTaskComposer.valid(pid, authorized) else {
                completion(.failure(.init(message: "导航期间焦点或控制权已变化，未输入正文。"))); return
            }
            var truncated = false
            let snapshot = AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true) { _, incomplete in truncated = incomplete }
            let selectors = projectSelectors(destination, nodes: snapshot)
            let isProject: Bool
            if case .project = destination { isProject = true } else { isProject = false }
            let inputs = snapshot.filter { $0.role == "AXTextArea" && $0.enabled }
            let textMatched = inputs.filter { $0.value == (text ?? "") }.count
            diagnostic = "nodes=\(snapshot.count); truncated=\(truncated); editors=\(inputs.count); textMatched=\(textMatched); projectSelectors=\(selectors.count); scopedSelectors=\(selectors.filter(\.composerScoped).count)"
            if isProject {
                if inputs.isEmpty { reason = "Codex 项目页尚未读到任务输入框；未发送，预填内容已保留。" }
                else if selectors.isEmpty { reason = "正文已预填，但未能核实撰写区的当前项目；未发送，草稿已保留。" }
            }
            if isProject ? !selectors.isEmpty : matches(destination, nodes: snapshot) {
                let acceptable = inputs.filter { input in
                    guard let value = input.value else { return false }
                    if case .project = destination { return value == (text ?? "") }
                    // 打开时保留旧草稿；发送时仅使用已空输入框。
                    return text == nil || AgentAppProfile.clean(value).isEmpty
                }
                if inputs.count == 1, let composer = acceptable.first {
                    guard selectors.count <= 1 else {
                        completion(.failure(.init(message: "当前项目选择器不唯一；未发送，草稿已保留。"))); return
                    }
                    let evidence: [AgentTaskComposer.Node]
                    if case .project = destination { evidence = selectors.map(\.node) }
                    else { evidence = snapshot.filter { node in
                        node.enabled && node.routeSelected && CodexSelection.identityMatches(destination, labels: [], selected: [node.label])
                    } }
                    guard let route = evidence.first else {
                        completion(.failure(.init(message: "未取得 Codex 目标选择证据，未输入正文。"))); return
                    }
                    let matchedLabel = selectors.first?.matchedLabel ?? route.label
                    let composerScoped = selectors.first?.composerScoped == true
                    let boundRoute = {
                        let role = AgentTaskComposer.string(route.element, kAXRoleAttribute) ?? ""
                        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
                            .compactMap { AgentTaskComposer.string(route.element, $0) }
                        var enabled: CFTypeRef?
                        _ = AXUIElementCopyAttributeValue(route.element, kAXEnabledAttribute as CFString, &enabled)
                        guard AgentTaskComposer.accessibilityBool(enabled) != false, labels.contains(matchedLabel),
                              !composerScoped || sharesComposerScope(control: route.element, editor: composer.element) else { return false }
                        return CodexSelection.isProjectSelector(destination, role: role, label: matchedLabel, composerScoped: composerScoped)
                            || AgentTaskComposer.isCurrentRoute(route.element)
                    }
                    AgentTaskComposer.press(composer.element, pid: pid, pointer: pointer, authorized: authorized) { success in
                        guard success, boundRoute(), let focused = InputFocus.focusedElement(pid: pid), CFEqual(focused, composer.element) else {
                            completion(.failure(.init(message: "目标已打开，但输入框焦点未核实。"))); return
                        }
                        let prefilled: Bool
                        if case .project = destination { prefilled = text != nil } else { prefilled = false }
                        var prepared = AgentTaskComposer.Prepared(element: focused, prefilled: prefilled,
                            validateTarget: boundRoute)
                        // 新页在成功创建任务后会替换项目选择器；提交前仍绑定精确目标，
                        // 提交后交给本次原框清空/新增正文与执行信号核验，不能要求已销毁的新页控件仍存在。
                        if case .project = destination { prepared.validateTargetAfterSubmit = false }
                        completion(.success(prepared))
                    }
                    return
                }
                reason = "目标已打开，但输入框不唯一、不可读或已有草稿；已保留草稿，未发送。"
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        ExecutionLog.shared.append(kind: "codex", label: "Codex 目标页核验", outcome: .blocked,
            detail: diagnostic)
        completion(.failure(.init(message: reason)))
    }
}
