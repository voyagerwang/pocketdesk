/**
 * [INPUT]: 依赖 AppKit Accessibility 与 Util 前台观测。
 * [OUTPUT]: 提供 InputFocus 三态焦点探测、带 PID/聚焦窗口/WebArea 校验的安全鼠标锚点、有界查找、显式聚焦及无正文诊断（字符数量、占位文本相等关系与选区）。
 * [POS]: Sources 的焦点能力边界；InputExecutor 决定是否允许聚焦，全屏绑定输入只读探测。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

enum InputFocus {
    struct EditableAnchor {
        fileprivate let scope: AXUIElement
        fileprivate let pid: pid_t
        let point: CGPoint
    }

    // Chromium 的真实 DOM 光标可能暴露成 WebArea 下的 Group/StaticText。传统可编辑元素
    // 直接作为范围；其他角色沿父链归一到最近 WebArea，浏览器工具栏不在这条链上。
    static func normalizedClickScope(_ observed: AXUIElement?, pid: pid_t) -> AXUIElement? {
        guard var current = observed, pid > 0 else { return nil }
        var chain: [AXUIElement] = []
        var roles: [String] = []
        for _ in 0..<16 {
            var ownerPID: pid_t = 0
            var roleValue: CFTypeRef?
            guard AXUIElementGetPid(current, &ownerPID) == .success, ownerPID == pid,
                  AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String else { return nil }
            chain.append(current)
            roles.append(role)
            if let index = ImagePastePolicy.boundClickScopeIndex(rolesFromFocused: roles) { return chain[index] }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return nil }
            current = parentValue as! AXUIElement
        }
        return nil
    }

    // Chrome 飞书多图需要在相邻附件之间重新点一下编辑器。只接受鼠标命中本轮绑定的
    // 可编辑元素或 WebArea 后代；地址栏、标签栏、其他页面/应用与未知区域都不允许。
    static func captureBoundAnchor(pid: pid_t, point: CGPoint, scope: AXUIElement) -> EditableAnchor? {
        guard pid > 0, scopeAllowsClick(scope, pid: pid), frame(of: scope)?.contains(point) == true,
              let hit = element(at: point), belongs(hit, to: scope, pid: pid),
              let focused = focusedElement(pid: pid), belongs(focused, to: scope, pid: pid) else { return nil }
        return EditableAnchor(scope: scope, pid: pid, point: point)
    }

    // Chromium 会在 DOM 更新后为同一个页面重新包装 AX 节点，CFEqual 因此不能作为页面身份。
    // 当前命中与当前焦点都必须落在聚焦窗口内同一 WebArea 的矩形中；工具栏没有 WebArea
    // 父链，后台窗口也不是 focusedWindow，两者都会被拒绝。
    static func captureCurrentWebAnchor(pid: pid_t, point: CGPoint) -> EditableAnchor? {
        guard pid > 0, let window = focusedWindow(pid), frame(of: window)?.contains(point) == true,
              let hit = element(at: point), belongs(hit, to: window, pid: pid),
              let hitWebArea = ancestor(of: hit, role: "AXWebArea", pid: pid, stopAt: window),
              let focused = focusedElement(pid: pid), belongs(focused, to: window, pid: pid),
              let focusedWebArea = ancestor(of: focused, role: "AXWebArea", pid: pid, stopAt: window),
              sameFrame(hitWebArea, focusedWebArea), frame(of: hitWebArea)?.contains(point) == true else { return nil }
        return EditableAnchor(scope: hitWebArea, pid: pid, point: point)
    }

    // 粘贴图片后 Chrome 可能暂时把 AX 焦点暴露为附件或 WebArea；此时不能要求原编辑元素
    // 仍报告 focused。只确认发送前保存的同一元素仍属于目标进程、仍可编辑且仍覆盖原锚点，
    // 外层同时验证前台与 InputBinding。点击后再由 captureEditableAnchor 确认焦点确实恢复。
    static func validateStoredAnchor(_ anchor: EditableAnchor) -> Bool {
        if scopeAllowsClick(anchor.scope, pid: anchor.pid), frame(of: anchor.scope)?.contains(anchor.point) == true,
           let hit = element(at: anchor.point), belongs(hit, to: anchor.scope, pid: anchor.pid) { return true }
        return captureCurrentWebAnchor(pid: anchor.pid, point: anchor.point) != nil
    }

    private static func scopeAllowsClick(_ scope: AXUIElement, pid: pid_t) -> Bool {
        var ownerPID: pid_t = 0
        var roleValue: CFTypeRef?
        guard AXUIElementGetPid(scope, &ownerPID) == .success, ownerPID == pid,
              AXUIElementCopyAttributeValue(scope, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }
        return editableRoles.contains(role) || role == "AXWebArea"
    }

    private static func element(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                Float(point.x), Float(point.y), &hit) == .success else { return nil }
        return hit
    }

    private static func belongs(_ element: AXUIElement, to scope: AXUIElement, pid: pid_t) -> Bool {
        var current = element
        for _ in 0..<16 {
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(current, &ownerPID) == .success, ownerPID == pid else { return false }
            if CFEqual(current, scope) { return true }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return false }
            current = parentValue as! AXUIElement
        }
        return false
    }

    private static func ancestor(of element: AXUIElement, role wanted: String, pid: pid_t,
                                 stopAt: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<20 {
            var ownerPID: pid_t = 0
            var roleValue: CFTypeRef?
            guard AXUIElementGetPid(current, &ownerPID) == .success, ownerPID == pid,
                  AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String else { return nil }
            if role == wanted { return current }
            if CFEqual(current, stopAt) { return nil }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return nil }
            current = parentValue as! AXUIElement
        }
        return nil
    }

    private static func sameFrame(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        guard let a = frame(of: lhs), let b = frame(of: rhs) else { return false }
        let tolerance: CGFloat = 2
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // 同一份焦点元素供绑定与选区替换消费；应用级不可见时尝试系统级，并核对 PID。
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        for owner in [AXUIElementCreateApplication(pid), AXUIElementCreateSystemWide()] {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let element = raw as! AXUIElement
            var actualPID: pid_t = 0
            guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid else { continue }
            return element
        }
        return nil
    }
    /* ---------- 注入前的焦点确认 ---------- */
    // 激活（activate）只保证应用到了前台，不保证里面有输入框拿着键盘焦点。
    // Electron/Chromium 应用尤其典型：窗口起来了，页面里却没有任何 first responder，
    // 此时 postUnicode 投出去的按键石沉大海——这正是"点了发送却什么都没进去"的根因。
    // 用户手动点一下输入框就好，因为那一步才真正把焦点放进去。

    /// 探测某应用里现在谁拿着键盘焦点。
    /// 连 AXError 一起带出来：只有看得到失败原因，才能区分「真的没焦点」「AX 不许我问」
    /// 「焦点停在容器上」——这三种在旧实现里都塌缩成同一个 false，正是误报的来源。
    static func probeFocus(pid: pid_t) -> (verdict: FocusVerdict, note: String) {
        guard pid > 0 else { return (.unknown, "pid 无效，未探测") }
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw)
        if focusStatus == .success, let element = raw, CFGetTypeID(element) == AXUIElementGetTypeID() {
            return Self.classify(element as! AXUIElement, source: "应用级")
        }
        // 应用级问不出来时（实测 ChatGPT 桌面版直接返回 noValue -25212），不代表没有输入框——
        // 它只是不肯回答。退回系统级 AX 再问一次：系统级问的是"全系统当前谁拿着键盘焦点"，
        // 对这类应用常常答得上来。
        var systemRaw: CFTypeRef?
        let systemStatus = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                        kAXFocusedUIElementAttribute as CFString, &systemRaw)
        if systemStatus == .success, let element = systemRaw, CFGetTypeID(element) == AXUIElementGetTypeID() {
            var ownerPID: pid_t = 0
            AXUIElementGetPid(element as! AXUIElement, &ownerPID)
            // pid 对不上说明焦点在别的应用上，这份答案不属于本次探测的目标，不能采信。
            guard ownerPID == pid else {
                return (.unknown, "系统级焦点属于 pid \(ownerPID)，与目标 \(pid) 不符")
            }
            return Self.classify(element as! AXUIElement, source: "系统级回退")
        }
        return (.unknown, "读不到聚焦元素（应用级 \(focusStatus.rawValue)，系统级 \(systemStatus.rawValue)）")
    }

    /// 给一个已确认拿到手的聚焦元素分类。
    private static func classify(_ element: AXUIElement, source: String) -> (verdict: FocusVerdict, note: String) {
        var value: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        guard roleStatus == .success, let role = value as? String else {
            return (.unknown, "\(source)：读不到 role（AXError \(roleStatus.rawValue)）")
        }
        if editableRoles.contains(role) { return (.editable, "\(source)：聚焦 \(role)") }
        if nonInputRoles.contains(role) { return (.notEditable, "\(source)：聚焦 \(role)，不是可输入控件") }
        // 认不出的角色（容器、web 页面、新角色）一律 unknown：不替用户下负面结论。
        return (.unknown, "\(source)：聚焦 \(role)，无法判定能否接字")
    }

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
           let window = raw, CFGetTypeID(window) == AXUIElementGetTypeID() { return (window as! AXUIElement) }
        // 少数应用不给"聚焦窗口"（尤其是刚被激活、窗口还没稳定的时候），退回取第一个窗口。
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement], let first = list.first { return first }
        return nil
    }

    // 抢焦点：先直接设 AXFocused，不行就退化为"按一下"——对输入框而言按一下就是聚焦，与用户手动点击等效。
    // 关键是写完必须等一拍再读：Chromium/Electron 对 AX 聚焦是异步生效的，调用返回 success 时
    // 焦点还没到位，立刻读会读到旧的 AXWebArea，从而误判失败（实测踩到过）。
    private static func takeFocus(_ element: AXUIElement, pid: pid_t) -> Bool {
        if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            usleep(150_000)
            if hasEditableFocus(pid: pid) { return true }
        }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { return false }
        usleep(150_000)
        return hasEditableFocus(pid: pid)
    }

    /// 注入前确保有地方能接字，并给出探测结论供回执分级。
    ///
    /// 只在**明确没有输入框**时才去抢焦点。焦点状态都读不出来（unknown）时绝不乱按：
    /// BFS 找到的第一个输入框未必是用户想要的那个（搜索框常排在更浅层），按下即改焦点，
    /// 把内容送进错误的框比送不进去更难发现。
    @discardableResult
    static func ensureEditableFocus(pid: pid_t) -> FocusVerdict {
        guard pid > 0 else {
            Self.noteProbe(pid: pid, verdict: .unknown, note: "pid 无效，未探测")
            return .unknown
        }
        let probe = Self.probeFocus(pid: pid)
        if probe.verdict != .notEditable {
            Self.noteProbe(pid: pid, verdict: probe.verdict, note: probe.note + "（未干预焦点）")
            return probe.verdict
        }
        let candidates = Self.editableCandidates(pid: pid)
        // 只去抢「输入框」：BFS 是层序的，浅层的搜索框/下拉会排在前头，而把内容打进搜索框
        // 比打不进去更难发现。所以既不能"找到第一个就用"，也不碰 ComboBox/SearchField。
        for role in Self.focusPriority {
            guard let hit = candidates.first(where: { $0.role == role }) else { continue }
            guard Self.takeFocus(hit.element, pid: pid) else { continue }
            // 抢完必须重新探一次：焦点可能已经变了。探测仍是 unknown 也照实返回——
            // 尽力干预过就把 unknown 交回去，不再升级成"没有输入框"的负面结论。
            let after = Self.probeFocus(pid: pid)
            Self.noteProbe(pid: pid, verdict: after.verdict, note: after.note + "（已尝试聚焦 \(role)）")
            return after.verdict
        }
        Self.noteProbe(pid: pid, verdict: .notEditable, note: probe.note + "（未找到可聚焦的输入框）")
        return .notEditable
    }

    /// 记下最近一次焦点探测的现场。只看到"没有聚焦的输入框"无法区分「真没聚焦」与
    /// 「AX 把 Electron 的 contenteditable 报成了容器」，排查全靠这份现场。控制台可读。
    private static let probeLock = NSLock()
    private static var lastProbe: [String: Any] = [:]
    static var lastFocusProbe: [String: Any] {
        probeLock.lock(); defer { probeLock.unlock() }
        return lastProbe
    }
    private static func noteProbe(pid: pid_t, verdict: FocusVerdict, note: String, via: String = "发送前探测") {
        let app = NSRunningApplication(processIdentifier: pid)
        let snapshot: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "app": app?.localizedName ?? "(未知)",
            "bundleID": app?.bundleIdentifier ?? "",
            "pid": Int(pid),
            "verdict": String(describing: verdict),
            "note": note,
            "via": via,
        ]
        probeLock.lock()
        lastProbe = snapshot
        probeLock.unlock()
    }

    /// 只读探测当前前台应用的焦点现场：不注入任何事件，只回答"现在谁拿着键盘焦点"。
    /// 排查「报没有聚焦的输入框」这类误报时，这是唯一能分清「真没聚焦」与
    /// 「AX 把 Electron 的 contenteditable 报成容器角色」的手段。
    static func probeFrontmostFocus() -> [String: Any] {
        guard let front = Util.frontmostApp() else { return ["error": "读不到前台应用"] }
        let probe = Self.probeFocus(pid: front.processIdentifier)
        Self.noteProbe(pid: front.processIdentifier, verdict: probe.verdict,
                       note: probe.note, via: "/api/focus-probe（只读）")
        var result = Self.lastFocusProbe
        if let element = focusedElement(pid: front.processIdentifier) {
            func attribute(_ name: CFString) -> CFTypeRef? {
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
            }
            // 只给元数据：排查 AXValue 是否混入占位文案，不返回编辑正文。
            let value = attribute(kAXValueAttribute as CFString) as? String
            let placeholder = attribute(kAXPlaceholderValueAttribute as CFString) as? String
            result["valueUTF16"] = value?.utf16.count
            result["characterCount"] = attribute(kAXNumberOfCharactersAttribute as CFString) as? NSNumber
            result["valueIsPlaceholder"] = value != nil && placeholder != nil && value == placeholder
            if let snapshot = KeyboardDraftWriter.read(element) {
                result["selectionLocation"] = snapshot.location
                result["selectionLength"] = snapshot.length
            }
        }
        return result
    }

    private static func hasEditableFocus(pid: pid_t) -> Bool {
        Self.probeFocus(pid: pid).verdict == .editable
    }

    // 窗口里所有可输入元素（有界 BFS，最多 400 个节点）。
    private static func editableCandidates(pid: pid_t) -> [(element: AXUIElement, role: String)] {
        guard let window = focusedWindow(pid) else { return [] }
        var found: [(element: AXUIElement, role: String)] = []
        var level = [window]
        var visited = 0
        while !level.isEmpty, visited < 400 {
            var next: [AXUIElement] = []
            for element in level {
                visited += 1
                var roleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
                   let role = roleValue as? String, editableRoles.contains(role) {
                    found.append((element, role))
                }
                var childrenValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                   let children = childrenValue as? [AXUIElement] { next.append(contentsOf: children) }
            }
            level = next
        }
        return found
    }

    // 焦点探测的三态结论。之所以不能只有「有 / 没有」两态：探测不到不等于没有。
    // Electron / Chromium 常把聚焦元素报成 AXWebArea（页面容器）而不是真正的输入框，
    // 此时 CGEvent 照样会路由到 DOM 的 document.activeElement，内容确实进去了——
    // 把这种情况说成"没有聚焦的输入框"，就是每次发送都误报一次。
    // 取舍：误报会让人不再相信这条提示（进而忽略真正需要它的那一次），代价高于漏报。
    // 故只有拿到"聚焦的不是输入框"这个**正面证据**才提示，其余一律不打扰用户。
    enum FocusVerdict {
        case editable       // 聚焦元素明确是可输入控件：内容有去处
        case unknown        // 无从判定（探测失败 / 焦点停在容器上 / 认不出的角色）
        case notEditable    // 聚焦元素明确不是可输入控件：内容大概率没有去处
    }

    // 可输入角色：AX 里能接住键盘输入的元素。Chromium/Electron 把 <textarea> 与 contenteditable
    // 暴露成 AXTextArea，把 <input> 暴露成 AXTextField，搜索框是 AXSearchField。
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String,
        kAXComboBoxRole as String, "AXSearchField",
    ]

    // 「确定不是输入框」的角色。只有命中这些才敢说"内容没进去"。
    // 认不出的角色一律归 unknown——遇到新角色时宁可沉默，也不误伤。
    private static let nonInputRoles: Set<String> = [
        kAXButtonRole as String, kAXCheckBoxRole as String, kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String, kAXMenuItemRole as String, kAXMenuBarItemRole as String,
        kAXMenuBarRole as String, kAXMenuRole as String, kAXImageRole as String,
        kAXStaticTextRole as String, kAXSliderRole as String,
        kAXToolbarRole as String, kAXProgressIndicatorRole as String, kAXValueIndicatorRole as String,
        "AXLink",   // SDK 没导出 kAXLinkRole，只能用字面量（web 页面里的超链接）
    ]

    // 抢焦点的角色优先级：只认输入框，不碰下拉与搜索（理由见 ensureEditableFocus）。
    private static let focusPriority: [String] = [
        kAXTextAreaRole as String, kAXTextFieldRole as String,
    ]

    // 「应用在前台但里面没有聚焦输入框」这句人话：既说清现象，也给出一步可执行的补救。
    static func noFocusHint(_ appName: String) -> String {
        "\(appName)已在前台，但它没有聚焦的输入框，内容可能没进去——请先在电脑上点一下要输入的位置，再发送。"
    }

}
