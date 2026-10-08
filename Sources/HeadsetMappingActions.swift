/** [INPUT]: 已校验规则与现有小精灵/输入焦点。[OUTPUT]: 有界按键和应用/语音动作。[POS]: 本机执行层，合成事件带 marker，取消必释放。[PROTOCOL]: 同步 Sources/CLAUDE.md。 */
import AppKit
import ApplicationServices

final class HeadsetKeyEmitter {
    private var held: HeadsetKey?
    private let post: (CGEvent) -> Void
    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) { self.post = post }
    @discardableResult func set(_ key: HeadsetKey, down: Bool) -> Bool {
        guard key.valid else { return false }
        if down, held != nil { return false }
        if !down, held == nil { return true }
        let actual = down ? key : held!
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: actual.code, keyDown: down) else { return false }
        if actual.modifier { event.type = .flagsChanged }
        var flags = CGEventFlags(rawValue: down ? actual.flags : actual.modifier ? 0 : actual.flags)
        // Preserve the side-specific Option marker required by the existing IME.
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
    var spriteCancel: (() -> Void)?
    var spriteBusy: (() -> Bool)?
    var message: ((String) -> Void)?
    var environmentAllows: () -> Bool = { !LockScreenInput.locked && AXIsProcessTrusted() }
    private let emitter: HeadsetKeyEmitter
    // Injectable seams keep cancellation tests free of external keyboard events.
    var prepareNormalVoice: (@escaping (Bool) -> Void) -> Void = { HeadsetController.shared.prepareClickVoice(completion: $0) }
    var cancelNormalVoice: () -> Void = { HeadsetController.shared.cancelClickVoice() }
    var normalOptionPosted: () -> Void = { HeadsetController.shared.clickVoiceOptionPosted(at: ProcessInfo.processInfo.systemUptime) }
    var endNormalVoice: () -> Void = { HeadsetController.shared.endClickVoice() }
    var foregroundPID: () -> pid_t? = { InputFocus.focusedApplicationPID() }
    var voiceKeysAvailable: () -> Bool = { CGEventSource.flagsState(.combinedSessionState).rawValue & HeadsetKey.allowedFlags == 0 }
    private var active: HeadsetRule?
    private var targetPID: pid_t?
    private var began = Date.distantPast
    private var generation = 0
    private var voiceStarted = false
    init(emitter: HeadsetKeyEmitter = HeadsetKeyEmitter()) { self.emitter = emitter }
    var busy: Bool { active != nil }
    var currentRuleID: String? { active?.id }
    func begin(_ rule: HeadsetRule) {
        guard rule.valid, environmentAllows() else { message?("未执行：请检查权限或解锁电脑"); return }
        if rule.action == .spriteEnd {
            if active?.action == .spriteVoice { finish() }
            else if active == nil { spriteEnd?() }
            else { message?("当前为普通语音，请用对应操作结束"); return }
            message?("正在结束语音并等待转写"); return
        }
        if active?.id == rule.id { finish(); return }
        if active != nil { cancel() }
        generation += 1
        switch rule.action {
        case .disabled: message?("已禁用此操作")
        case .cancel: cancel(); HeadsetClickControl.shared.cancelCurrent(); HeadsetController.shared.cancelSession("mapping cancelled"); spriteCancel?(); message?("已取消当前操作")
        case .spriteEnd: finish(); spriteEnd?(); message?("正在结束语音并等待转写")
        case .spriteWake: message?(spriteWake?() == true ? "小精灵已唤醒" : "未能唤醒小精灵")
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
                let sent = rule.voiceToggle ? self.emitter.tap(key) : self.emitter.set(key, down: true)
                guard sent else { self.cancel(); self.message?("语音快捷键未发出"); return }
                self.voiceStarted = true; self.began = Date(); self.normalOptionPosted()
                self.message?("输入框已聚焦，正在唤醒语音；再次操作结束")
            }
        case .spriteVoice:
            guard let key = rule.key, spriteBegin?(key, rule.voiceToggle) == true else { message?("未能启动小精灵语音"); return }
            arm(rule); message?(rule.gesture == .hold ? "正在启动小精灵语音，松开结束" : "正在启动小精灵语音，再次操作结束")
        }
    }
    private func arm(_ rule: HeadsetRule) {
        active = rule; began = Date()
        // Sprite capture deliberately moves focus into its own verified receiver.
        targetPID = rule.action == .spriteVoice ? nil : InputFocus.focusedApplicationPID()
    }
    func finish() {
        guard let rule = active else { return }
        generation += 1
        active = nil
        if rule.action == .voice {
            if voiceStarted {
                if rule.voiceToggle, let key = rule.key { _ = emitter.tap(key) } else { emitter.release() }
                endNormalVoice()
            } else { cancelNormalVoice() }
        } else if rule.action == .spriteVoice { spriteEnd?() }
        else { emitter.release() }
        voiceStarted = false; targetPID = nil; message?("操作已结束")
    }
    func cancel() {
        generation += 1
        if let rule = active, rule.action == .voice, voiceStarted, rule.voiceToggle, let key = rule.key { _ = emitter.tap(key) }
        emitter.release()
        if active?.action == .spriteVoice { spriteCancel?() }
        cancelNormalVoice()
        voiceStarted = false; active = nil; targetPID = nil
    }
    func tick() {
        guard let rule = active else { return }
        let timeout: TimeInterval = [.voice, .spriteVoice].contains(rule.action) ? HeadsetVoiceTiming.maxRecordingSeconds : 60
        let timedOut = Date().timeIntervalSince(began) > timeout
        if LockScreenInput.locked || !AXIsProcessTrusted() || timedOut || (targetPID != nil && InputFocus.focusedApplicationPID() != targetPID) || (rule.action == .spriteVoice && spriteBusy?() == false) {
            if timedOut { HeadsetLog("mapping cancelled: action timeout after \(Int(timeout)) seconds") }
            cancel(); message?("操作已中断；按键已释放")
        }
    }
}
