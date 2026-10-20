/**
 * [INPUT]: WorkBuddy 主窗/独立窗的 AX 身份、共享新建导航/空框核验与受租约保护的指针执行器。
 * [OUTPUT]: 保留旧会话与主窗新页草稿，返回独立新任务的精确输入框及窗口绑定；主窗有草稿时使用原生“在独立窗口中打开”，不清空、不归档、不调用覆盖 home 的任务深链。
 * [POS]: WorkBuddy 原生新任务准备边界；项目选择和正文投递由 WorkspaceComposer/AppDispatch 后续完成，原有独立窗不参与候选写入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

enum AgentWorkBuddyNewTask {
    typealias Node = AgentTaskComposer.Node
    typealias Reply = Result<AgentTaskComposer.Prepared, AgentComposerFailure>
    enum WindowKind { case primary, independent, other }
    enum HomeState { case absent, empty, draft, unreadable, ambiguous }
    private static let homeWaitSeconds: TimeInterval = 6
    private static let windowWaitSeconds: TimeInterval = 8
    private static let menuWaitSeconds: TimeInterval = 3
    private static let maximumWindows = 16

    /// 只认应用自身 renderer 的宿主 URL；正文链接、预览页和其他应用面板不能冒充主窗。
    static func windowKind(_ snapshot: [Node], bundlePath: String = "/Applications/WorkBuddy.app", complete: Bool = true) -> WindowKind {
        guard complete, bundlePath.hasPrefix("/"), bundlePath.hasSuffix(".app") else { return .other }
        let hostPaths = Set(["app.asar", "app.asar.unpacked"].map { bundlePath + "/Contents/Resources/" + $0 + "/renderer/index.html" })
        let hosts = snapshot.filter { $0.role == "AXWebArea" }.compactMap(\.pageURL).compactMap(URLComponents.init(string:))
            .filter { $0.scheme == "file" && ($0.host == nil || $0.host == "" || $0.host == "localhost") && hostPaths.contains($0.path) }
        let kinds = Set(hosts.map { host in
            host.queryItems?.first(where: { $0.name == "windowKind" })?.value
                ?? host.queryItems?.first(where: { $0.name == "windowAppId" })?.value ?? "main"
        })
        if kinds == ["conversation"] { return .independent }
        if kinds == ["main"] { return .primary }
        return .other
    }

    static func homeState(_ snapshot: [Node], complete: Bool = true) -> HomeState {
        guard complete else { return .unreadable }
        let welcome = AgentTaskComposer.uniqueNavigationControls(snapshot.filter {
            $0.role == "AXHeading" && $0.navigationVisible
                && ($0.accessibleNames + [$0.label]).contains("WorkBuddy, 我帮你")
        })
        guard welcome.count == 1 else { return welcome.isEmpty ? .absent : .ambiguous }
        let editors = AgentTaskComposer.uniqueNavigationControls(snapshot.filter {
            $0.role == "AXTextArea" && $0.enabled && $0.navigationVisible
        })
        guard editors.count == 1, let editor = editors.first else { return editors.isEmpty ? .unreadable : .ambiguous }
        guard editor.value != nil else { return .unreadable }
        return AgentAppProfile.workbuddy.isEmptyComposer(value: editor.value, placeholder: editor.placeholder) ? .empty : .draft
    }

    static func independentMenuItems(_ snapshot: [Node]) -> [Node] {
        let menus = AgentTaskComposer.uniqueNavigationControls(snapshot.filter { $0.role == "AXMenu" })
        guard menus.count == 1 else { return [] }
        let names: Set<String> = ["在独立窗口中打开", "Open in a separate window"]
        return AgentTaskComposer.uniqueNavigationControls(snapshot.filter {
            $0.role == "AXMenuItem" && $0.inMenu && $0.enabled && $0.navigationVisible
                && ($0.accessibleNames + [$0.label]).contains(where: names.contains)
        })
    }

    static func uniqueWindows(_ windows: [AXUIElement]) -> [AXUIElement] {
        windows.reduce(into: []) { result, window in
            if !result.contains(where: { CFEqual($0, window) }) { result.append(window) }
        }
    }

    /// 窗口必须本次新增且为真实 focused window；已有独立窗或同时出现两个新窗均不授权。
    static func newFocusedWindow(before: [AXUIElement], after: [AXUIElement], focused: AXUIElement?) -> AXUIElement? {
        let created = uniqueWindows(after).filter { window in !before.contains { CFEqual($0, window) } }
        guard created.count == 1, let window = created.first, let focused, CFEqual(window, focused) else { return nil }
        return window
    }

    static func prepare(pid: pid_t, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                        completion: @escaping (Reply) -> Void) {
        AgentTaskComposer.queue.async {
            guard AgentTaskComposer.valid(pid, authorized), let bundlePath = applicationBundlePath(pid),
                  let initial = windows(pid), initial.count <= maximumWindows else {
                fail("WorkBuddy 窗口或控制权未核实，未输入正文。", completion); return
            }
            let snapshots = initial.map { window in (window, readWindow(window, pid: pid)) }
            guard snapshots.allSatisfy({ $0.1.complete }) else { fail("WorkBuddy 窗口内容尚未完整可读，已有草稿已保留。", completion); return }
            let primary = snapshots.filter { windowKind($0.1.nodes, bundlePath: bundlePath, complete: $0.1.complete) == .primary }.map(\.0)
            guard primary.count == 1, let window = primary.first else {
                fail("未找到唯一 WorkBuddy 主窗口，已有窗口与草稿均已保留。", completion); return
            }
            guard AgentTaskComposer.valid(pid, authorized) else { fail("准备新任务时控制权或应用焦点已变化。", completion); return }
            if !isFocused(window, pid: pid) {
                guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
                    fail("WorkBuddy 主窗口未能置前，已有草稿已保留。", completion); return
                }
                let deadline = ProcessInfo.processInfo.systemUptime + AgentTaskComposer.nativeNavigationWaitSeconds
                while !isFocused(window, pid: pid), ProcessInfo.processInfo.systemUptime < deadline {
                    guard AgentTaskComposer.valid(pid, authorized) else { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            let bound = windowAuthorization(window, pid: pid, authorized: authorized)
            guard bound() else { fail("WorkBuddy 主窗口的键盘焦点未核实，未输入正文。", completion); return }
            AgentTaskComposer.nativeNavigationSnapshot(profile: .workbuddy, pid: pid, pointer: pointer, authorized: bound) { result in
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success:
                    guard bound() else { fail("原主窗口或控制权已变化，未输入正文。", completion); return }
                    let observed = readWindow(window, pid: pid)
                    guard observed.complete else { fail("新任务入口内容尚未完整可读，草稿已保留。", completion); return }
                    let snapshot = observed.nodes
                    switch homeState(snapshot) {
                    case .empty: verify(window, pid: pid, pointer: pointer, authorized: authorized, completion: completion)
                    case .draft: openIndependent(window, snapshot: snapshot, pid: pid, pointer: pointer, authorized: authorized, completion: completion)
                    case .unreadable: fail("新任务页草稿暂时不可读，已保留；未输入正文。", completion)
                    case .ambiguous: fail("新任务页或输入框不唯一，已有草稿已保留。", completion)
                    case .absent:
                        let buttons = AgentTaskComposer.newTaskButtons(profile: .workbuddy, snapshot: snapshot)
                        guard buttons.count == 1, let button = buttons.first else {
                            fail("未找到唯一新建任务入口，未输入正文。", completion); return
                        }
                        // 旧会话草稿交给应用按会话保存；这里只点击一次新建，不读写旧框正文。
                        AgentTaskComposer.press(button.element, pid: pid, pointer: pointer, authorized: bound) { pressed in
                            AgentTaskComposer.queue.async {
                                guard pressed else { fail("新建任务入口未能点击，旧会话草稿已保留。", completion); return }
                                waitForHome(window, pid: pid, pointer: pointer, authorized: authorized, completion: completion)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func waitForHome(_ window: AXUIElement, pid: pid_t, pointer: PointerExecutor?,
                                    authorized: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        let bound = windowAuthorization(window, pid: pid, authorized: authorized)
        let deadline = ProcessInfo.processInfo.systemUptime + homeWaitSeconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard bound() else { fail("新建后原窗口或控制权已变化，未输入正文。", completion); return }
            let observed = readWindow(window, pid: pid)
            guard observed.complete else { Thread.sleep(forTimeInterval: 0.1); continue }
            let snapshot = observed.nodes
            switch homeState(snapshot) {
            case .empty: verify(window, pid: pid, pointer: pointer, authorized: authorized, completion: completion); return
            case .draft: openIndependent(window, snapshot: snapshot, pid: pid, pointer: pointer, authorized: authorized, completion: completion); return
            case .unreadable: fail("新任务页内容不可读，已有草稿已保留。", completion); return
            case .ambiguous: fail("新任务页输入框不唯一，未输入正文。", completion); return
            case .absent: Thread.sleep(forTimeInterval: 0.1)
            }
        }
        fail("点击新建后未能核实新任务页，旧会话草稿已保留。", completion)
    }

    private static func openIndependent(_ primary: AXUIElement, snapshot: [Node], pid: pid_t, pointer: PointerExecutor?,
                                        authorized: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        let bound = windowAuthorization(primary, pid: pid, authorized: authorized)
        let buttons = AgentTaskComposer.newTaskButtons(profile: .workbuddy, snapshot: snapshot)
        guard bound(), buttons.count == 1, let button = buttons.first, let before = windows(pid) else {
            fail("有草稿的新页未找到唯一独立窗口入口，原文已保留。", completion); return
        }
        AgentTaskComposer.clickGuarded(button.element, pid: pid, pointer: pointer, authorized: authorized,
            preflight: bound, button: .right) { opened in
            AgentTaskComposer.queue.async {
                guard opened else { fail("新建任务菜单未能打开，原草稿已保留。", completion); return }
                let deadline = ProcessInfo.processInfo.systemUptime + menuWaitSeconds
                while ProcessInfo.processInfo.systemUptime < deadline {
                    guard bound() else { fail("打开菜单时原窗口或控制权已变化。", completion); return }
                    // 原生 context menu 可能挂在应用焦点树而非主窗子树；原窗绑定仍约束读取与后续点击。
                    var limited = true
                    let menu = AgentTaskComposer.nodes(pid: pid, prioritizeEditor: true) { _, truncated in limited = truncated }
                    guard !limited else { Thread.sleep(forTimeInterval: 0.1); continue }
                    let rows = independentMenuItems(menu)
                    if rows.count == 1, let row = rows.first {
                        // 菜单也按真实矩形点击；AXPress 成功回执不能代替窗口实际出现。
                        AgentTaskComposer.clickGuarded(row.element, pid: pid, pointer: pointer, authorized: authorized, preflight: bound) { clicked in
                            AgentTaskComposer.queue.async {
                                guard clicked else { fail("独立窗口菜单项未能点击，原草稿已保留。", completion); return }
                                waitForIndependent(primary: primary, before: before, pid: pid, pointer: pointer, authorized: authorized, completion: completion)
                            }
                        }
                        return
                    }
                    if rows.count > 1 { fail("独立窗口菜单项不唯一，原草稿已保留。", completion); return }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                fail("未找到原生“在独立窗口中打开”菜单，原草稿已保留。", completion)
            }
        }
    }

    private static func waitForIndependent(primary: AXUIElement, before: [AXUIElement], pid: pid_t, pointer: PointerExecutor?,
                                           authorized: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + windowWaitSeconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard AgentTaskComposer.valid(pid, authorized), let current = windows(pid) else {
                fail("独立窗口打开期间焦点或控制权已变化，未输入正文。", completion); return
            }
            guard current.contains(where: { CFEqual($0, primary) }) else {
                fail("原主窗口已变化，未向新增窗口输入正文。", completion); return
            }
            let added = uniqueWindows(current).filter { window in !before.contains { CFEqual($0, window) } }
            guard added.count <= 1 else { fail("同时出现多个新窗口，未选择输入落点。", completion); return }
            if let window = newFocusedWindow(before: before, after: current, focused: focusedWindow(pid)) {
                let observed = readWindow(window, pid: pid)
                guard observed.complete else { Thread.sleep(forTimeInterval: 0.1); continue }
                let snapshot = observed.nodes
                if let bundlePath = applicationBundlePath(pid), windowKind(snapshot, bundlePath: bundlePath, complete: observed.complete) == .independent {
                    switch homeState(snapshot) {
                    case .empty:
                        ExecutionLog.shared.append(kind: "workspace", label: "保留草稿并新建", outcome: .delivered,
                            detail: "主窗草稿留在原位，已核实本次新增的独立空白任务窗口；尚未输入或发送正文。")
                        verify(window, pid: pid, pointer: pointer, authorized: authorized, completion: completion); return
                    case .draft: fail("新独立窗口已有草稿，未覆盖或发送。", completion); return
                    case .unreadable: fail("独立窗口输入框暂时不可读，未输入正文。", completion); return
                    case .ambiguous: fail("独立窗口输入框不唯一，未输入正文。", completion); return
                    case .absent: break
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        fail("未能确认本次新增且聚焦的独立空白窗口，原草稿已保留。", completion)
    }

    private static func verify(_ window: AXUIElement, pid: pid_t, pointer: PointerExecutor?,
                               authorized: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        let bound = windowAuthorization(window, pid: pid, authorized: authorized)
        AgentTaskComposer.verify(profile: .workbuddy, pid: pid, text: "", beforeLabels: [], pointer: pointer, authorized: bound) { result in
            completion(result.map { original in
                var prepared = original
                prepared.validateTarget = bound
                prepared.validateWindow = bound
                return prepared
            })
        }
    }

    private static func windowAuthorization(_ window: AXUIElement, pid: pid_t, authorized: @escaping () -> Bool) -> () -> Bool {
        { AgentTaskComposer.valid(pid, authorized) && isFocused(window, pid: pid)
            && windows(pid)?.contains(where: { CFEqual($0, window) }) == true }
    }
    private static func readWindow(_ window: AXUIElement, pid: pid_t) -> (nodes: [Node], complete: Bool) {
        var limited = true
        let snapshot = AgentTaskComposer.nodes(pid: pid, window: window) { _, truncated in limited = truncated }
        return (snapshot, !limited)
    }
    private static func applicationBundlePath(_ pid: pid_t) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid && !$0.isTerminated }?.bundleURL?.path
    }
    private static func isFocused(_ window: AXUIElement, pid: pid_t) -> Bool {
        focusedWindow(pid).map { CFEqual($0, window) } == true
    }
    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }
    private static func windows(_ pid: pid_t) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return uniqueWindows(windows)
    }
    private static func fail(_ message: String, _ completion: (Reply) -> Void) {
        completion(.failure(.init(message: message)))
    }
}
