/**
 * [INPUT]: 依赖默认有线唤醒的 HeadsetHold 纯按压状态。
 * [OUTPUT]: 验证短按、单次长按、重复 HID 与取消消费；消费后的阈值和松开不会重新触发长按，新按压重新可用。
 * [POS]: tests 的默认有线按压回归，不监听硬件、不发音量或录音事件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
@main struct HeadsetHoldTests {
    static func main() {
        var hold = HeadsetHold()
        assert(hold.press()); assert(!hold.release()); assert(!hold.threshold())
        assert(hold.press()); assert(!hold.press()); assert(hold.threshold())
        assert(!hold.threshold()); assert(hold.release()); assert(!hold.release())
        assert(hold.press()); _ = hold.release(); assert(!hold.threshold())
        assert(hold.press()); assert(hold.consume()); assert(hold.consumed)
        assert(!hold.press() && !hold.threshold(), "取消后的重复脉冲和阈值不能启动录音")
        let consumed = hold.consumed
        assert(!hold.release() && consumed && !hold.consumed, "松开消费过的按压不会成为长按结束")
        assert(hold.press() && !hold.consumed && hold.threshold() && hold.release(), "下一次独立长按仍可用")
        print("PASS short press, hold once, repeated HID, release once, cancellation consumed without new recording")
    }
}
