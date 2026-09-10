/**
 * [INPUT]: 依赖 Util 前台应用观测及 InputFocus 应用/系统级焦点元素，不遍历或移动焦点。
 * [OUTPUT]: 提供 InputBinding 的短期上下文令牌、完整写入前校验、当前页面点击范围与附件粘贴期间的目标进程校验；Chromium AX 对象变化时以当前聚焦窗口的 WebArea 重新核验。
 * [POS]: Sources 的全屏输入目标边界；HTTP 建立上下文，InputExecutor 每次写入前验证。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

final class InputBinding {
    static let shared = InputBinding()
    private let lock = NSLock()
    private struct Binding {
        let token: String
        let pid: pid_t
        let element: AXUIElement?
        let clickScope: AXUIElement?
        var touched: Double
    }
    private var binding: Binding?
    private func focused(_ pid: pid_t) -> AXUIElement? {
        InputFocus.focusedElement(pid: pid)
    }
    func establish() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let app = Util.frontmostApp() else { return ["error": "无法确定前台应用，请先点击电脑输入框。"] }
        let pid = app.processIdentifier
        let observedFocus = focused(pid)
        let clickScope = InputFocus.normalizedClickScope(observedFocus, pid: pid)
        var element = observedFocus
        let verdict = InputFocus.probeFocus(pid: pid).verdict
        if verdict == .notEditable { return ["error": "请先点击电脑上的输入框。"] }
        // 容器或不支持 AX 的编辑器只能绑定应用，不声称识别到了具体输入框。
        if verdict == .unknown { element = nil }
        var response: [String: Any] = ["context": "", "name": app.localizedName ?? "当前应用", "scope": element == nil ? "application" : "element"]
        if let element,
           let snapshot = KeyboardDraftWriter.read(element),
           !snapshot.text.isEmpty {
            response["text"] = snapshot.text
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let old = binding, old.pid == pid, same(old.element, element),
           same(old.clickScope, clickScope), now - old.touched < 600 {
            binding?.touched = now
        } else {
            binding = Binding(token: UUID().uuidString, pid: pid, element: element,
                clickScope: clickScope, touched: now)
        }
        response["context"] = binding!.token
        return response
    }
    private func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        if let a, let b { return CFEqual(a, b) }
        return a == nil && b == nil
    }
    func validate(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let b = binding, b.token == token, ProcessInfo.processInfo.systemUptime - b.touched < 600,
              Util.frontmostApp()?.processIdentifier == b.pid else { return false }
        if let element = b.element { guard let current = focused(b.pid), CFEqual(element, current) else { return false } }
        binding?.touched = ProcessInfo.processInfo.systemUptime
        return true
    }

    // 图片粘贴后 Chromium 可能短暂把焦点暴露为附件/WebArea。中间点击前只允许放宽
    // “同一聚焦元素”这一项，令牌、时效、目标进程仍必须成立；点击后调用方恢复完整 validate。
    func validateOwner(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let b = binding, b.token == token, ProcessInfo.processInfo.systemUptime - b.touched < 600,
              Util.frontmostApp()?.processIdentifier == b.pid else { return false }
        binding?.touched = ProcessInfo.processInfo.systemUptime
        return true
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
