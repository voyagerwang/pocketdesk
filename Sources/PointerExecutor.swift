/**
 * [INPUT]: 依赖 CoreGraphics 的 CGEvent/CGDisplay 系列 API；消费 WSServer 转发的手势 JSON。
 * [OUTPUT]: 对外提供 PointerExecutor（虚拟光标维护、有效屏区域钳制、pointer 绝对拖动与 move/drag/click/scroll/zoom/tap 手势到 CGEvent 的映射、会话重置、目标窗口定位（只移动不点击，按代际与用户活动门禁）、拒绝执行时经 onError 上报）。
 * 安全边界：锁屏密码仅走 HTTPS 专用执行器，普通输入在锁屏时受阻；安全监听共享原控制租约。
 * [POS]: Sources 的指针执行层；仅被 WSServer 消费，与 InputExecutor（键盘）平行为一对执行兄弟。
 *          维护的是**命令期望值**，与 CursorMonitor 的**观测值**严格分离，两者互不写入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CoreGraphics
import Foundation

// 手势命令来自 WebSocket（端口 46388）：
// {"t":"move","dx":..,"dy":..} 相对移动光标；拖动时客户端改发 {"t":"drag"}（左键按住移动）
// {"t":"down"}/{"t":"up"} 左键按下/抬起；{"t":"click","button":"left"|"right","clickState":1|2}
//   —— clickState 是**这一下**在点击序列中的序号（1=单击，2=双击的第二下），只发一组 down/up；
//      旧字段 count 是"完整点击次数"（会循环 1...count），只为旧客户端保留，新前端请用 clickState。
// {"t":"tap","rx":..,"ry":..,"display":<id>,"click":true|false,"clickState":1|2}
//   —— 点画面移光标：rx/ry 是目标显示器内的比例坐标（0~1），click=true 时顺带左键单击。
// {"t":"scroll","dx":..,"dy":..} 自然滚动（内容跟随手指方向）
// {"t":"zoom","delta":..} 捏合缩放，经 Cmd+滚轮 合成（Chrome/Safari 页面缩放）
final class PointerExecutor {
    private let queue = DispatchQueue(label: "dev.voicedeck.pointer")
    /// 命令期望值：上一条移动/点击指令执行后，我们认为光标应该在的位置。
    /// 注意它不是系统真值——真值由 CursorMonitor 独立观测，两者不互相写入。
    private var expected: CGPoint?
    private var dragging = false
    private var epoch: UInt64 = 0
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var scrollPhaseActive = false
    private var lastScrollAt: TimeInterval = 0

    /// 无法安全执行的命令（如显示器已拔掉仍要求点击）经此上报，由 WSServer 广播给手机。
    /// 静默回退主屏更糟：点击会落到错误的应用上。
    var onError: ((_ message: String) -> Void)?

    // 新的触控板会话（WS 连接建立）时调用：强制抬起可能卡住的左键，避免后续点击失效。
    func resetSession() {
        queue.async {
            self.epoch &+= 1
            if self.dragging {
                self.dragging = false
                self.post(.leftMouseUp, at: self.basePosition())
            }
            self.apply(["t": "scrollEnd"])
            self.scrollRemainder = (0, 0)
        }
    }

    /// 定位结果：区分"移动了 / 已在位 / 跳过（附原因）"，不能用命令预期伪造手机光标。
    enum LocateOutcome {
        case moved(CGPoint)
        case unchanged(CGPoint)
        case skipped(String)
    }

    /// 选择代际：只有不早于已执行最大代际的定位才会生效。
    /// 快速点 A 再点 B 时，A 的迟到回执不得把光标从 B 抢走。
    private var locateGeneration: UInt64 = 0

    /// 把光标定位到目标窗口的可见区域。**只移动**：不点击、不改选区、不夺取焦点。
    /// 与其它指针命令在同一串行队列里核验锁屏、拖动、代际与用户活动之后才注入，并同步更新 expected。
    /// - anchor: 请求发出时的鼠标位置。等待激活期间用户动过鼠标/触控板 → 放弃本次定位，
    ///   不能等用户手势结束后再突然把光标挪走。
    func locate(to point: CGPoint, generation: UInt64, anchor: CGPoint?, completion: @escaping (LocateOutcome) -> Void) {
        queue.async {
            guard LockScreenInput.state == "unlocked" else { completion(.skipped("locked")); return }
            guard !self.dragging else { completion(.skipped("dragging")); return }
            guard generation >= self.locateGeneration else { completion(.skipped("stale")); return }
            self.locateGeneration = generation
            let current = CGEvent(source: nil)?.location
            if let anchor, let current, hypot(current.x - anchor.x, current.y - anchor.y) > 3 {
                completion(.skipped("user-active")); return
            }
            let target = self.clamped(point)
            self.expected = target
            if let current, hypot(current.x - target.x, current.y - target.y) <= 1.5 {
                completion(.unchanged(target)); return
            }
            self.post(.mouseMoved, at: target)
            completion(.moved(target))
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
        guard LockScreenInput.state == "unlocked" else { return }
        let type = command["t"] as? String ?? ""
        let dx = command["dx"] as? Double ?? 0
        let dy = command["dy"] as? Double ?? 0
        guard dx.isFinite, dy.isFinite, abs(dx) < 100_000, abs(dy) < 100_000 else { return }
        switch type {
        case "pointer":
            let action = command["action"] as? String ?? ""
            if action == "up" || action == "cancel" {
                if dragging { dragging = false; post(.leftMouseUp, at: basePosition()) }
                return
            }
            guard let rx = command["rx"] as? Double, let ry = command["ry"] as? Double,
                  rx.isFinite, ry.isFinite, (0...1).contains(rx), (0...1).contains(ry),
                  let display = command["display"] as? UInt32, let bounds = displayBounds(display) else {
                onError?("画面坐标或显示器已失效，请刷新后重试。"); return
            }
            let point = CGPoint(x: min(bounds.maxX - 1, bounds.minX + rx * bounds.width),
                                y: min(bounds.maxY - 1, bounds.minY + ry * bounds.height))
            expected = point
            switch action {
            case "move": post(.mouseMoved, at: point)
            case "down":
                if !dragging { dragging = true; post(.leftMouseDown, at: point) }
            case "drag":
                guard dragging else { return }
                post(.leftMouseDragged, at: point)
            case "click":
                let right = command["button"] as? String == "right"
                let button: CGMouseButton = right ? .right : .left
                let state = Int64(min(2, max(1, command["clickState"] as? Int ?? 1)))
                post(.mouseMoved, at: point)
                post(right ? .rightMouseDown : .leftMouseDown, at: point, button: button, clickState: state)
                usleep(40_000)
                post(right ? .rightMouseUp : .leftMouseUp, at: point, button: button, clickState: state)
            default: break
            }

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
            guard let rx = command["rx"] as? Double, let ry = command["ry"] as? Double,
                  rx.isFinite, ry.isFinite, (0...1).contains(rx), (0...1).contains(ry) else { return }
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
                // down/up 留 40ms：与下方 "click" 分支统一。很多应用（含 WebKit/Electron/
                // 自定义 NSTextView）的输入框在 mousedown 阶段抢焦点，down/up 之间零间隔时
                // 系统来不及派发"设置第一响应者"就被 up 中断，表现为"指针动了但框没聚焦"。
                // clickState=2 表示"这是双击的第二下"，绝不是"再点两次"。
                let clickState = Int64(min(2, max(1, command["clickState"] as? Int ?? 1)))
                post(.leftMouseDown, at: point, clickState: clickState)
                usleep(40_000)
                post(.leftMouseUp, at: point, clickState: clickState)
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
            let point = basePosition()
            // clickState（新语义）：这一下在点击序列中的序号——1=单击，2=双击的第二下，
            //   **只发一组 down/up**。前端的双击是"第一下 clickState=1 + 第二下 clickState=2"。
            // count（旧语义）：完整点击次数，按 1...count 循环注入。前端曾先发 count=1 再发
            //   count=2，被循环执行成 3 次点击——所以前端已改走 clickState；count 只为旧客户端保留。
            let states: [Int64]
            if let state = command["clickState"] as? Int {
                states = [Int64(min(2, max(1, state)))]
            } else {
                let count = min(3, max(1, command["count"] as? Int ?? 1))
                states = (1...count).map { Int64($0) }
            }
            // 按下与抬起间隔 40ms，双击按真实系统的 clickState 1→2 序列注入。
            let scheduledEpoch = epoch
            for (index, state) in states.enumerated() {
                let base = Double(index) * 0.12
                let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
                let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
                queue.asyncAfter(deadline: .now() + base) { [weak self] in
                    guard let self, self.epoch == scheduledEpoch else { return }
                    self.post(down, at: point, button: button, clickState: state)
                    // 同一串行执行片段内配对，接管/reset 不会与旧点击的抬起交错。
                    usleep(40_000)
                    self.post(up, at: point, button: button, clickState: state)
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
            guard delta.isFinite, abs(delta) < 100_000 else { return }
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
