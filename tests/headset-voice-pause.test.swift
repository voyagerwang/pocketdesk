/**
 * [INPUT]: 依赖 HeadsetMappingActions 的策略、转写、时钟与取消/接续状态注入，复用真实规则、文字停顿判定及 HeadsetKeyEmitter 事件构造。
 * [OUTPUT]: 隔离验证语音停顿、生命周期及设备策略、所有唤醒手势取消、单击/按住的接收框接续与同步退休；核验 Option 同源 HID 状态、左右标记与 Esc 私有状态，事件只保存在内存。
 * [POS]: tests 的语音结束回归，覆盖生产动作路由，不启动单例、录音、应用计时器或真实输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import ApplicationServices

private final class VoiceHarness {
    struct KeyEvent {
        let code: Int64
        let down: Bool
    }
    var now = 0.0
    var focus: pid_t? = 123
    var allowed = true
    var keysAvailable = true
    var normalText: String? = ""
    var spriteText: String? = ""
    var preferences: [String: HeadsetClickPreference] = [:]
    var preferenceRequests: [String] = []
    var preparations: [(Bool) -> Void] = []
    var keys: [KeyEvent] = []
    var normalTextReads = 0
    var spriteTextReads = 0
    var optionPosts = 0
    var normalEnds = 0
    var normalCancels = 0
    var spriteBegins = 0
    var spriteEnds = 0
    var spriteCancels = 0
    var spriteRecording = false
    var spriteInputOpen = false
    var spriteStarting = false
    var spriteDismissals = 0
    var spriteWakes = 0
    var spriteRouteStarts = 0
    var spriteRouteEnds = 0
    var spriteContinueRequests: [(HeadsetKey, Bool)] = []
    var spriteHeldRequests: [(HeadsetKey, Bool)] = []
    var actions: HeadsetMappingActions!

    init() {
        actions = HeadsetMappingActions(emitter: HeadsetKeyEmitter { [unowned self] event in
            keys.append(.init(code: event.getIntegerValueField(.keyboardEventKeycode),
                              down: event.flags.contains(.maskAlternate)))
        })
        actions.environmentAllows = { [unowned self] in allowed }
        actions.foregroundPID = { [unowned self] in focus }
        actions.voiceKeysAvailable = { [unowned self] in keysAvailable }
        actions.voiceClock = { [unowned self] in now }
        actions.voiceLog = { _ in }
        actions.voicePreference = { [unowned self] uid in
            preferenceRequests.append(uid)
            return preferences[uid]
        }
        actions.normalVoiceText = { [unowned self] in normalTextReads += 1; return normalText }
        actions.spriteText = { [unowned self] in spriteTextReads += 1; return spriteText }
        actions.prepareNormalVoice = { [unowned self] completion in preparations.append(completion) }
        actions.cancelNormalVoice = { [unowned self] in normalCancels += 1 }
        actions.normalOptionPosted = { [unowned self] in optionPosts += 1 }
        actions.endNormalVoice = { [unowned self] in normalEnds += 1 }
        actions.spriteBegin = { [unowned self] _, _ in
            spriteBegins += 1
            spriteRecording = true
            spriteInputOpen = true
            spriteText = ""
            return true
        }
        actions.spriteEnd = { [unowned self] in spriteRecording = false; spriteEnds += 1 }
        actions.spriteCancel = { [unowned self] in spriteRecording = false; spriteCancels += 1 }
        actions.spriteBusy = { [unowned self] in spriteRecording }
    }

    func useSpriteInputRoutes() {
        actions.spriteWake = { [unowned self] in spriteWakes += 1; spriteInputOpen = true; return true }
        actions.spriteDismissInput = { [unowned self] in
            guard spriteInputOpen else { return false }
            spriteDismissals += 1; spriteInputOpen = false; spriteRecording = false; spriteStarting = false
            return true
        }
        actions.spriteContinueVoice = { [unowned self] key, toggle in
            spriteContinueRequests.append((key, toggle))
            guard spriteInputOpen else { return .unavailable }
            if spriteStarting { return .waiting }
            if spriteRecording {
                spriteRecording = false; spriteRouteEnds += 1
                return .ended
            }
            spriteRecording = true; spriteRouteStarts += 1
            return .started
        }
        actions.spriteContinueHeldVoice = { [unowned self] key, toggle in
            spriteHeldRequests.append((key, toggle))
            guard spriteInputOpen else { return .unavailable }
            if spriteStarting && !spriteRecording { return .waiting }
            actions.retireSpriteRecording()
            if !spriteRecording { spriteRecording = true; spriteRouteStarts += 1 }
            return .started
        }
    }

    func usePause(device: String = "device-A", seconds: Double = 3, mode: HeadsetFinishMode = .textPause) {
        // 默认音量控制关闭时，自定义操作仍应采用这个设备的结束策略。
        preferences[device] = .init(uid: device, name: device, enabled: false, step: nil,
                                   finishMode: mode, textPauseSeconds: seconds)
    }
    func resolvePreparation(_ ready: Bool = true) {
        precondition(!preparations.isEmpty)
        preparations.removeFirst()(ready)
    }
    func tick(_ time: Double) { now = time; actions.tick() }
    func startNormal(_ rule: HeadsetRule) { actions.begin(rule); resolvePreparation() }
}

@main struct HeadsetVoicePauseTests {
    static func main() {
        keyEmitterKeepsModifierSourceState()
        textChangesExtendDeadline()
        noTranscriptDoesNotEnd()
        manualAndHoldKeepTheirEndBoundary()
        toggleEndsWithSecondTap()
        preparationDoesNotStartCountdown()
        obsoletePreparationCannotStartVoice()
        interruptionClearsCountdown()
        spriteUsesItsOwnTranscript()
        spriteStartupFailureKeepsFeedback()
        explicitSpriteCancelStillInterrupts()
        spriteEnvironmentInterruptionStillCancels()
        unavailableTranscriptRestartsCountdown()
        strategyDoesNotCrossDevices()
        finalTranscriptStillWaitsForSendGate()
        spriteInputRepeatedTapDismisses()
        spriteContinuationPrecedesModifierGate()
        continuedSameVoiceRuleEndsOnce()
        waitingContinuationKeepsOwnerAndDeadline()
        crossSideContinuationPreservesReceiver()
        retiredSpriteOwnerCannotFinishRetry()
        unavailableContinuationAndHoldKeepOrdinaryVoice()
        heldVoiceContinuesReceiverUntilRelease()
        print("PASS custom headset voice pause: same-source HID modifiers and private ordinary keys, transcript renewal, unavailable-text suspension, single finish, empty/original guards, manual/hold/toggle, preparation generations, interruption, sprite text and startup-failure cleanup, explicit/environment cancellation, device isolation, final send gate, repeated sprite dismissal and receiver continuation before modifier gate; no physical input")
    }

    static func rule(action: HeadsetRule.Action = .voice, gesture: HeadsetRule.Gesture = .click,
                     device: String = "device-A", toggle: Bool = false) -> HeadsetRule {
        let signal: HeadsetSignal
        if gesture == .hold {
            signal = .init(kind: .hid, device: device, name: device, vendor: 1, product: 2, usage: 0xCD)
        } else {
            signal = .init(kind: .volume, device: device, name: device, usage: 1, step: 0.0625)
        }
        var result = HeadsetRule(signal: signal, gesture: gesture, action: action, key: HeadsetKey.parse("LeftOption"))
        result.voiceToggle = toggle
        assert(result.valid)
        return result
    }

    // -------------------- 输入法快捷键按下与释放的同源契约 --------------------
    static func keyEmitterKeepsModifierSourceState() {
        var events: [CGEvent] = []
        let emitter = HeadsetKeyEmitter { events.append($0) }
        for label in ["LeftOption", "RightOption"] {
            events.removeAll()
            let key = HeadsetKey.parse(label)!
            assert(emitter.set(key, down: true) && emitter.set(key, down: false))
            assert(events.count == 2)
            let sideFlag: UInt64 = key.code == 58 ? 0x20 : 0x40
            assert(events[0].type == .flagsChanged && events[1].type == .flagsChanged)
            assert(events[0].flags.rawValue == (key.flags | sideFlag) && events[1].flags.rawValue == 0,
                   "Option 按下保留对应左右标记，释放必须清空修饰键状态")
            for event in events {
                assert(event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue),
                       "修饰键按下与释放必须使用同一 HID 状态表，不能分别创建私有表")
                assert(event.getIntegerValueField(.keyboardEventKeycode) == Int64(key.code))
                assert(event.getIntegerValueField(.eventSourceUserData) == HeadsetMarker,
                       "自发事件必须保留耳机标记，避免识别器再次消费")
            }
        }
        events.removeAll()
        let escape = HeadsetKey.parse("Esc")!
        assert(emitter.tap(escape) && events.count == 2)
        assert(events[0].type == .keyDown && events[1].type == .keyUp && events.allSatisfy { $0.flags.rawValue == 0 })
        // 私有源的 -1 是创建请求；构造后的事件字段返回该私有表独有的动态 ID。
        let privateID = events[0].getIntegerValueField(.eventSourceStateID)
        assert(privateID != Int64(CGEventSourceStateID.hidSystemState.rawValue) &&
               privateID != Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        assert(emitter.tap(escape) && events.count == 4)
        assert(events.allSatisfy {
            $0.getIntegerValueField(.eventSourceStateID) == privateID &&
            $0.getIntegerValueField(.keyboardEventKeycode) == 53 &&
            $0.getIntegerValueField(.eventSourceUserData) == HeadsetMarker
        }, "普通 Esc 的重复按下与释放复用同一私有状态表，并保留键码和耳机事件标记")
    }

    // -------------------- 文字续期与幂等结束 --------------------
    static func textChangesExtendDeadline() {
        let h = VoiceHarness(); h.usePause(); h.normalText = "原有草稿"
        h.startNormal(rule())
        h.tick(10)
        assert(h.actions.busy && h.normalEnds == 0, "原文稳定不能当成本次转写")
        h.normalText = "原有草稿，新内容"; h.tick(11)
        h.tick(13.5)
        assert(h.normalEnds == 0)
        h.normalText = "原有草稿，新内容继续"; h.tick(13.5)
        h.tick(16.49)
        assert(h.actions.busy && h.normalEnds == 0, "每次文字变化都必须重新等待")
        h.tick(16.5)
        assert(!h.actions.busy && h.normalEnds == 1 && h.normalCancels == 0)
        assert(h.keys.map(\.down) == [true, false] && h.keys.allSatisfy { $0.code == 58 })
        h.tick(20); h.tick(30)
        assert(h.normalEnds == 1 && h.keys.count == 2, "重复轮询不能重复结束或发送快捷键")
        assert(h.spriteTextReads == 0)
    }

    static func noTranscriptDoesNotEnd() {
        let h = VoiceHarness(); h.usePause(); h.startNormal(rule())
        h.normalText = nil; h.tick(10)
        h.normalText = ""; h.tick(20)
        h.normalText = " \n "; h.tick(30); h.tick(100)
        assert(h.actions.busy && h.normalEnds == 0, "没有非空转写时必须继续等待")
        h.actions.cancel()
        assert(h.keys.map(\.down) == [true, false])
    }

    // -------------------- 手动、长按与切换快捷键 --------------------
    static func manualAndHoldKeepTheirEndBoundary() {
        for manual in [true, false] {
            let h = VoiceHarness()
            if manual { h.usePause(mode: .manual) }
            h.startNormal(rule())
            h.normalText = "说完了"; h.tick(1); h.tick(10)
            assert(h.actions.busy && h.normalEnds == 0, "手动或未配置策略不得自动结束")
            h.actions.finish()
            assert(h.normalEnds == 1 && !h.actions.busy)
        }
        let h = VoiceHarness(); h.usePause()
        h.startNormal(rule(gesture: .hold))
        h.normalText = "长按中的内容"; h.tick(1); h.tick(10)
        assert(h.actions.busy && h.normalEnds == 0, "长按必须等待松开")
        h.actions.finish()
        assert(h.normalEnds == 1 && h.keys.map(\.down) == [true, false])

        let sprite = VoiceHarness(); sprite.usePause()
        sprite.actions.begin(rule(action: .spriteVoice, gesture: .hold))
        sprite.spriteText = "长按小精灵"; sprite.tick(1); sprite.tick(10)
        assert(sprite.actions.busy && sprite.spriteEnds == 0)
        sprite.actions.finish()
        assert(sprite.spriteEnds == 1)
    }

    static func toggleEndsWithSecondTap() {
        let h = VoiceHarness(); h.usePause(seconds: 1)
        h.startNormal(rule(gesture: .doubleClick, toggle: true))
        assert(h.keys.map(\.down) == [true, false])
        h.normalText = "切换式语音"; h.tick(1); h.tick(2)
        assert(h.normalEnds == 1 && !h.actions.busy)
        assert(h.keys.map(\.down) == [true, false, true, false], "切换式结束需要第二次完整按下/释放")
        h.tick(5)
        assert(h.keys.count == 4 && h.normalEnds == 1)
    }

    // -------------------- 异步准备与取消代际 --------------------
    static func preparationDoesNotStartCountdown() {
        let h = VoiceHarness(); h.usePause()
        h.actions.begin(rule())
        h.normalText = "焦点准备期间的旧内容"; h.tick(50)
        assert(h.keys.isEmpty && h.normalEnds == 0 && h.normalTextReads == 0)
        h.resolvePreparation()
        h.tick(55)
        assert(h.actions.busy && h.normalEnds == 0, "基线必须在准备完成、快捷键发出前捕获")
        h.normalText = "真正的转写"; h.tick(56); h.tick(58.99)
        assert(h.normalEnds == 0)
        h.tick(59)
        assert(h.normalEnds == 1)
    }

    static func obsoletePreparationCannotStartVoice() {
        let h = VoiceHarness(); h.usePause()
        let r = rule()
        h.actions.begin(r)
        let obsolete = h.preparations.removeFirst()
        h.actions.cancel()
        h.actions.begin(r)
        obsolete(true)
        assert(h.keys.isEmpty && h.optionPosts == 0 && h.actions.busy)
        h.resolvePreparation()
        assert(h.keys.count == 1 && h.optionPosts == 1)
        h.normalText = "新一轮"; h.tick(1); h.tick(4)
        assert(h.normalEnds == 1 && !h.actions.busy)

        let rejected = VoiceHarness(); rejected.usePause()
        rejected.actions.begin(rule()); rejected.resolvePreparation(false)
        rejected.tick(100)
        assert(!rejected.actions.busy && rejected.keys.isEmpty && rejected.normalEnds == 0)
    }

    static func interruptionClearsCountdown() {
        for cause in 0..<3 {
            let h = VoiceHarness(); h.usePause(); h.startNormal(rule())
            h.normalText = "未结束的内容"; h.tick(1)
            if cause == 0 { h.actions.cancel() }
            else if cause == 1 { h.focus = 456; h.tick(2) }
            else { h.allowed = false; h.tick(2) }
            h.tick(10)
            assert(!h.actions.busy && h.normalEnds == 0 && h.normalCancels == 1)
            assert(h.keys.map(\.down) == [true, false])
            h.allowed = true; h.focus = 123; h.normalText = "新基线"
            h.now = 20; h.startNormal(rule()); h.tick(30)
            assert(h.actions.busy && h.normalEnds == 0, "旧倒计时不能结束后续录音")
            h.normalText = "新转写"; h.tick(31); h.tick(34)
            assert(h.normalEnds == 1 && !h.actions.busy)
        }
    }

    // -------------------- 小精灵同源文字与设备隔离 --------------------
    static func spriteUsesItsOwnTranscript() {
        let h = VoiceHarness(); h.usePause()
        h.spriteText = "上次残留"
        h.actions.begin(rule(action: .spriteVoice))
        assert(h.spriteText == "", "启动会清空原生接收框，应在启动成功后捕获基线")
        h.normalText = "普通输入的无关文字"; h.tick(1); h.tick(10)
        assert(h.actions.busy && h.spriteEnds == 0 && h.normalTextReads == 0)
        h.spriteText = "小精灵转写"; h.tick(11)
        h.focus = 456
        h.tick(13.99)
        assert(h.actions.busy && h.spriteEnds == 0, "小精灵焦点由自己的接收框管理")
        h.tick(14); h.tick(20)
        assert(!h.actions.busy && h.spriteEnds == 1 && h.normalEnds == 0 && h.keys.isEmpty)
    }

    // -------------------- 小精灵启动失败与取消边界 --------------------
    static func spriteStartupFailureKeepsFeedback() {
        let h = VoiceHarness(); h.usePause()
        let voice = rule(action: .spriteVoice)
        h.actions.begin(voice)
        assert(h.actions.busy && h.spriteRecording)
        // 启动焦点超时已由接收层停止录音；映射层不得再次取消可见的重试提示。
        h.spriteRecording = false
        h.tick(1); h.tick(10)
        assert(!h.actions.busy && h.actions.currentRuleID == nil,
               "小精灵自行停止后必须清理映射拥有者")
        assert(h.spriteCancels == 0 && h.spriteEnds == 0 && h.keys.isEmpty,
               "启动失败清理不得收起小精灵、再次结束录音或发按键")
        h.actions.begin(voice)
        assert(h.actions.busy && h.spriteRecording && h.spriteBegins == 2,
               "清理后同一操作可以重新启动补充")
        h.spriteText = "重试后的补充"; h.tick(11); h.tick(14)
        assert(!h.actions.busy && h.spriteEnds == 1 && h.spriteCancels == 0,
               "重试后的新转写仍按正常停顿结束一次")
    }

    static func explicitSpriteCancelStillInterrupts() {
        let h = VoiceHarness(); h.usePause()
        h.actions.begin(rule(action: .spriteVoice))
        h.actions.begin(rule(action: .cancel))
        assert(!h.actions.busy && !h.spriteRecording && h.spriteCancels > 0 && h.spriteEnds == 0,
               "明确取消操作仍通知接收层取消，不能误当作自行停止")
        let cancellations = h.spriteCancels
        h.tick(10)
        assert(h.spriteCancels == cancellations && h.keys.isEmpty,
               "明确取消后轮询不得重复取消或发送按键")
    }

    static func spriteEnvironmentInterruptionStillCancels() {
        let h = VoiceHarness(); h.usePause()
        h.actions.begin(rule(action: .spriteVoice))
        h.spriteText = "仍在录音的内容"; h.tick(1)
        assert(h.actions.busy && h.spriteRecording)
        h.allowed = false; h.tick(2); h.tick(10)
        assert(!h.actions.busy && !h.spriteRecording && h.spriteCancels == 1 && h.spriteEnds == 0,
               "录音尚在进行时环境中断仍必须取消，不能提交已有文字")
        assert(h.keys.isEmpty)
    }

    static func unavailableTranscriptRestartsCountdown() {
        for sprite in [false, true] {
            let h = VoiceHarness(); h.usePause()
            if sprite { h.actions.begin(rule(action: .spriteVoice)) }
            else { h.startNormal(rule()) }
            let text = "同一段仍在接收的转写"
            if sprite { h.spriteText = text } else { h.normalText = text }
            h.tick(1)
            if sprite { h.spriteText = nil } else { h.normalText = nil }
            h.tick(2); h.tick(9)
            assert(h.actions.busy && h.normalEnds == 0 && h.spriteEnds == 0,
                   "转写不可观察时必须暂停停顿判定")
            if sprite { h.spriteText = text } else { h.normalText = text }
            h.tick(10)
            assert(h.actions.busy && h.normalEnds == 0 && h.spriteEnds == 0,
                   "恢复相同文字也不能继承失焦期间的倒计时")
            h.tick(12.99)
            assert(h.actions.busy && h.normalEnds == 0 && h.spriteEnds == 0)
            h.tick(13); h.tick(20)
            assert(!h.actions.busy && h.normalEnds == (sprite ? 0 : 1) && h.spriteEnds == (sprite ? 1 : 0),
                   "恢复后必须重等完整三秒，且只结束一次")
        }
    }

    static func strategyDoesNotCrossDevices() {
        let h = VoiceHarness(); h.usePause(device: "device-A", seconds: 1)
        h.usePause(device: "device-B", seconds: 5)
        h.startNormal(rule(device: "device-B"))
        h.normalText = "设备 B 的转写"; h.tick(1); h.tick(2); h.tick(5.99)
        assert(h.actions.busy && h.normalEnds == 0)
        h.tick(6)
        assert(h.normalEnds == 1 && Set(h.preferenceRequests) == ["device-B"])

        let missing = VoiceHarness(); missing.usePause(device: "device-A")
        missing.startNormal(rule(device: "device-C"))
        missing.normalText = "设备 C 的转写"; missing.tick(1); missing.tick(100)
        assert(missing.actions.busy && missing.normalEnds == 0)
        assert(Set(missing.preferenceRequests) == ["device-C"])
        missing.actions.cancel()
    }

    static func finalTranscriptStillWaitsForSendGate() {
        let h = VoiceHarness(); h.usePause(seconds: 1); h.startNormal(rule())
        func ready(visible: Bool = false, stable: Double = 0.6, closed: Double = 0.6,
                   delay: Double = 0, immediate: Bool = false) -> Bool {
            HeadsetSendGate.ready(sameFocus: true, panelObserved: true, panelVisible: visible,
                                 textChanged: true, nonempty: true, recordingEnded: h.normalEnds == 1,
                                 stableFor: stable, closedFor: closed,
                                 delay: HeadsetVoiceTiming.sendWait(delay: delay, immediate: immediate))
        }
        assert(HeadsetVoiceTiming.sendWait(delay: 0, immediate: false) == 0.6)
        h.normalText = "初步转写"; h.tick(1)
        assert(!ready(stable: 100, closed: 100), "录音尚未结束时不能发送")
        h.tick(2)
        assert(h.normalEnds == 1)
        assert(!ready(visible: true, stable: 100, closed: 100), "结束后豆包面板仍可见时不能发送")
        h.normalText = "最后补齐的完整转写"
        assert(!ready(stable: 0, closed: 100), "最终文字更新后必须重算稳定窗口")
        assert(!ready(stable: 0.59, closed: 0.6))
        assert(!ready(stable: 0.6, closed: 0.59), "面板关闭也要经过完整稳定窗口")
        assert(ready(), "文字和面板稳定满 0.6 秒即发送，无需额外等待两秒")

        assert(HeadsetVoiceTiming.sendWait(delay: 2, immediate: false) == 2)
        assert(!ready(stable: 1.99, closed: 2, delay: 2), "显式选择两秒时仍遵守用户等待设置")
        assert(!ready(stable: 2, closed: 1.99, delay: 2))
        assert(ready(stable: 2, closed: 2, delay: 2))

        assert(HeadsetVoiceTiming.sendWait(delay: 2, immediate: true) == 0.4)
        assert(!ready(stable: 0.39, closed: 0.4, delay: 2, immediate: true))
        assert(!ready(stable: 0.4, closed: 0.39, delay: 2, immediate: true))
        assert(ready(stable: 0.4, closed: 0.4, delay: 2, immediate: true), "明确立即发送沿用 0.4 秒门禁")
        h.tick(10)
        assert(h.normalEnds == 1 && h.keys.count == 2)
    }

    // -------------------- 当前小精灵接收框的取消与跨侧接续 --------------------
    static func spriteInputRepeatedTapDismisses() {
        for action in [HeadsetRule.Action.spriteVoice, .spriteWake] {
            for gesture in [HeadsetRule.Gesture.click, .doubleClick, .hold] {
                for receiverStopped in [false, true] {
                    let h = VoiceHarness(); h.usePause(); h.useSpriteInputRoutes()
                    let r = rule(action: action, gesture: gesture)
                    h.actions.begin(r)
                    h.spriteText = "误唤醒后已有文字"
                    if receiverStopped { h.spriteRecording = false }
                    h.actions.begin(r); h.actions.finish(); h.tick(100)
                    assert(!h.actions.busy && !h.spriteInputOpen && h.spriteDismissals == 1,
                           "小精灵单击/双击/长按再次操作必须取消，旧松开不再结束，包括启动失败后的接收框")
                    assert(h.spriteEnds == 0 && h.spriteCancels == 0 && h.spriteRouteEnds == 0,
                           "接收层已经取消后，映射层只清理拥有者，不能再次结束或取消")
                    assert(h.spriteBegins == (action == .spriteVoice ? 1 : 0) &&
                           h.spriteWakes == (action == .spriteWake ? 1 : 0) && h.keys.isEmpty,
                           "取消不能重新唤醒输入法或发出普通输入按键")
                }
            }
        }
    }

    static func spriteContinuationPrecedesModifierGate() {
        for gesture in [HeadsetRule.Gesture.click, .doubleClick] {
            let h = VoiceHarness(); h.usePause(seconds: 1); h.useSpriteInputRoutes()
            h.spriteInputOpen = true; h.spriteText = "补开前保留的目标"; h.keysAvailable = false
            let r = rule(gesture: gesture, toggle: true)
            h.actions.begin(r)
            assert(h.actions.busy && h.actions.currentRuleID == r.id && h.spriteRouteStarts == 1,
                   "当前小精灵输入优先接续，按住语音修饰键不能阻断该路由")
            assert(h.spriteContinueRequests.count == 1 && h.spriteContinueRequests[0].1,
                   "接续必须沿用原规则快捷键的切换策略")
            assert(h.preparations.isEmpty && h.keys.isEmpty && h.optionPosts == 0 && h.spriteBegins == 0 &&
                   h.spriteText == "补开前保留的目标", "接续同一接收框不清文字、不定位普通输入框、不重新创建小精灵")
            h.tick(10)
            assert(h.actions.busy && h.spriteEnds == 0, "补开前原文不能启动自动结束计时")
            h.spriteText = "补开前保留的目标，加上新的语音"; h.tick(11); h.tick(12)
            assert(!h.actions.busy && h.spriteEnds == 1 && h.normalEnds == 0 && h.normalTextReads == 0,
                   "接续后的规则必须读取小精灵转写并按同设备策略结束")
        }
    }

    static func continuedSameVoiceRuleEndsOnce() {
        let h = VoiceHarness(); h.usePause(); h.useSpriteInputRoutes(); h.spriteInputOpen = true
        let r = rule()
        h.actions.begin(r); h.actions.begin(r); h.tick(10)
        assert(!h.actions.busy && h.actions.currentRuleID == nil && h.spriteRouteStarts == 1 && h.spriteRouteEnds == 1,
               "同一 voice 规则已拥有小精灵时，再次操作必须先经过接续状态回调")
        assert(h.spriteContinueRequests.count == 2 && h.spriteEnds == 0 && h.spriteCancels == 0 &&
               h.normalEnds == 0 && h.normalCancels == 0 && h.keys.isEmpty,
               "回调已经结束录音，映射层不能再结束、取消或触发普通语音")
    }

    static func waitingContinuationKeepsOwnerAndDeadline() {
        let h = VoiceHarness(); h.usePause(); h.useSpriteInputRoutes()
        let spriteRule = rule(action: .spriteVoice)
        h.actions.begin(spriteRule); h.spriteText = "仍在同一接收框输入"; h.tick(1)
        h.spriteStarting = true
        h.actions.begin(rule())
        assert(h.actions.currentRuleID == spriteRule.id && h.spriteRouteStarts == 0 && h.spriteContinueRequests.count == 1,
               "输入法仍在准备时，跨侧重复操作应等待并保留原拥有者")
        assert(h.spriteBegins == 1 && h.spriteCancels == 0 && h.preparations.isEmpty && h.keys.isEmpty)
        h.spriteStarting = false; h.tick(4)
        assert(!h.actions.busy && h.spriteEnds == 1, "等待不能重置原转写停顿计时或设备策略")
    }

    static func crossSideContinuationPreservesReceiver() {
        let h = VoiceHarness(); h.usePause(seconds: 1); h.usePause(device: "device-B", seconds: 5)
        h.useSpriteInputRoutes()
        h.actions.begin(rule(action: .spriteVoice)); h.spriteText = "失败提示后保留的内容"; h.spriteRecording = false
        let voiceRule = rule(device: "device-B")
        h.actions.begin(voiceRule)
        assert(h.actions.currentRuleID == voiceRule.id && h.spriteRouteStarts == 1 && h.spriteBegins == 1 &&
               h.spriteCancels == 0 && h.normalCancels == 0 && h.spriteText == "失败提示后保留的内容",
               "旧小精灵拥有者尚未清理时，另一侧补开必须沿用接收框且不能先取消")
        h.spriteText = "补开的新内容"; h.tick(1); h.tick(2); h.tick(5.99)
        assert(h.actions.busy && h.spriteEnds == 0, "接续后结束策略跟随发起该操作的设备")
        h.tick(6)
        assert(!h.actions.busy && h.spriteEnds == 1 && h.keys.isEmpty)

        let stopped = VoiceHarness(); stopped.usePause(); stopped.useSpriteInputRoutes()
        stopped.actions.begin(rule(action: .spriteVoice)); stopped.spriteRecording = false; stopped.tick(1)
        assert(!stopped.actions.busy && stopped.spriteInputOpen && stopped.spriteCancels == 0)
        stopped.actions.begin(rule())
        assert(stopped.actions.busy && stopped.spriteRouteStarts == 1 && stopped.spriteBegins == 1 && stopped.keys.isEmpty,
               "启动失败清理拥有者后，另一侧仍能补开现有输入框")
        stopped.actions.begin(rule(action: .spriteVoice))
        assert(!stopped.actions.busy && !stopped.spriteInputOpen && stopped.spriteDismissals == 1 && stopped.spriteEnds == 0,
               "另一侧拥有录音期间，原小精灵操作仍应取消整个输入")
    }

    static func unavailableContinuationAndHoldKeepOrdinaryVoice() {
        let fallback = VoiceHarness(); fallback.usePause(); fallback.useSpriteInputRoutes()
        let r = rule()
        fallback.startNormal(r); fallback.actions.begin(r)
        assert(fallback.spriteContinueRequests.count == 2 && fallback.normalEnds == 1 && !fallback.actions.busy &&
               fallback.keys.map(\.down) == [true, false], "无小精灵接收框时普通语音保留原启动与再次结束行为")

        let blocked = VoiceHarness(); blocked.useSpriteInputRoutes(); blocked.keysAvailable = false
        blocked.actions.begin(rule())
        assert(!blocked.actions.busy && blocked.spriteContinueRequests.count == 1 && blocked.preparations.isEmpty && blocked.keys.isEmpty,
               "小精灵路由不可用后，普通语音仍执行修饰键门禁")

        let held = VoiceHarness(); held.useSpriteInputRoutes()
        held.startNormal(rule(gesture: .hold)); held.actions.finish()
        assert(held.spriteContinueRequests.isEmpty && held.normalEnds == 1 && held.keys.map(\.down) == [true, false],
               "没有小精灵接收框时长按普通语音保持松开结束")

        let spriteHeld = VoiceHarness(); spriteHeld.useSpriteInputRoutes()
        spriteHeld.actions.begin(rule(action: .spriteVoice, gesture: .hold)); spriteHeld.actions.finish()
        assert(spriteHeld.spriteDismissals == 0 && spriteHeld.spriteBegins == 1 && spriteHeld.spriteEnds == 1,
               "首次小精灵长按保持松开提交")
    }
    static func heldVoiceContinuesReceiverUntilRelease() {
        for alreadyRecording in [false, true] {
            let h = VoiceHarness(); h.useSpriteInputRoutes(); h.usePause(seconds: 1)
            h.spriteInputOpen = true; h.spriteRecording = alreadyRecording; h.keysAvailable = false
            let held = rule(gesture: .hold)
            h.actions.begin(held)
            assert(h.actions.busy && h.spriteHeldRequests.count == 1 && h.spriteContinueRequests.isEmpty,
                   "按住接续与单击开关分离，不在按下时结束已有小精灵录音")
            assert(h.preparations.isEmpty && h.keys.isEmpty && h.spriteRouteStarts == (alreadyRecording ? 0 : 1))
            h.spriteText = "接续中的内容"; h.tick(1); h.tick(10)
            assert(h.spriteEnds == 0 && h.spriteRouteEnds == 0, "按住接续不被停顿计时或单击toggle结束")
            h.actions.finish(); h.actions.finish()
            assert(h.spriteEnds == 1 && !h.actions.busy && h.normalEnds == 0, "只有所属松开结束接续一次")
        }
    }

    static func retiredSpriteOwnerCannotFinishRetry() {
        for gesture in [HeadsetRule.Gesture.click, .hold] {
            let h = VoiceHarness(); h.usePause(); h.useSpriteInputRoutes()
            h.actions.begin(rule(action: .spriteVoice, gesture: gesture))
            h.spriteText = "旧录音尚未提交的文字"; h.tick(1)
            h.actions.retireSpriteRecording(); h.actions.finish()
            assert(!h.actions.busy && h.spriteEnds == 0 && h.spriteCancels == 0,
                   "接收层同步退休拥有者后，旧长按松开或自动收尾都不能再次结束或取消")
            h.spriteRecording = false
            let retry = rule()
            h.actions.begin(retry); h.tick(4)
            assert(h.actions.busy && h.actions.currentRuleID == retry.id && h.spriteRouteStarts == 1 && h.spriteEnds == 0,
                   "接收框即时补开不继承旧录音的停顿倒计时")
            h.spriteText = "重试后的新转写"; h.tick(5); h.tick(7.99)
            assert(h.spriteEnds == 0)
            h.tick(8)
            assert(!h.actions.busy && h.spriteEnds == 1 && h.spriteCancels == 0 && h.keys.isEmpty)
        }
    }
}
