/**
 * [INPUT]: ChromeTabCleanup 注入快照、关闭与状态替身。
 * [OUTPUT]: 验证延迟关闭只发一次、核验超时停止、URL/窗口边界、失权停止及脚本语法（只编译不执行）。
 * [POS]: 无 Chrome 操作、无授权弹窗的隔离回归。
 */
import AppKit

@main struct ChromeTabCleanupTests {
    static func main() {
        func tab(_ id: Int, _ url: String = "https://example.com/a?x=1#foo", window: Int = 1, active: Bool = false, loading: Bool = false) -> ChromeTabCleanup.Tab {
            .init(window: window, id: id, url: url, active: active, loading: loading)
        }
        let tabs = [tab(1), tab(2, active: true), tab(3), tab(4, window: 2), tab(5, loading: true),
                    tab(6, "https://example.com/a?x=2#foo"), tab(7, "https://example.com/a?x=1#bar"),
                    tab(8, "https://example.com/A?x=1#foo"), tab(9, "chrome://newtab/"), tab(10, "chrome://newtab/")]
        let plan = ChromeTabCleanup.plan(tabs)
        assert(plan.map(\.close.id) == [1, 3])
        assert(plan.allSatisfy { $0.keep.id == 2 })
        assert(ChromeTabCleanup.plan([tab(1), tab(2)])[0].keep.id == 1)
        assert(ChromeTabCleanup.plan([tab(1, ""), tab(2, "")]).isEmpty)
        assert(ChromeTabCleanup.plan([tab(1, "https://example.com/a\n"), tab(2, "https://example.com/a\n")]).isEmpty)

        // 编译检查不发送 AppleEvent；使用本机 Chrome 的真实脚本字典。
        let hostile = tab(20, "https://example.com/\"&\\test")
        for source in [ChromeTabCleanup.readSource, ChromeTabCleanup.closeSource(plan[0]), ChromeTabCleanup.verifySource(plan[0]),
                       ChromeTabCleanup.closeSource(.init(keep: hostile, close: hostile))] {
            var error: NSDictionary?
            assert(NSAppleScript(source: source)?.compileAndReturnError(&error) == true, "\(String(describing: error))")
        }
        ChromeTabCleanup.available = { true }
        ChromeTabCleanup.snapshot = { tabs }
        var allowed = true
        AgentRunner.canControl = { _ in allowed }
        var closes = 0
        var reads = 0
        ChromeTabCleanup.close = { _ in closes += 1; return true }
        ChromeTabCleanup.verify = { _ in
            reads += 1
            return reads % 3 == 0 ? .closed : .pending
        }
        var result: AgentRunner.ToolOutcome?
        func awaitResult() {
            let deadline = Date().addingTimeInterval(4)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            assert(result != nil, "必须在有界等待内结束")
        }
        ChromeTabCleanup.run(taskId: "test") { result = $0 }
        awaitResult()
        guard case .sent(let success) = result else { fatalError("延迟关闭应成功") }
        assert(closes == 2 && reads == 6 && success.contains("已关闭 2 个"), "轮询不能重发关闭")

        closes = 0; reads = 0; result = nil
        ChromeTabCleanup.verify = { _ in reads += 1; return .pending }
        ChromeTabCleanup.run(taskId: "test") { result = $0 }
        awaitResult()
        guard case .failed(let timedOut) = result else { fatalError("超时必须停止") }
        assert(closes == 1 && reads > 1 && timedOut.contains("已确认关闭 0 个"), "未知结果不得关闭下一页")

        closes = 0; result = nil
        ChromeTabCleanup.verify = { _ in allowed = false; return .closed }
        ChromeTabCleanup.run(taskId: "test") { result = $0 }
        awaitResult()
        guard case .failed(let message) = result else { fatalError("失权必须中止") }
        assert(closes == 1 && message.contains("已确认关闭 1 个"))

        allowed = true
        ChromeTabCleanup.close = { _ in closes += 1; throw ChromeTabCleanup.Failure(message: "结果未知") }
        result = nil
        ChromeTabCleanup.run(taskId: "test") { result = $0 }
        awaitResult()
        guard case .failed(let failure) = result else { fatalError("未知结果必须停止") }
        assert(closes == 2 && failure.contains("已确认关闭 0 个"))
        print("Chrome tab cleanup: passed")
    }
}
