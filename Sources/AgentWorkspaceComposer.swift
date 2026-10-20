/**
 * [INPUT]: AgentWorkBuddyNewTask的新窗口隔离与WorkBuddy 本地工作空间 ComboBox/PopUpButton、项目行的分支/Worktree 结构，ZCode 项目 PopupButton/MenuItem 与共享 AX/指针执行器。
 * [OUTPUT]: 允许保留旧会话草稿后原生新建，仅校验新目标空框；WorkBuddy 选择器按真实 AX 矩形点击后核验菜单，避免 AXPress 假成功；已选项目通过真实输入区下方的工作空间/分支/Worktree 行定位，不把分支名当项目；原生菜单候选与指定工作空间的空白新任务撰写框；输入不可读与真实草稿分别拒绝，均不清空；按完整名称/值重新核验 WorkBuddy 选择器并排除模型/权限控件，发送前重新绑定当前选择器，ZCode 发送前读回唯一选中项。
 * [POS]: 原生项目导航适配；只使用真实菜单，不猜坐标，不修改权限、模型、分支或工作树开关。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

enum AgentWorkspaceComposer {
    typealias Reply = Result<AgentTaskComposer.Prepared, AgentComposerFailure>
    static var cancelMenu: (pid_t, @escaping () -> Bool, @escaping (Bool) -> Void) -> Void = { _, _, done in done(false) }
    static func selectorNames(_ profile: AgentAppProfile) -> Set<String> {
        profile == .workbuddy ? ["选择工作空间", "Select workspace"] : ["选择项目", "Select project"]
    }
    static func supported(_ profile: AgentAppProfile) -> Bool { [.workbuddy, .zcode].contains(profile) }
    static func selector(profile: AgentAppProfile, nodes: [AgentTaskComposer.Node], selectedName: String? = nil) -> AgentTaskComposer.Node? {
        let roles = profile == .workbuddy ? ["AXComboBox", "AXPopUpButton"] : ["AXPopUpButton"]
        let names = selectorNames(profile).union(selectedName.map { [$0] } ?? [])
        let candidates = AgentTaskComposer.uniqueNavigationControls(nodes.filter {
            guard roles.contains($0.role), $0.enabled, $0.navigationVisible, !$0.inMenu else { return false }
            let labels = $0.accessibleNames + [$0.label]
            // 选中后工作空间标签会变成项目名；模型与权限仍靠稳定语义排除，不能被同名项目误认。
            let unrelated = ["更多操作", "More actions", "允许完全访问", "Allow full access", "选择模型", "Select model"]
            return profile != .workbuddy || !labels.contains { label in
                unrelated.contains { AgentWorkspacePolicy.key(label).hasPrefix(AgentWorkspacePolicy.key($0)) }
            }
        })
        if profile == .workbuddy {
            switch workspaceRowSelector(nodes: nodes, candidates: candidates) {
            case .selected(let row): return row
            case .ambiguous: return nil
            case .absent: break
            }
        }
        let found = candidates.filter { node in
            names.contains { AgentWorkspacePolicy.selectedProject($0, names: node.accessibleNames + [node.label], value: node.value) }
        }
        if !found.isEmpty { return found.count == 1 ? found[0] : nil }
        // 已选中的 WorkBuddy 项目名称未知时，只接受输入区之后唯一剩下的工作空间控件。
        guard profile == .workbuddy, let editor = nodes.firstIndex(where: { $0.role == "AXTextArea" }) else { return nil }
        let local = candidates.filter { candidate in
            nodes.dropFirst(editor + 1).contains { CFEqual($0.element, candidate.element) }
                && !(candidate.accessibleNames + [candidate.label]).allSatisfy { $0.isEmpty }
        }
        return local.count == 1 ? local[0] : nil
    }

    /// 已选工作空间会以任意项目名替换标签；分支名同样任意，须先按已核验的局部行隔离。
    private enum WorkspaceRow { case absent, selected(AgentTaskComposer.Node), ambiguous }
    private static let workspaceRowGapInPickerHeights: CGFloat = 3
    private static func workspaceRowSelector(nodes: [AgentTaskComposer.Node], candidates: [AgentTaskComposer.Node]) -> WorkspaceRow {
        let editors = AgentTaskComposer.uniqueNavigationControls(nodes.filter { $0.role == "AXTextArea" && $0.enabled && $0.navigationVisible })
        let toggles = AgentTaskComposer.uniqueNavigationControls(nodes.filter {
            $0.role == "AXCheckBox" && $0.navigationVisible && !$0.inMenu
                && ($0.accessibleNames + [$0.label]).contains("Worktree")
        })
        guard !toggles.isEmpty, candidates.filter({ $0.role == "AXPopUpButton" }).count >= 2 else { return .absent }
        guard editors.count == 1, let editor = editors.first?.navigationFrame else { return .ambiguous }
        var matches: [AgentTaskComposer.Node] = []
        for workspace in candidates where workspace.role == "AXPopUpButton" {
            guard let left = workspace.navigationFrame, left.minY >= editor.maxY,
                  // AXTextArea 可只覆盖正文；工具条仍在工作空间行之前，间隔按真实控件高度约束。
                  left.minY - editor.maxY <= left.height * workspaceRowGapInPickerHeights,
                  editor.minX <= left.midX, left.midX <= editor.maxX else { continue }
            for branch in candidates where branch.role == "AXPopUpButton" && !CFEqual(branch.element, workspace.element) {
                guard let right = branch.navigationFrame, left.maxX <= right.minX,
                      editor.minX <= right.midX, right.midX <= editor.maxX else { continue }
                if toggles.contains(where: { toggle in
                    guard let check = toggle.navigationFrame else { return false }
                    return right.maxX <= check.minX && check.midX <= editor.maxX
                        && max(left.minY, max(right.minY, check.minY)) < min(left.maxY, min(right.maxY, check.maxY))
                }) { matches.append(workspace) }
            }
        }
        let unique = AgentTaskComposer.uniqueNavigationControls(matches)
        return unique.count == 1 ? .selected(unique[0]) : .ambiguous
    }
    static func selectionMatches(_ project: String, profile: AgentAppProfile, nodes: [AgentTaskComposer.Node]) -> Bool {
        guard let picker = selector(profile: profile, nodes: nodes, selectedName: project) else { return false }
        return AgentWorkspacePolicy.selectedProject(project, names: picker.accessibleNames + [picker.label], value: picker.value)
    }
    static func options(_ nodes: [AgentTaskComposer.Node]) -> [AgentTaskComposer.Node] {
        nodes.filter { $0.inMenu && $0.role == "AXMenuItem" && $0.enabled && AgentWorkspacePolicy.isProject($0.label) }
    }
    static func hasWorkspaceMenuEvidence(_ nodes: [AgentTaskComposer.Node]) -> Bool {
        guard AgentTaskComposer.uniqueNavigationControls(nodes.filter { $0.role == "AXMenu" }).count == 1 else { return false }
        let labels = Set(nodes.filter { $0.inMenu && $0.role == "AXMenuItem" && $0.enabled }.map { AgentWorkspacePolicy.key($0.label) })
        let folder = ["打开文件夹", "打开本地文件夹", "Open folder", "Open local folder"].contains { labels.contains(AgentWorkspacePolicy.key($0)) }
        let workspaceAction = ["新建工作空间", "不在项目中工作", "不使用工作空间", "New workspace", "No project"].contains { labels.contains(AgentWorkspacePolicy.key($0)) }
        return folder && workspaceAction
    }
    static func prepare(profile: AgentAppProfile, target: TargetConfig, pid: pid_t, project: String?,
                        pointer: PointerExecutor?, authorized: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        AgentTaskComposer.queue.async {
            guard supported(profile), AgentTaskComposer.valid(pid, authorized) else {
                completion(.failure(.init(message: "项目导航：应用或控制权不可用。"))); return
            }
            // 旧会话草稿归原会话所有；只核验新建后的目标框，不要求用户先清旧文字。
            let prepareNew: (@escaping (Reply) -> Void) -> Void = { done in
                if profile == .workbuddy {
                    AgentWorkBuddyNewTask.prepare(pid: pid, pointer: pointer, authorized: authorized, completion: done)
                } else {
                    AgentTaskComposer.prepare(profile: profile, target: target, pid: pid, text: "", pointer: pointer, authorized: authorized, completion: done)
                }
            }
            prepareNew { result in
                switch result {
                case .failure: completion(result)
                case .success(var composer):
                    guard let project else { completion(.success(composer)); return }
                    let windowIsValid = composer.validateTarget
                    let contextAuthorized = { authorized() && windowIsValid?() != false }
                    choose(profile: profile, pid: pid, project: project, pointer: pointer, authorized: contextAuthorized) { choice in
                        switch choice {
                        case .failure(let error): completion(.failure(error))
                        case .success(let name):
                            composer.contextName = name
                            // 新任务提交后选择器会随页面消失；接收事实用本次正文和清空/开始信号核验。
                            composer.validateTargetAfterSubmit = false
                            var picker = profile == .workbuddy ? selector(profile: profile, nodes: AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true), selectedName: name) : nil
                            if profile == .workbuddy {
                                composer.validateTarget = {
                                    // 输入队列会频繁调用此门禁；只读绑定控件，完整重查留给发送前导航核验。
                                    guard windowIsValid?() != false, let picker else { return false }
                                    let names = AgentTaskComposer.controlAccessibleNames(picker.element, role: picker.role)
                                    return AgentWorkspacePolicy.selectedProject(name, names: names,
                                        value: AgentTaskComposer.string(picker.element, kAXValueAttribute))
                                }
                            }
                            // 发送前再核对项目；弹出菜单后重新捕获并聚焦唯一的撰写框。
                            composer.refreshBeforeSubmit = { done in
                                verifySelection(profile: profile, pid: pid, name: name, pointer: pointer, authorized: contextAuthorized) { result in
                                    switch result {
                                    case .failure(let error): done(.failure(error))
                                    case .success:
                                        focusComposer(profile: profile, pid: pid, requireEmpty: false, pointer: pointer, authorized: contextAuthorized) { focus in
                                            if profile == .workbuddy, case .success = focus {
                                                picker = selector(profile: profile, nodes: AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true), selectedName: name)
                                            }
                                            done(focus)
                                        }
                                    }
                                }
                            }
                            focusComposer(profile: profile, pid: pid, requireEmpty: true, pointer: pointer, authorized: contextAuthorized) { result in
                                switch result {
                                case .failure(let error): completion(.failure(error))
                                case .success(let editor): composer.element = editor; completion(.success(composer))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    static func readProjects(profile: AgentAppProfile, pid: pid_t, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                             completion: @escaping (Result<[String], AgentComposerFailure>) -> Void) {
        openMenu(profile: profile, pid: pid, pointer: pointer, authorized: authorized) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let rows):
                let names = rows.map(\.label)
                ExecutionLog.shared.append(kind: "workspace", label: "读取项目菜单", outcome: .delivered,
                    detail: profile.rawValue + "：" + String(names.joined(separator: "、").prefix(500)))
                dismiss(pid: pid, authorized: authorized) { closed in
                    completion(closed ? .success(names) : .failure(.init(message: "项目菜单未能收起，未继续操作。")))
                }
            }
        }
    }
    private static func choose(profile: AgentAppProfile, pid: pid_t, project: String, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                               completion: @escaping (Result<String, AgentComposerFailure>) -> Void) {
        openMenu(profile: profile, pid: pid, pointer: pointer, authorized: authorized) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let rows):
                let indices = AgentWorkspacePolicy.matches(project, labels: rows.map(\.label))
                guard indices.count == 1 else {
                    let names = rows.map(\.label).joined(separator: "、")
                    dismiss(pid: pid, authorized: authorized) { _ in
                        completion(.failure(.init(message: indices.isEmpty ? "没有找到这个已有项目：\(project)。可选：\(names)" : "项目名称重复，请先在应用中区分项目后再试：\(project)。")))
                    }
                    return
                }
                let chosen = rows[indices[0]]
                AgentTaskComposer.press(chosen.element, pid: pid, pointer: pointer, authorized: authorized) { pressed in
                    guard pressed else { completion(.failure(.init(message: "项目菜单项未能选择。"))); return }
                    verifySelection(profile: profile, pid: pid, name: chosen.label, pointer: pointer, authorized: authorized) { result in
                        completion(result.map { chosen.label })
                    }
                }
            }
        }
    }
    private static func verifySelection(profile: AgentAppProfile, pid: pid_t, name: String, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                                        completion: @escaping (Result<Void, AgentComposerFailure>) -> Void) {
        AgentTaskComposer.queue.async {
            guard AgentTaskComposer.valid(pid, authorized) else { completion(.failure(.init(message: "选择项目时焦点或控制权已变化。"))); return }
            if profile == .workbuddy {
                let deadline = ProcessInfo.processInfo.systemUptime + 4
                repeat {
                    if selectionMatches(name, profile: profile, nodes: AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true)) {
                        completion(.success(())); return
                    }
                    guard AgentTaskComposer.valid(pid, authorized) else { break }
                    Thread.sleep(forTimeInterval: 0.1)
                } while ProcessInfo.processInfo.systemUptime < deadline
                completion(.failure(.init(message: "工作空间选中结果未能读回，未发送。"))); return
            }
            openMenu(profile: profile, pid: pid, pointer: pointer, authorized: authorized) { result in
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let rows):
                    let confirmed = AgentWorkspacePolicy.uniqueSelected(name, labels: rows.map(\.label), values: rows.map { $0.selected ? "1" : "0" })
                    dismiss(pid: pid, authorized: authorized) { closed in
                        completion(confirmed && closed ? .success(()) : .failure(.init(message: "当前 ZCode 项目不是指定目标或选中状态不可读，未发送。")))
                    }
                }
            }
        }
    }
    private static func openMenu(profile: AgentAppProfile, pid: pid_t, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                                 completion: @escaping (Result<[AgentTaskComposer.Node], AgentComposerFailure>) -> Void) {
        AgentTaskComposer.queue.async {
            guard AgentTaskComposer.valid(pid, authorized) else { completion(.failure(.init(message: "控制权或目标焦点已变化。"))); return }
            let before = AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true)
            guard let button = selector(profile: profile, nodes: before) else {
                let controls = before.enumerated().filter { ["AXComboBox", "AXPopUpButton"].contains($0.element.role) }
                    .map { index, node in "\(index):\(node.role) \(node.accessibleNames + [node.label]) enabled=\(node.enabled) menu=\(node.inMenu) frame=\(String(describing: node.navigationFrame))" }
                ExecutionLog.shared.append(kind: "workspace", label: "项目选择器核验", outcome: .blocked,
                    detail: String("\(profile.rawValue) nodes=\(before.count) editor=\(before.firstIndex { $0.role == "AXTextArea" }.map(String.init) ?? "none") \(controls.joined(separator: "; "))".prefix(1000)))
                completion(.failure(.init(message: "没有找到唯一的项目选择器，未猜测点击。"))); return
            }
            // Chromium 的 ComboBox AXPress 可能只聚焦而不展开，直接点击已核验的真实控件矩形。
            let open = profile == .workbuddy ? AgentTaskComposer.click : AgentTaskComposer.press
            open(button.element, pid, pointer, authorized) { pressed in
                guard pressed else { completion(.failure(.init(message: "项目选择器未能打开。"))); return }
                AgentTaskComposer.queue.async {
                    let deadline = ProcessInfo.processInfo.systemUptime + 4
                    var scanned = 0, truncated = false
                    repeat {
                        guard AgentTaskComposer.valid(pid, authorized) else { break }
                        let snapshot = AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true) { count, limited in scanned = count; truncated = limited }
                        let menus = AgentTaskComposer.uniqueNavigationControls(snapshot.filter { $0.role == "AXMenu" })
                        if !menus.isEmpty {
                            guard menus.count == 1 else {
                                completion(.failure(.init(message: "当前菜单不唯一，未选择项目或发送。"))); return
                            }
                            guard profile != .workbuddy || hasWorkspaceMenuEvidence(snapshot) else {
                                dismiss(pid: pid, authorized: authorized) { _ in
                                    completion(.failure(.init(message: "打开的菜单不是已核验工作空间菜单，未选择或发送。")))
                                }
                                return
                            }
                            completion(.success(options(snapshot))); return
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                    } while ProcessInfo.processInfo.systemUptime < deadline
                    ExecutionLog.shared.append(kind: "workspace", label: "项目菜单核验", outcome: .blocked,
                        detail: "\(profile.rawValue) nodes=\(scanned) truncated=\(truncated) authorized=\(authorized()) focused=\(InputFocus.focusedApplicationPID() == pid)")
                    completion(.failure(.init(message: "项目菜单不可读，未选择项目。")))
                }
            }
        }
    }
    private static func dismiss(pid: pid_t, authorized: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        AgentTaskComposer.queue.async {
            guard AgentTaskComposer.valid(pid, authorized) else { completion(false); return }
            let menus = AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true).filter { $0.role == "AXMenu" }
            if menus.isEmpty { completion(true); return }
            guard menus.count == 1 else { completion(false); return }
            // Chromium 的菜单虽暴露 Cancel，实机 AXCancel 不一定执行；使用已核验的 Esc，仍由共享键盘队列发送。
            cancelMenu(pid, authorized) { sent in
                guard sent else { completion(false); return }
                AgentTaskComposer.queue.async {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    repeat {
                        if !AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true).contains(where: { $0.role == "AXMenu" }) { completion(true); return }
                        guard AgentTaskComposer.valid(pid, authorized) else { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    } while ProcessInfo.processInfo.systemUptime < deadline
                    completion(false)
                }
            }
        }
    }
    private static func focusComposer(profile: AgentAppProfile, pid: pid_t, requireEmpty: Bool, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                                      completion: @escaping (Result<AXUIElement, AgentComposerFailure>) -> Void) {
        AgentTaskComposer.queue.async {
            let editors = AgentTaskComposer.uniqueNavigationControls(AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true)
                .filter { $0.role == "AXTextArea" && $0.enabled && $0.navigationVisible })
            guard editors.count == 1, let editor = editors.first, editor.value != nil,
                  !requireEmpty || profile.isEmptyComposer(value: editor.value, placeholder: editor.placeholder) else {
                completion(.failure(.init(message: "项目页输入框不唯一、不可读或已有草稿，未写入。"))); return
            }
            AgentTaskComposer.press(editor.element, pid: pid, pointer: pointer, authorized: authorized) { focused in
                let current = profile == .workbuddy
                    ? AgentTaskComposer.workBuddyFocusedComposer(pid: pid, expected: editor.element,
                        text: requireEmpty ? nil : editor.value, authorized: authorized)
                    : InputFocus.focusedElement(pid: pid).flatMap { CFEqual($0, editor.element) ? $0 : nil }
                guard focused, let current else {
                    completion(.failure(.init(message: "项目页输入焦点未核实。"))); return
                }
                completion(.success(current))
            }
        }
    }
}
