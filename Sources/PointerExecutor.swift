/**
 * [INPUT]: 依赖 CoreGraphics 的 CGEvent/CGDisplay 系列 API；消费 WSServer 转发的手势 JSON。
 * [OUTPUT]: 对外提供 PointerExecutor（虚拟光标维护、双屏包围盒钳制、move/drag/click/scroll/zoom 手势到 CGEvent 的映射、会话重置）。
 * [POS]: Sources 的指针执行层；仅被 WSServer 消费，与 InputExecutor（键盘）平行为一对执行兄弟。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CoreGraphics
import Foundation

// 手势命令来自 WebSocket（端口 46388）：
// {"t":"move","dx":..,"dy":..} 相对移动光标；拖动时客户端改发 {"t":"drag"}（左键按住移动）
// {"t":"down"}/{"t":"up"} 左键按下/抬起；{"t":"click","button":"left"|"right"}
// {"t":"scroll","dx":..,"dy":..} 自然滚动（内容跟随手指方向）
// {"t":"zoom","delta":..} 捏合缩放，经 Cmd+滚轮 合成（Chrome/Safari 页面缩放）
final class PointerExecutor {
    private let queue = DispatchQueue(label: "dev.voicedeck.pointer")
    private var position: CGPoint?
    private var dragging = false
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var scrollPhaseActive = false
    private var lastScrollAt: TimeInterval = 0

    // 新的触控板会话（WS 连接建立）时调用：强制抬起可能卡住的左键，避免后续点击失效。
    func resetSession() {
        queue.async {
            if self.dragging {
                self.dragging = false
                self.post(.leftMouseUp, at: self.currentPosition())
            }
            self.scrollPhaseActive = false
        }
    }

    private func currentPosition() -> CGPoint {
        if let position { return position }
        let current = CGEvent(source: nil)?.location ?? CGPoint(x: 600, y: 400)
        position = current
        return current
    }

    // 所有活动显示器的包围盒：双屏时光标可以跨屏移动。
    private func clamped(_ point: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        var bounds = CGRect.null
        for i in 0..<Int(count) { bounds = bounds.union(CGDisplayBounds(ids[i])) }
        if bounds.isNull { bounds = CGDisplayBounds(CGMainDisplayID()) }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                       y: min(max(point.y, bounds.minY), bounds.maxY))
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
            let next = clamped(CGPoint(x: currentPosition().x + dx, y: currentPosition().y + dy))
            position = next
            if dragging || type == "drag" {
                if !dragging { dragging = true; post(.leftMouseDown, at: next) }
                post(.leftMouseDragged, at: next)
            } else {
                post(.mouseMoved, at: next)
            }
        case "down":
            dragging = true
            post(.leftMouseDown, at: currentPosition())
        case "up":
            guard dragging else { return }
            dragging = false
            post(.leftMouseUp, at: currentPosition())
        case "click":
            let right = (command["button"] as? String) == "right"
            let button: CGMouseButton = right ? .right : .left
            let count = min(3, max(1, command["count"] as? Int ?? 1))
            let point = currentPosition()
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
