/**
 * [INPUT]: 依赖耳机音量来源票据、后台有界 AX 鼠标命中、设备结束偏好、HeadsetVoiceFocus 的耳机专用应用归属、HeadsetController 与小精灵接收层的取消/继续语音回执。
 * [OUTPUT]: 仅音量语义滑块排除音量来源，普通点击不触发冷却；鼠标核验稍迟保留耳机候选，命中滑块后确有系统音量变化才取消录音；有效单击路由到普通或小精灵语音，自动停顿保留待提交取消权。
 * [POS]: Sources 的默认音量单击录音拥有者；接收层决定录音事实，拥有者只维护耳机时序，不重复取消失败或待转写回执。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import ApplicationServices

/// Persistent per-device control. Window lifetime is independent of input lifetime.
final class HeadsetClickControl: NSObject {
    static let shared = HeadsetClickControl()
    var onSpriteBegin: (() -> Bool)?
    var onSpriteEnd: (() -> Void)?
    var onSpriteCancel: (() -> Void)?
    var onSpriteDismissInput: (() -> Bool)?
    var onSpriteContinueVoice: (() -> HeadsetSpriteVoiceAction)?
    var onSpriteRecording: (() -> Bool)?
    var onSpriteText: (() -> String?)?
    var onSpriteStatus: ((String) -> Void)?
    private var timer: Timer?
    private let volumeObserver = HeadsetVolumeObserver()
    private var gate: HeadsetClickGate?
    private var calibration: HeadsetClickCalibration?
    private var device: HeadsetAudioDevice?
    private var step: Float?
    private var began: Date?
    private var mode: HeadsetClickGate.Side?
    private var finishMode: HeadsetFinishMode = .manual
    private var textPauseSeconds = 3.0
    private var textPauseLabel: String { String(format: "%g", textPauseSeconds) }
    private var textPause: HeadsetTextPause?
    private var pauseHintShown = false
    private var ownsSprite = false
    private var optionDown = false
    private var voiceGeneration = 0
    private var targetPID: pid_t?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var suppressUntil = 0.0
    private var retryTapAt = Date.distantPast
    private var pendingVolumeTokens: Set<UUID> = []
    private var pendingVolumeLevel: Float?
    private let pointerSourceQueue = DispatchQueue(label: "pocketdesk.headset-pointer-source", qos: .userInteractive)
    var hasPendingVolumeSource: Bool { !pendingVolumeTokens.isEmpty }
    private(set) var statusText = "未启用单击控制"
    var recording: Bool { mode != nil }
    var spriteListeningStatus: String? {
        guard mode == .left else { return nil }
        return finishMode == .textPause ? "正在听 · 停顿 \(textPauseLabel) 秒自动结束 · 左侧取消，右侧结束" : "正在听 · 左侧取消，右侧结束"
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(shutdown), name: NSApplication.willTerminateNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(cancelCurrent), name: .init("com.apple.screenIsLocked"), object: nil)
    }
    private func status(_ value: String) {
        guard statusText != value else { return }
        statusText = value; HeadsetLog("click control: \(value)")
    }
    private func installTap() -> Bool {
        if let eventTap { return CGEvent.tapIsEnabled(tap: eventTap) }
        guard Date() >= retryTapAt else { return false }
        retryTapAt = Date().addingTimeInterval(3)
        let types: [CGEventType] = [.keyDown, CGEventType(rawValue: 14)!, .leftMouseDown, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: mask, callback: { _, type, event, ref in
            guard let ref else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<HeadsetClickControl>.fromOpaque(ref).takeUnretainedValue()
            if event.getIntegerValueField(.eventSourceUserData) == HeadsetMarker { return Unmanaged.passUnretained(event) }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { owner.disconnect(); owner.removeTap() }
            } else if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                DispatchQueue.main.async { owner.cancelCurrent() }
            } else if type.rawValue == 14, let e = NSEvent(cgEvent: event), HeadsetVolumeSourceEvent.isSystemVolume(type: type.rawValue, subtype: e.subtype.rawValue, data1: e.data1, marker: event.getIntegerValueField(.eventSourceUserData)) {
                HeadsetVolumeSourceGuard.shared.exclude()
                DispatchQueue.main.async { owner.manualVolumeChange(source: "system-media") }
            } else if type == .leftMouseDown {
                // ---------- 只核验实际滑块，事件回调不做 AX IPC ----------
                owner.observePointerSource(at: event.location)
            } else if type == .leftMouseUp {
                HeadsetVolumeSourceGuard.shared.endPointer()
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let eventTap else { return false }
        eventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), eventSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true); return true
    }
    private func observePointerSource(at point: CGPoint) {
        let source = HeadsetVolumeSourceGuard.shared
        guard let ticket = source.beginPointer() else { return }
        pointerSourceQueue.async {
            let slider = Self.pointerHitsVolumeSlider(at: point)
            source.resolvePointer(ticket, slider: slider)
        }
    }
    private static func pointerHitsVolumeSlider(at point: CGPoint) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + HeadsetVolumeSourceGuard.pointerVerificationBudget
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.02)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return false }
        var foundSlider = false
        var labels: [String] = []
        for _ in 0..<5 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            AXUIElementSetMessagingTimeout(current, 0.02)
            var rawRole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &rawRole) == .success,
                  let role = rawRole as? String else { return false }
            foundSlider = foundSlider || role == "AXSlider"
            if foundSlider {
                for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute] {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(current, attribute as CFString, &value) == .success,
                       let text = value as? String { labels.append(text) }
                }
                if HeadsetVolumeSourceEvent.isVolumeSlider(role: "AXSlider", labels: labels) { return true }
            }
            if ["AXApplication", "AXWindow", "AXTextArea", "AXTextField", "AXWebArea"].contains(role) { return false }
            var rawParent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &rawParent) == .success,
                  let rawParent, CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { return false }
            current = rawParent as! AXUIElement
        }
        return false
    }
    func manualVolumeChange(source: String) {
        HeadsetVolumeSourceGuard.shared.exclude()
        HeadsetMappingRuntime.shared.discardLearningVolume()
        HeadsetLog("volume source excluded: \(source)")
        cancelCurrent(); suppressUntil = ProcessInfo.processInfo.systemUptime + 0.8
    }
    @objc func cancelCurrent() {
        pendingVolumeTokens = []; pendingVolumeLevel = nil
        HeadsetMappingRuntime.shared.cancelVolumeGestures()
        voiceGeneration += 1
        HeadsetController.shared.cancelClickVoice()
        _ = option(false)
        if ownsSprite { onSpriteCancel?() }
        ownsSprite = false; mode = nil; began = nil; targetPID = nil; textPause = nil; pauseHintShown = false
        suppressUntil = ProcessInfo.processInfo.systemUptime + 0.6
    }
    func retireSpriteRecording() {
        guard mode == .left || ownsSprite else { return }
        voiceGeneration += 1
        ownsSprite = false; mode = nil; began = nil; targetPID = nil; textPause = nil; pauseHintShown = false
    }
    private func disconnect() {
        if device != nil || recording { cancelCurrent() }
        volumeObserver.stop()
        device = nil; gate = nil; calibration = nil; step = nil
    }
    private func makeGate(volume: Float, step: Float, uid: String) -> HeadsetClickGate {
        HeadsetClickGate(baseline: volume, step: step, minimumInterval: HeadsetMappingRuntime.shared.volumeDoubleClickEnabled(uid: uid) ? 0 : 0.6)
    }
    private func defaultVolumeClick(_ current: HeadsetAudioDevice, side: HeadsetClickGate.Side, preference: HeadsetClickPreference, detectedAt: Double) {
        guard let output = HeadsetAudio.current(), output.uid == current.uid, output.id == current.id,
              !LockScreenInput.locked, AXIsProcessTrusted() else { return }
        if !preference.enabled {
            // A double-click rule must preserve native volume for an unmatched single click.
            guard let volume = output.volume, let step else { return }
            let restored = min(1, max(0, volume + (side == .right ? step : -step)))
            if HeadsetAudio.setVolume(restored, device: current.id) {
                gate = makeGate(volume: restored, step: step, uid: current.uid)
            } else { disconnect(); status("无法恢复原有音量操作，请重新连接耳机") }
            return
        }
        // --- 小精灵输入先由接收层裁决，耳机拥有者只同步结果 ---
        if side == .left, onSpriteDismissInput?() == true {
            retireSpriteRecording()
            pendingVolumeTokens = []; pendingVolumeLevel = nil
            HeadsetMappingRuntime.shared.cancelVolumeGestures()
            suppressUntil = ProcessInfo.processInfo.systemUptime + 0.6
            status("本次小精灵输入已取消")
            return
        }
        if side == .right {
            switch onSpriteContinueVoice?() ?? .unavailable {
            case .started:
                if mode == .right {
                    HeadsetController.shared.cancelClickVoice()
                    _ = option(false)
                }
                voiceGeneration += 1
                ownsSprite = true; mode = .left; began = Date(); targetPID = nil
                finishMode = preference.effectiveFinishMode; pauseHintShown = false
                textPauseSeconds = preference.effectiveTextPauseSeconds
                textPause = HeadsetTextPause(original: onSpriteText?() ?? "", delay: textPauseSeconds)
                HeadsetLog(String(format: "click startup: preparation %.0f ms; route=sprite-resume", (ProcessInfo.processInfo.systemUptime - detectedAt) * 1000))
                return
            case .waiting:
                return
            case .ended:
                retireSpriteRecording()
                return
            case .unavailable:
                break
            }
        }
        if let mode {
            if mode != side { cancelCurrent() }
            else {
                finishRecording()
            }
        } else {
            guard CGEventSource.flagsState(.combinedSessionState).intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift]).isEmpty else { return }
            HeadsetController.shared.cancelSession("headset click")
            if ownsSprite { onSpriteCancel?(); ownsSprite = false }
            if side == .right {
                targetPID = HeadsetVoiceFocus.currentApplicationPID()
                mode = side; began = Date(); finishMode = preference.effectiveFinishMode; pauseHintShown = false
                textPauseSeconds = preference.effectiveTextPauseSeconds; textPause = nil
                voiceGeneration += 1
                let generation = voiceGeneration
                status("正在定位当前输入框…")
                HeadsetController.shared.prepareClickVoice { [weak self] ready in
                    guard let self, self.voiceGeneration == generation, self.mode == .right,
                          self.device?.uid == current.uid else { return }
                    guard ready else {
                        let hint = HeadsetController.shared.statusText
                        self.cancelCurrent(); self.status(hint); return
                    }
                    guard CGEventSource.flagsState(.combinedSessionState).intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift]).isEmpty,
                          self.option(true) else { self.cancelCurrent(); return }
                    self.began = Date()
                    HeadsetController.shared.clickVoiceOptionPosted(at: ProcessInfo.processInfo.systemUptime)
                    self.textPause = HeadsetTextPause(original: HeadsetController.shared.clickVoiceText ?? "", delay: self.textPauseSeconds)
                    HeadsetLog(String(format: "click startup: preparation %.0f ms; route=input; focus verified", (ProcessInfo.processInfo.systemUptime - detectedAt) * 1000))
                }
            } else {
                guard onSpriteBegin?() == true else { return }; ownsSprite = true
                mode = side; began = Date(); finishMode = preference.effectiveFinishMode; pauseHintShown = false
                textPauseSeconds = preference.effectiveTextPauseSeconds
                textPause = HeadsetTextPause(original: onSpriteText?() ?? "", delay: textPauseSeconds)
                HeadsetLog(String(format: "click startup: preparation %.0f ms; route=sprite", (ProcessInfo.processInfo.systemUptime - detectedAt) * 1000))
            }
        }
    }
    private func queueVolumeClick(_ current: HeadsetAudioDevice, side: HeadsetClickGate.Side, step: Float, baseline: Float, preference: HeadsetClickPreference, detectedAt: Double) {
        guard let ticket = HeadsetVolumeSourceGuard.shared.ticket(now: detectedAt) else { return }
        let token = UUID(); pendingVolumeTokens.insert(token)
        let generation = voiceGeneration, recordedMode = mode
        let pid = HeadsetVoiceFocus.currentApplicationPID()
        func confirm(_ owner: HeadsetClickControl) {
            guard owner.pendingVolumeTokens.contains(token) else { return }
            if HeadsetVolumeSourceGuard.shared.checkingPointer,
               ProcessInfo.processInfo.systemUptime - detectedAt < HeadsetVolumeSourceGuard.maximumPointerWait {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak owner] in
                    if let owner { confirm(owner) }
                }
                return
            }
            owner.pendingVolumeTokens.remove(token)
            if owner.pendingVolumeTokens.isEmpty { owner.pendingVolumeLevel = nil }
            guard let output = HeadsetAudio.current(), output.uid == current.uid, output.id == current.id,
                  owner.voiceGeneration == generation, owner.mode == recordedMode,
                  HeadsetVoiceFocus.currentApplicationPID() == pid, !LockScreenInput.locked, AXIsProcessTrusted(),
                  !HeadsetMappingRuntime.shared.learning else { return }
            guard HeadsetVolumeSourceGuard.shared.allows(ticket) else {
                owner.pendingVolumeTokens = []; owner.pendingVolumeLevel = nil
                HeadsetMappingRuntime.shared.cancelVolumeGestures()
                if let volume = output.volume { owner.gate = owner.makeGate(volume: volume, step: step, uid: output.uid) }
                return
            }
            guard HeadsetAudio.setVolume(baseline, device: current.id) else {
                owner.cancelCurrent(); owner.gate = nil; owner.device = nil; owner.status("无法恢复音量，本次语音已取消"); return
            }
            // Queued steps are already captured; the restoration echo is not another tap.
            if !owner.pendingVolumeTokens.isEmpty { owner.pendingVolumeLevel = baseline }
            if HeadsetMappingRuntime.shared.handleVolume(current, side: side, step: step, now: ticket.observedAt, fallback: { [weak owner] in
                guard let owner, owner.voiceGeneration == generation, owner.mode == recordedMode else { return }
                owner.defaultVolumeClick(current, side: side, preference: preference, detectedAt: detectedAt)
            }) { return }
            owner.defaultVolumeClick(current, side: side, preference: preference, detectedAt: detectedAt)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + HeadsetVolumeSourceGuard.confirmationDelay) { [weak self] in
            if let self { confirm(self) }
        }
    }
    private func tick(notifiedAt: TimeInterval? = nil) {
        let tickStartedAt = ProcessInfo.processInfo.systemUptime
        guard !LockScreenInput.locked, AXIsProcessTrusted() else { disconnect(); status("等待解锁或辅助功能权限"); return }
        guard !HeadsetPairing.shared.isActive, !HeadsetTouchDiagnostic.shared.isActive, !HeadsetMappingRuntime.shared.learning else { disconnect(); status("按键检测中，语音控制暂时暂停"); return }
        guard let current = HeadsetAudio.current(), let volume = current.volume else { disconnect(); return }
        let preference = HeadsetClickPreferences.shared.preference(for: current.uid) ?? HeadsetClickPreference(uid: current.uid, name: current.name, enabled: false, step: nil)
        let selectedStep = HeadsetMappingRuntime.shared.volumeStep(uid: current.uid) ?? preference.step
        guard preference.enabled || selectedStep != nil && HeadsetMappingRuntime.shared.volumeStep(uid: current.uid) != nil else {
            disconnect(); status("当前输出未启用单击控制"); return
        }
        guard installTap() else { disconnect(); status("无法监听取消操作，请检查辅助功能权限"); return }
        let interval = HeadsetMappingRuntime.shared.volumeDoubleClickEnabled(uid: current.uid) ? 0.0 : 0.6
        if device?.uid != current.uid || device?.id != current.id || step != selectedStep || gate != nil && gate?.minimumInterval != interval {
            disconnect(); device = current; step = selectedStep
            if let step { gate = makeGate(volume: volume, step: step, uid: current.uid) }
            else { calibration = HeadsetClickCalibration(volume: volume) }
            HeadsetLog("click control connected: \(current.name); configured=\(step != nil)")
        }
        volumeObserver.start(device: current.id) { [weak self] receivedAt in self?.tick(notifiedAt: receivedAt) }
        let now = ProcessInfo.processInfo.systemUptime
        let observedAt = HeadsetVolumeSourceEvent.observationTime(notifiedAt: notifiedAt, now: now)
        if HeadsetVolumeSourceGuard.shared.pointerVolumeActive(now: now),
           let baseline = gate?.baseline, abs(volume - baseline) >= 0.004 {
            manualVolumeChange(source: "mouse-volume-slider")
        }
        if now < suppressUntil || HeadsetVolumeSourceGuard.shared.ticket(now: now) == nil {
            if let step { gate = makeGate(volume: volume, step: step, uid: current.uid) }
            else { calibration = HeadsetClickCalibration(volume: volume) }
            return
        }
        if selectedStep == nil {
            status("\(current.name)：请单击音量加，再单击音量减，完成识别")
            if let learned = calibration?.observe(volume) {
                var saved = preference; saved.step = learned
                do { try HeadsetClickPreferences.shared.save(saved); step = learned; gate = HeadsetClickGate(baseline: volume, step: learned); calibration = nil }
                catch { disconnect(); status("未能保存耳机配置：\(error.localizedDescription)") }
            }
            return
        }
        if let began, Date().timeIntervalSince(began) > HeadsetVoiceTiming.maxRecordingSeconds {
            HeadsetLog("click voice cancelled: recording exceeded \(Int(HeadsetVoiceTiming.maxRecordingSeconds)) seconds")
            cancelCurrent()
        }
        if mode == .right, HeadsetVoiceFocus.currentApplicationPID() != targetPID { cancelCurrent() }
        if mode == .right, !optionDown, !HeadsetController.shared.preparingClickVoice { cancelCurrent() }
        if mode == .left, onSpriteRecording?() == false { retireSpriteRecording() }
        guard let step else { return }
        if let gate, !gate.restoring, (gate.baseline < step - 0.008 || gate.baseline > 1 - step + 0.008) {
            // An output at its limit cannot emit a second step; don't begin a recording there.
            self.gate = makeGate(volume: volume, step: step, uid: current.uid)
            status("\(current.name)：请将音量调到 10%～90% 后使用"); return
        }
        if hasPendingVolumeSource {
            // Capture a rapid second step before the first step's source check completes.
            if gate?.minimumInterval == 0, let previous = pendingVolumeLevel, let baseline = gate?.baseline {
                let delta = volume - previous
                if abs(delta) >= 0.004 {
                    guard abs(abs(delta) - step) < 0.008 else {
                        cancelCurrent(); gate = makeGate(volume: volume, step: step, uid: current.uid); return
                    }
                    let side: HeadsetClickGate.Side = delta > 0 ? .right : .left
                    guard preference.enabled || HeadsetMappingRuntime.shared.hasVolumeRule(current, side: side, step: step) else {
                        cancelCurrent(); gate = makeGate(volume: volume, step: step, uid: current.uid); return
                    }
                    pendingVolumeLevel = volume
                    queueVolumeClick(current, side: side, step: step, baseline: baseline, preference: preference, detectedAt: observedAt)
                }
            }
            return
        }
        let side = gate?.observe(volume, now: observedAt)
        if gate?.failed == true {
            cancelCurrent(); gate = makeGate(volume: volume, step: step, uid: current.uid)
            status("音量已重新同步，单击控制保持开启"); return
        }
        if let side {
            let detectedAt = ProcessInfo.processInfo.systemUptime
            HeadsetLog(String(format: "click detected: source=%@ queueWait=%.0f ms precheck=%.0f ms", notifiedAt == nil ? "poll" : "audio-notification", notifiedAt.map { max(0, tickStartedAt - $0) * 1000 } ?? 0, (detectedAt - tickStartedAt) * 1000))
            if !preference.enabled && !HeadsetMappingRuntime.shared.hasVolumeRule(current, side: side, step: step) {
                gate = makeGate(volume: volume, step: step, uid: current.uid); return
            }
            guard let baseline = gate?.baseline else { return }
            pendingVolumeLevel = volume
            queueVolumeClick(current, side: side, step: step, baseline: baseline, preference: preference, detectedAt: observedAt)
            return
        }
        // Handle a deliberate second click before the inactivity timer, so a click
        // at the deadline cannot accidentally begin another recording.
        var endingSoon = false
        if mode != nil, finishMode == .textPause {
            let text = mode == .right ? HeadsetController.shared.clickVoiceText : onSpriteText?()
            if let text, let remaining = textPause?.remaining(text: text, now: now) {
                if remaining <= 0 {
                    finishRecording()
                    HeadsetLog("click voice automatically ended after \(textPauseLabel) seconds of unchanged text")
                } else {
                    endingSoon = remaining <= 1
                    if mode == .left {
                        pauseHintShown = true
                        onSpriteStatus?(endingSoon ? "即将结束 · 左侧或 Esc 取消" : spriteListeningStatus ?? "正在听")
                    }
                }
            } else if mode == .left, pauseHintShown, let hint = spriteListeningStatus { onSpriteStatus?(hint) }
        }
        if mode == .right, !optionDown { status("正在定位当前输入框…") }
        else if mode == .right { status("\(current.name)：" + (endingSoon ? "即将结束 · Esc 取消" : finishMode == .textPause ? "文字停顿 \(textPauseLabel) 秒自动结束；再点可立即结束" : "语音输入中，再点音量加结束")) }
        else if mode == .left { status("\(current.name)：" + (finishMode == .textPause ? "文字停顿 \(textPauseLabel) 秒自动结束；左侧取消，右侧结束" : "小精灵正在听；左侧取消，右侧结束")) }
        else if HeadsetController.shared.session?.fromClickControl == true { status(HeadsetController.shared.statusText) }
        else { status("\(current.name) · 单击控制已开启") }
    }
    private func finishRecording() {
        guard let mode else { return }
        voiceGeneration += 1
        if mode == .right {
            guard optionDown else { cancelCurrent(); return }
            option(false)
            HeadsetController.shared.endClickVoice()
        } else { onSpriteEnd?() }
        self.mode = nil; began = nil; targetPID = nil; textPause = nil; pauseHintShown = false
    }
    @discardableResult func finishSpriteRecordingIfOwned() -> Bool {
        guard mode == .left, ownsSprite else { return false }
        finishRecording(); return true
    }
    @discardableResult private func option(_ down: Bool) -> Bool {
        guard down != optionDown else { return true }
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 58, keyDown: down) else { return false }
        event.type = .flagsChanged
        event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20) : []
        event.setIntegerValueField(.eventSourceUserData, value: HeadsetMarker)
        event.post(tap: .cghidEventTap); optionDown = down; return true
    }
    private func removeTap() {
        HeadsetVolumeSourceGuard.shared.endPointer()
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }; eventSource = nil
        if let eventTap { CFMachPortInvalidate(eventTap) }; eventTap = nil
    }
    @objc private func shutdown() { disconnect(); timer?.invalidate(); timer = nil; removeTap() }
}
