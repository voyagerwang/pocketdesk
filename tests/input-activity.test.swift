/**
 * [INPUT]: 依赖 InputActivity 的纯计数与时间戳，不启动服务、不触碰系统输入。
 * [OUTPUT]: 验证活动门闩语义：事务进行中 isBusy、异常路径也会释放、静默期未满不得重启、归零后可重启。
 * [POS]: tests 的自愈重启门禁回归；看门狗的重启时序在真机上另行观察。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct InputActivityTests {
    static func main() {
        let gate = InputActivity.shared
        gate.resetForTesting()

        // 初始态：不忙，且"静默期"成立（从未有过活动）。
        assert(!gate.isBusy)
        assert(gate.quiet(for: 3), "从未活动过应视为静默")

        // 事务进行中：忙碌，且无论等多久都不算静默——重启会打断不可重放的输入。
        gate.begin()
        assert(gate.isBusy)
        assert(!gate.quiet(for: 0), "事务进行中绝不允许重启")
        gate.begin()
        assert(gate.isBusy)
        gate.end()
        assert(gate.isBusy, "嵌套计数：还剩一层事务时仍算忙碌")
        gate.end()
        assert(!gate.isBusy)

        // 刚结束：静默期还没过，仍不允许重启。
        assert(!gate.quiet(for: 3), "刚结束输入就重启会打断收尾（事件可能还在路上）")
        assert(gate.quiet(for: 0), "静默阈值给 0 时即可重启")

        // 异常路径（抛错）也必须释放门闩，否则看门狗会永久失效。
        struct Boom: Error {}
        do { try withInputActivity { throw Boom() } } catch {}
        assert(!gate.isBusy, "抛错路径必须释放门闩")

        gate.resetForTesting()
        print("input activity: 忙碌期禁重启、嵌套计数、静默期、异常路径释放 全部通过")
    }
}
