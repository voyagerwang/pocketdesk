/**
 * [INPUT]: WorkBuddy 新任务准备的纯窗口、草稿与菜单策略；AX 元素仅作合成身份，不读取桌面。
 * [OUTPUT]: 验证主窗/独立窗宿主 URL、真实空值/占位/草稿/不可读与歧义、新菜单完整名称，以及新窗口必须新增且聚焦，已有独立窗不提供写入授权。
 * [POS]: 保留旧草稿后独立新建的无副作用回归；不启动应用、不保存用户草稿、不发正文或鼠标事件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

@main struct AgentNewTaskDraftTests {
    static func main() {
        var serial: pid_t = 900000
        func node(_ role: String, _ label: String = "", value: String? = nil, url: String? = nil,
                  visible: Bool = true, enabled: Bool = true, menu: Bool = false) -> AgentTaskComposer.Node {
            serial += 1
            return .init(element: AXUIElementCreateApplication(serial), role: role, label: label, value: value,
                placeholder: "", selected: false, enabled: enabled, pageURL: url, inMenu: menu, navigationVisible: visible)
        }
        let mainURL = "file:///Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/renderer/index.html"
        let primary = node("AXWebArea", url: mainURL)
        let independent = node("AXWebArea", url: mainURL + "?windowKind=conversation&windowId=window:conversation:one")
        assert(AgentWorkBuddyNewTask.windowKind([primary]) == .primary)
        assert(AgentWorkBuddyNewTask.windowKind([independent]) == .independent)
        assert(AgentWorkBuddyNewTask.windowKind([node("AXWebArea", url: mainURL + "?windowKind=settings")]) == .other)
        assert(AgentWorkBuddyNewTask.windowKind([primary, independent]) == .other, "混合宿主证据不归入单一窗口")
        assert(AgentWorkBuddyNewTask.windowKind([node("AXStaticText", url: mainURL)]) == .other, "正文链接不提供窗口身份")
        assert(AgentWorkBuddyNewTask.windowKind([node("AXWebArea", url: "https://example.com/index.html")]) == .other)
        assert(AgentWorkBuddyNewTask.windowKind([node("AXWebArea", url: "https://example.com/renderer/index.html?windowKind=conversation")]) == .other)
        assert(AgentWorkBuddyNewTask.windowKind([node("AXWebArea", url: "file:///private/tmp/WorkBuddy.app/Contents/Resources/app.asar.unpacked/renderer/index.html?windowKind=conversation")]) == .other)
        assert(AgentWorkBuddyNewTask.windowKind([primary], complete: false) == .other, "截断树不能证明唯一主窗身份")

        let welcome = node("AXHeading", "WorkBuddy, 我帮你")
        let blank = node("AXTextArea", value: "")
        let draft = node("AXTextArea", value: "保留这份尚未发送的草稿")
        assert(AgentWorkBuddyNewTask.homeState([welcome, blank]) == .empty)
        assert(AgentWorkBuddyNewTask.homeState([welcome, blank], complete: false) == .unreadable, "部分空框快照不能证明唯一空框")
        assert(AgentWorkBuddyNewTask.homeState([welcome]) == .unreadable, "欢迎页已出现但编辑器未就绪时不能降级为旧会话再点新建")
        assert(AgentWorkBuddyNewTask.homeState([welcome, node("AXTextArea", value: "\n﻿")]) == .empty)
        assert(AgentWorkBuddyNewTask.homeState([welcome, node("AXTextArea", value: "今天帮你做些什么？@添加上下文，/调用技能与指令")]) == .empty)
        assert(AgentWorkBuddyNewTask.homeState([welcome, draft]) == .draft, "主窗新页草稿应转原生独立窗而非清空")
        assert(AgentWorkBuddyNewTask.homeState([draft]) == .absent, "旧会话草稿不阻止先点击新建")
        assert(AgentWorkBuddyNewTask.homeState([welcome, node("AXTextArea")]) == .unreadable)
        assert(AgentWorkBuddyNewTask.homeState([welcome, blank, draft]) == .ambiguous)
        assert(AgentWorkBuddyNewTask.homeState([welcome, blank, node("AXTextArea", value: "隐藏草稿", visible: false)]) == .empty)
        assert(AgentWorkBuddyNewTask.homeState([node("AXHeading", "WorkBuddy, 我帮你", visible: false), blank]) == .absent)

        let menu = node("AXMenu")
        let open = node("AXMenuItem", "在独立窗口中打开", menu: true)
        assert(AgentWorkBuddyNewTask.independentMenuItems([menu, open]).count == 1)
        assert(AgentWorkBuddyNewTask.independentMenuItems([menu, node("AXMenuItem", "Open in a separate window", menu: true)]).count == 1)
        assert(AgentWorkBuddyNewTask.independentMenuItems([menu, open, node("AXMenuItem", "在独立窗口中打开", menu: true)]).count == 2)
        for invalid in [node("AXMenuItem", "在独立窗口中打开", enabled: false, menu: true),
                        node("AXMenuItem", "在独立窗口中打开", visible: false, menu: true),
                        node("AXMenuItem", "在独立窗口中打开"), node("AXMenuItem", "在独立窗口中打开设置", menu: true)] {
            assert(AgentWorkBuddyNewTask.independentMenuItems([menu, invalid]).isEmpty)
        }
        assert(AgentWorkBuddyNewTask.independentMenuItems([menu, node("AXMenu"), open]).isEmpty)

        let old = primary.element, previousIndependent = independent.element, created = blank.element, second = draft.element
        let before = [old, previousIndependent]
        assert(AgentWorkBuddyNewTask.newFocusedWindow(before: before, after: before + [created], focused: created) != nil)
        assert(AgentWorkBuddyNewTask.newFocusedWindow(before: before, after: before + [created, created], focused: created) != nil)
        assert(AgentWorkBuddyNewTask.newFocusedWindow(before: before, after: before, focused: previousIndependent) == nil,
            "已有独立窗可能有草稿，不能作为新派单落点")
        assert(AgentWorkBuddyNewTask.newFocusedWindow(before: before, after: before + [created], focused: old) == nil)
        assert(AgentWorkBuddyNewTask.newFocusedWindow(before: before, after: before + [created, second], focused: created) == nil)
        assert(AgentWorkBuddyNewTask.newFocusedWindow(before: before, after: before + [created], focused: nil) == nil)
        verifyPointerClick(button: nil, cancelAt: nil, expected: [.mouseMoved, .leftMouseDown, .leftMouseUp], success: true)
        verifyPointerClick(button: .right, cancelAt: nil, expected: [.mouseMoved, .rightMouseDown, .rightMouseUp], success: true)
        verifyPointerClick(button: .right, cancelAt: .rightMouseDown, expected: [.mouseMoved, .rightMouseDown, .rightMouseUp], success: true)
        verifyPointerClick(button: .right, cancelAt: .mouseMoved, expected: [.mouseMoved], success: false)
        print("PASS WorkBuddy native new-task draft preservation policies")
    }

    /// 注入事件接收器验证实际队列，事件只留在内存；取消发生在按下后仍必须释放同一右键。
    private static func verifyPointerClick(button: CGMouseButton?, cancelAt: CGEventType?, expected: [CGEventType], success: Bool) {
        let semaphore = DispatchSemaphore(value: 0)
        let marker: Int64 = 424242
        var allowed = true, completed = false
        var events: [CGEventType] = []
        let executor = PointerExecutor(postEvent: { event in
            events.append(event.type)
            assert(event.getIntegerValueField(.eventSourceUserData) == marker)
            if event.type != .mouseMoved {
                assert(event.getIntegerValueField(.mouseEventButtonNumber) == Int64((button ?? .left).rawValue))
                assert(event.getIntegerValueField(.mouseEventClickState) == 1)
            }
            if event.type == cancelAt { allowed = false }
        }, clickEnvironment: { true })
        let done: (Bool) -> Void = { result in completed = result; semaphore.signal() }
        if let button { executor.click(at: CGPoint(x: 1, y: 1), authorized: { allowed }, marker: marker, button: button, completion: done) }
        else { executor.click(at: CGPoint(x: 1, y: 1), authorized: { allowed }, marker: marker, completion: done) }
        assert(semaphore.wait(timeout: .now() + 3) == .success, "指针替身队列应有界完成")
        assert(completed == success && events == expected)
    }
}
