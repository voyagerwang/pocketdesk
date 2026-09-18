/**
 * [INPUT]: 依赖 NSScreen 可用区域、AX 窗口属性与 AgentDesktopActions 的精确窗口身份。
 * [OUTPUT]: 半屏、上下半屏、四角、铺满、居中、最小化和恢复，以及实际窗口几何回执。
 * [POS]: 桌面窗口布局执行层；统一使用 AX 全局点坐标，读回位置尺寸后才确认成功，不修改全屏空间。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

enum DesktopWindowLayout {
    enum Position: String, Codable, CaseIterable {
        case left, right, top, bottom, topLeft = "top_left", topRight = "top_right"
        case bottomLeft = "bottom_left", bottomRight = "bottom_right", maximize, center, minimize, restore
    }
    static func frame(position: Position, visible: CGRect, current: CGRect) -> CGRect {
        let halfW = visible.width / 2, halfH = visible.height / 2
        switch position {
        case .left: return CGRect(x: visible.minX, y: visible.minY, width: halfW, height: visible.height)
        case .right: return CGRect(x: visible.minX + halfW, y: visible.minY, width: halfW, height: visible.height)
        case .top: return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfH)
        case .bottom: return CGRect(x: visible.minX, y: visible.minY + halfH, width: visible.width, height: halfH)
        case .topLeft: return CGRect(x: visible.minX, y: visible.minY, width: halfW, height: halfH)
        case .topRight: return CGRect(x: visible.minX + halfW, y: visible.minY, width: halfW, height: halfH)
        case .bottomLeft: return CGRect(x: visible.minX, y: visible.minY + halfH, width: halfW, height: halfH)
        case .bottomRight: return CGRect(x: visible.minX + halfW, y: visible.minY + halfH, width: halfW, height: halfH)
        case .maximize: return visible
        case .center:
            let w = min(current.width, visible.width), h = min(current.height, visible.height)
            return CGRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h)
        case .minimize, .restore: return current
        }
    }
    static func axRect(_ window: AXUIElement) -> CGRect? {
        guard let p = DesktopMenuActions.attribute(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = DesktopMenuActions.attribute(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func matches(_ actual: CGRect, _ expected: CGRect) -> Bool {
        abs(actual.minX - expected.minX) <= 3 && abs(actual.minY - expected.minY) <= 3
            && abs(actual.width - expected.width) <= 3 && abs(actual.height - expected.height) <= 3
    }
    static func screens() -> [(id: Int, rect: CGRect)] {
        func read() -> [(id: Int, rect: CGRect)] {
            guard let primary = NSScreen.screens.first else { return [] }
            return NSScreen.screens.enumerated().map { index, screen in
                let v = screen.visibleFrame
                return (index + 1, CGRect(x: v.minX, y: primary.frame.maxY - v.maxY, width: v.width, height: v.height))
            }
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }
    static func perform(_ request: DesktopActionRequest, app: NSRunningApplication, valid: () -> Bool) -> AgentDesktopActions.Reply {
        guard let position = request.position, let window = AgentDesktopActions.selectedWindow(request, app: app),
              valid() else { return .failure(.message("目标窗口未唯一确定，请先 list_windows 并指定 window 标识。")) }
        if DesktopMenuActions.attribute(window, "AXFullScreen") as? Bool == true {
            return .failure(.message("目标窗口处于系统全屏空间，请先退出全屏再调整布局。"))
        }
        if position == .minimize || position == .restore {
            let value = position == .minimize
            guard valid(), AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) == .success else {
                return .failure(.message("应用拒绝更改窗口最小化状态。"))
            }
            for _ in 0..<10 {
                if DesktopMenuActions.attribute(window, kAXMinimizedAttribute) as? Bool == value {
                    return .success(.delivered(value ? "已最小化指定窗口。" : "已恢复指定窗口。"))
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return .success(.sent("已请求调整窗口状态，尚未确认。"))
        }
        guard let current = axRect(window) else { return .failure(.message("无法读取目标窗口位置。")) }
        let available = screens()
        let screen = request.display.flatMap { id in available.first { $0.id == id } }
            ?? (request.display == nil ? available.max { a, b in
                let ia = a.rect.intersection(current), ib = b.rect.intersection(current)
                return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
            } : nil)
        guard let screen else { return .failure(.message("指定屏幕不存在；未改用其他屏幕。")) }
        guard request.display != nil || !screen.rect.intersection(current).isNull else {
            return .failure(.message("窗口不在可确认的屏幕上，请指定 list_windows 返回的屏幕编号。"))
        }
        let desired = frame(position: position, visible: screen.rect, current: current)
        var point = desired.origin, size = desired.size
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size), valid() else {
            return .failure(.message("布局执行前控制权或窗口状态变化。"))
        }
        if DesktopMenuActions.attribute(window, kAXMinimizedAttribute) as? Bool == true {
            guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                return .failure(.message("窗口未能恢复，未移动窗口。"))
            }
        }
        guard valid() else { return .success(.sent("窗口恢复后控制权变化，布局未完成。")) }
        // 先缩放再移动，最后再设尺寸，兼容系统跨屏时的尺寸钳制；不重放用户输入。
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        guard valid() else { return .success(.sent("调整尺寸后控制权变化，布局未完成。")) }
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        guard valid() else { return .success(.sent("移动窗口后控制权变化，布局未完成。")) }
        let adjusted = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        for _ in 0..<12 {
            if let actual = axRect(window), matches(actual, desired) {
                return .success(.delivered("已调整窗口到屏幕 \(screen.id) 的 \(position.rawValue)，位置与尺寸已核验。"))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let accepted = resized == .success || moved == .success || adjusted == .success
        return accepted ? .success(.sent("已请求布局，但实际位置或尺寸不符；应用可能有最小宽度或布局限制，未报告排列成功。"))
            : .failure(.message("应用不允许调整该窗口的位置或尺寸。"))
    }
}
