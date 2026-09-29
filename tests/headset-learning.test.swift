import Foundation
@main struct LearningTests {
 static func main() {
    var learner = HeadsetLearning()
    assert(!learner.receive(usage: 0xCD, down: false, time: 0))
    assert(!learner.receive(usage: 0xE9, down: true, time: 0))
    assert(learner.stage == .center)
    for (i, key) in [UInt32(0xCD), 0xE9, 0xEA].enumerated() {
        let t = Double(i)
        assert(!learner.receive(usage: key, down: true, time: t))
        assert(!learner.receive(usage: key, down: true, time: t + 0.01))
        assert(learner.receive(usage: key, down: false, time: t + 0.1))
    }
    assert(learner.stage == .hold)
    _ = learner.receive(usage: 0xEA, down: true, time: 5)
    assert(!learner.receive(usage: 0xEA, down: false, time: 5.2))
    assert(learner.stage == .hold)
    _ = learner.receive(usage: 0xEA, down: true, time: 6)
    assert(learner.receive(usage: 0xEA, down: false, time: 7))
    assert(learner.stage == .complete)
    assert(!learner.receive(usage: 0xEA, down: true, time: 8))
    let data = try! JSONEncoder().encode([HeadsetProfile.quark])
    assert(try! JSONDecoder().decode([HeadsetProfile].self, from: data) == [.quark])
    assert(!HeadsetProfile(vendorID: 0, productID: 1, name: "invalid", supportsHold: true).valid)
    print("PASS wrong key, orphan release, repeated down, ordered learning, short hold rejected, full hold, profile roundtrip")
 }
}
