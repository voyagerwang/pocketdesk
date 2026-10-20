/**
 * [INPUT]: 依赖应用页面语义、AppKit AX、TargetWindowLocator 与 PointerExecutor；租约和焦点约束每次导航、输入与发送。
 * [OUTPUT]: 提供指定窗口的有界AX快照、唯一新建入口与新页空框核验、物理编辑器焦点绑定及发送前全文核验；共享真实矩形左右键点击，语义提交一次后核验实际接收，未知结果不重发。
 * [POS]: 应用新建适配的共享机制；WorkBuddy草稿隔离由AgentWorkBuddyNewTask决定，项目选择由AgentWorkspaceComposer决定；此层只允许向已核验的新空框写入，Codex仍使用官方预填深链。
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
        var validateWindow: (() -> Bool)? = nil
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
        var navigationVisible: Bool = true
        var navigationFrame: CGRect? = nil
        var inComposer: Bool = false
    }
    static let queue = DispatchQueue(label: "pocketdesk.agent-composer", qos: .userInitiated)
    static let navigationFocusGraceSeconds: TimeInterval = 1
    static let nativeNavigationWaitSeconds: TimeInterval = 3

    enum NativeNavigationStep {
        case expandSidebar(Node), ready, waiting, blocked(String)
    }

    /// 同一物理控件的 AX 包装可重复出现；只合并同角色、精确同矩形的实际落点。
    static func uniqueNavigationControls(_ candidates: [Node]) -> [Node] {
        var unique: [Node] = []
        for candidate in candidates {
            let duplicated = unique.contains { existing in
                CFEqual(existing.element, candidate.element) || (existing.role == candidate.role
                    && candidate.navigationFrame != nil && existing.navigationFrame == candidate.navigationFrame)
            }
            if !duplicated { unique.append(candidate) }
        }
        return unique
    }

    static func newTaskButtons(profile: AgentAppProfile, snapshot: [Node]) -> [Node] {
        uniqueNavigationControls(snapshot.filter {
            ["AXButton", "AXRadioButton", "AXTab", "AXLink"].contains($0.role) && $0.enabled && $0.navigationVisible
                && ($0.accessibleNames + [$0.label]).contains(where: profile.newButtonNames.contains)
        })
    }

    static func visibleEmptyComposers(profile: AgentAppProfile, snapshot: [Node]) -> [Node] {
        uniqueNavigationControls(snapshot.filter {
            $0.role == "AXTextArea" && $0.enabled && $0.navigationVisible
                && profile.isEmptyComposer(value: $0.value, placeholder: $0.placeholder)
        })
    }

    static func preparedWorkBuddyComposers(snapshot: [Node], element: AXUIElement, bounds: CGRect?, text: String) -> [Node] {
        uniqueNavigationControls(snapshot.filter {
            $0.role == "AXTextArea" && $0.enabled && $0.navigationVisible
                && preparedTextMatches(value: $0.value, text: text, profile: .workbuddy)
                && (CFEqual($0.element, element) || (bounds != nil && $0.navigationFrame == bounds))
        })
    }

    /// 几何只补证同一控件的 AX 包装差异；角色、可见性、正文与应用归属仍必须成立。
    static func matchesWorkBuddyFocus(expected: Node, focused: Node, text: String?) -> Bool {
        guard [expected, focused].allSatisfy({ $0.role == "AXTextArea" && $0.enabled && $0.navigationVisible }),
              CFEqual(expected.element, focused.element)
                || (expected.navigationFrame != nil && expected.navigationFrame == focused.navigationFrame) else { return false }
        if let text {
            return [expected, focused].allSatisfy { preparedTextMatches(value: $0.value, text: text, profile: .workbuddy) }
        }
        return [expected, focused].allSatisfy { AgentAppProfile.workbuddy.isEmptyComposer(value: $0.value, placeholder: nil) }
    }

    static func workBuddyFocusedComposer(pid: pid_t, expected: AXUIElement, text: String?,
                                                  authorized: () -> Bool) -> AXUIElement? {
        guard valid(pid, authorized), let focused = InputFocus.focusedElement(pid: pid),
              let window = TargetWindowLocator.resolve(pid: pid) else { return nil }
        func node(_ element: AXUIElement) -> Node {
            let bounds = frame(element)
            return Node(element: element, role: string(element, kAXRoleAttribute) ?? "", label: "",
                value: string(element, kAXValueAttribute), placeholder: "", selected: false,
                enabled: bool(element, kAXEnabledAttribute) != false,
                navigationVisible: bounds.map { window.rect.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false,
                navigationFrame: bounds)
        }
        let original = node(expected), current = node(focused)
        let matches = matchesWorkBuddyFocus(expected: original, focused: current, text: text)
        ExecutionLog.shared.append(kind: "focus", label: "WorkBuddy 输入焦点引用核验",
            outcome: matches ? .delivered : .blocked,
            detail: "sameReference=\(CFEqual(expected, focused)); expectedRole=\(original.role); focusedRole=\(current.role); expectedFrame=\(String(describing: original.navigationFrame)); focusedFrame=\(String(describing: current.navigationFrame)); matched=\(matches)")
        return matches && valid(pid, authorized) ? focused : nil
    }

    static func emptyNewComposers(profile: AgentAppProfile, snapshot: [Node]) -> [Node] {
        guard AgentWorkspaceComposer.supported(profile) else { return [] }
        let labels = Set(snapshot.filter(\.navigationVisible).map(\.label))
        let selected = newTaskButtons(profile: profile, snapshot: snapshot).contains { $0.selected }
        let welcomeVisible = uniqueNavigationControls(snapshot.filter {
            $0.role == "AXHeading" && $0.navigationVisible && ($0.accessibleNames + [$0.label]).contains("WorkBuddy, 我帮你")
        }).count == 1
        let workspaceVisible = profile == .workbuddy
            ? AgentWorkspaceComposer.selector(profile: profile, nodes: snapshot) != nil
            : snapshot.contains {
                ["AXComboBox", "AXPopUpButton"].contains($0.role) && $0.enabled && $0.navigationVisible
                    && ($0.accessibleNames + [$0.label]).contains(where: AgentWorkspaceComposer.selectorNames(profile).contains)
            }
        return visibleEmptyComposers(profile: profile, snapshot: snapshot).filter {
            profile.hasNewPageEvidence(labels: labels, selectedNewTab: selected,
                    placeholder: $0.placeholder, beforeLabels: [], visibleWelcome: welcomeVisible && workspaceVisible)
        }
    }

    /// 获取焦点本身不能要求已经持有焦点；仅点击目标窗口中唯一可见空框，点击后才授权输入。
    static func acquireWorkBuddyFocus(pid: pid_t, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                                      completion: @escaping (Bool) -> Void) {
        queue.async {
            guard authorized(), EnvironmentGate.blockReason() == nil, let pointer else { completion(false); return }
            let composers = visibleEmptyComposers(profile: .workbuddy, snapshot: nodes(pid: pid))
            guard composers.count == 1, let composer = composers.first, let bounds = frame(composer.element),
                  AgentAppProfile.workbuddy.isEmptyComposer(value: string(composer.element, kAXValueAttribute), placeholder: nil) else {
                completion(false); return
            }
            let point = CGPoint(x: bounds.midX, y: bounds.midY)
            guard authorized(), EnvironmentGate.blockReason() == nil,
                  let window = TargetWindowLocator.resolve(pid: pid), frame(composer.element) == bounds,
                  PointerGeometry.isCursorSettled(at: point, window: window.rect,
                    screens: PointerGeometry.activeDisplayRects(), occluders: window.occluders) else { completion(false); return }
            let canAcquire: () -> Bool = {
                guard authorized(), EnvironmentGate.blockReason() == nil, frame(composer.element) == bounds,
                      let currentWindow = TargetWindowLocator.resolve(pid: pid) else { return false }
                return PointerGeometry.isCursorSettled(at: point, window: currentWindow.rect,
                    screens: PointerGeometry.activeDisplayRects(), occluders: currentWindow.occluders)
            }
            pointer.click(at: point, authorized: canAcquire, marker: 0) { clicked in
                queue.asyncAfter(deadline: .now() + .milliseconds(150)) {
                    let confirmed = clicked && workBuddyFocusedComposer(pid: pid, expected: composer.element, text: nil, authorized: authorized) != nil
                    ExecutionLog.shared.append(kind: "focus", label: "WorkBuddy 输入框聚焦",
                        outcome: confirmed ? .delivered : .blocked, detail: confirmed ? "真实空框点击后已核实键盘归属与输入焦点。" : "输入焦点未核实，未输入正文。")
                    completion(confirmed)
                }
            }
        }
    }

    /// 只接受唯一、语义明确的入口；折叠侧栏不能靠欢迎语或猜坐标放行。
    static func nativeNavigationStep(profile: AgentAppProfile, snapshot: [Node], sidebarExpanded: Bool) -> NativeNavigationStep {
        let composers = emptyNewComposers(profile: profile, snapshot: snapshot)
        if composers.count > 1 { return .blocked("新建任务：输入框不唯一，未输入正文。") }
        if composers.count == 1 { return .ready }
        let expanders = uniqueNavigationControls(snapshot.filter {
            $0.role == "AXButton" && $0.enabled && $0.navigationVisible
                && ($0.accessibleNames + [$0.label]).contains(where: profile.expandSidebarNames.contains)
        })
        if expanders.count > 1 { return .blocked("新建任务：侧边栏展开入口不唯一，未输入正文。") }
        if let expander = expanders.first {
            return sidebarExpanded ? .waiting : .expandSidebar(expander)
        }
        let buttons = newTaskButtons(profile: profile, snapshot: snapshot)
        if buttons.count > 1 { return .blocked("新建任务：新建入口不唯一，未输入正文。") }
        return buttons.count == 1 ? .ready : .waiting
    }

    static func nativeNavigationSnapshot(profile: AgentAppProfile, pid: pid_t, pointer: PointerExecutor?,
                        authorized: @escaping () -> Bool, sidebarExpanded: Bool = false,
                        completion: @escaping (Result<[Node], AgentComposerFailure>) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + nativeNavigationWaitSeconds
        repeat {
            guard valid(pid, authorized) else {
                completion(.failure(.init(message: "新建任务：目标已失去焦点或控制权。"))); return
            }
            let snapshot = nodes(pid: pid, prioritizeEditor: AgentWorkspaceComposer.supported(profile))
            let sidebarNames = snapshot.filter { node in
                node.role == "AXButton" && (node.accessibleNames + [node.label]).contains(where: profile.expandSidebarNames.contains)
            }
            if !sidebarNames.isEmpty, !sidebarExpanded {
                ExecutionLog.shared.append(kind: "workspace", label: "侧边栏可见性核验", outcome: .sent,
                    detail: sidebarNames.map { node in
                        let bounds = frame(node.element).map { "x=\($0.minX),y=\($0.minY),w=\($0.width),h=\($0.height)" } ?? "bounds=unknown"
                        return "visible=\(node.navigationVisible); \(bounds)"
                    }.joined(separator: " | "))
            }
            switch nativeNavigationStep(profile: profile, snapshot: snapshot, sidebarExpanded: sidebarExpanded) {
            case .expandSidebar(let button):
                click(button.element, pid: pid, pointer: pointer, authorized: authorized) { success in
                    queue.async {
                        guard success else {
                            completion(.failure(.init(message: "新建任务：侧边栏未能展开，未输入正文。"))); return
                        }
                        ExecutionLog.shared.append(kind: "workspace", label: "展开侧边栏", outcome: .sent,
                            detail: profile.rawValue + "：已点击唯一展开入口，继续核验新建页。")
                        nativeNavigationSnapshot(profile: profile, pid: pid, pointer: pointer, authorized: authorized,
                            sidebarExpanded: true, completion: completion)
                    }
                }
                return
            case .ready: completion(.success(snapshot)); return
            case .blocked(let message): completion(.failure(.init(message: message))); return
            case .waiting: Thread.sleep(forTimeInterval: 0.15)
            }
        } while ProcessInfo.processInfo.systemUptime < deadline
        completion(.failure(.init(message: sidebarExpanded
            ? "新建任务：展开侧边栏后仍未确认新建入口，未输入正文。"
            : "新建任务：未找到唯一的新建入口，未输入正文。")))
    }

    /// 深链回调仅证明系统接收请求；首次 AX 焦点未知不等于用户切走。
    struct NavigationFocus {
        enum State { case waiting, ready, stopped }
        let deadline: TimeInterval
        private(set) var confirmed = false

        mutating func observe(expectedPID: pid_t, focusedPID: pid_t?, authorized: Bool,
                              environmentAllowed: Bool, now: TimeInterval) -> State {
            guard authorized, environmentAllowed else { return .stopped }
            if focusedPID == expectedPID { confirmed = true; return .ready }
            if focusedPID == nil, !confirmed, now < deadline { return .waiting }
            return .stopped
        }
    }

    /// 等待只读焦点，不重开页面、不激活应用；日志不包含任务正文。
    static func navigationFocus(pid: pid_t, observer: inout NavigationFocus,
                                authorized: () -> Bool) -> NavigationFocus.State {
        let allowed = authorized(), blockReason = EnvironmentGate.blockReason()
        let owner = InputFocus.applicationOwner(), focusedPID = owner.pid
        let wasConfirmed = observer.confirmed
        let state = observer.observe(expectedPID: pid, focusedPID: focusedPID, authorized: allowed,
                                     environmentAllowed: blockReason == nil, now: ProcessInfo.processInfo.systemUptime)
        if state == .stopped || (state == .ready && !wasConfirmed) {
            ExecutionLog.shared.append(kind: "codex", label: "导航焦点核验", outcome: state == .stopped ? .blocked : .delivered,
                detail: "authorized=\(allowed); blockReason=\(blockReason ?? "none"); expectedPID=\(pid); focusedPID=\(focusedPID.map(String.init) ?? "unknown"); focusConfirmed=\(observer.confirmed); \(owner.detail)")
        }
        return state
    }

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
            nativeNavigationSnapshot(profile: profile, pid: pid, pointer: pointer, authorized: authorized) { navigation in
                guard case .success(let before) = navigation else {
                    if case .failure(let error) = navigation { completion(.failure(error)) }
                    return
                }
                if AgentWorkspaceComposer.supported(profile) {
                    let emptyNew = emptyNewComposers(profile: profile, snapshot: before)
                    if emptyNew.count == 1, let composer = emptyNew.first {
                        press(composer.element, pid: pid, pointer: pointer, authorized: authorized) { focused in
                            let current = profile == .workbuddy
                                ? workBuddyFocusedComposer(pid: pid, expected: composer.element, text: nil, authorized: authorized)
                                : InputFocus.focusedElement(pid: pid).flatMap { CFEqual($0, composer.element) ? $0 : nil }
                            guard focused, valid(pid, authorized), let current else {
                                completion(.failure(.init(message: authorized() ? "空白新任务页的输入焦点未核实。" : "控制连接已失效，请重新连接后重试。"))); return
                            }
                            completion(.success(.init(element: current, prefilled: false)))
                        }
                        return
                    }
                }
                let buttons = newTaskButtons(profile: profile, snapshot: before)
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
    }

    /// 预填正文不等于已创建任务。点击可访问性发送入口，避免回车被当作换行或被页面吞掉。
    static func semanticSendButtons(_ snapshot: [Node]) -> [Node] {
        let names: Set<String> = ["发送", "发送消息", "提交", "创建任务", "Send", "Send message", "Submit", "Create task", "Send now"]
        return uniqueNavigationControls(snapshot.filter { node in
            node.role == "AXButton" && node.enabled && node.navigationVisible
                && (node.accessibleNames + [node.label]).contains(where: names.contains)
        })
    }

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
            let prioritizeEditor = prepared.prefilled || profile == .codex || profile.map(AgentWorkspaceComposer.supported) == true
            let inputBounds = frame(prepared.element)
            var button: Node?
            for _ in 0..<12 {
                guard valid(pid, authorized), prepared.validateWindow?() != false, prepared.validateTarget?() != false,
                      (profile == .workbuddy || InputFocus.focusedElement(pid: pid).map { CFEqual($0, prepared.element) } == true),
                      preparedTextMatches(value: string(prepared.element, kAXValueAttribute), text: text, profile: profile) else {
                    completion(.failure(.init(message: "提交前正文或焦点已变化，保留草稿。"))); return
                }
                let snapshot = nodes(pid: pid, prioritizeEditor: prioritizeEditor)
                let candidates: [Node]
                if profile == .cue, let index = snapshot.firstIndex(where: { CFEqual($0.element, prepared.element) }) {
                    candidates = Array(snapshot.dropFirst(index + 1).prefix(8)).filter { $0.role == "AXButton" && $0.enabled && $0.label.isEmpty }
                } else {
                    candidates = semanticSendButtons(snapshot)
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
            let send: (AXUIElement) -> Void = { editor in
                // 快照读取可能耗时；真正点击前再次核对项目、焦点和正文。
                guard valid(pid, authorized), prepared.validateWindow?() != false, prepared.validateTarget?() != false,
                      let focused = InputFocus.focusedElement(pid: pid), CFEqual(focused, editor),
                      preparedTextMatches(value: string(editor, kAXValueAttribute), text: text, profile: profile) else {
                    completion(.failure(.init(message: "发送前目标或正文已变化；未发送，草稿已保留。"))); return
                }
                let actualButton: AXUIElement
                if profile == .workbuddy {
                    let fresh = semanticSendButtons(nodes(pid: pid, prioritizeEditor: true))
                    guard fresh.count == 1, let currentButton = fresh.first,
                          valid(pid, authorized), prepared.validateWindow?() != false, prepared.validateTarget?() != false,
                          InputFocus.focusedElement(pid: pid).map { CFEqual($0, editor) } == true,
                          preparedTextMatches(value: string(editor, kAXValueAttribute), text: text, profile: profile) else {
                        completion(.failure(.init(message: "发送前按钮、目标或正文未核实；未发送，草稿已保留。"))); return
                    }
                    actualButton = currentButton.element
                } else { actualButton = button.element }
                // Chromium 可对发送按钮的 AXPress 报成功却不执行；按重新捕获的真实按钮矩形点击一次。
                let canSend: () -> Bool = {
                    guard authorized(), prepared.validateWindow?() != false, prepared.validateTarget?() != false,
                          InputFocus.focusedElement(pid: pid).map { CFEqual($0, editor) } == true else { return false }
                    return preparedTextMatches(value: string(editor, kAXValueAttribute), text: text, profile: profile)
                }
                let perform: (@escaping (Bool) -> Void) -> Void = { done in
                    if profile == .workbuddy {
                        clickGuarded(actualButton, pid: pid, pointer: pointer, authorized: authorized, preflight: canSend, completion: done)
                    } else { press(actualButton, pid: pid, pointer: pointer, authorized: authorized, completion: done) }
                }
                perform { pressed in
                    queue.async {
                        guard pressed else {
                            completion(.failure(.init(message: "发送动作结果待核对，请查看目标应用。", submissionAttempted: true))); return
                        }
                        for _ in 0..<40 {
                            guard valid(pid, authorized), prepared.validateWindow?() != false, !prepared.validateTargetAfterSubmit || prepared.validateTarget?() != false else { break }
                            let snapshot = nodes(pid: pid, prioritizeEditor: prioritizeEditor)
                            // 原绑定框清空是强证据；重建后的框须同时出现本次正文，不能认旁边的空框。
                            let composers = snapshot.filter { $0.role == "AXTextArea" }
                            let originalCleared = composers.contains {
                                CFEqual($0.element, editor) && isClearedComposer(value: $0.value, profile: profile)
                            }
                            let newMessage = matchingMessages(snapshot, text: text) > beforeMessages
                            let runningStarted = !beforeRunning && hasRunningControl(snapshot)
                            let emptyComposer = composers.contains { isClearedComposer(value: $0.value, profile: profile) }
                            guard valid(pid, authorized), prepared.validateWindow?() != false,
                                  !prepared.validateTargetAfterSubmit || prepared.validateTarget?() != false else { break }
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
            if profile == .workbuddy {
                // 只重聚焦同矩形、完整正文匹配的唯一撰写框；不重输、不重发、不认旁边的空框。
                let editors = preparedWorkBuddyComposers(snapshot: before, element: prepared.element, bounds: inputBounds, text: text)
                guard editors.count == 1, let editor = editors.first else {
                    completion(.failure(.init(message: "发送前未找到唯一且正文匹配的原输入框；未发送，草稿已保留。"))); return
                }
                press(editor.element, pid: pid, pointer: pointer, authorized: authorized) { focused in
                    queue.async {
                        guard focused, let current = workBuddyFocusedComposer(pid: pid, expected: editor.element, text: text, authorized: authorized) else {
                            completion(.failure(.init(message: "正文已填好，但发送前未确认输入焦点；未发送。"))); return
                        }
                        send(current)
                    }
                }
            } else { send(prepared.element) }
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

    static func matchingMessages(_ snapshot: [Node], text: String) -> Int {
        let expected = AgentAppProfile.clean(text)
        return snapshot.filter {
            $0.role == "AXStaticText" && !$0.inComposer && AgentAppProfile.clean($0.value ?? $0.label) == expected
        }.count
    }

    private static func hasRunningControl(_ snapshot: [Node]) -> Bool {
        let names: Set<String> = ["停止", "停止生成", "停止响应", "Stop", "Stop generating", "Stop response"]
        return snapshot.contains { $0.role == "AXButton" && $0.enabled && names.contains($0.label) }
    }

    static func verify(profile: AgentAppProfile, pid: pid_t, text: String, beforeLabels: Set<String>,
                               pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                               completion: @escaping (Result<Prepared, AgentComposerFailure>) -> Void) {
        // 只重复观察，不重复点击新建、写入或提交。
        var reason = "未能确认新任务页面与输入框，未输入正文。"
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 6
        var focus = NavigationFocus(deadline: started + navigationFocusGraceSeconds)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if profile == .codex {
                switch navigationFocus(pid: pid, observer: &focus, authorized: authorized) {
                case .waiting: Thread.sleep(forTimeInterval: 0.05); continue
                case .stopped:
                    completion(.failure(.init(message: "Codex 导航焦点或控制权未核实；正文可能已预填，未发送。"))); return
                case .ready: break
                }
            } else {
                guard valid(pid, authorized) else { reason = "目标已失去焦点或控制权。"; break }
            }
            let snapshot = nodes(pid: pid, prioritizeEditor: profile == .codex || AgentWorkspaceComposer.supported(profile))
            let labels = Set(snapshot.map(\.label))
            if profile == .cola && labels.contains("请选择模型") {
                // 1.5.0 的 coding.modelUnavailableAction：只有会话的模型不可用时页面才出现这个动作。
                // 沿用上次模型的前提是它可用；模型不可用时不得替用户选一个（可能直接产生计费），如实停下。
                reason = "Cola 这个会话的模型不可用，页面要求选择模型；未输入正文，请在 Cola 选好模型后重试。"
                break
            }
            let composers = AgentWorkspaceComposer.supported(profile) ? emptyNewComposers(profile: profile, snapshot: snapshot) : snapshot.filter { node in
                guard node.role == "AXTextArea", node.enabled else { return false }
                if profile == .codex { return node.value == text }
                return profile.isEmptyComposer(value: node.value, placeholder: node.placeholder)
                    && profile.hasNewPageEvidence(labels: labels,
                        selectedNewTab: newTaskButtons(profile: profile, snapshot: snapshot).contains { $0.selected },
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
                        let focused = profile == .workbuddy
                            ? workBuddyFocusedComposer(pid: pid, expected: composer.element, text: nil, authorized: authorized)
                            : InputFocus.focusedElement(pid: pid).flatMap { CFEqual($0, composer.element) ? $0 : nil }
                        guard success, valid(pid, authorized), let focused else {
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

    /// Chromium 的下拉框/欢迎标题名称可能只在子文本；只读控件的有界局部，不扩成全窗扫描。
    static func controlAccessibleNames(_ element: AXUIElement, role: String) -> [String] {
        let own = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { string(element, $0) }.filter { !$0.isEmpty }
        guard role == "AXHeading" || (["AXComboBox", "AXPopUpButton"].contains(role) && own.isEmpty) else { return own }
        var labels: [String] = [], budget = 16
        func readChildren(_ parent: AXUIElement, depth: Int) {
            guard depth < 2, budget > 0 else { return }
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &raw) == .success,
                  let children = raw as? [AXUIElement] else { return }
            for child in children.prefix(budget) {
                budget -= 1
                let childRole = string(child, kAXRoleAttribute) ?? ""
                if childRole == "AXStaticText", let label = string(child, kAXValueAttribute) ?? string(child, kAXTitleAttribute), !label.isEmpty {
                    labels.append(label)
                } else if childRole == "AXGroup" { readChildren(child, depth: depth + 1) }
                if budget == 0 { break }
            }
        }
        readChildren(element, depth: 0)
        return own + labels
    }

    static func nodes(pid: pid_t, window: AXUIElement? = nil, prioritizeEditor: Bool = false,
                      onScan: ((Int, Bool) -> Void)? = nil) -> [Node] {
        guard let root = window ?? TargetWindowLocator.axWindowElement(pid: pid) else { onScan?(0, true); return [] }
        let windowFrame = frame(root)
        var result: [Node] = [], remaining = 6000
        var deadline = ProcessInfo.processInfo.systemUptime + 2
        var truncated = false
        var visited: [CFHashCode: [AXUIElement]] = [:]
        var complete: [CFHashCode: [AXUIElement]] = [:]
        func walk(_ element: AXUIElement, depth: Int, inMenu: Bool = false, inComposer: Bool = false) {
            guard depth < 32, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; return }
            let hash = CFHash(element)
            var needsComposerPropagation = false
            if inComposer, let index = result.firstIndex(where: { CFEqual($0.element, element) }) {
                needsComposerPropagation = !result[index].inComposer
                result[index].inComposer = true
            }
            // 焦点子树可能先于 TextArea 被扫描；上下文升级后须把草稿标记传给已完成的孩子。
            if !needsComposerPropagation, complete[hash]?.contains(where: { CFEqual($0, element) }) == true { return }
            let known = visited[hash]?.contains(where: { CFEqual($0, element) }) == true
            remaining -= 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if !known {
            visited[hash, default: []].append(element)
            let accessibleNames = controlAccessibleNames(element, role: role)
            let label = accessibleNames.first
                ?? (role == "AXStaticText" ? string(element, kAXValueAttribute) : nil) ?? ""
            // Chromium 手动辅助功能会暴露折叠侧栏的隐藏副本；只用真实窗口内落点认导航候选。
            let navigationRole = ["AXButton", "AXRadioButton", "AXTab", "AXLink", "AXHeading", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXCheckBox"].contains(role)
            let navigationFrame = navigationRole ? frame(element) : nil
            let navigationVisible = !navigationRole || (navigationFrame.flatMap { bounds in
                windowFrame.map { $0.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }
            } ?? false)
            result.append(Node(element: element, role: role, label: label,
                value: string(element, kAXValueAttribute), placeholder: string(element, "AXPlaceholderValue") ?? "",
                selected: isSelected(element),
                enabled: bool(element, kAXEnabledAttribute) != false, help: string(element, kAXHelpAttribute) ?? "", pageURL: pageURL(element),
                routeSelected: isCurrentRoute(element), inMenu: inMenu, accessibleNames: accessibleNames,
                navigationVisible: navigationVisible, navigationFrame: navigationFrame, inComposer: inComposer || role == "AXTextArea"))
            } else if inMenu, let index = result.firstIndex(where: { CFEqual($0.element, element) }) {
                result[index].inMenu = true
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { return }
            for child in list { walk(child, depth: depth + 1, inMenu: inMenu || role == "AXMenu", inComposer: inComposer || role == "AXTextArea") }
            if remaining > 0, ProcessInfo.processInfo.systemUptime < deadline { complete[hash, default: []].append(element) }
        }
        if window == nil, prioritizeEditor, let focused = InputFocus.focusedElement(pid: pid) {
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
        let role = string(element, kAXRoleAttribute)
        if let role, role != "AXTextArea",
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            Thread.sleep(forTimeInterval: 0.15); completion(true); return
        }
        if role == "AXTextArea" {
            let status = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            ExecutionLog.shared.append(kind: "focus", label: "输入框 AX 聚焦", outcome: status == .success ? .sent : .blocked,
                detail: "expectedPID=\(pid); status=\(status.rawValue)")
            if status == .success {
                Thread.sleep(forTimeInterval: 0.15)
                if let current = InputFocus.focusedElement(pid: pid), CFEqual(current, element) { completion(true); return }
            }
        }
        click(element, pid: pid, pointer: pointer, authorized: authorized) { clicked in
            ExecutionLog.shared.append(kind: "focus", label: "控件实际点击", outcome: clicked ? .sent : .blocked,
                detail: "expectedPID=\(pid); role=\(role ?? "unknown"); clicked=\(clicked)")
            completion(clicked)
        }
    }

    /// 只点击已识别控件的真实矩形；与 AXPress 降级共用窗口/焦点/租约边界，不猜坐标。
    static func click(_ element: AXUIElement, pid: pid_t, pointer: PointerExecutor?,
                      authorized: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        clickGuarded(element, pid: pid, pointer: pointer, authorized: authorized, preflight: { true }, completion: completion)
    }

    /// 输入正文与目标身份在指针执行队列里再次核验；点击后的预期清空不反过来否定已发送事件。
    static func clickGuarded(_ element: AXUIElement, pid: pid_t, pointer: PointerExecutor?,
                             authorized: @escaping () -> Bool, preflight: @escaping () -> Bool,
                             button: CGMouseButton = .left,
                             completion: @escaping (Bool) -> Void) {
        guard valid(pid, authorized), preflight() else { completion(false); return }
        guard let pointer, let point = center(element), let window = TargetWindowLocator.resolve(pid: pid),
              PointerGeometry.isCursorSettled(at: point, window: window.rect,
                    screens: PointerGeometry.activeDisplayRects(), occluders: window.occluders), valid(pid, authorized) else {
            completion(false); return
        }
        let canClick: () -> Bool = {
            guard valid(pid, authorized), preflight(), center(element) == point,
                  let currentWindow = TargetWindowLocator.resolve(pid: pid) else { return false }
            return PointerGeometry.isCursorSettled(at: point, window: currentWindow.rect,
                screens: PointerGeometry.activeDisplayRects(), occluders: currentWindow.occluders)
        }
        pointer.click(at: point, authorized: canClick, marker: 0, button: button) { clicked in
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
