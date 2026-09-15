/**
 * [INPUT]: 依赖 Util 前台应用观测及 InputFocus 应用/系统级焦点元素，不遍历或移动焦点。
 * [OUTPUT]: 提供 InputBinding 的短期上下文令牌、完整写入前校验、当前页面点击范围、附件粘贴期间的目标进程校验、
 *           不可伪造的绑定身份与只读快照（原 PID、元素/页面范围、最后确认文本边界）、以及最近一次校验失败的原因；
 *           Chromium AX 对象变化时以当前聚焦窗口的 WebArea 重新核验；另为图片直发提供应用级兜底绑定 establishRelaxed（白板/画布无输入框目标，validate 届时只核验前台进程）。
 * [POS]: Sources 的全屏输入目标边界；HTTP 建立上下文，InputExecutor 每次写入前验证并据失效原因分级草稿状态。
 * [PROTOCOL]: validate 在切应用/编辑器重建导致 AX 元素失效时自愈（沿用原令牌更新元素引用，避免可恢复中断误判 needs-user-focus）；establish/establishRelaxed 的绑定进程跟随键盘焦点归属（focusedApplicationPID），读不出焦点才退回窗口层序——半激活态下按层序绑会绑错应用；变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

final class InputBinding {
    static let shared = InputBinding()
    private let lock = NSLock()
    private struct Binding {
        let token: String
        let pid: pid_t
        var element: AXUIElement?
        let clickScope: AXUIElement?
        var touched: Double
        // 最后确认的电脑文本边界：恢复协议据此判断"电脑内容是否仍等于最后确认状态"。
        var confirmedText: String
        var confirmedLocation: Int
        var confirmedLength: Int
    }
    private var binding: Binding?
    /// 最近一次 validate 失败的原因（不含用户正文），供草稿状态分级与控制台诊断。
    private(set) var lastInvalidReason = ""

    private func focused(_ pid: pid_t) -> AXUIElement? {
        InputFocus.focusedElement(pid: pid)
    }

    /// 绑定目标进程：键盘焦点归属的应用优先（键入会落到谁就绑谁），读不出焦点才退回
    /// 窗口层序的最上层应用。后台 agent 激活 Electron 应用的半激活态（窗口在最上、活跃
    /// 应用是别人）下按层序绑会把 A 应用的元素当靶子、键却打进了 B 应用。
    private static func bindingTargetApp() -> NSRunningApplication? {
        if let focusPID = InputFocus.focusedApplicationPID() {
            return NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == focusPID })
        }
        return Util.frontmostApp()
    }

    func establish() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let app = Self.bindingTargetApp() else { return ["error": "无法确定前台应用，请先点击电脑输入框。"] }
        let pid = app.processIdentifier
        let observedFocus = focused(pid)
        let clickScope = InputFocus.normalizedClickScope(observedFocus, pid: pid)
        var element = observedFocus
        let verdict = InputFocus.probeFocus(pid: pid).verdict
        if verdict == .notEditable { return ["error": "请先点击电脑上的输入框。"] }
        // 容器或不支持 AX 的编辑器只能绑定应用，不声称识别到了具体输入框。
        if verdict == .unknown { element = nil }
        var confirmed = DraftSnapshot.end(of: "")
        var response: [String: Any] = ["context": "", "name": app.localizedName ?? "当前应用", "scope": element == nil ? "application" : "element"]
        if let element,
           let snapshot = KeyboardDraftWriter.read(element) {
            confirmed = snapshot
            if !snapshot.text.isEmpty { response["text"] = snapshot.text }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let old = binding, old.pid == pid, same(old.element, element),
           same(old.clickScope, clickScope), now - old.touched < 600 {
            binding?.touched = now
        } else {
            binding = Binding(token: UUID().uuidString, pid: pid, element: element,
                clickScope: clickScope, touched: now,
                confirmedText: confirmed.text, confirmedLocation: confirmed.location, confirmedLength: confirmed.length)
        }
        response["context"] = binding!.token
        lastInvalidReason = ""
        return response
    }

    /// 图片直发的兜底绑定：目标没有可编辑元素可认（白板画布、AX 把画布报成"不是输入框"）时，
    /// 常规 establish 会直接报错。粘贴只要求前台应用正确、不要求焦点在输入框，故退化为
    /// 应用级绑定（element=nil，validate 因此只核验前台进程）。只允许图片提交走这条路——
    /// 文字必须有可核验的编辑位置，画布上的 Cmd+V 不需要。
    func establishRelaxed() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let app = Self.bindingTargetApp() else { return ["error": "无法确定前台应用，请先点击电脑输入框。"] }
        let pid = app.processIdentifier
        let clickScope = InputFocus.normalizedClickScope(focused(pid), pid: pid)
        let now = ProcessInfo.processInfo.systemUptime
        if let old = binding, old.pid == pid, old.element == nil, same(old.clickScope, clickScope),
           now - old.touched < 600 {
            binding?.touched = now
        } else {
            binding = Binding(token: UUID().uuidString, pid: pid, element: nil,
                clickScope: clickScope, touched: now,
                confirmedText: "", confirmedLocation: 0, confirmedLength: 0)
        }
        lastInvalidReason = ""
        return ["context": binding!.token, "name": app.localizedName ?? "当前应用", "scope": "application"]
    }

    private func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        if let a, let b { return CFEqual(a, b) }
        return a == nil && b == nil
    }

    func validate(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var b = binding, b.token == token else { lastInvalidReason = "绑定令牌已失效（会话已重建）"; return false }
        guard ProcessInfo.processInfo.systemUptime - b.touched < 600 else { lastInvalidReason = "绑定已过期"; return false }
        guard Util.frontmostApp()?.processIdentifier == b.pid else { lastInvalidReason = "目标应用已不在前台"; return false }
        if let element = b.element {
            // 正常路径：原 AX 元素对象仍指向同一输入框。
            if let current = focused(b.pid), CFEqual(element, current) {
                b.touched = ProcessInfo.processInfo.systemUptime; binding = b; lastInvalidReason = ""; return true
            }
            // 自愈：切应用/编辑器重建会让同一输入框的 AX 元素对象换新（CFEqual 失败），
            // 但目标进程仍在前台且当前焦点是可编辑文本元素——这恰恰是原输入位置重新出现。
            // 仅更新元素引用、沿用原令牌，避免把可恢复的中断误判成 needs-user-focus 永久冻结。
            if let current = focused(b.pid), KeyboardDraftWriter.read(current) != nil {
                b.element = current
                b.touched = ProcessInfo.processInfo.systemUptime
                binding = b
                lastInvalidReason = ""
                return true
            }
            lastInvalidReason = "原编辑元素已变化（可能被重建）"
            return false
        }
        b.touched = ProcessInfo.processInfo.systemUptime; binding = b; lastInvalidReason = ""; return true
    }

    // 图片粘贴后 Chromium 可能短暂把焦点暴露为附件/WebArea。中间点击前只允许放宽
    // “同一聚焦元素”这一项，令牌、时效、目标进程仍必须成立；点击后调用方恢复完整 validate。
    func validateOwner(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let b = binding, b.token == token else { lastInvalidReason = "绑定令牌已失效（会话已重建）"; return false }
        guard ProcessInfo.processInfo.systemUptime - b.touched < 600 else { lastInvalidReason = "绑定已过期"; return false }
        guard Util.frontmostApp()?.processIdentifier == b.pid else { lastInvalidReason = "目标应用已不在前台"; return false }
        binding?.touched = ProcessInfo.processInfo.systemUptime
        lastInvalidReason = ""
        return true
    }

    /// 写入成功后再记一次"最后确认状态"。恢复探测靠它判断电脑内容是否被外部改动过。
    func recordConfirmed(_ token: String, text: String) {
        lock.lock(); defer { lock.unlock() }
        guard var b = binding, b.token == token else { return }
        b.confirmedText = text
        b.confirmedLocation = text.utf16.count
        b.confirmedLength = 0
        b.touched = ProcessInfo.processInfo.systemUptime
        binding = b
    }

    /// 只读快照：不触碰焦点、不改令牌时效。原 PID、元素是否有身份、最后确认文本边界都在这里。
    func snapshot(forToken token: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let b = binding, b.token == token else { return nil }
        return [
            "pid": Int(b.pid),
            "scope": b.element == nil ? "application" : "element",
            "hasClickScope": b.clickScope != nil,
            "confirmedLength": b.confirmedText.utf16.count,
            "confirmedLocation": b.confirmedLocation,
            "confirmedSelection": b.confirmedLength,
        ]
    }

    func captureClickAnchor(_ token: String, point: CGPoint) -> InputFocus.EditableAnchor? {
        lock.lock(); defer { lock.unlock() }
        guard let b = binding, b.token == token, ProcessInfo.processInfo.systemUptime - b.touched < 600,
              Util.frontmostApp()?.processIdentifier == b.pid else { return nil }
        let anchor = b.clickScope.flatMap { InputFocus.captureBoundAnchor(pid: b.pid, point: point, scope: $0) }
            ?? InputFocus.captureCurrentWebAnchor(pid: b.pid, point: point)
        guard let anchor else { return nil }
        binding?.touched = ProcessInfo.processInfo.systemUptime
        return anchor
    }
}
