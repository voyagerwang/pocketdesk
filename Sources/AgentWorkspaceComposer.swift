/**
 * [INPUT]: WorkBuddy 5.7.6 工作空间 ComboBox、ZCode 项目 PopupButton/MenuItem 的实机证据与共享 AX/指针执行器。
 * [OUTPUT]: 原生菜单候选与指定项目的空白新任务撰写框；ZCode 发送前重新打开选择器读回唯一选中项。
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
        let role = profile == .workbuddy ? "AXComboBox" : "AXPopUpButton"
        let names = selectorNames(profile).union(selectedName.map { [$0] } ?? [])
        let found = nodes.filter { $0.role == role && $0.enabled && names.contains($0.label) }
        return found.count == 1 ? found[0] : nil
    }
    static func options(_ nodes: [AgentTaskComposer.Node]) -> [AgentTaskComposer.Node] {
        nodes.filter { $0.inMenu && $0.role == "AXMenuItem" && $0.enabled && !$0.label.isEmpty && !AgentWorkspacePolicy.excluded.contains($0.label) }
    }
    static func prepare(profile: AgentAppProfile, target: TargetConfig, pid: pid_t, project: String?,
                        pointer: PointerExecutor?, authorized: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        AgentTaskComposer.queue.async {
            guard supported(profile), AgentTaskComposer.valid(pid, authorized) else {
                completion(.failure(.init(message: "项目导航：应用或控制权不可用。"))); return
            }
            _ = InputFocus.focusedElement(pid: pid)
            let existing = AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true).filter { $0.role == "AXTextArea" && $0.enabled }
            guard existing.allSatisfy({ profile.isEmptyComposer(value: $0.value, placeholder: $0.placeholder) }) else {
                completion(.failure(.init(message: "当前输入框已有草稿，已保留；请先处理草稿再新建任务。"))); return
            }
            AgentTaskComposer.prepare(profile: profile, target: target, pid: pid, text: "", pointer: pointer, authorized: authorized) { result in
                switch result {
                case .failure: completion(result)
                case .success(var composer):
                    guard let project else { completion(.success(composer)); return }
                    choose(profile: profile, pid: pid, project: project, pointer: pointer, authorized: authorized) { choice in
                        switch choice {
                        case .failure(let error): completion(.failure(error))
                        case .success(let name):
                            composer.contextName = name
                            // 新任务提交后选择器会随页面消失；接收事实用本次正文和清空/开始信号核验。
                            composer.validateTargetAfterSubmit = false
                            if profile == .workbuddy {
                                let picker = selector(profile: profile, nodes: AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true), selectedName: name)
                                composer.validateTarget = {
                                    guard let picker else { return false }
                                    return [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                                        .compactMap { AgentTaskComposer.string(picker.element, $0) }.contains(name)
                                }
                            }
                            // 发送前再核对项目；弹出菜单后重新捕获并聚焦唯一的撰写框。
                            composer.refreshBeforeSubmit = { done in
                                verifySelection(profile: profile, pid: pid, name: name, pointer: pointer, authorized: authorized) { result in
                                    switch result {
                                    case .failure(let error): done(.failure(error))
                                    case .success: focusComposer(profile: profile, pid: pid, requireEmpty: false, pointer: pointer, authorized: authorized, completion: done)
                                    }
                                }
                            }
                            focusComposer(profile: profile, pid: pid, requireEmpty: true, pointer: pointer, authorized: authorized) { result in
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
                    if selector(profile: profile, nodes: AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true), selectedName: name)?.label == name {
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
            // WorkBuddy 选择后标题变为项目名称，只在新建页面输入框之后查找该唯一 ComboBox。
            var button = selector(profile: profile, nodes: before)
            if button == nil && profile == .workbuddy, let index = before.firstIndex(where: { $0.role == "AXTextArea" }) {
                let candidates = before.dropFirst(index + 1).filter { $0.role == "AXComboBox" && $0.enabled && $0.label != "更多操作" && $0.label != "允许完全访问" && !$0.label.isEmpty && !$0.label.hasPrefix("Select model:") }
                if candidates.count == 1 { button = candidates[0] }
            }
            guard let button else { completion(.failure(.init(message: "没有找到唯一的项目选择器，未猜测点击。"))); return }
            AgentTaskComposer.press(button.element, pid: pid, pointer: pointer, authorized: authorized) { pressed in
                guard pressed else { completion(.failure(.init(message: "项目选择器未能打开。"))); return }
                AgentTaskComposer.queue.async {
                    let deadline = ProcessInfo.processInfo.systemUptime + 4
                    repeat {
                        guard AgentTaskComposer.valid(pid, authorized) else { break }
                        let snapshot = AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true)
                        if snapshot.contains(where: { $0.role == "AXMenu" }) {
                            completion(.success(options(snapshot))); return
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                    } while ProcessInfo.processInfo.systemUptime < deadline
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
            let editors = AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true).filter { $0.role == "AXTextArea" && $0.enabled }
            guard editors.count == 1, let editor = editors.first, editor.value != nil,
                  !requireEmpty || profile.isEmptyComposer(value: editor.value, placeholder: editor.placeholder) else {
                completion(.failure(.init(message: "项目页输入框不唯一、不可读或已有草稿，未写入。"))); return
            }
            AgentTaskComposer.press(editor.element, pid: pid, pointer: pointer, authorized: authorized) { focused in
                guard focused, let current = InputFocus.focusedElement(pid: pid), CFEqual(current, editor.element) else {
                    completion(.failure(.init(message: "项目页输入焦点未核实。"))); return
                }
                completion(.success(current))
            }
        }
    }
}
