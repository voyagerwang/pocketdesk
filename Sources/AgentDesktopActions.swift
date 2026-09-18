/**
 * [INPUT]: 依赖 DesktopMenuActions/DesktopWindowLayout 提供可发现菜单与窗口布局，AppOperator/TargetStore 解析应用、InputFocus/KeyboardDraftWriter 读取焦点与选区、AppKit 的应用与窗口操作；按键由 InputExecutor 注入。
 * [OUTPUT]: DesktopActionRequest 固定动作协议与 AgentDesktopActions 定向执行、窗口身份枚举、菜单能力发现、窗口布局和输入框编辑核验。
 * [POS]: 小精灵桌面动作适配层；不运行任意命令、不猜窗口、不强退、不处理保存确认框。所有写操作绑定原 PID/AX 元素，回执区分已生效与待核对。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

struct DesktopActionRequest: Codable {
    enum Action: String, Codable, CaseIterable {
        case clearInput = "clear_input", selectAll = "select_all", closeWindow = "close_window"
        case hideApp = "hide_app", quitApp = "quit_app", listWindows = "list_windows"
        case listActions = "list_actions", menuAction = "menu_action", arrangeWindow = "arrange_window"
    }
    let action: Action
    var app: String?
    var window: String?
    var command: String?
    var menuPath: [String]?
    var position: DesktopWindowLayout.Position?
    var display: Int?
    var isReadOnly: Bool { action == .listWindows || action == .listActions }

    static func parse(_ text: String) -> Self? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["action", "app", "window", "command", "menuPath", "position", "display"]),
              let request = try? JSONDecoder().decode(Self.self, from: data),
              [request.app, request.window].compactMap({ $0 }).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              request.window == nil || [.closeWindow, .menuAction, .arrangeWindow].contains(request.action),
              request.action == .menuAction ? DesktopMenuActions.commands.contains(where: { $0.id == request.command }) : request.command == nil,
              request.menuPath == nil || (request.action == .menuAction && !(request.menuPath?.isEmpty ?? true) && request.menuPath!.count <= 8 && request.menuPath!.allSatisfy { !$0.isEmpty && $0.count <= 200 }),
              request.action == .arrangeWindow ? request.position != nil : request.position == nil,
              request.display == nil || (request.action == .arrangeWindow && request.display! > 0) else { return nil }
        return request
    }
    var reservation: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(data: try! encoder.encode(self), encoding: .utf8)!
    }
    static func uniqueWindowIndex(_ title: String, titles: [String]) -> Int? {
        let matches = titles.indices.filter { titles[$0] == title }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum AgentDesktopActions {
    typealias Reply = Result<ExecutionFeedback, ShortcutError>

    static func target(_ name: String?, store: TargetStore) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        guard let name else {
            guard let pid = InputFocus.focusedApplicationPID() else { return nil }
            return running.first { $0.processIdentifier == pid }
        }
        guard let resolved = AppOperator.resolve(name, configured: store.targets) else { return nil }
        let path = URL(fileURLWithPath: resolved.path).standardizedFileURL
        let matches = running.filter { $0.bundleURL?.standardizedFileURL == path && !$0.isTerminated }
        return matches.count == 1 ? matches[0] : nil
    }

    static func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
    static func title(_ window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static let identityLock = NSLock()
    private static var identities: [(id: String, pid: pid_t, element: AXUIElement)] = []
    static func windowID(_ window: AXUIElement, pid: pid_t) -> String {
        identityLock.lock(); defer { identityLock.unlock() }
        if let found = identities.first(where: { $0.pid == pid && CFEqual($0.element, window) }) { return found.id }
        let id = "window-" + UUID().uuidString
        if identities.count >= 128 { identities.removeFirst() }
        identities.append((id, pid, window))
        return id
    }
    static func selectedWindow(_ request: DesktopActionRequest, app: NSRunningApplication) -> AXUIElement? {
        let items = windows(app), pid = app.processIdentifier
        if let name = request.window {
            let matches = items.filter { windowID($0, pid: pid) == name || title($0) == name }
            return matches.count == 1 ? matches.first : nil
        }
        if request.app != nil && request.action != .menuAction { return items.count == 1 ? items.first : nil }
        guard let focused = TargetWindowLocator.axWindowElement(pid: pid),
              items.contains(where: { CFEqual($0, focused) }) else { return nil }
        return focused
    }

    /// InputExecutor 的串行队列调用；应用/窗口目标在排队前捕获，不能执行时悄悄换成另一个前台。
    static func perform(_ request: DesktopActionRequest, app: NSRunningApplication,
                        authorized: @escaping () -> Bool, canClear: () -> Bool,
                        selectAll: () -> Bool, delete: () -> Bool,
                        completion: @escaping (Reply) -> Void) {
        let pid = app.processIdentifier
        func valid() -> Bool { authorized() && !app.isTerminated && EnvironmentGate.blockReason() == nil
            && (request.app != nil || InputFocus.focusedApplicationPID() == pid) }
        guard valid() else { completion(.failure(.message("控制权或目标应用状态已变化，未执行。"))); return }
        let name = app.localizedName ?? request.app ?? "目标应用"
        switch request.action {
        case .listWindows:
            let titles = windows(app).map { ["id": windowID($0, pid: pid), "title": title($0)] }
            guard !titles.isEmpty else { completion(.failure(.message("未读到\(name)的窗口，请确认应用窗口已打开。"))); return }
            let data = try? JSONSerialization.data(withJSONObject: ["app": name, "windows": titles, "screens": DesktopWindowLayout.screens().map { ["display": $0.id, "width": $0.rect.width, "height": $0.rect.height] }], options: [.sortedKeys])
            completion(.success(.delivered(data.flatMap { String(data: $0, encoding: .utf8) } ?? "窗口列表不可读。")))
        case .listActions:
            completion(.success(.delivered(DesktopMenuActions.describe(app: app))))
        case .menuAction:
            completion(DesktopMenuActions.perform(request, app: app, valid: valid))
        case .arrangeWindow:
            completion(DesktopWindowLayout.perform(request, app: app, valid: valid))
        case .clearInput, .selectAll:
            guard InputFocus.focusedApplicationPID() == pid, let element = InputFocus.focusedElement(pid: pid),
                  InputFocus.probeFocus(pid: pid).verdict == .editable else {
                completion(.failure(.message("请先把焦点放在\(name)需要操作的输入框，未选择或删除内容。"))); return
            }
            guard request.action != .clearInput || canClear() else {
                completion(.failure(.message("当前焦点属于文档正文，不能把清空输入框当作删除整篇文档。"))); return
            }
            let bound: () -> Bool = {
                guard valid(), InputFocus.focusedApplicationPID() == pid,
                      let current = InputFocus.focusedElement(pid: pid) else { return false }
                return CFEqual(current, element)
            }
            completion(edit(request.action, valid: bound, read: { KeyboardDraftWriter.read(element) }, selectAll: selectAll, delete: delete))
        case .hideApp, .quitApp:
            guard pid != ProcessInfo.processInfo.processIdentifier else {
                completion(.failure(.message("请通过 PocketDesk 菜单操作本控制服务，避免执行中断。"))); return
            }
            DispatchQueue.main.async {
                guard valid() else { completion(.failure(.message("执行前控制权或应用状态已变化。"))); return }
                let issued = request.action == .hideApp ? app.hide() : app.terminate()
                guard issued else { completion(.failure(.message("\(name)未接受操作请求，可能有待处理的保存提示。"))); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1000)) {
                    let confirmed = request.action == .hideApp ? app.isHidden : app.isTerminated
                    let verb = request.action == .hideApp ? "隐藏" : "退出"
                    completion(.success(confirmed ? .delivered("已\(verb)\(name)。") : .sent("已请求\(verb)\(name)，尚未确认；如有保存提示，请在电脑处理。")))
                }
            }
        case .closeWindow:
            guard let target = selectedWindow(request, app: app), valid() else {
                completion(.failure(.message("窗口未唯一匹配，请先 list_windows 并指定准确 window 标识；未关闭窗口。"))); return
            }
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(target, kAXCloseButtonAttribute as CFString, &button) == .success,
                  let button, CFGetTypeID(button) == AXUIElementGetTypeID(), valid(),
                  AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success else {
                completion(.failure(.message("目标窗口没有可用的关闭按钮，未改用可能关闭标签页的快捷键。"))); return
            }
            let windowTitle = title(target)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(700)) {
                // 查询失败不是窗口已关闭：必须成功取得剩余窗口列表，或进程确已退出。
                var remaining: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &remaining)
                let gone = app.isTerminated || (status == .success && (remaining as? [AXUIElement]).map { !$0.contains(where: { CFEqual($0, target) }) } == true)
                completion(.success(gone ? .delivered("已关闭\(name)的窗口：\(windowTitle)。") : .sent("已请求关闭指定窗口，尚未确认；如有保存提示，请在电脑处理。")))
            }
        }
    }

    /// 可隔离测试的输入事务：先证明选中了原输入框全文，才能发送一次删除；未知结果不补删。
    static func edit(_ action: DesktopActionRequest.Action, valid: () -> Bool, read: () -> DraftSnapshot?,
                     selectAll: () -> Bool, delete: () -> Bool) -> Reply {
        guard action == .clearInput || action == .selectAll else { return .failure(.message("此操作不属于输入框编辑。")) }
        guard valid(), let before = read() else { return .failure(.message("输入框正文或选区不可核验，未操作。")) }
        if before.text.isEmpty { return .success(.delivered("输入框已经为空。")) }
        guard valid(), selectAll() else { return .failure(.message("未能发出全选操作。")) }
        var selected: DraftSnapshot?
        for _ in 0..<6 {
            guard valid() else { return .failure(.message("全选后焦点或控制权变化，未删除。")) }
            if let snapshot = read(), snapshot.text == before.text, snapshot.location == 0,
               snapshot.length == before.text.utf16.count { selected = snapshot; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard selected != nil else { return .success(.sent("已发出全选，但未确认完整选区；未删除。")) }
        if action == .selectAll { return .success(.delivered("已全选当前输入框内容。")) }
        guard valid(), read() == selected, delete() else { return .failure(.message("删除前内容或选区发生变化，已停止。")) }
        for _ in 0..<6 {
            guard valid() else { return .success(.sent("已发出删除，焦点或控制权变化，结果待核对。")) }
            if read()?.text.isEmpty == true { return .success(.delivered("已清空当前输入框。")) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return .success(.sent("已发出删除，但未确认输入框清空，不会自动重试。"))
    }
}
