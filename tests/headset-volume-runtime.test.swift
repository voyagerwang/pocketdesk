import Foundation

/// Exercise production routing with a temporary store and inert action callbacks.
/// No application timers, CoreAudio writes, key events or voice capture are started.
@main struct HeadsetVolumeRuntimeTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HeadsetRuleStore(file: folder.appendingPathComponent("rules.json"))
        let signal = HeadsetSignal(kind: .volume, device: "test-output", name: "test", usage: 1, step: 0.0625)
        var click = HeadsetRule(signal: signal, gesture: .click, action: .disabled); click.id = "click"
        var double = HeadsetRule(signal: signal, gesture: .doubleClick, action: .disabled); double.id = "double"
        try store.save(click); try store.save(double)
        var performed: [String] = []
        var fallbacks = 0
        let runtime = HeadsetMappingRuntime(volumeRules: store) { performed.append($0.id) }
        let output = HeadsetAudioDevice(id: 42, uid: signal.device, name: signal.name, volume: 0.5)
        var current: HeadsetAudioDevice? = output
        var focus: pid_t? = 123
        var allowed = true
        runtime.volumeOutput = { current }; runtime.volumeFocus = { focus }; runtime.volumeEnvironmentAllows = { allowed }
        func tap(_ time: Double) {
            assert(runtime.handleVolume(output, side: .right, step: 0.0625, now: time) { fallbacks += 1 })
        }
        tap(0); assert(performed.isEmpty)
        tap(0.2); runtime.tickVolume(now: 0.8)
        assert(performed == ["double"] && fallbacks == 0)
        performed = []
        tap(0.9)
        runtime.volumeSourcePending = { true }
        runtime.tickVolume(now: 1.30)
        assert(performed.isEmpty)
        runtime.volumeSourcePending = { false }
        let deliveredAt = HeadsetVolumeSourceEvent.observationTime(notifiedAt: 1.27, now: 1.31)
        assert(deliveredAt == 1.27)
        tap(deliveredAt) // Main processing after the deadline keeps the original event time.
        runtime.tickVolume(now: 1.4)
        assert(performed == ["double"] && fallbacks == 0)
        performed = []
        tap(1); runtime.tickVolume(now: 1.39)
        assert(performed == ["click"] && fallbacks == 0)

        // With only a double rule, one click retains its original/default action.
        try store.remove(click.id); performed = []
        tap(2); runtime.tickVolume(now: 2.39)
        assert(performed.isEmpty && fallbacks == 1)
        tap(3); tap(3.2); runtime.tickVolume(now: 3.7)
        assert(performed == ["double"] && fallbacks == 1)

        // A pending click must never move into a different app or output device.
        performed = []
        tap(4); focus = 456; runtime.tickVolume(now: 4.4)
        assert(performed.isEmpty && fallbacks == 1)
        tap(5); current = HeadsetAudioDevice(id: 43, uid: "other", name: "other", volume: 0.5)
        runtime.tickVolume(now: 5.4)
        assert(performed.isEmpty && fallbacks == 1)
        current = output
        tap(6); runtime.cancelVolumeGestures(); runtime.tickVolume(now: 6.4)
        assert(performed.isEmpty && fallbacks == 1)
        tap(7); allowed = false; runtime.tickVolume(now: 7.4)
        assert(performed.isEmpty && fallbacks == 1)
        allowed = true

        // A second tap after a focus switch starts a new sequence, not a double.
        tap(8); focus = 789; tap(8.2); runtime.tickVolume(now: 8.6)
        assert(performed.isEmpty && fallbacks == 2)
        try store.remove(double.id); try store.save(click)
        tap(9)
        assert(performed == ["click"] && fallbacks == 2)
        let actions = HeadsetMappingActions(emitter: HeadsetKeyEmitter { _ in fatalError("Unexpected keyboard event") })
        actions.environmentAllows = { true }
        var clickEnds = 0, otherEnds = 0
        actions.finishClickSprite = { clickEnds += 1; return true }
        actions.spriteEnd = { otherEnds += 1 }
        let end = HeadsetRule(signal: signal, gesture: .doubleClick, action: .spriteEnd)
        actions.begin(end)
        assert(clickEnds == 1 && otherEnds == 0)
        actions.finishClickSprite = { false }
        actions.begin(end)
        assert(clickEnds == 1 && otherEnds == 1)
        print("PASS production volume routing: exclusive double, delayed single, native/default fallback, output/focus/cancel guards and immediate single-only rule; no physical input")
    }
}
