/** Native sprite voice capture: active native receiver and asynchronous system-focus verification before Option; common-mode polling and shared live/final text; finalization through TaskService. Logs contain focus state and lengths, never transcript text. */
import AppKit
import ApplicationServices

final class SpriteDesktopInput: NSObject, NSTextFieldDelegate {
    private static let localControlSession = UUID().uuidString
    static func authorizes(_ task: AgentTask) -> Bool {
        task.controlSession == localControlSession && !LockScreenInput.locked
    }
    private let panel: SpriteFeedbackPanel
    private let headset = HeadsetLongPress()
    private var optionDown = false
    private var customVoiceKey: HeadsetKey?
    private var customVoiceToggle = false
    private let customVoiceEmitter = HeadsetKeyEmitter()
    private var recording = false
    private var voiceObserved = false
    private var textObserved = false
    private var triggerAt: Date?
    private var triggerUptime: TimeInterval?
    private var captureGeneration = 0
    private var releasedAt: Date?
    private var changedAt = Date()
    private var previousText = ""
    private var taskId: String?
    private var routingInput = false
    private var continuationPending = false
    private var timer: Timer?
    init(panel: SpriteFeedbackPanel) {
        self.panel = panel
        super.init()
        panel.desktopInput.delegate = self
        panel.onDesktopInterrupted = { [weak self] reason in self?.cancel(reason) }
        headset.onBegin = { [weak self] in self?.begin() }
        headset.onEnd = { [weak self] in self?.end() }
        headset.onCancel = { [weak self] in self?.cancel("headset interrupted") }
        headset.start()
        HeadsetClickControl.shared.onSpriteBegin = { [weak self] in self?.begin(); return self?.recording == true }
        HeadsetClickControl.shared.onSpriteEnd = { [weak self] in self?.end() }
        HeadsetClickControl.shared.onSpriteCancel = { [weak self] in self?.cancel("headset click cancelled") }
        HeadsetClickControl.shared.onSpriteRecording = { [weak self] in self?.recording == true }
        HeadsetClickControl.shared.onSpriteText = { [weak self] in
            guard let self, self.recording, self.panel.desktopMode, self.panel.isKeyWindow else { return nil }
            return self.panel.desktopText
        }
        HeadsetClickControl.shared.onSpriteStatus = { [weak self] in self?.panel.desktopStatus($0) }
        HeadsetClickControl.shared.start()
        HeadsetMappingActions.shared.spriteBegin = { [weak self] key, toggle in
            guard let self, !self.recording else { return false }
            self.begin(key:key,toggle:toggle); return self.recording
        }
        HeadsetMappingActions.shared.spriteWake = { [weak self] in
            guard let self else { return false }; self.cancel()
            let opened = self.panel.beginDesktopCapture(); self.panel.desktopStatus("小精灵已唤醒，可输入后按 Enter 提交"); return opened
        }
        HeadsetMappingActions.shared.spriteEnd = { [weak self] in
            guard let self else { return }; if self.recording { self.end() } else if self.panel.desktopMode { self.releasedAt = Date(); self.changedAt = Date() }
        }
        HeadsetMappingActions.shared.spriteCancel = { [weak self] in self?.cancel(); self?.panel.endDesktopCapture(); self?.panel.orderOut(nil) }
        HeadsetMappingActions.shared.spriteBusy = { [weak self] in self?.recording == true }
        HeadsetMappingRuntime.shared.start()
        timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(terminating), name: NSApplication.willTerminateNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(terminating), name: .init("com.apple.screenIsLocked"), object: nil)
    }
    private func option(_ down: Bool) {
        guard down != optionDown else { return }
        if let key = customVoiceKey {
            let sent = customVoiceToggle ? customVoiceEmitter.tap(key) : customVoiceEmitter.set(key, down: down)
            if sent { optionDown = down }
            return
        }
        optionDown = down
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20) : []
        event.post(tap: .cghidEventTap)
    }
    private func begin(key: HeadsetKey? = nil, toggle: Bool = false) {
        guard !LockScreenInput.locked, AXIsProcessTrusted() else { return }
        guard !recording else { return }
        // A new deliberate hold replaces a failed/pending transcript immediately.
        if releasedAt != nil { cancel() }
        customVoiceKey = key; customVoiceToggle = toggle
        captureGeneration += 1
        let generation = captureGeneration
        let beganAt = ProcessInfo.processInfo.systemUptime
        guard panel.beginDesktopCapture() else { return }
        recording = true; voiceObserved = false; textObserved = false; triggerAt = nil; triggerUptime = nil; previousText = ""
        let subject = String(Auth.token.prefix(8))
        // TaskStore can be writing a large snapshot. Resolve continuation alongside
        // startup, then require completion before submitting the final transcript.
        continuationPending = true
        let existingTaskId = taskId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var resolvedTaskId = existingTaskId
            if resolvedTaskId == nil {
                let latest = TaskStore.all().filter { $0.subject == subject }.max { $0.updatedAt < $1.updatedAt }
                if let latest, TaskContinuation.isCandidate(latest, subject: subject) { resolvedTaskId = latest.id }
            }
            let preparedTaskId = resolvedTaskId
            DispatchQueue.main.async {
                guard let self, self.captureGeneration == generation else { return }
                self.taskId = preparedTaskId
                self.continuationPending = false
                HeadsetLog(String(format: "sprite startup: continuation prepared after %.0f ms", (ProcessInfo.processInfo.systemUptime - beganAt) * 1000))
            }
        }
        startWhenFocused(generation: generation, beganAt: beganAt)
    }
    private func startWhenFocused(generation: Int, beganAt: Double) {
        guard captureGeneration == generation, recording, !LockScreenInput.locked else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - beganAt
        if panel.desktopInputReady {
            // Read system AX off the main thread: this app's accessibility responses
            // can themselves need the main thread. The local key window/editor must
            // still be the same receiver when the asynchronous result returns.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let focusedPID = InputFocus.focusedApplicationPID()
                DispatchQueue.main.async {
                    guard let self, self.captureGeneration == generation, self.recording, !LockScreenInput.locked else { return }
                    if focusedPID == ProcessInfo.processInfo.processIdentifier, self.panel.desktopInputReady,
                       ProcessInfo.processInfo.systemUptime - beganAt <= 1 {
                        self.option(true)
                        self.triggerAt = Date()
                        self.triggerUptime = ProcessInfo.processInfo.systemUptime
                        HeadsetLog(String(format: "sprite startup: Option sent after %.0f ms; system focus verified", (ProcessInfo.processInfo.systemUptime - beganAt) * 1000))
                    } else if ProcessInfo.processInfo.systemUptime - beganAt < 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.startWhenFocused(generation: generation, beganAt: beganAt) }
                    } else {
                        self.cancel("system input focus not acquired; pid=\(focusedPID.map(String.init) ?? "unknown")")
                        self.panel.desktopStatus("未取得语音输入焦点，请重试")
                    }
                }
            }
        } else if elapsed < 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.startWhenFocused(generation: generation, beganAt: beganAt)
            }
        } else {
            cancel("local input focus timeout")
            panel.desktopStatus("未能聚焦语音输入，请重试")
            HeadsetLog("sprite startup: focus timeout; no Option sent")
        }
    }
    private func end() {
        guard recording else { return }
        recording = false; option(false)
        releasedAt = Date(); changedAt = Date()
        panel.desktopStatus("正在完成转写…")
        HeadsetLog("sprite capture ended; editorChars=\(panel.desktopText.utf16.count) controlChars=\(panel.desktopInput.stringValue.utf16.count) marked=\(panel.desktopHasMarkedText)")
        NSLog("PocketDesk headset released; waiting for transcript")
    }
    private func cancel(_ reason: String = "cancelled") {
        if recording || releasedAt != nil {
            HeadsetLog("sprite capture cancelled: \(reason); editorChars=\(panel.desktopText.utf16.count) controlChars=\(panel.desktopInput.stringValue.utf16.count)")
        }
        captureGeneration += 1
        recording = false; releasedAt = nil; triggerAt = nil; triggerUptime = nil; continuationPending = false; option(false)
    }
    @objc private func terminating() { cancel() }
    private func dictationVisible() -> Bool {
        let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix("com.bytedance.inputmethod") == true }.map(\.processIdentifier))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] else { return false }
        return windows.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let b = w[kCGWindowBounds as String] as? [String:Any],
                  let width = b["Width"] as? Double, let height = b["Height"] as? Double else { return false }
            return width >= 80 && height >= 25
        }
    }
    private func tick() {
        panel.updateDesktopSubtitle()
        if LockScreenInput.locked { cancel(); return }
        if recording, let triggerAt {
            let text = panel.desktopText
            if !voiceObserved && dictationVisible() {
                voiceObserved = true
                if !textObserved { panel.desktopStatus("语音已唤醒，等待文字…") }
                HeadsetLog(String(format: "sprite startup: dictation window observed %.0f ms after Option", Date().timeIntervalSince(triggerAt) * 1000))
            }
            if !textObserved && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textObserved = true
                panel.desktopStatus(HeadsetClickControl.shared.spriteListeningStatus ?? "正在听 · 松开执行")
                let elapsed = triggerUptime.map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 } ?? 0
                HeadsetLog(String(format: "sprite transcription received %.0f ms after Option; chars=%d marked=%@", elapsed, text.utf16.count, String(panel.desktopHasMarkedText)))
            }
            if !textObserved && Date().timeIntervalSince(triggerAt) > 2 {
                panel.desktopStatus(voiceObserved ? "语音已唤醒，尚未收到文字…" : "尚未检测到语音转写，请结束后检查快捷键")
            }
        }
        if let released = releasedAt {
            guard panel.desktopMode, panel.isKeyWindow else { cancel("input window lost after release"); return }
            let text = panel.desktopText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text != previousText { previousText = text; changedAt = Date() }
            if Date().timeIntervalSince(released) > 15 {
                let waitingForContinuation = continuationPending
                cancel(waitingForContinuation ? "continuation preparation timeout" : "final transcription timeout")
                panel.desktopStatus(waitingForContinuation ? "任务接续核对未完成，未执行" : "未收到完整转写，未执行"); return
            }
            guard !continuationPending, !text.isEmpty, Date().timeIntervalSince(released) >= 0.6,
                  Date().timeIntervalSince(changedAt) >= 0.6, !dictationVisible(),
                  !panel.desktopHasMarkedText else { return }
            releasedAt = nil
            routingInput = true
            panel.desktopStatus("正在理解你的补充…")
            TaskService.send(subject: String(Auth.token.prefix(8)), requestId: UUID().uuidString,
                text: text, context: nil, controlSession: Self.localControlSession, previousTaskId: taskId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.routingInput = false
                    switch result {
                    case .success(let task):
                        self.taskId = task.id
                        self.panel.desktopStatus(task.status.displayName, result: task.result ?? text)
                        NSLog("PocketDesk headset submitted task %@", task.id)
                    case .failure(let error): self.panel.desktopStatus("原任务已保留", result: error.localizedDescription)
                    }
                }
            }
        } else if !recording, !routingInput, let id = taskId, panel.desktopMode, let task = TaskStore.task(id: id) {
            let hint = task.json()["continuationHint"] as? String
            let result = task.result ?? task.error ?? task.text
            panel.desktopStatus(task.status.displayName, result: hint.map { result + "\n\n" + $0 } ?? result)
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel(); panel.endDesktopCapture(); panel.orderOut(nil); return true
        }
        // Do not let a stray Enter submit before the held button is released.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if !recording && panel.desktopMode { releasedAt = Date(); changedAt = Date() }
            return true
        }
        return false
    }
}
