import Foundation
@main struct HeadsetHoldTests {
    static func main() {
        var hold = HeadsetHold()
        assert(hold.press()); assert(!hold.release()); assert(!hold.threshold())
        assert(hold.press()); assert(!hold.press()); assert(hold.threshold())
        assert(!hold.threshold()); assert(hold.release()); assert(!hold.release())
        assert(hold.press()); _ = hold.release(); assert(!hold.threshold())
        print("PASS short press, hold once, repeated HID, release once, disconnect cancellation")
    }
}
