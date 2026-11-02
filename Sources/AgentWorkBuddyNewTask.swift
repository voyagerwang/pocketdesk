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

    /// 等待窗口列表与页面内容就绪的上限。一轮要扫全部窗口（主窗 + 独立窗），
    /// 实测双窗全扫最慢 2.02s，2s 会把"刚好扫完"误判成"读不到"。
    private static let readyWaitSeconds: TimeInterval = 5

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

    /// homeState 的判定依据摘要：只记角色、矩形与"是否空白"，不记正文。
    static func homeStateEvidence(_ snapshot: [Node]) -> String {
        let welcome = snapshot.filter { $0.role == "AXHeading" && $0.navigationVisible
            && ($0.accessibleNames + [$0.label]).contains("WorkBuddy, 我帮你") }
        let editors = AgentTaskComposer.uniqueNavigationControls(snapshot.filter {
            $0.role == "AXTextArea" && $0.enabled && $0.navigationVisible
        })
        let parts = editors.prefix(6).map { editor -> String in
            let empty = AgentAppProfile.workbuddy.isEmptyComposer(value: editor.value, placeholder: editor.placeholder)
            return "frame=\(editor.navigationFrame.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" } ?? "nil") empty=\(empty)"
        }
        return "welcome=\(welcome.count) visibleEditors=\(editors.count) [\(parts.joined(separator: " ; "))]"
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
        // 新增判定与焦点判定都用同一物理窗口补证：AX 包装在读取之间可能被重建，
        // 只认 CFEqual 会把"同一个窗口的新引用"当成不同窗口。
        let created = uniqueWindows(after).filter { window in !before.contains { sameWindow($0, window) } }
        guard created.count == 1, let window = created.first, let focused, sameWindow(window, focused) else { return nil }
        return window
    }

    static func prepare(pid: pid_t, pointer: PointerExecutor?, authorized: @escaping () -> Bool,
                        completion: @escaping (Reply) -> Void) {
        AgentTaskComposer.queue.async {
            let entryGate = AgentTaskComposer.validWithDetail(pid, authorized)
            guard entryGate.valid, let bundlePath = applicationBundlePath(pid) else {
                ExecutionLog.shared.append(kind: "focus", label: "派单入口归属核验", outcome: .blocked,
                    detail: "pid=\(pid); \(entryGate.detail)")
                fail("WorkBuddy 窗口或控制权未核实，未输入正文。", completion); return
            }
            // 激活后（或冷启动时辅助功能树刚被请求）窗口列表与页面内容未必一拍就可读。
            // 这里只读等待，不点击、不激活、不写正文；等不到就如实停下。
            let readyDeadline = ProcessInfo.processInfo.systemUptime + readyWaitSeconds
            var snapshots: [(window: AXUIElement, read: (nodes: [Node], complete: Bool, cause: String))] = []
            var lastReadSummary = ""
            while ProcessInfo.processInfo.systemUptime < readyDeadline {
                guard AgentTaskComposer.valid(pid, authorized) else { break }
                if let list = windows(pid), list.count <= maximumWindows {
                    let reads: [(window: AXUIElement, read: (nodes: [Node], complete: Bool, cause: String))] = list.map { window in (window, readWindow(window, pid: pid)) }
                    // 诊断只记节点数与完整标志，不含正文，便于区分"读不到"与"页面没有"。
                    lastReadSummary = reads.map { "nodes=\($0.read.nodes.count) complete=\($0.read.complete) cause=\($0.read.cause.isEmpty ? "-" : $0.read.cause)" }.joined(separator: "; ")
                    if reads.allSatisfy({ $0.read.complete }) { snapshots = reads; break }
                } else {
                    lastReadSummary = "windowList=\(windows(pid)?.count ?? -1)"
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard !snapshots.isEmpty else {
                ExecutionLog.shared.append(kind: "workspace", label: "主窗读取核验", outcome: .blocked,
                    detail: "pid=\(pid); 窗口与内容未在预算内读全；\(lastReadSummary)")
                fail("WorkBuddy 窗口或控制权未核实，未输入正文。", completion); return
            }
            let primary = snapshots.filter { windowKind($0.read.nodes, bundlePath: bundlePath, complete: $0.read.complete) == .primary }.map(\.window)
            guard primary.count == 1, let window = primary.first else {
                ExecutionLog.shared.append(kind: "workspace", label: "主窗读取核验", outcome: .blocked,
                    detail: "pid=\(pid); primary窗口数=\(primary.count)（快照数=\(snapshots.count)）；\(lastReadSummary)")
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
                    guard observed.complete else {
                        ExecutionLog.shared.append(kind: "workspace", label: "主窗读取核验", outcome: .blocked,
                            detail: "pid=\(pid); 新任务入口内容未读全；cause=\(observed.cause.isEmpty ? "-" : observed.cause)")
                        fail("新任务入口内容尚未完整可读，草稿已保留。", completion); return
                    }
                    let snapshot = observed.nodes
                    let evidence = homeStateEvidence(snapshot)
                    switch homeState(snapshot) {
                    case .empty: verify(window, pid: pid, pointer: pointer, authorized: authorized, completion: completion)
                    case .draft:
                        ExecutionLog.shared.append(kind: "workspace", label: "新页状态核验", outcome: .sent,
                            detail: "pid=\(pid); 判定为草稿，走独立窗口路径；\(evidence)")
                        openIndependent(window, snapshot: snapshot, pid: pid, pointer: pointer, authorized: authorized, completion: completion)
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
                                ExecutionLog.shared.append(kind: "workspace", label: "独立窗口入口", outcome: .delivered,
                                    detail: "pid=\(pid); 已点击“在独立窗口中打开”；点击前窗口数=\(before.count)")
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
        var lastSummary = ""
        while ProcessInfo.processInfo.systemUptime < deadline {
            let gate = AgentTaskComposer.validWithDetail(pid, authorized)
            let current = windows(pid)
            guard gate.valid, let current else {
                ExecutionLog.shared.append(kind: "focus", label: "独立窗口归属核验", outcome: .blocked,
                    detail: "pid=\(pid); windowsRead=\(current == nil ? "nil" : "ok"); \(gate.detail)")
                fail("独立窗口打开期间焦点或控制权已变化，未输入正文。", completion); return
            }
            guard current.contains(where: { sameWindow($0, primary) }) else {
                ExecutionLog.shared.append(kind: "focus", label: "独立窗口归属核验", outcome: .blocked,
                    detail: "pid=\(pid); 原主窗口不在当前窗口列表中；currentCount=\(current.count)")
                fail("原主窗口已变化，未向新增窗口输入正文。", completion); return
            }
            let added = uniqueWindows(current).filter { window in !before.contains { CFEqual($0, window) } }
            guard added.count <= 1 else { fail("同时出现多个新窗口，未选择输入落点。", completion); return }
            let focused = focusedWindow(pid)
            // 诊断只记窗口数量与矩形，不含正文。
            lastSummary = "before=\(before.count) current=\(current.count) added=\(added.count) "
                + "focusedFrame=\(focused.map { "\(AgentTaskComposer.frame($0) ?? .zero)" } ?? "nil") "
                + "addedFrames=\(added.map { "\(AgentTaskComposer.frame($0) ?? .zero)" }.joined(separator: ","))"
            if let window = newFocusedWindow(before: before, after: current, focused: focused) {
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
        ExecutionLog.shared.append(kind: "workspace", label: "独立窗口核验", outcome: .blocked,
            detail: "pid=\(pid); 等待新增且聚焦的独立空白窗口超时；\(lastSummary)")
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
        // 窗口归属是后续每一步的门禁，允许短重试吃掉 AX 的偶发读空。
        { AgentTaskComposer.retrying {
            AgentTaskComposer.valid(pid, authorized) && isFocused(window, pid: pid)
                && windows(pid)?.contains(where: { sameWindow($0, window) }) == true
        } }
    }

    /// 窗口的 AX 包装会被重建（同一块物理窗口、新的 AX 引用）；引用不同时用位置与尺寸补证。
    static func sameWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if CFEqual(lhs, rhs) { return true }
        guard let a = AgentTaskComposer.frame(lhs), let b = AgentTaskComposer.frame(rhs) else { return false }
        return a == b
    }
    private static func readWindow(_ window: AXUIElement, pid: pid_t) -> (nodes: [Node], complete: Bool, cause: String) {
        var limited = true
        var cause = ""
        let snapshot = AgentTaskComposer.nodes(pid: pid, window: window) { _, truncated in limited = truncated }
            onScanDetail: { _, _, detail in if !detail.isEmpty { cause = detail } }
        return (snapshot, !limited, cause)
    }
    private static func applicationBundlePath(_ pid: pid_t) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid && !$0.isTerminated }?.bundleURL?.path
    }
    private static func isFocused(_ window: AXUIElement, pid: pid_t) -> Bool {
        focusedWindow(pid).map { sameWindow($0, window) } == true
    }
    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        // 同 windows：AX 忙时的 cannotComplete 不能当成"没有焦点窗口"。
        var result: AXUIElement?
        AgentTaskComposer.retrying(4, spacing: 40_000) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
            result = value as! AXUIElement
            return true
        }
        return result
    }
    private static func windows(_ pid: pid_t) -> [AXUIElement]? {
        // AX 读会偶发返回 cannotComplete：归属核验把进程级 AX 超时压到 40ms 后，
        // AX 服务正忙时窗口列表就读不到（实测 5 次里有 1 次失败）。
        // 裸读会把"读不到"当成"没有窗口"，整轮派单被误判失败，故短重试。
        var result: [AXUIElement]?
        AgentTaskComposer.retrying(4, spacing: 40_000) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return false }
            result = uniqueWindows(windows)
            return true
        }
        return result
    }
    private static func fail(_ message: String, _ completion: (Reply) -> Void) {
        completion(.failure(.init(message: message)))
    }
}
