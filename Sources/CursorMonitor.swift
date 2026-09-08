/**
 * [INPUT]: 依赖 CoreGraphics 的 CGEvent 读数与 CGGetActiveDisplayList 显示器枚举；由 WSServer 按需启停。
 * [OUTPUT]: 对外提供 CursorMonitor（约 30Hz 真实光标采样、显示器归属判定、变化才发 + 1 秒心跳）。
 * [POS]: Sources 的光标观测层；只观测不控制，与 PointerExecutor（命令执行）严格分离——前者读系统真值，后者维护命令期望值。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CoreGraphics
import Foundation

// 鼠标位置回传：Mac 真实光标 → 采样 → WS 广播 → 手机叠加箭头。
//
// 设计前提（与 PointerExecutor 的分工）：
//   - 本类只读：CGEvent(source: nil)?.location 是系统真值，读它不需要辅助功能权限（发事件才需要）。
//   - PointerExecutor 维护的是"命令期望值"，本类维护的是"观测值"，两者永不互相写入。
//     否则实体鼠标一动、手机再发相对移动就会跳回旧缓存位置。
//   - 没有订阅者就停表：不在后台空转耗电。

final class CursorMonitor {
    private let queue = DispatchQueue(label: "dev.voicedeck.cursor")
    private var timer: DispatchSourceTimer?
    private var subscribers = 0
    private var seq: UInt64 = 0
    private var last: (display: UInt32, rx: Double, ry: Double)?
    private var lastBeatAt: TimeInterval = 0

    /// 采样回调。display 为 nil 表示光标不在任何已知显示器上（罕见），此时前端应隐藏箭头。
    var onSample: ((_ seq: UInt64, _ display: UInt32?, _ rx: Double, _ ry: Double) -> Void)?

    /// 订阅者数量变更入口：降到 0 立刻停表并丢弃去重状态。
    func setSubscribers(_ count: Int) {
        queue.async {
            self.subscribers = max(0, count)
            self.syncTimer()
        }
    }

    private func syncTimer() {
        if subscribers > 0, timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33))  // ≈30Hz
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        } else if subscribers <= 0, let timer {
            timer.cancel()
            self.timer = nil
            last = nil
        }
    }

    private func tick() {
        guard subscribers > 0 else { return }
        guard let point = CGEvent(source: nil)?.location else { return }

        var display: UInt32?
        var rx = 0.0
        var ry = 0.0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        for index in 0..<Int(count) {
            let bounds = CGDisplayBounds(ids[index])
            // CGRect.contains 语义是 minX <= x < maxX，正好避开 maxX 这个越界坐标。
            if bounds.contains(point) {
                display = ids[index]
                rx = (point.x - bounds.minX) / bounds.width
                ry = (point.y - bounds.minY) / bounds.height
                break
            }
        }

        let now = Date().timeIntervalSince1970
        if let last, display != nil, last.display == display,
           abs(last.rx - rx) < 0.0005, abs(last.ry - ry) < 0.0005 {
            // 位置没变：只在 1 秒心跳时才补发一次，让手机知道链路还活着。
            guard now - lastBeatAt >= 1 else { return }
        }
        // 光标滑出了所有显示器：last 置空，回到任一屏时立刻重发。
        last = display.map { (display: $0, rx: rx, ry: ry) }
        lastBeatAt = now
        seq += 1
        onSample?(seq, display, rx, ry)
    }
}
