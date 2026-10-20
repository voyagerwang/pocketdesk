/**
 * [INPUT]: 依赖已校验耳机规则、同设备语音偏好、输入焦点、实时转写及小精灵取消/接续状态回调；修饰键复用 HID 状态事件源，普通键复用私有事件源。
 * [OUTPUT]: 提供同源按下/释放的按键、应用与语音动作及小精灵录音拥有者退休；小精灵所有唤醒手势再次操作取消，普通语音优先接续当前接收框，长按仍松开结束；已松开中键回放先准备再安全点按收尾。
 * [POS]: Sources 的自定义耳机动作拥有者；小精灵路由先于旧拥有者切换与修饰键门禁，文字停顿只结束录音，最终转写与发送交给原链路。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import ApplicationServices

final class HeadsetKeyEmitter {
    private var held: HeadsetKey?
    private let post: (CGEvent) -> Void
    private let modifierSource = CGEventSource(stateID: .hidSystemState)
    private let nonmodifierSource = CGEventSource(stateID: .privateState)
    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) { self.post = post }
    @discardableResult func set(_ key: HeadsetKey, down: Bool) -> Bool {
        guard key.valid else { return false }
        if down, held != nil { return false }
        if !down, held == nil { return true }
        let actual = down ? key : held!
        // ---------- 按下与释放沿用同一状态表 ----------
        // 修饰键跟随系统 HID 状态，普通键留在此投递器持有的私有状态表。
        guard let source = actual.modifier ? modifierSource : nonmodifierSource,
              let event = CGEvent(keyboardEventSource: source, virtualKey: actual.code, keyDown: down) else { return false }
        if actual.modifier { event.type = .flagsChanged }
        var flags = CGEventFlags(rawValue: down ? actual.flags : actual.modifier ? 0 : actual.flags)
        // 保留输入法识别的左右 Option 标记。
        if down && actual.code == 58 { flags.insert(CGEventFlags(rawValue: 0x20)) }
        if down && actual.code == 61 { flags.insert(CGEventFlags(rawValue: 0x40)) }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: HeadsetMarker)
        post(event); held = down ? actual : nil; return true
    }
    @discardableResult func tap(_ key: HeadsetKey) -> Bool {
        guard set(key, down: true) else { return false }
        return set(key, down: false)
    }
    func release() { if let held { _ = set(held, down: false) } }
}

final class HeadsetMappingActions {
    static let shared = HeadsetMappingActions()
    var spriteBegin: ((HeadsetKey, Bool) -> Bool)?
    var spriteWake: (() -> Bool)?
    var spriteEnd: (() -> Void)?
    var finishClickSprite: () -> Bool = { HeadsetClickControl.shared.finishSpriteRecordingIfOwned() }
    var spriteCancel: (() -> Void)?
    var spriteBusy: (() -> Bool)?
    var spriteDismissInput: (() -> Bool)?
    var spriteContinueVoice: ((HeadsetKey, Bool) -> HeadsetSpriteVoiceAction)?
    var spriteContinueHeldVoice: ((HeadsetKey, Bool) -> HeadsetSpriteVoiceAction)?
    var message: ((String) -> Void)?
    var environmentAllows: () -> Bool = { !LockScreenInput.locked && AXIsProcessTrusted() }
    private let emitter: HeadsetKeyEmitter
    // Injectable seams keep cancellation tests free of external keyboard events.
    var prepareNormalVoice: (@escaping (Bool) -> Void) -> Void = { HeadsetController.shared.prepareClickVoice(completion: $0) }
    var cancelNormalVoice: () -> Void = { HeadsetController.shared.cancelClickVoice() }
    var normalOptionPosted: () -> Void = { HeadsetController.shared.clickVoiceOptionPosted(at: ProcessInfo.processInfo.systemUptime) }
    var endNormalVoice: () -> Void = { HeadsetController.shared.endClickVoice() }
    var voicePreference: (String) -> HeadsetClickPreference? = { HeadsetClickPreferences.shared.preference(for: $0) }
    var normalVoiceText: () -> String? = { HeadsetController.shared.clickVoiceText }
    var spriteText: (() -> String?)?
    var voiceClock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var voiceLog: (String) -> Void = HeadsetLog
    var foregroundPID: () -> pid_t? = { HeadsetVoiceFocus.currentApplicationPID() }
    var voiceKeysAvailable: () -> Bool = { CGEventSource.flagsState(.combinedSessionState).rawValue & HeadsetKey.allowedFlags == 0 }
    private var active: HeadsetRule?
    private var targetPID: pid_t?
    private var began = Date.distantPast
    private var generation = 0
    private var voiceStarted = false
    private var textPause: HeadsetTextPause?
    init(emitter: HeadsetKeyEmitter = HeadsetKeyEmitter()) { self.emitter = emitter }
    var busy: Bool { active != nil }
    var currentRuleID: String? { active?.id }
    var recordingGeneration: Int { generation }
    func begin(_ rule: HeadsetRule, releaseAfterPreparation: Bool = false) {
        guard rule.valid, environmentAllows() else { message?("未执行：请检查权限或解锁电脑"); return }
        if rule.action == .spriteEnd {
            if active?.action == .spriteVoice { finish() }
            else if active == nil { if !finishClickSprite() { spriteEnd?() } }
            else { message?("当前为普通语音，请用对应操作结束"); return }
            message?("正在结束语音并等待转写"); return
        }
        // ---------- 当前接收框优先，先区分取消与接续 ----------
        // 同侧再次操作取消；另一侧的普通语音操作接续现有小精灵，不能先取消旧拥有者。
        if [.spriteVoice, .spriteWake].contains(rule.action), spriteDismissInput?() == true {
            retireSpriteRecording(); message?("已取消小精灵输入并收起"); return
        }
        if rule.gesture == .hold, rule.action == .voice, let key = rule.key {
            switch spriteContinueHeldVoice?(key, rule.voiceToggle) ?? .unavailable {
            case .started:
                if active != nil, active?.action != .spriteVoice { cancel() }
                generation += 1; voiceStarted = false; textPause = nil
                var spriteRule = rule; spriteRule.action = .spriteVoice
                arm(spriteRule); message?("正在接续小精灵语音；松开结束"); return
            case .waiting: message?("正在等待小精灵语音，请稍候"); return
            case .ended: retireSpriteRecording(); return
            case .unavailable: break
            }
        }
        if rule.gesture != .hold {
            if rule.action == .voice, let key = rule.key {
                switch spriteContinueVoice?(key, rule.voiceToggle) ?? .unavailable {
                case .started:
                    if active != nil, active?.action != .spriteVoice { cancel() }
                    generation += 1; voiceStarted = false; textPause = nil
                    var spriteRule = rule; spriteRule.action = .spriteVoice
                    arm(spriteRule); configureTextPause(spriteRule, original: spriteText?() ?? "")
                    message?("正在接续小精灵语音；" + endHint(spriteRule)); return
                case .waiting:
                    message?("正在启动小精灵语音，请稍候"); return
                case .ended:
                    retireSpriteRecording(); message?("正在结束语音并等待转写"); return
                case .unavailable: break
                }
            }
        }
        if active?.id == rule.id { finish(); return }
        if active != nil { cancel() }
        textPause = nil
        generation += 1
        switch rule.action {
        case .disabled: message?("已禁用此操作")
        case .cancel: cancel(); HeadsetClickControl.shared.cancelCurrent(); HeadsetController.shared.cancelSession("mapping cancelled"); spriteCancel?(); message?("已取消当前操作")
        case .spriteEnd: finish(); spriteEnd?(); message?("正在结束语音并等待转写")
        case .spriteWake:
            let awakened = spriteWake?() == true
            message?(awakened ? "小精灵已唤醒" : "未能唤醒小精灵")
        case .openApp:
            guard let path = rule.appPath, FileManager.default.fileExists(atPath: path) else { message?("未执行：应用不存在，请重新选择"); return }
            let token = generation
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if let error { self.message?("未打开：\(error.localizedDescription)") }
                    else { self.message?(app == nil ? "未能确认应用启动" : "已启动应用；请查看目标窗口") }
                }
            }
        case .hotkey:
            guard let key = rule.key, CGEventSource.flagsState(.combinedSessionState).rawValue & HeadsetKey.allowedFlags == 0 else { message?("未执行：请先松开电脑上的修饰键"); return }
            if rule.holdsKey {
                guard emitter.set(key, down: true) else { message?("按键未发出"); return }
                arm(rule); message?("按键保持中，松开耳机操作后释放")
            } else { message?(emitter.tap(key) ? "快捷键已发出；请核对目标效果" : "快捷键未发出") }
        case .voice:
            guard let key = rule.key, voiceKeysAvailable() else { message?("未执行：请先松开电脑上的修饰键"); return }
            active = rule; began = Date(); targetPID = foregroundPID(); voiceStarted = false
            let token = generation
            message?("正在定位当前输入框…")
            prepareNormalVoice { [weak self] ready in
                guard let self, self.generation == token, self.active?.id == rule.id else { return }
                guard ready, self.environmentAllows(), self.voiceKeysAvailable(), self.foregroundPID() == self.targetPID else {
                    self.cancel(); self.message?("未能确认当前输入框，请点击目标输入框后重新唤醒"); return
                }
                let original = self.normalVoiceText() ?? ""
                let sent = rule.voiceToggle ? self.emitter.tap(key) : self.emitter.set(key, down: true)
                guard sent else { self.cancel(); self.message?("语音快捷键未发出"); return }
                self.voiceStarted = true; self.began = Date(); self.normalOptionPosted()
                self.configureTextPause(rule, original: original)
                self.message?("输入框已聚焦，正在唤醒语音；" + self.endHint(rule))
                if releaseAfterPreparation { self.finish() }
            }
        case .spriteVoice:
            guard let key = rule.key, spriteBegin?(key, rule.voiceToggle) == true else { message?("未能启动小精灵语音"); return }
            arm(rule); configureTextPause(rule, original: spriteText?() ?? "")
            message?("正在启动小精灵语音；" + endHint(rule))
        }
    }
    private func configureTextPause(_ rule: HeadsetRule, original: String) {
        guard rule.gesture != .hold, let preference = voicePreference(rule.signal.device),
              preference.effectiveFinishMode == .textPause else { textPause = nil; return }
        textPause = HeadsetTextPause(original: original, delay: preference.effectiveTextPauseSeconds)
    }
    private func endHint(_ rule: HeadsetRule) -> String {
        if rule.gesture == .hold { return "松开结束" }
        if rule.action == .spriteVoice {
            return (textPause != nil ? "转写文字停顿后自动结束；" : "") + "语音操作结束，小精灵操作取消"
        }
        if textPause != nil { return "转写文字停顿后自动结束，也可再次操作结束" }
        return "再次操作结束"
    }
    func retireSpriteRecording() {
        guard active?.action == .spriteVoice else { return }
        generation += 1
        active = nil; targetPID = nil; voiceStarted = false; textPause = nil
    }
    private func arm(_ rule: HeadsetRule) {
        active = rule; began = Date()
        // Sprite capture deliberately moves focus into its own verified receiver.
        targetPID = rule.action == .spriteVoice ? nil : foregroundPID()
    }
    func finish() {
        guard let rule = active else { return }
        generation += 1
        active = nil; textPause = nil
        if rule.action == .voice {
            if voiceStarted {
                if rule.voiceToggle, let key = rule.key { _ = emitter.tap(key) } else { emitter.release() }
                endNormalVoice()
            } else { cancelNormalVoice() }
        } else if rule.action == .spriteVoice { spriteEnd?() }
        else { emitter.release() }
        voiceStarted = false; targetPID = nil; message?("操作已结束")
    }
    func cancel(interruptSprite: Bool = true) {
        generation += 1
        if let rule = active, rule.action == .voice, voiceStarted, rule.voiceToggle, let key = rule.key { _ = emitter.tap(key) }
        emitter.release()
        if interruptSprite, active?.action == .spriteVoice { spriteCancel?() }
        cancelNormalVoice()
        voiceStarted = false; active = nil; targetPID = nil; textPause = nil
    }
    func tick() {
        guard let rule = active else { return }
        let timeout: TimeInterval = [.voice, .spriteVoice].contains(rule.action) ? HeadsetVoiceTiming.maxRecordingSeconds : 60
        let timedOut = Date().timeIntervalSince(began) > timeout
        if !environmentAllows() || timedOut || (targetPID != nil && foregroundPID() != targetPID) || (rule.action == .spriteVoice && spriteBusy?() == false) {
            if timedOut { HeadsetLog("mapping cancelled: action timeout after \(Int(timeout)) seconds") }
            // ---------- 录音拥有者收尾 ----------
            // 启动失败已经释放录音；再调用 spriteCancel 会把面板上的重试提示一起收起。
            let spriteAlreadyStopped = rule.action == .spriteVoice && spriteBusy?() == false
            cancel(interruptSprite: !spriteAlreadyStopped); message?("操作已中断；按键已释放"); return
        }
        // --- 停顿只释放当前录音，不越过最终转写与发送门禁 ---
        if textPause != nil {
            let text = rule.action == .voice ? normalVoiceText() : spriteText?()
            guard let text else { textPause?.suspend(); return }
            if let remaining = textPause?.remaining(text: text, now: voiceClock()), remaining <= 0 {
                finish()
                voiceLog("mapping voice automatically ended after unchanged text; route=\(rule.action.rawValue)")
            }
        }
    }
}
