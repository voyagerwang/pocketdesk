/**
 * [INPUT]: 依赖 Foundation 的 NSLock 与 ProcessInfo 单调时钟；被 InputExecutor 在提交、图片粘贴、草稿写入期间增减。
 * [OUTPUT]: 提供 InputActivity 进程级活动门闩：isBusy 表示输入事务进行中，quiet(for:) 表示既无事务又在静默期内。
 * [POS]: Sources 的输入事务看守；看门狗据此推迟自愈重启，避免打断一次正在进行、无法重放的输入。
 *        刻意只做计数与时间戳，不承担事件分发（不引入通用事件总线）。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

final class InputActivity {
    static let shared = InputActivity()
    private let lock = NSLock()
    private var depth = 0
    private var lastBusyAt: TimeInterval = -(.greatestFiniteMagnitude)

    /// 当前是否有输入事务在进行（提交、图片粘贴、草稿写入）。
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return depth > 0
    }

    func begin() {
        lock.lock()
        depth += 1
        lastBusyAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func end() {
        lock.lock()
        depth = max(0, depth - 1)
        lastBusyAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// 距最近一次输入活动已经静默了至少 interval 秒，且当前没有事务在进行。
    /// 看门狗重启前必须满足：重启本身会杀掉进程，任何未完成的事务都无法重放。
    func quiet(for interval: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return depth == 0 && ProcessInfo.processInfo.systemUptime - lastBusyAt >= interval
    }

    /// 测试用：清回初始态。
    func resetForTesting() {
        lock.lock(); depth = 0; lastBusyAt = -(.greatestFiniteMagnitude); lock.unlock()
    }
}

/// 供执行层使用的语法糖：把一段输入事务包在门闩里，异常路径也会释放。
func withInputActivity<T>(_ body: () throws -> T) rethrows -> T {
    InputActivity.shared.begin()
    defer { InputActivity.shared.end() }
    return try body()
}
