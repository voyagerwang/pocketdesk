import Foundation
@main struct LearningTests {
    static func main() {
        healthFreshness()
        hidLearning()
        tapGestures()
        volumeLearning()
        volumeRestorationGate()
        ab13xCapabilities()
        rulePersistence()
        print("PASS HID/volume single and double recognition, preset retry, signal isolation, restoration echo, AB13X capabilities and temporary rule persistence; no physical input or production configuration writes")
    }

    static func healthFreshness() {
        assert(HeadsetMappingRuntime.healthIsFresh(timestamp: 100, now: 100))
        assert(HeadsetMappingRuntime.healthIsFresh(timestamp: 100, now: 102.99))
        assert(!HeadsetMappingRuntime.healthIsFresh(timestamp: 100, now: 103))
        assert(!HeadsetMappingRuntime.healthIsFresh(timestamp: 100, now: 99))
        assert(!HeadsetMappingRuntime.healthIsFresh(timestamp: .nan, now: 100))
    }

    static func hidLearning() {
        let button = HeadsetSignal(kind: .hid, device: "1:2:test", name: "test", vendor: 1, product: 2, usage: 0xCD)
        var machine = HeadsetOperationLearning()
        assert(machine.edge(button, down: true, now: 0) == [.pressed])
        assert(machine.edge(button, down: false, now: 0.1).isEmpty)
        assert(machine.tick(now: 0.49) == [.recognized(.init(signal: button, gesture: .click))])
        machine = HeadsetOperationLearning()
        _ = machine.edge(button, down: true, now: 1); _ = machine.edge(button, down: false, now: 1.1)
        _ = machine.edge(button, down: true, now: 1.2)
        assert(machine.edge(button, down: false, now: 1.3) == [.recognized(.init(signal: button, gesture: .doubleClick))])
        assert(machine.tick(now: 2).isEmpty)
        machine = HeadsetOperationLearning()
        _ = machine.edge(button, down: true, now: 3)
        assert(machine.tick(now: 3.71) == [.holding])
        assert(machine.edge(button, down: false, now: 4) == [.recognized(.init(signal: button, gesture: .hold))])
        machine = HeadsetOperationLearning(expected: .doubleClick)
        _ = machine.edge(button, down: true, now: 5); _ = machine.edge(button, down: false, now: 5.1)
        assert(machine.tick(now: 5.5) == [.mismatch(.click)])
        _ = machine.edge(button, down: true, now: 6); _ = machine.edge(button, down: false, now: 6.1)
        _ = machine.edge(button, down: true, now: 6.2)
        assert(machine.edge(button, down: false, now: 6.3) == [.recognized(.init(signal: button, gesture: .doubleClick))])
        var other = button; other.usage = 0xE9
        machine = HeadsetOperationLearning()
        _ = machine.edge(button, down: true, now: 7); _ = machine.edge(button, down: false, now: 7.05)
        _ = machine.edge(other, down: true, now: 7.15); _ = machine.edge(other, down: false, now: 7.2)
        assert(machine.tick(now: 7.6).filter { if case .recognized = $0 { return true }; return false }.count == 2)
        machine = HeadsetOperationLearning(); assert(machine.tick(now: 50).isEmpty)
    }

    static func tapGestures() {
        var taps = HeadsetTapGesture()
        assert(taps.tap(now: 0, doubleEnabled: true).isEmpty)
        assert(taps.tick(now: 0.38).isEmpty)
        assert(taps.tick(now: 0.381) == [.click])
        assert(taps.tick(now: 1).isEmpty)

        taps = HeadsetTapGesture()
        assert(taps.tap(now: 0, doubleEnabled: true).isEmpty)
        assert(taps.tap(now: 0.2, doubleEnabled: true) == [.doubleClick])
        assert(taps.tick(now: 1).isEmpty) // A double must not also execute its first click.
        assert(taps.tap(now: 2, doubleEnabled: true).isEmpty)
        assert(taps.tap(now: 2.5, doubleEnabled: true) == [.click])
        assert(taps.tick(now: 2.881) == [.click])

        taps = HeadsetTapGesture()
        assert(taps.tap(now: 0, doubleEnabled: true).isEmpty)
        assert(taps.tap(now: 0.38, doubleEnabled: true) == [.doubleClick])
        assert(taps.tick(now: 1).isEmpty)
        assert(taps.tap(now: 2, doubleEnabled: true).isEmpty)
        taps.cancel()
        assert(taps.tick(now: 3).isEmpty)
        assert(taps.tap(now: 4, doubleEnabled: false) == [.click])
        assert(taps.tap(now: 4.2, doubleEnabled: false) == [.click])
        assert(taps.tick(now: 5).isEmpty)
    }

    static func volumeLearning() {
        let volume = HeadsetSignal(kind: .volume, device: "audio-test", name: "test audio", usage: 1, step: 0.0625)
        assert(HeadsetOperationLearning.supports(.click, device: volume))
        assert(HeadsetOperationLearning.supports(.doubleClick, device: volume))
        assert(!HeadsetOperationLearning.supports(.hold, device: volume))
        let click = HeadsetOperationLearning.Update.recognized(.init(signal: volume, gesture: .click))
        let double = HeadsetOperationLearning.Update.recognized(.init(signal: volume, gesture: .doubleClick))

        let singlePresets: [HeadsetRule.Gesture?] = [nil, .click]
        for preset in singlePresets {
            var machine = HeadsetOperationLearning(expected: preset)
            assert(machine.volume(volume, now: 0).isEmpty)
            assert(machine.tick(now: 0.38).isEmpty)
            assert(machine.tick(now: 0.381) == [click])
            assert(machine.tick(now: 1).isEmpty)
        }
        let doublePresets: [HeadsetRule.Gesture?] = [nil, .doubleClick]
        for preset in doublePresets {
            var machine = HeadsetOperationLearning(expected: preset)
            assert(machine.volume(volume, now: 0).isEmpty)
            assert(machine.volume(volume, now: 0.2) == [double])
            assert(machine.tick(now: 1).isEmpty)
        }

        var machine = HeadsetOperationLearning(expected: .doubleClick)
        assert(machine.volume(volume, now: 0).isEmpty)
        assert(machine.tick(now: 0.4) == [.mismatch(.click)])
        assert(machine.volume(volume, now: 1).isEmpty)
        assert(machine.volume(volume, now: 1.2) == [double])
        machine = HeadsetOperationLearning(expected: .click)
        assert(machine.volume(volume, now: 0).isEmpty)
        assert(machine.volume(volume, now: 0.2) == [.mismatch(.doubleClick)])
        assert(machine.tick(now: 1).isEmpty)

        var down = volume; down.usage = -1
        var otherDevice = volume; otherDevice.device = "other-audio-test"
        for other in [down, otherDevice] {
            machine = HeadsetOperationLearning()
            assert(machine.volume(volume, now: 0).isEmpty)
            assert(machine.volume(other, now: 0.2).isEmpty)
            let updates = machine.tick(now: 0.6)
            assert(updates.count == 2 && updates.contains(click))
            assert(updates.contains(.recognized(.init(signal: other, gesture: .click))))
        }

        // A changed step must not combine with the pending tap of the same identity.
        var changedStep = volume; changedStep.step = 0.08
        machine = HeadsetOperationLearning()
        assert(machine.volume(volume, now: 0).isEmpty)
        let updates = machine.volume(changedStep, now: 0.2) + machine.tick(now: 0.6)
        assert(updates.count == 2 && updates.contains(click))
        assert(updates.contains(.recognized(.init(signal: changedStep, gesture: .click))))

        // Noise inside the calibration tolerance still permits a double.
        var nearStep = volume; nearStep.step = 0.066
        machine = HeadsetOperationLearning()
        assert(machine.volume(volume, now: 0).isEmpty)
        let nearUpdates = machine.volume(nearStep, now: 0.2)
        assert(nearUpdates.count == 1)
        if case .recognized(let operation)? = nearUpdates.first { assert(operation.gesture == .doubleClick) }
        else { assertionFailure("A compatible step must recognize double-click") }

        var invalid = volume; invalid.step = nil
        machine = HeadsetOperationLearning()
        assert(machine.volume(invalid, now: 0).isEmpty && machine.tick(now: 1).isEmpty)
        machine = HeadsetOperationLearning()
        assert(machine.volume(volume, now: 0).isEmpty)
        machine = HeadsetOperationLearning()
        assert(machine.tick(now: 1).isEmpty)
    }

    static func volumeRestorationGate() {
        var legacy = HeadsetClickGate(baseline: 0.5, step: 0.0625)
        assert(legacy.observe(0.5625, now: 0) == .right)
        assert(legacy.observe(0.5, now: 0.05) == nil && !legacy.restoring)
        assert(legacy.observe(0.5625, now: 0.2) == nil) // Preserve the default 0.6-second debounce.
        assert(legacy.observe(0.5625, now: 0.6) == .right)

        var gate = HeadsetClickGate(baseline: 0.5, step: 0.0625, minimumInterval: 0)
        var taps = HeadsetTapGesture()
        assert(gate.observe(0.5625, now: 0) == .right)
        assert(taps.tap(now: 0, doubleEnabled: true).isEmpty)
        assert(gate.observe(0.5, now: 0.05) == nil && !gate.restoring)
        assert(gate.observe(0.5, now: 0.1) == nil)
        assert(gate.observe(0.5625, now: 0.2) == .right)
        assert(taps.tap(now: 0.2, doubleEnabled: true) == [.doubleClick])
        assert(gate.observe(0.5, now: 0.25) == nil)
        assert(taps.tick(now: 1).isEmpty)

        gate = HeadsetClickGate(baseline: 0.5, step: 0.0625, minimumInterval: 0)
        taps = HeadsetTapGesture()
        assert(gate.observe(0.4375, now: 0) == .left)
        assert(taps.tap(now: 0, doubleEnabled: true).isEmpty)
        assert(gate.observe(0.5, now: 0.2) == nil)
        assert(taps.tick(now: 0.4) == [.click]) // Restoring volume is not a second physical tap.
    }

    static func ab13xCapabilities() {
        let signal = HeadsetSignal(kind: .hid, device: "31:2849:test", name: "AB13X test", vendor: 31, product: 2849, usage: 0xCD)
        for usage in [0xCD, 0xE9, 0xEA] {
            var button = signal; button.usage = usage
            let supportsDouble = usage != 0xEA
            assert(HeadsetOperationLearning.supports(.doubleClick, device: button) == supportsDouble)
            assert(HeadsetRule(signal: button, gesture: .doubleClick, action: .spriteWake).valid == supportsDouble)
            assert(HeadsetRule(signal: button, gesture: .click, action: .spriteWake).valid)
            if supportsDouble {
                var machine = HeadsetOperationLearning(expected: .doubleClick)
                _ = machine.edge(button, down: true, now: 0)
                _ = machine.edge(button, down: false, now: 0.1)
                _ = machine.edge(button, down: true, now: 0.2)
                assert(machine.edge(button, down: false, now: 0.3) == [.recognized(.init(signal: button, gesture: .doubleClick))])
                assert(machine.tick(now: 1).isEmpty)
            }
        }
        var device = signal; device.usage = 0 // Device picker represents capability before an individual key is learned.
        assert(HeadsetOperationLearning.supports(.doubleClick, device: device))
        var otherModel = signal; otherModel.product = 2850; otherModel.usage = 0xEA
        assert(HeadsetOperationLearning.supports(.doubleClick, device: otherModel))
        assert(HeadsetRule(signal: otherModel, gesture: .doubleClick, action: .spriteWake).valid)
    }

    static func rulePersistence() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pocketdesk-headset-rule-tests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rules.json")
        let volume = HeadsetSignal(kind: .volume, device: "store-audio-test", name: "test audio", usage: 1, step: 0.0625)
        let click = HeadsetRule(id: "test-click", signal: volume, gesture: .click, action: .spriteWake)
        let double = HeadsetRule(id: "test-double", signal: volume, gesture: .doubleClick, action: .spriteEnd)
        assert(click.valid && double.valid)
        assert(!HeadsetRule(signal: volume, gesture: .hold, action: .spriteWake).valid)
        do {
            let store = HeadsetRuleStore(file: file)
            try store.save(click)
            try store.save(double)
            let reloaded = HeadsetRuleStore(file: file)
            assert(reloaded.loadIssue == nil && reloaded.rules == [click, double])
            assert(reloaded.matching(volume, gesture: .click, app: nil) == click)
            assert(reloaded.matching(volume, gesture: .doubleClick, app: nil) == double)
            assert(reloaded.matching(volume, gesture: .hold, app: nil) == nil)
            assert(reloaded.controls(volume))

            var duplicate = double; duplicate.id = "duplicate-double"
            expectSaveError(duplicate, store: reloaded, code: 2)
            assert(reloaded.rules == [click, double])
            assert(HeadsetRuleStore(file: file).rules == [click, double])

            var scoped = double; scoped.id = "scoped-double"; scoped.scope = "com.example.test"
            try reloaded.save(scoped)
            assert(reloaded.matching(volume, gesture: .doubleClick, app: "com.example.test") == scoped)
            assert(reloaded.matching(volume, gesture: .doubleClick, app: "com.example.other") == double)

            var differentStep = volume; differentStep.usage = -1; differentStep.step = 0.08
            let incompatible = HeadsetRule(id: "incompatible-step", signal: differentStep, gesture: .click, action: .spriteWake)
            expectSaveError(incompatible, store: reloaded, code: 3)
            assert(HeadsetRuleStore(file: file).rules == [click, double, scoped])
        } catch { fatalError("Temporary headset rule persistence failed: \(error)") }
    }

    static func expectSaveError(_ rule: HeadsetRule, store: HeadsetRuleStore, code: Int) {
        do { try store.save(rule); assertionFailure("Expected rule save rejection") }
        catch { assert((error as NSError).domain == "HeadsetMapping" && (error as NSError).code == code) }
    }
}
