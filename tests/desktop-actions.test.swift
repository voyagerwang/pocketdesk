/**
 * [INPUT]: 桌面请求解析、菜单语义目录、AX 元素替身与纯窗口几何函数。
 * [OUTPUT]: 常用操作跨参数拒绝、菜单禁用/重名隔离、窗口标识稳定及多屏布局回归。
 * [POS]: 无桌面副作用的动作边界测试；不点击菜单、不移动窗口、不读写真实剪贴板。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

@main struct DesktopActionsTests {
    static func main() {
        func parse(_ json: String) -> DesktopActionRequest? { DesktopActionRequest.parse(json) }
        assert(parse(#"{"action":"menu_action","command":"refresh"}"#) != nil)
        assert(parse(#"{"action":"menu_action","command":"shell"}"#) == nil)
        assert(parse(#"{"action":"menu_action"}"#) == nil)
        assert(parse(#"{"action":"menu_action","command":"refresh","position":"left"}"#) == nil)
        assert(parse(#"{"action":"list_actions","command":"copy"}"#) == nil)
        assert(parse(#"{"action":"arrange_window","position":"left","display":0}"#) == nil)
        assert(parse(#"{"action":"arrange_window","position":"left","display":1.5}"#) == nil)
        assert(parse(#"{"action":"arrange_window","position":"left","display":2,"window":"exact"}"#) != nil)
        assert(parse(#"{"action":"arrange_window","position":"unknown"}"#) == nil)
        assert(parse(#"{"action":"menu_action","command":"copy","menuPath":[]}"#) == nil)
        assert(parse(#"{"action":"menu_action","command":"copy","hotkey":"Cmd+Q"}"#) == nil)
        assert(parse(#"{"action":"list_actions"}"#)?.isReadOnly == true)
        assert(parse(#"{"action":"list_windows"}"#)?.isReadOnly == true)
        assert(parse(#"{"action":"menu_action","command":"copy"}"#)?.isReadOnly == false)
        let first = parse(#"{"action":"menu_action","command":"copy","app":"Chrome"}"#)!
        let reordered = parse(#"{"app":"Chrome","command":"copy","action":"menu_action"}"#)!
        assert(first.reservation == reordered.reservation)
        let element = AXUIElementCreateApplication(12345)
        let id = AgentDesktopActions.windowID(element, pid: 12345)
        assert(id == AgentDesktopActions.windowID(AXUIElementCreateApplication(12345), pid: 12345))
        assert(id != AgentDesktopActions.windowID(AXUIElementCreateApplication(54321), pid: 54321))
        let copy = DesktopMenuActions.commands.first { $0.id == "copy" }!
        let entries = [DesktopMenuActions.Entry(element: element, path: ["编辑", "复制"], enabled: true),
                       DesktopMenuActions.Entry(element: element, path: ["别处", "复制"], enabled: true),
                       DesktopMenuActions.Entry(element: element, path: ["禁用", "复制"], enabled: false)]
        assert(DesktopMenuActions.candidates(copy, entries: entries).count == 2)
        assert(DesktopMenuActions.candidates(copy, entries: entries, path: ["编辑", "复制"]).count == 1)
        assert(DesktopMenuActions.candidates(copy, entries: entries, path: ["禁用", "复制"]).isEmpty)
        assert(DesktopMenuActions.candidates(copy, entries: entries, path: ["假菜单", "复制"]).isEmpty)
        assert(!DesktopMenuActions.matches("复制文件到云端", command: copy))
        let saveAs = DesktopMenuActions.commands.first { $0.id == "save_as" }!
        assert(DesktopMenuActions.matches("Save As…", command: saveAs))
        let visible = CGRect(x: -1920, y: -800, width: 1920, height: 1080)
        let current = CGRect(x: 50, y: 60, width: 2500, height: 1400)
        let left = DesktopWindowLayout.frame(position: .left, visible: visible, current: current)
        let right = DesktopWindowLayout.frame(position: .right, visible: visible, current: current)
        assert(left.minX == visible.minX && right.maxX == visible.maxX && left.maxX == right.minX)
        assert(left.minY == -800 && left.height == 1080)
        assert(DesktopWindowLayout.frame(position: .maximize, visible: visible, current: current) == visible)
        assert(DesktopWindowLayout.frame(position: .center, visible: visible, current: current) == visible)
        for position in [DesktopWindowLayout.Position.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let rect = DesktopWindowLayout.frame(position: position, visible: visible, current: current)
            assert(visible.contains(rect) && rect.width == 960 && rect.height == 540)
        }
        assert(DesktopWindowLayout.matches(left, left.offsetBy(dx: 2, dy: 2)))
        assert(!DesktopWindowLayout.matches(left, left.insetBy(dx: -40, dy: 0)))
        assert(Set(DesktopMenuActions.commands.map(\.id)).count == DesktopMenuActions.commands.count)
        let undo = DesktopMenuActions.commands.first { $0.id == "undo" }!
        assert(DesktopMenuActions.matches("Undo Typing", command: undo))
        assert(!DesktopMenuActions.matches("UndoAll", command: undo))
        if CommandLine.arguments.contains("--inspect") {
            // 可选只读真机检查，不激活应用、不按菜单、不回传窗口正文。
            for app in NSWorkspace.shared.runningApplications where ["com.google.Chrome", "com.apple.Safari"].contains(app.bundleIdentifier ?? "") {
                let entries = DesktopMenuActions.entries(pid: app.processIdentifier)
                let available = DesktopMenuActions.commands.filter { !DesktopMenuActions.candidates($0, entries: entries).isEmpty }.map(\.id)
                print("Read-only menu evidence: \(app.localizedName ?? "browser") entries=\(entries.count), available=\(available)")
            }
        }
        print("desktop actions: parameter isolation, menu evidence, stable identities, multi-screen geometry passed")
    }
}
