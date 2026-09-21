/**
 * [INPUT]: 生产 LockScreenInput 的键盘布局映射入口与 macOS 主运行循环。
 * [OUTPUT]: 验证后台解锁队列请求键码时，布局读取切回主线程且不会触发 HIToolbox 队列断言；不发送任何按键。
 * [POS]: 原生解锁输入的线程边界回归。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

@main enum LockScreenInputTest {
    static func main() {
        _ = NSApplication.shared
        let lock = NSLock()
        var finished = false
        var mapped = false

        DispatchQueue.global(qos: .userInitiated).async {
            let keys = LockScreenInput.keys(for: "a")
            lock.lock()
            mapped = keys?.count == 1
            finished = true
            lock.unlock()
        }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock()
            let done = finished
            lock.unlock()
            if done { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        lock.lock()
        let passed = finished && mapped
        lock.unlock()
        print("\(passed ? "PASS" : "FAIL") background keyboard layout lookup returns safely")
        if !passed { exit(1) }
    }
}
