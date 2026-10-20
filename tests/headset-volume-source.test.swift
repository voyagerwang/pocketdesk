/**
 * [INPUT]: 依赖真实音量来源票据、鼠标 Slider 音量语义分类和操作学习状态机；鼠标/时间/媒体键均为内存样本。
 * [OUTPUT]: 验证普通点击/非音量滑块不取消或冷却、核验超过80ms仍保留票据、音量滑块点击/持续拖动排除，以及迟到命中、键盘来源和耳机双击的边界。
 * [POS]: tests 的耳机音量来源回归；不读取 AX、改变音量、安装监听、触发录音或写正式配置。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// These fixtures exercise source filtering and learning only. They never invoke
/// an action, change system volume, install an event tap or write configuration.
@main struct HeadsetVolumeSourceTests {
    struct Fixture {
        var source = HeadsetVolumeSourceGate()
        var learning = HeadsetOperationLearning()
        var recognized: [HeadsetOperationLearning.Update] = []

        mutating func observe(now: Double) -> HeadsetVolumeSourceGate.Ticket? {
            source.ticket(now: now)
        }
        mutating func confirm(_ ticket: HeadsetVolumeSourceGate.Ticket, signal: HeadsetSignal, now: Double) -> [HeadsetOperationLearning.Update] {
            guard source.allows(ticket, now: now) else { return [] }
            let updates = learning.volume(signal, now: ticket.observedAt)
            recognized += updates
            return updates
        }
        mutating func exclude(now: Double) {
            source.exclude(now: now)
            learning.cancelVolume()
        }
        mutating func tick(now: Double) -> [HeadsetOperationLearning.Update] {
            let updates = learning.tick(now: now)
            recognized += updates
            return updates
        }
    }

    static let signal = HeadsetSignal(kind: .volume, device: "source-test-audio", name: "Test audio", usage: 1, step: 0.0625)
    static let delay = HeadsetVolumeSourceGate.confirmationDelay

    static func main() {
        confirmationAndSuppression()
        notificationOrdering()
        headsetDoubleStillWorks()
        keyboardCancelsPendingClick()
        volumeCancellationPreservesHID()
        invalidTimes()
        nativeEventClassification()
        mouseClickAttribution()
        wrapperUsesSameGate()
        print("PASS volume source ordering, ordinary/non-volume mouse click without cancellation or cooldown, delayed verification, volume slider drag exclusion, late-pointer isolation, double-click and invalid-time guards; no physical input or action execution")
    }

    static func confirmationAndSuppression() {
        assert(delay > 0 && delay < HeadsetGesture.doubleInterval)
        var source = HeadsetVolumeSourceGate()
        let ticket = source.ticket(now: 0)!
        assert(ticket.observedAt == 0)
        assert(!source.allows(ticket, now: delay - 0.0001))
        assert(source.allows(ticket, now: delay))

        source.exclude(now: 0.01)
        assert(!source.allows(ticket, now: 1)) // Expiry must never revalidate an old candidate.
        assert(source.ticket(now: 0.809) == nil)
        let afterSuppression = source.ticket(now: 0.811)!
        assert(afterSuppression.revision != ticket.revision)
        assert(!source.allows(afterSuppression, now: 0.811 + delay - 0.0001))
        assert(source.allows(afterSuppression, now: 0.811 + delay + 0.0001))

        source.exclude(now: 0.82)
        assert(!source.allows(afterSuppression, now: 2))
        source.exclude(now: 1.5) // A second keyboard press extends the suppression window.
        assert(source.ticket(now: 2.299) == nil)
        assert(source.ticket(now: 2.301) != nil)

        source = HeadsetVolumeSourceGate()
        source.exclude(now: 0)
        assert(source.ticket(now: 0.7999) == nil)
        assert(source.ticket(now: 0.8) != nil)
    }

    static func notificationOrdering() {
        var keyboardFirst = Fixture()
        keyboardFirst.exclude(now: 0)
        assert(keyboardFirst.observe(now: 0.01) == nil)
        assert(keyboardFirst.tick(now: 1).isEmpty)
        assert(keyboardFirst.recognized.isEmpty)

        var audioFirst = Fixture()
        let candidate = audioFirst.observe(now: 0)!
        audioFirst.exclude(now: 0.01)
        assert(audioFirst.confirm(candidate, signal: signal, now: delay + 0.01).isEmpty)
        assert(audioFirst.tick(now: 1).isEmpty)
        assert(audioFirst.recognized.isEmpty)

        // The suppression window is temporary; an independent later headset tap can be learned.
        let later = audioFirst.observe(now: 1.1)!
        assert(audioFirst.confirm(later, signal: signal, now: 1.1 + delay + 0.001).isEmpty)
        assert(audioFirst.tick(now: 1.5) == [.recognized(.init(signal: signal, gesture: .click))])
    }

    static func headsetDoubleStillWorks() {
        var fixture = Fixture()
        let first = fixture.observe(now: 0)!
        assert(fixture.confirm(first, signal: signal, now: delay).isEmpty)
        let second = fixture.observe(now: 0.2)!
        assert(fixture.confirm(second, signal: signal, now: 0.2 + delay + 0.001) == [.recognized(.init(signal: signal, gesture: .doubleClick))])
        assert(fixture.tick(now: 1).isEmpty)
        assert(fixture.recognized.count == 1)

        // Use observed time for pairing, so unequal callback scheduling cannot turn a real double into two singles.
        fixture = Fixture()
        let delayedFirst = fixture.observe(now: 0)!
        assert(fixture.confirm(delayedFirst, signal: signal, now: delay + 0.01).isEmpty)
        let delayedSecond = fixture.observe(now: 0.37)!
        assert(fixture.confirm(delayedSecond, signal: signal, now: 0.37 + delay + 0.03) == [.recognized(.init(signal: signal, gesture: .doubleClick))])
        assert(fixture.tick(now: 1).isEmpty)
    }

    static func keyboardCancelsPendingClick() {
        var fixture = Fixture()
        let first = fixture.observe(now: 0)!
        assert(fixture.confirm(first, signal: signal, now: delay).isEmpty)
        fixture.exclude(now: 0.15)
        assert(fixture.observe(now: 0.2) == nil)
        assert(fixture.tick(now: 1).isEmpty)
        assert(fixture.recognized.isEmpty)

        // Exclusion after the second audio notification also invalidates its outstanding ticket.
        fixture = Fixture()
        let accepted = fixture.observe(now: 0)!
        assert(fixture.confirm(accepted, signal: signal, now: delay).isEmpty)
        let outstanding = fixture.observe(now: 0.2)!
        fixture.exclude(now: 0.21)
        assert(fixture.confirm(outstanding, signal: signal, now: 0.2 + delay + 0.001).isEmpty)
        assert(fixture.tick(now: 1).isEmpty)
        assert(fixture.recognized.isEmpty)
    }

    static func volumeCancellationPreservesHID() {
        var learning = HeadsetOperationLearning()
        let hid = HeadsetSignal(kind: .hid, device: "1:2:source-test", name: "Test HID", vendor: 1, product: 2, usage: 0xCD)
        assert(learning.edge(hid, down: true, now: 0) == [.pressed])
        assert(learning.edge(hid, down: false, now: 0.1).isEmpty)
        assert(learning.volume(signal, now: 0.2).isEmpty)
        learning.cancelVolume()
        assert(learning.tick(now: 0.5) == [.recognized(.init(signal: hid, gesture: .click))])
        assert(learning.tick(now: 1).isEmpty)
    }

    static func invalidTimes() {
        var source = HeadsetVolumeSourceGate()
        for time in [Double.nan, Double.infinity, -Double.infinity, -0.001] {
            assert(source.ticket(now: time) == nil)
        }
        let ticket = source.ticket(now: 1)!
        for time in [Double.nan, Double.infinity, -Double.infinity, 0.99] {
            assert(!source.allows(ticket, now: time))
        }
        assert(!source.allows(ticket, now: 1 + delay - 0.0001))
        assert(source.allows(ticket, now: 1 + delay + 0.0001))
        assert(!source.allows(.init(revision: ticket.revision, observedAt: .nan), now: 2))
        assert(!source.allows(.init(revision: ticket.revision, observedAt: -1), now: 2))
        assert(!source.allows(.init(revision: ticket.revision + 1, observedAt: 1), now: 2))
    }

    static func nativeEventClassification() {
        assert(HeadsetVolumeSourceEvent.observationTime(notifiedAt: 0.37, now: 0.41) == 0.37)
        assert(HeadsetVolumeSourceEvent.observationTime(notifiedAt: nil, now: 0.41) == 0.41)
        for invalid in [-1.0, Double.nan, Double.infinity, 0.42] {
            assert(HeadsetVolumeSourceEvent.observationTime(notifiedAt: invalid, now: 0.41) == 0.41)
        }
        func media(_ key: Int, state: Int = 0xA) -> Int { (key << 16) | (state << 8) }
        for key in [0, 1] {
            assert(HeadsetVolumeSourceEvent.isSystemVolume(type: 14, subtype: 8, data1: media(key), marker: 0))
            assert(HeadsetVolumeSourceEvent.isSystemVolume(type: 14, subtype: 8, data1: media(key, state: 0xB), marker: 0))
            assert(!HeadsetVolumeSourceEvent.isSystemVolume(type: 14, subtype: 8, data1: media(key), marker: HeadsetMarker))
            assert(!HeadsetVolumeSourceEvent.isSystemVolume(type: 10, subtype: 8, data1: media(key), marker: 0))
            assert(!HeadsetVolumeSourceEvent.isSystemVolume(type: 14, subtype: 7, data1: media(key), marker: 0))
        }
        for unrelatedKey in [2, 7, 16, 0xFFFF] {
            assert(!HeadsetVolumeSourceEvent.isSystemVolume(type: 14, subtype: 8, data1: media(unrelatedKey), marker: 0))
        }
        for usage in [0xE9, 0xEA] {
            assert(HeadsetVolumeSourceEvent.isKeyboardVolume(page: 12, usage: usage, keyboardCollection: true, pairedHeadset: false))
            assert(!HeadsetVolumeSourceEvent.isKeyboardVolume(page: 12, usage: usage, keyboardCollection: true, pairedHeadset: true))
            assert(!HeadsetVolumeSourceEvent.isKeyboardVolume(page: 12, usage: usage, keyboardCollection: false, pairedHeadset: false))
            assert(!HeadsetVolumeSourceEvent.isKeyboardVolume(page: 1, usage: usage, keyboardCollection: true, pairedHeadset: false))
        }
        for unrelatedUsage in [0x04, 0xCD, 0xB5, 0] {
            assert(!HeadsetVolumeSourceEvent.isKeyboardVolume(page: 12, usage: unrelatedUsage, keyboardCollection: true, pairedHeadset: false))
        }
    }

    static func wrapperUsesSameGate() {
        let source = HeadsetVolumeSourceGuard() // An isolated wrapper, never the production singleton.
        let ticket = source.ticket(now: 0)!
        assert(!source.allows(ticket, now: delay - 0.0001))
        assert(source.allows(ticket, now: delay))
        source.exclude(now: 0.01)
        assert(!source.allows(ticket, now: 1))
        assert(source.ticket(now: 0.809) == nil)
        let next = source.ticket(now: 0.811)!
        assert(source.allows(next, now: 0.811 + delay + 0.0001))
        let pointer = source.beginPointer(now: 1)!
        let clicked = source.ticket(now: 1.01)!
        assert(!source.allows(clicked, now: 1.1))
        assert(!source.resolvePointer(pointer, slider: false, now: 1.02))
        source.endPointer(now: 1.03)
        assert(source.allows(clicked, now: 1.1))
    }

    static func mouseClickAttribution() {
        assert(HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXSlider", labels: ["Output Volume"]))
        assert(HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXSlider", labels: ["输出音量"]))
        assert(HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXSlider", labels: ["volume-slider"]))
        assert(!HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXTextArea", labels: ["Volume"]))
        assert(!HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXSlider", labels: ["Brightness", "显示亮度"]))
        assert(!HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXSlider", labels: ["Playback position", "播放进度"]))
        assert(!HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXSlider", labels: ["Volumetric zoom"]))
        assert(!HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXSlider", labels: []))

        // ---------- 点输入框后马上按耳机，不再被 800ms 全局鼠标冷却吞掉 ----------
        var source = HeadsetVolumeSourceGate()
        let click = source.beginPointer(now: 0)!
        let ear = source.ticket(now: 0.01)!
        assert(!source.allows(ear, now: 0.09)) // 命中未确认前不执行。
        assert(source.checkingPointer)
        assert(!source.resolvePointer(click, slider: false, now: 0.03))
        source.endPointer(now: 0.04)
        assert(!source.checkingPointer && !source.pointerVolumeActive(now: 0.09))
        assert(source.allows(ear, now: 0.091)) // 原票据有效，无额外冷却。

        // AX 慢于原80ms来源确认时，只保留候选；核验完成后同票据执行。
        source = HeadsetVolumeSourceGate()
        let slow = source.beginPointer(now: 0)!
        let retained = source.ticket(now: 0.01)!
        assert(source.checkingPointer && !source.allows(retained, now: 0.09))
        assert(source.checkingPointer && !source.allows(retained, now: 0.14))
        assert(!source.resolvePointer(slow, slider: false, now: 0.16))
        assert(source.allows(retained, now: 0.17))

        // 非音量滑块不提供取消依据，哪怕其标签或读回稍晚。
        source = HeadsetVolumeSourceGate()
        let unrelated = source.beginPointer(now: 0)!
        let volumeWhileScrubbing = source.ticket(now: 0.01)!
        let audioSource = HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXSlider", labels: ["Brightness"])
        assert(!source.resolvePointer(unrelated, slider: audioSource, now: 0.03))
        assert(!source.pointerVolumeActive(now: 0.09))
        assert(source.allows(volumeWhileScrubbing, now: 0.091))

        // 普通点击也不能撤销之前已确认的键盘音量排除。
        source.exclude(now: 0.1)
        let ordinary = source.beginPointer(now: 0.2)!
        assert(!source.resolvePointer(ordinary, slider: false, now: 0.21))
        assert(source.ticket(now: 0.89) == nil)
        assert(source.ticket(now: 0.901) != nil)

        // ---------- 真正拖动滑块超过冷却期，仍禁止由其音量变化唤醒 ----------
        source = HeadsetVolumeSourceGate()
        let slider = source.beginPointer(now: 0)!
        let outstanding = source.ticket(now: 0.01)!
        assert(source.resolvePointer(slider, slider: true, now: 0.03))
        assert(source.pointerVolumeActive(now: 0.03))
        assert(!source.allows(outstanding, now: 0.9))
        assert(source.ticket(now: 2) == nil)
        source.endPointer(now: 2.1)
        assert(source.ticket(now: 2.89) == nil)
        assert(source.ticket(now: 2.901) != nil)

        // 快速松开仍等待同一轮命中；迟到旧鼠标结果不能污染新点击。
        source = HeadsetVolumeSourceGate()
        let released = source.beginPointer(now: 0)!
        source.endPointer(now: 0.01)
        assert(source.resolvePointer(released, slider: true, now: 0.02))
        assert(source.ticket(now: 0.821) != nil)
        source = HeadsetVolumeSourceGate()
        let old = source.beginPointer(now: 0)!
        let newest = source.beginPointer(now: 0.01)!
        assert(!source.resolvePointer(old, slider: true, now: 0.02))
        assert(!source.resolvePointer(newest, slider: false, now: 0.03))
        let accepted = source.ticket(now: 0.04)!
        assert(source.allows(accepted, now: 0.121))
    }
}
