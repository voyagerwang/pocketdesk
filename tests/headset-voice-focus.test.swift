/**
 * [INPUT]: 真实 HeadsetVoiceFocus 状态机与 Driver；不可达 PID 创建的 AX 句柄仅作内存身份，窗口、控件、鼠标、时间与聚焦结果全部注入。
 * [OUTPUT]: 验证非输入焦点自动定位、未知应用唯一编辑器、候选歧义/不可读分支拒绝、冷树准备、原应用/窗口及迟到回调隔离；系统焦点缺值补证不覆盖明确反证。
 * [POS]: tests 的共享耳机定位隔离回归；不读取真实应用、不启动 NSApplication、不激活窗口、不点击、不发送 Option 或其他系统事件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

private final class VoiceFocusFixture {
    typealias Node = HeadsetVoiceFocus.Node
    let pid: pid_t = 910_001
    let request = HeadsetVoiceFocusRequest(pid: 910_001)
    private let lock = NSRecursiveLock()
    private var handles: [String: AXUIElement] = [:]
    var nodes: [String: Node] = [:]
    var branches: [String: [String]] = [:]
    var unavailableNodes: Set<String> = []
    var unavailableBranches: Set<String> = []
    var outsideWindow: Set<String> = []
    var clock: TimeInterval = 10
    var currentPID: pid_t? = 910_001
    var windowName: String? = "window"
    var focusName: String? = "body"
    var cursor = CGPoint(x: 10, y: 10)
    var unlocked = true
    var trusted = true
    var supported = false
    var text = "保留原文🙂e\u{301}"
    var axFocusAccepted = true
    var provideClick = true
    var clickPointAvailable = true
    var focusAttempts: [String] = []
    var focusChanges: [String] = []
    var clicks = 0
    var warmCalls = 0
    var completions = 0
    var diagnostic: HeadsetVoiceFocus.Diagnostic?
    var onChildren: ((VoiceFocusFixture, String) -> Void)?
    var onNode: ((VoiceFocusFixture, String) -> Void)?
    var onFocusedPID: ((VoiceFocusFixture) -> Void)?
    var onWarm: ((VoiceFocusFixture) -> Void)?
    var afterFocus: ((VoiceFocusFixture) -> Void)?
    var beforeClick: ((VoiceFocusFixture) -> Void)?
    var onDiagnostic: ((VoiceFocusFixture) -> Void)?
    var targeted: HeadsetVoiceFocus.TargetedResult?

    init() {
        add("window", Node(role: "AXWindow"))
        add("body", Node(role: "AXGroup"))
        add("editor", Self.editor())
        add("field", Self.editor("AXTextField"))
        add("other-window", Node(role: "AXWindow"))
        branches["window"] = ["body", "editor"]
        branches["body"] = []
    }
    static func editor(_ role: String = "AXTextArea") -> Node {
        var value = Node(role: role)
        value.editable = true
        return value
    }
    func locked<T>(_ operation: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return operation()
    }
    func add(_ name: String, _ node: Node) {
        // AXUIElementCreateApplication 不读取该进程；这些不存在的 PID 只提供互异的 opaque 身份。
        if handles[name] == nil { handles[name] = AXUIElementCreateApplication(pid + pid_t(handles.count + 1)) }
        nodes[name] = node
    }
    func element(_ name: String) -> AXUIElement { handles[name]! }
    func name(_ element: AXUIElement) -> String? {
        handles.first { CFEqual($0.value, element) }?.key
    }
    func driver() -> HeadsetVoiceFocus.Driver {
        var driver = HeadsetVoiceFocus.Driver(
            now: { self.locked { self.clock } },
            sleep: { delay in self.locked { self.clock += delay } },
            unlocked: { self.locked { self.unlocked } },
            trusted: { self.locked { self.trusted } },
            focusedPID: { self.locked { self.onFocusedPID?(self); return self.currentPID } },
            window: { pid in self.locked { pid == self.pid ? self.windowName.map(self.element) : nil } },
            focus: { pid in self.locked { pid == self.pid ? self.focusName.map(self.element) : nil } },
            node: { element, _ in self.locked {
                guard let name = self.name(element) else { return nil }
                self.onNode?(self, name)
                return self.unavailableNodes.contains(name) ? nil : self.nodes[name]
            } },
            children: { element in self.locked {
                guard let name = self.name(element) else { return nil }
                self.onChildren?(self, name)
                guard !self.unavailableBranches.contains(name), let names = self.branches[name] else { return nil }
                return names.map(self.element)
            } },
            belongs: { element, window, pid in self.locked {
                pid == self.pid && self.name(window) == "window" &&
                    self.name(element).map { !self.outsideWindow.contains($0) } == true
            } },
            equal: { CFEqual($0, $1) },
            supportedTextField: { _ in self.locked { self.supported } },
            text: { _ in self.locked { self.text } },
            setFocus: { element in self.locked {
                guard let name = self.name(element) else { return false }
                self.focusAttempts.append(name)
                guard self.axFocusAccepted else { return false }
                self.focusName = name; self.focusChanges.append(name)
                self.afterFocus?(self)
                return true
            } },
            mouse: { self.locked { self.cursor } },
            clickPoint: { _, _, _ in self.locked { self.clickPointAvailable ? CGPoint(x: 100, y: 100) : nil } },
            click: nil,
            warmAccessibility: { _, allowed, _ in self.locked {
                guard allowed() else { return }
                self.warmCalls += 1; self.onWarm?(self)
            } },
            diagnostic: { diagnostic in self.locked {
                self.diagnostic = diagnostic; self.onDiagnostic?(self)
            } })
        if provideClick {
            driver.click = { point, allowed, done in
                let clicked = self.locked { () -> Bool in
                    self.beforeClick?(self)
                    guard allowed() else { return false }
                    self.cursor = point
                    guard allowed() else { return false }
                    self.clicks += 1; self.focusName = "editor"
                    return true
                }
                done(clicked)
            }
        }
        if targeted != nil {
            driver.targetedLocator = { _, _, allowed, _ in self.locked {
                guard allowed() else { return .init(candidates: [], complete: false, reason: "targeted-state-changed") }
                return self.targeted!
            } }
        }
        return driver
    }
    func prepare() async -> Result<HeadsetVoiceFocus.Prepared, HeadsetVoiceFocusFailure> {
        await withCheckedContinuation { continuation in
            HeadsetVoiceFocus.prepare(request: request, driver: driver()) { result in
                self.locked { self.completions += 1 }
                continuation.resume(returning: result)
            }
        }
    }
}

@main struct HeadsetVoiceFocusTests {
    static func main() async {
        var checks = 0
        func success(_ fixture: VoiceFocusFixture, target: String = "editor", _ message: String) async {
            let original = fixture.text
            switch await fixture.prepare() {
            case .success(let prepared):
                assert(prepared.pid == fixture.pid && CFEqual(prepared.element, fixture.element(target)), message)
                assert(prepared.original == original && fixture.text == original, "定位保留完整 Unicode 原文")
            case .failure(let failure): fatalError(message + ": " + failure.message + " [" + failure.reason + "]")
            }
            assert(fixture.completions == 1, "只完成一次准备")
            checks += 1
        }
        func failure(_ fixture: VoiceFocusFixture, reason: String? = nil, noActions: Bool = true, _ message: String) async {
            switch await fixture.prepare() {
            case .success: fatalError(message + ": 不应返回已准备")
            case .failure(let failure):
                if let reason { assert(failure.reason == reason, message + ": " + failure.reason) }
            }
            if noActions { assert(fixture.focusAttempts.isEmpty && fixture.clicks == 0, message + ": 不应改焦点或点击") }
            assert(fixture.completions == 1 && !fixture.request.active, "失败退休请求且只回调一次")
            checks += 1
        }

        let body = VoiceFocusFixture()
        body.nodes["body"]?.readOnly = true
        await success(body, "只读非输入正文不阻断唯一主编辑器定位")
        assert(body.focusChanges == ["editor"] && body.clicks == 0, "AX 聚焦成功无需点击")

        let readOnlyText = VoiceFocusFixture()
        readOnlyText.nodes["body"] = VoiceFocusFixture.editor()
        readOnlyText.nodes["body"]?.readOnly = true
        await success(readOnlyText, "只读文本域不是候选，但其兄弟普通编辑器仍可定位")

        let container = VoiceFocusFixture()
        container.nodes["body"] = .init(role: "AXWebArea")
        container.nodes["body"]?.readOnly = true
        container.branches["window"] = ["body"]; container.branches["body"] = ["editor"]
        await success(container, "只读容器下的普通编辑器仍被完整检查")

        let existing = VoiceFocusFixture()
        existing.focusName = "editor"
        await success(existing, "已有普通编辑焦点不重新定位")
        assert(existing.focusAttempts.isEmpty && existing.clicks == 0)

        let field = VoiceFocusFixture()
        field.branches["window"] = ["body", "field"]
        await success(field, target: "field", "未知应用的唯一普通 TextField 可以定位")

        let mixed = VoiceFocusFixture()
        mixed.branches["window"] = ["body", "editor", "field"]
        await failure(mixed, reason: "scan-ambiguous", "TextArea 与 TextField 同时存在不靠角色偏好猜测")

        let ambiguous = VoiceFocusFixture()
        ambiguous.add("second", VoiceFocusFixture.editor())
        ambiguous.branches["window"] = ["editor", "second"]
        await failure(ambiguous, reason: "scan-ambiguous", "多个普通编辑器拒绝自动选择")

        let excluded = VoiceFocusFixture()
        excluded.add("search", .init(role: "AXSearchField"))
        excluded.add("password", .init(role: "AXTextField", subrole: kAXSecureTextFieldSubrole, editable: true))
        excluded.add("disabled", .init(role: "AXTextField", enabled: false, editable: true))
        excluded.add("hidden", .init(role: "AXTextField", visible: false, editable: true))
        excluded.branches["window"] = ["search", "password", "disabled", "hidden", "editor"]
        await success(excluded, "搜索/密码/隐藏/禁用控件不参与候选")

        let password = VoiceFocusFixture()
        password.nodes["body"] = .init(role: "AXTextField", subrole: kAXSecureTextFieldSubrole, editable: true)
        await failure(password, reason: "secure-focus", "当前密码焦点禁止自动移交")

        let noCandidate = VoiceFocusFixture()
        noCandidate.branches["window"] = ["body"]
        await failure(noCandidate, reason: "scan-no-editor", "完整空候选不猜坐标")

        let unreadable = VoiceFocusFixture()
        unreadable.add("unknown", .init(role: "AXGroup"))
        unreadable.branches["window"] = ["editor", "unknown"]
        unreadable.unavailableBranches.insert("unknown")
        await failure(unreadable, reason: "scan-children-unavailable", "发现编辑器后仍需检查剩余不可读分支")

        let unreadableNode = VoiceFocusFixture()
        unreadableNode.unavailableNodes.insert("body")
        await failure(unreadableNode, reason: "scan-node-unavailable", "不可读控件不能被忽略以宣称唯一")

        let outside = VoiceFocusFixture()
        outside.outsideWindow.insert("editor")
        await failure(outside, reason: "scan-editor-outside-window", "编辑器必须属于原聚焦窗口")

        let cold = VoiceFocusFixture()
        cold.windowName = nil; cold.focusName = nil
        cold.onWarm = { $0.windowName = "window"; $0.focusName = "body" }
        await success(cold, "冷 AX 树只在仍授权时准备并重新读取原窗口")
        assert(cold.warmCalls == 1)

        let cancelledCold = VoiceFocusFixture()
        cancelledCold.focusName = nil
        cancelledCold.onWarm = { $0.request.cancel() }
        await failure(cancelledCold, "冷树准备期间取消，不触发聚焦")

        let locked = VoiceFocusFixture()
        locked.unlocked = false
        await failure(locked, "锁屏不读取目标或聚焦")
        let untrusted = VoiceFocusFixture()
        untrusted.trusted = false
        await failure(untrusted, "权限不足不聚焦")

        let switchedApp = VoiceFocusFixture()
        switchedApp.onChildren = { fixture, _ in fixture.currentPID = 920_001 }
        await failure(switchedApp, reason: "scan-state-changed", "候选检查期间切应用取消准备")

        let switchedWindow = VoiceFocusFixture()
        switchedWindow.onChildren = { fixture, _ in fixture.windowName = "other-window" }
        await failure(switchedWindow, reason: "scan-state-changed", "同应用切窗口同样取消准备")

        let movedMouse = VoiceFocusFixture()
        movedMouse.onChildren = { fixture, _ in fixture.cursor = CGPoint(x: 50, y: 50) }
        await failure(movedMouse, "用户鼠标活动使自动聚焦失效")

        let click = VoiceFocusFixture()
        click.axFocusAccepted = false
        await success(click, "AX 拒绝时由授权点击替身聚焦并精确读回")
        assert(click.focusAttempts == ["editor"] && click.clicks == 1)

        let clickChangedApp = VoiceFocusFixture()
        clickChangedApp.axFocusAccepted = false
        clickChangedApp.beforeClick = { $0.currentPID = 920_001 }
        await failure(clickChangedApp, noActions: false, "点击执行前切应用，授权拒绝且不返回准备成功")
        assert(clickChangedApp.clicks == 0 && clickChangedApp.focusChanges.isEmpty)

        let afterFocus = VoiceFocusFixture()
        afterFocus.afterFocus = { $0.windowName = "other-window" }
        await failure(afterFocus, noActions: false, "聚焦后窗口变化不能成为准备成功")
        assert(afterFocus.clicks == 0)

        let beforeCompletion = VoiceFocusFixture()
        beforeCompletion.onFocusedPID = { fixture in
            if Thread.isMainThread && !fixture.focusChanges.isEmpty { fixture.currentPID = 920_001 }
        }
        await failure(beforeCompletion, reason: "completion-state-changed", noActions: false,
                      "已在后台准备成功但返回主线程时失焦，不能向调用方交付成功")

        let expired = VoiceFocusFixture()
        expired.onChildren = { fixture, _ in fixture.clock += 2 }
        await failure(expired, reason: "request-deadline", "扫描过期不允许迟到聚焦")

        let targeted = VoiceFocusFixture()
        targeted.supported = true
        targeted.targeted = .init(candidates: [targeted.element("editor")], complete: true)
        targeted.branches["window"] = ["editor", "field"]
        await success(targeted, "已核验应用主输入区可明确选中其编辑器")

        let incompleteRegion = VoiceFocusFixture()
        incompleteRegion.supported = true
        incompleteRegion.targeted = .init(candidates: [incompleteRegion.element("editor")], complete: false, reason: "targeted-ancestor-unverified")
        await failure(incompleteRegion, reason: "targeted-ancestor-unverified", "主输入区证据不完整不降级为猜测")

        // ---------- 系统焦点缺值与明确反证 ----------
        let identity = VoiceFocusFixture()
        var applicationReads = 0
        func resolve(_ status: AXError, _ element: AXUIElement?, _ owner: pid_t?, localOwner: pid_t = 910_001) -> AXUIElement? {
            HeadsetVoiceFocus.resolveFocusedElement(pid: identity.pid, systemStatus: status, systemElement: element, systemOwner: owner) {
                applicationReads += 1
                return (identity.element("editor"), localOwner)
            }
        }
        assert(CFEqual(resolve(.success, identity.element("body"), identity.pid)!, identity.element("body")))
        assert(applicationReads == 0, "系统成功不读取应用级旧焦点")
        assert(resolve(.success, identity.element("body"), 920_001) == nil && applicationReads == 0)
        assert(resolve(.success, identity.element("body"), nil) == nil && applicationReads == 0)
        assert(resolve(.success, nil, identity.pid) == nil && applicationReads == 0)
        for status in [AXError.noValue, .cannotComplete] {
            assert(CFEqual(resolve(status, nil, nil)!, identity.element("editor")))
            assert(resolve(status, nil, nil, localOwner: 920_001) == nil)
        }
        for status in [AXError.apiDisabled, .attributeUnsupported, .invalidUIElement, .failure] {
            let count = applicationReads
            assert(resolve(status, nil, nil) == nil && applicationReads == count)
        }
        checks += 12
        // ---------- 耳机作用域应用归属补证 ----------
        func owner(_ status: AXError, axPID: pid_t? = nil, active: [pid_t] = [22], immediate: pid_t? = 22,
                   trusted: Bool = true, secure: Bool = false, uiStatus: AXError = .noValue,
                   uiOwner: pid_t? = nil, expected: pid_t?, source: HeadsetVoiceFocus.ApplicationOwner.Source) {
            let result = HeadsetVoiceFocus.resolveApplicationOwner(axStatus: status, axPID: axPID, activePIDs: active,
                immediatePID: immediate, trusted: trusted, secureInput: secure, systemUIStatus: uiStatus, systemUIOwner: uiOwner)
            assert(result.pid == expected && result.source == source && result.axStatus == status,
                   "耳机归属必须保留 AX 状态、权限与互不冲突的 PID 证据")
            checks += 1
        }
        owner(.success, axPID: 11, active: [22, 33], immediate: nil, uiStatus: .failure, expected: 11, source: .accessibility)
        owner(.success, expected: nil, source: .unavailable)
        owner(.success, axPID: 0, expected: nil, source: .unavailable)
        for status in [AXError.noValue, .cannotComplete] {
            owner(status, expected: 22, source: .activeApplication)
            owner(status, uiStatus: .success, uiOwner: 22, expected: 22, source: .activeApplication)
            owner(status, uiStatus: .cannotComplete, expected: 22, source: .activeApplication)
            owner(status, active: [], expected: nil, source: .unavailable)
            owner(status, active: [22, 33], expected: nil, source: .unavailable)
            owner(status, active: [22, 22], expected: nil, source: .unavailable)
            owner(status, immediate: 33, expected: nil, source: .unavailable)
            owner(status, immediate: nil, expected: nil, source: .unavailable)
            owner(status, active: [0], immediate: 0, expected: nil, source: .unavailable)
            owner(status, trusted: false, expected: nil, source: .unavailable)
            owner(status, secure: true, expected: nil, source: .unavailable)
            owner(status, uiStatus: .success, uiOwner: 33, expected: nil, source: .unavailable)
            owner(status, uiStatus: .success, expected: nil, source: .unavailable)
            owner(status, uiStatus: .success, uiOwner: 0, expected: nil, source: .unavailable)
            owner(status, uiStatus: .apiDisabled, expected: nil, source: .unavailable)
            owner(status, uiStatus: .attributeUnsupported, expected: nil, source: .unavailable)
            owner(status, uiStatus: .failure, expected: nil, source: .unavailable)
        }
        for status in [AXError.apiDisabled, .attributeUnsupported, .invalidUIElement, .illegalArgument, .failure] {
            owner(status, expected: nil, source: .unavailable)
        }
        try? await Task.sleep(nanoseconds: 1_350_000_000)
        assert(body.completions == 1 && unreadable.completions == 1 && beforeCompletion.completions == 1,
               "截止时间回调迟到也不重复成功/失败或改变新状态")
        print("PASS headset voice focus: \(checks) isolated cases; unique editors, complete scans, cold AX, focus/cancellation guards; no live app reads or input")
    }
}
