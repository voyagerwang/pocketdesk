/**
 * [INPUT]: 依赖 CoreGraphics 的 CGEvent/CGDisplay 系列 API；消费 WSServer 转发的手势 JSON。
 * [OUTPUT]: 对外提供 PointerExecutor（虚拟光标维护、有效屏区域钳制、move/drag/click/scroll/zoom/tap 手势到 CGEvent 的映射、会话重置、拒绝执行时经 onError 上报）。
 * [POS]: Sources 的指针执行层；仅被 WSServer 消费，与 InputExecutor（键盘）平行为一对执行兄弟。
 *          维护的是**命令期望值**，与 CursorMonitor 的**观测值**严格分离，两者互不写入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CoreGraphics
import Foundation

// 手势命令来自 WebSocket（端口 46388）：
// {"t":"move","dx":..,"dy":..} 相对移动光标；拖动时客户端改发 {"t":"drag"}（左键按住移动）
// {"t":"down"}/{"t":"up"} 左键按下/抬起；{"t":"click","button":"left"|"right"}
// {"t":"tap","rx":..,"ry":..,"display":<id>,"click":true|false}
//   —— 点画面移光标：rx/ry 是目标显示器内的比例坐标（0~1），click=true 时顺带左键单击。
// {"t":"scroll","dx":..,"dy":..} 自然滚动（内容跟随手指方向）
// {"t":"zoom","delta":..} 捏合缩放，经 Cmd+滚轮 合成（Chrome/Safari 页面缩放）
final class PointerExecutor {
    private let queue = DispatchQueue(label: "dev.voicedeck.pointer")
    /// 命令期望值：上一条移动/点击指令执行后，我们认为光标应该在的位置。
    /// 注意它不是系统真值——真值由 CursorMonitor 独立观测，两者不互相写入。
    private var expected: CGPoint?
    private var dragging = false
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var scrollPhaseActive = false
    private var lastScrollAt: TimeInterval = 0

    /// 无法安全执行的命令（如显示器已拔掉仍要求点击）经此上报，由 WSServer 广播给手机。
    /// 静默回退主屏更糟：点击会落到错误的应用上。
    var onError: ((_ message: String) -> Void)?

    // 新的触控板会话（WS 连接建立）时调用：强制抬起可能卡住的左键，避免后续点击失效。
    func resetSession() {
        queue.async {
            if self.dragging {
                self.dragging = false
                self.post(.leftMouseUp, at: self.basePosition())
            }
            self.scrollPhaseActive = false
        }
    }

    /// 相对移动的起点。这里是最容易出错的地方，规则是"能用期望值就别用观测值"：
    /// - 系统真值与期望值基本一致（差 < 2px）→ 走期望值。否则拖动会被注入延迟打断
    ///   （CGEvent 注入后系统读数滞后，每帧读真值等于每帧把光标往回拽）。
    /// - 差得远 → 说明实体鼠标动过（或首次运行），以真值为基准，避免跳回旧位置。
    private func basePosition() -> CGPoint {
        let actual = CGEvent(source: nil)?.location
        if let expected, let actual,
           abs(actual.x - expected.x) < 2, abs(actual.y - expected.y) < 2 {
            return expected
        }
        return actual ?? expected ?? CGPoint(x: 600, y: 400)
    }

    /// 有效显示器矩形集合。所有屏的外接矩形不能用来钳制：L 形排列时外接矩形包含
    /// 没有屏幕的空洞，光标会被允许停在不存在的区域，之后就从那儿"消失"了。
    private func activeDisplayBounds() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let rects = (0..<Int(count)).map { CGDisplayBounds(ids[$0]) }.filter { !$0.isNull }
        return rects.isEmpty ? [CGDisplayBounds(CGMainDisplayID())] : rects
    }

    /// 钳制到真实存在的屏幕区域：已在某块屏内就原样返回，越界则投影到最近的有效边缘。
    /// maxX/maxY 是矩形外沿、不是可用像素，所以上界取 maxX-1 / maxY-1。
    private func clamped(_ point: CGPoint) -> CGPoint {
        let rects = activeDisplayBounds()
        if rects.contains(where: { $0.contains(point) }) { return point }
        var best = point
        var bestDistance = Double.infinity
        for rect in rects {
            let x = min(max(point.x, rect.minX), rect.maxX - 1)
            let y = min(max(point.y, rect.minY), rect.maxY - 1)
            let distance = hypot(point.x - x, point.y - y)
            if distance < bestDistance {
                bestDistance = distance
                best = CGPoint(x: x, y: y)
            }
        }
        return best
    }

    /// 指定显示器的逻辑包围盒（点，非像素）。显示器已离线或 ID 未知时返回 nil，
    /// 由调用方决定是拒绝执行还是降级——绝不在这里静默回退主屏。
    /// macOS 全局坐标 Y 轴向下（CGEvent 语义），CGDisplayBounds 返回的即是该坐标系下的矩形，
    /// 比例坐标直接线性映射，无需翻转。
    private func displayBounds(_ displayID: CGDirectDisplayID) -> CGRect? {
        guard displayID != 0, CGDisplayIsOnline(displayID) != 0 else { return nil }
        let bounds = CGDisplayBounds(displayID)
        return bounds.isNull ? nil : bounds
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clickState: Int64 = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        // 显式标记 clickState：Electron/Chromium 系应用会丢弃未带按下次数的合成点击（表现为点不动、无法聚焦）。
        event?.setIntegerValueField(.mouseEventClickState, value: clickState)
        event?.post(tap: .cghidEventTap)
    }

    func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        queue.async { self.apply(command) }
    }

    private func apply(_ command: [String: Any]) {
        let type = command["t"] as? String ?? ""
        let dx = command["dx"] as? Double ?? 0
        let dy = command["dy"] as? Double ?? 0
        switch type {
        case "move", "drag":
            let base = basePosition()
            let next = clamped(CGPoint(x: base.x + dx, y: base.y + dy))
            expected = next
            if dragging || type == "drag" {
                if !dragging { dragging = true; post(.leftMouseDown, at: next) }
                post(.leftMouseDragged, at: next)
            } else {
                post(.mouseMoved, at: next)
            }
        case "tap":
            // 点画面移光标：比例坐标 → 目标显示器绝对坐标。先移动，可选顺带单击。
            let rx = min(1, max(0, command["rx"] as? Double ?? 0))
            let ry = min(1, max(0, command["ry"] as? Double ?? 0))
            let displayID = command["display"] as? UInt32 ?? 0
            // 显示器已拔掉或 ID 失效时拒绝执行。以前的写法是静默回退主屏，
            // 那会把这次点击送到完全错误的应用上——宁可不点，也不能乱点。
            guard let bounds = displayBounds(displayID) else {
                onError?("显示器已断开，请重新选择显示器后再操作。")
                return
            }
            // maxX 是矩形外沿而非可用像素，rx=1 时收到 maxX-1，避免点到屏幕外。
            let point = CGPoint(x: min(bounds.minX + rx * bounds.width, bounds.maxX - 1),
                                y: min(bounds.minY + ry * bounds.height, bounds.maxY - 1))
            expected = point
            post(.mouseMoved, at: point)
            if command["click"] as? Bool == true {
                post(.leftMouseDown, at: point)
                post(.leftMouseUp, at: point)
            }
        case "down":
            dragging = true
            post(.leftMouseDown, at: basePosition())
        case "up":
            guard dragging else { return }
            dragging = false
            post(.leftMouseUp, at: basePosition())
        case "click":
            let right = (command["button"] as? String) == "right"
            let button: CGMouseButton = right ? .right : .left
            let count = min(3, max(1, command["count"] as? Int ?? 1))
            let point = basePosition()
            // 按下与抬起间隔 40ms，双击按真实系统的 clickState 1→2 序列注入。
            for i in 1...count {
                let base = Double(i - 1) * 0.12
                let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
                let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
                queue.asyncAfter(deadline: .now() + base) { [weak self] in
                    guard let self else { return }
                    self.post(down, at: point, button: button, clickState: Int64(i))
                    self.queue.asyncAfter(deadline: .now() + 0.04) {
                        self.post(up, at: point, button: button, clickState: Int64(i))
                    }
                }
            }
        case "scroll":
            // 像素级平滑滚动；小数残差留在服务端累积，避免高频小位移被取整吞掉。
            let totalX = scrollRemainder.x + dx
            let totalY = scrollRemainder.y + dy
            let wheelX = Int32(round(totalX))
            let wheelY = Int32(round(totalY))
            scrollRemainder = (totalX - Double(wheelX), totalY - Double(wheelY))
            guard wheelX != 0 || wheelY != 0 else { return }
            let now = Date().timeIntervalSince1970
            let began = !scrollPhaseActive || (now - lastScrollAt) > 0.15
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: wheelY, wheel2: wheelX, wheel3: 0) {
                // 滚动相位让 Chrome/Safari 按触控板式直接位移处理，而不是逐格滚轮动画，消除迟滞。
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: began ? 1 : 2)
                event.post(tap: .cghidEventTap)
            }
            scrollPhaseActive = true
            lastScrollAt = now
        case "scrollEnd":
            guard scrollPhaseActive else { return }
            scrollPhaseActive = false
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: 0, wheel2: 0, wheel3: 0) {
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4) // ended
                event.post(tap: .cghidEventTap)
            }
        case "zoom":
            let delta = command["delta"] as? Double ?? 0
            let wheel = Int32(round(delta * 8))
            guard wheel != 0 else { return }
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: wheel, wheel2: 0, wheel3: 0) {
                event.flags = .maskCommand
                event.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }
}
