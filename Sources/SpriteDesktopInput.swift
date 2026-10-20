/**
 * [INPUT]: 依赖原生小精灵接收框、系统输入焦点、耳机默认/自定义操作与 TaskService。
 * [OUTPUT]: 显式恢复选择绑定原任务，重试直接提交并封住连点；可见文字输入切换话题保留草稿，转语音沿用同一字段；默认语音仍按语义判断归属。接收框焦点交接在共享有界准备期内确认后立即唤起豆包，超时记录归属和分段耗时，快捷键前与失败时记录接收框AX/输入法/修饰键事实，并只读观察本进程带标记的修饰键到达；同源转写、组合文字稳定提交、取消及迟到清理共用既有代际与焦点门禁；接收状态用简短标题，具体失败原因仅记日志，不记录正文。
 * [POS]: Sources 的桌面语音适配层；复用普通语音链路的豆包窗口判断，收尾组合文字后交给 TaskService，不承担语音识别。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
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
    private var voiceShortcutRequested = false
    private var customVoiceKey: HeadsetKey?
    private var customVoiceToggle = false
    private let voiceEmitter: HeadsetKeyEmitter
    private let focusedPID: () -> pid_t?
    private let dictationPanelVisible: () -> Bool
    private let uptime: () -> TimeInterval
    private let environmentAllows: () -> Bool
    private let voiceLog: (String) -> Void
    private let connectHeadset: Bool
    private var legacyCaptureGeneration: Int?
    private var recording = false
    private var voiceObserved = false
    private var textObserved = false
    private var voiceOriginalText = ""
    private var triggerAt: Date?
    private var triggerUptime: TimeInterval?
    private var captureGeneration = 0
    private var releasedAt: Date?
    private var changedAt = Date()
    private var previousText = ""
    private var taskId: String?
    private var inputContextTaskId: String?
    private var showingTask = false
    private var routingInput = false
    private var continuationPending = false
    private var inputIntent: TaskRecovery.InputIntent = .automatic
    private var preparedInput = false
    private var timer: Timer?
    private var shortcutMonitor: Any?
    private struct DictationCancellation {
        let generation: Int
        let beganAt: TimeInterval
        var retried = false
    }
    private var dictationCancellation: DictationCancellation?
    // ---------- 松开等待诊断 ----------
    // 诊断采用单调时钟；原有转写、焦点与代际门禁仍由提交链路决定。
    private struct ReleaseDiagnostics {
        let startedAt: TimeInterval
        var lastTickAt: TimeInterval
        var reason = "initial"
        var reasonAt: TimeInterval
        var waits: [String: TimeInterval] = [:]
        var maxTickGap: TimeInterval = 0
        var slowTickGaps: TimeInterval = 0
        var dictationProbeTotal: TimeInterval = 0
        var dictationProbeMax: TimeInterval = 0
        init(now: TimeInterval) { startedAt = now; lastTickAt = now; reasonAt = now }
        mutating func changeReason(_ next: String, now: TimeInterval) -> Bool {
            guard reason != next else { return false }
            waits[reason, default: 0] += max(0, now - reasonAt)
            reason = next; reasonAt = now
            return true
        }
        func summary(now: TimeInterval) -> String {
            var totals = waits
            totals[reason, default: 0] += max(0, now - reasonAt)
            let segments = totals.keys.sorted().map { String(format: "%@=%.0f", $0, totals[$0, default: 0] * 1000) }.joined(separator: ",")
            return String(format: "waitMs=%.0f maxTickGapMs=%.0f slowTickGapMs=%.0f dictationWaitMs=%.0f dictationProbeMs=%.0f maxDictationProbeMs=%.0f gateMs=[%@]",
                          max(0, now - startedAt) * 1000, maxTickGap * 1000, slowTickGaps * 1000,
                          totals["dictation-visible", default: 0] * 1000, dictationProbeTotal * 1000,
                          dictationProbeMax * 1000, segments)
        }
    }
    private var releaseDiagnostics: ReleaseDiagnostics?
    init(panel: SpriteFeedbackPanel, connectHeadset: Bool = true,
         emitter: HeadsetKeyEmitter = HeadsetKeyEmitter(),
         focusedPID: @escaping () -> pid_t? = { InputFocus.focusedApplicationPID() },
         dictationPanelVisible: @escaping () -> Bool = { HeadsetController.shared.panelVisible() },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         environmentAllows: @escaping () -> Bool = { !LockScreenInput.locked && AXIsProcessTrusted() },
         voiceLog: @escaping (String) -> Void = HeadsetLog) {
        self.panel = panel
        voiceEmitter = emitter; self.focusedPID = focusedPID
        self.dictationPanelVisible = dictationPanelVisible; self.uptime = uptime
        self.environmentAllows = environmentAllows
        self.voiceLog = voiceLog
        self.connectHeadset = connectHeadset
        super.init()
        panel.desktopInput.delegate = self
        panel.onDesktopInterrupted = { [weak self] reason in self?.cancel(reason) }
        panel.onRecoveryInputRequested = { [weak self] taskId, intent in self?.prepareRecoveryInput(taskId: taskId, intent: intent) }
        panel.onRecoveryRetryRequested = { [weak self] taskId in self?.retryTask(taskId) }
        panel.onInputIntentChanged = { [weak self] intent in self?.changeInputIntent(intent) }
        panel.onDesktopSubmitRequested = { [weak self] in self?.requestTextSubmission() }
        guard connectHeadset else { return }
        // ---------- 区分已投递与本应用实际收到 ----------
        // 只观察本进程带标记的修饰键，不修改事件、不记录普通键或正文。
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let self, event.cgEvent?.getIntegerValueField(.eventSourceUserData) == HeadsetMarker {
                self.voiceLog("sprite shortcut received; code=\(event.keyCode) flags=\(event.modifierFlags.rawValue) receiverReady=\(self.panel.desktopInputReady)")
            }
            return event
        }
        headset.onDismissInput = { [weak self] in self?.dismissLegacyHeadsetInput() ?? false }
        headset.onBegin = { [weak self] in self?.beginLegacyHeadsetCapture() }
        headset.onEnd = { [weak self] in self?.endLegacyHeadsetCapture() }
        headset.onCancel = { [weak self] in
            guard let self, self.legacyCaptureGeneration == self.captureGeneration else { return }
            self.cancel("headset interrupted")
        }
        headset.start()
        HeadsetClickControl.shared.onSpriteBegin = { [weak self] in self?.begin(); return self?.recording == true }
        HeadsetClickControl.shared.onSpriteEnd = { [weak self] in self?.end() }
        HeadsetClickControl.shared.onSpriteCancel = { [weak self] in self?.dismissInput() }
        HeadsetClickControl.shared.onSpriteDismissInput = { [weak self] in self?.dismissInput() ?? false }
        HeadsetClickControl.shared.onSpriteContinueVoice = { [weak self] in self?.continueVoice() ?? .unavailable }
        HeadsetClickControl.shared.onSpriteRecording = { [weak self] in self?.recording == true }
        HeadsetClickControl.shared.onSpriteText = { [weak self] in
            guard let self, self.recording, self.panel.desktopInputReady else { return nil }
            return self.panel.desktopText
        }
        HeadsetClickControl.shared.onSpriteStatus = { [weak self] _ in
            guard let self, self.voiceObserved || self.textObserved else { return }
            self.panel.desktopStatus("正在听")
        }
        HeadsetClickControl.shared.start()
        HeadsetMappingActions.shared.spriteBegin = { [weak self] key, toggle in
            guard let self, !self.recording else { return false }
            self.begin(key:key,toggle:toggle); return self.recording
        }
        HeadsetMappingActions.shared.spriteWake = { [weak self] in
            guard let self else { return false }; self.cancel()
            let opened = self.panel.beginDesktopCapture(); self.preparedInput = opened
            self.panel.desktopStatus("小精灵已唤醒"); return opened
        }
        HeadsetMappingActions.shared.spriteDismissInput = { [weak self] in self?.dismissInput() ?? false }
        HeadsetMappingActions.shared.spriteContinueVoice = { [weak self] key, toggle in self?.continueVoice(key: key, toggle: toggle) ?? .unavailable }
        HeadsetMappingActions.shared.spriteContinueHeldVoice = { [weak self] key, toggle in self?.continueHeldVoice(key: key, toggle: toggle) ?? .unavailable }
        HeadsetMappingActions.shared.spriteEnd = { [weak self] in
            guard let self else { return }; if self.recording { self.end() } else if self.panel.desktopMode {
                self.releasedAt = Date(); self.changedAt = Date(); self.startReleaseDiagnostics()
            }
        }
        HeadsetMappingActions.shared.spriteCancel = { [weak self] in self?.dismissInput() }
        HeadsetMappingActions.shared.spriteBusy = { [weak self] in self?.recording == true }
        HeadsetMappingActions.shared.spriteText = HeadsetClickControl.shared.onSpriteText
        HeadsetMappingRuntime.shared.start()
        timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(terminating), name: NSApplication.willTerminateNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(terminating), name: .init("com.apple.screenIsLocked"), object: nil)
    }
    // ---------- 默认有线唤醒与自定义操作共用接收层裁决 ----------
    deinit { if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) } }

    @discardableResult func dismissLegacyHeadsetInput() -> Bool {
        guard dismissInput() else { return false }
        legacyCaptureGeneration = nil
        return true
    }
    func beginLegacyHeadsetCapture() {
        guard !dismissLegacyHeadsetInput() else { return }
        begin()
        legacyCaptureGeneration = recording ? captureGeneration : nil
    }
    func endLegacyHeadsetCapture() {
        guard legacyCaptureGeneration == captureGeneration else { return }
        end()
    }
    @discardableResult private func option(_ down: Bool) -> Bool {
        guard down != optionDown else { return true }
        let key = customVoiceKey ?? HeadsetKey.parse("LeftOption")!
        // ---------- 点按开关的未知状态 ----------
        // 尚未观察到启动时，第二次点按可能反而打开录音；只撤销拥有权，等待用户明确重试。
        if customVoiceToggle, !down, !voiceObserved, !textObserved {
            optionDown = false; return true
        }
        let sent = customVoiceToggle ? voiceEmitter.tap(key) : voiceEmitter.set(key, down: down)
        if sent { optionDown = down }
        if !down { voiceLog("sprite shortcut release requested; sent=\(sent); code=\(key.code)") }
        return sent
    }
    private var inputOpen: Bool { panel.desktopMode && !panel.desktopInput.isHidden && panel.isVisible && !routingInput }

    /// 唤醒键只取消尚未提交的输入；已执行任务沿用任务服务的生命周期。
    @discardableResult func dismissInput() -> Bool {
        guard inputOpen else { return false }
        if let pending = dictationCancellation {
            if uptime() - pending.beganAt >= HeadsetVoiceTiming.cancellationConfirmationSeconds {
                dictationCancellation = .init(generation: captureGeneration, beganAt: uptime())
                requestDictationCancellation()
            }
            return true
        }
        let voiceWasRequested = voiceShortcutRequested || optionDown || triggerUptime != nil || voiceObserved || textObserved || releasedAt != nil
        cancel("explicit input dismissal")
        guard voiceWasRequested, panel.desktopInputReady else {
            panel.dismissDesktopCapture(); return true
        }
        // ---------- 取消必须保留输入法的宿主焦点 ----------
        // Option 松开只结束录音；Esc 取消识别。先核验语音条关闭，再移除 field editor。
        dictationCancellation = .init(generation: captureGeneration, beganAt: uptime())
        panel.desktopStatus("正在取消语音…")
        requestDictationCancellation()
        return true
    }
    private func requestDictationCancellation() {
        guard let pending = dictationCancellation, pending.generation == captureGeneration,
              panel.desktopInputReady, environmentAllows() else { return }
        // 系统 AX 在后台读取；本地 key 状态不能代替真实键盘接收进程。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pid = self?.focusedPID()
            DispatchQueue.main.async {
                guard let self, let current = self.dictationCancellation,
                      current.generation == pending.generation, current.beganAt == pending.beganAt,
                      self.captureGeneration == pending.generation else { return }
                guard pid == ProcessInfo.processInfo.processIdentifier,
                      self.panel.desktopInputReady, self.environmentAllows() else {
                    self.dictationCancellation = nil
                    self.voiceLog("sprite cancellation: system focus lost; no Escape sent; closure unconfirmed")
                    self.panel.dismissDesktopCapture(); return
                }
                let sent = self.voiceEmitter.tap(HeadsetKey.parse("Esc")!)
                self.voiceLog("sprite cancellation: Escape requested; sent=\(sent); system focus verified")
            }
        }
    }
    private func pollDictationCancellation() {
        guard var pending = dictationCancellation else { return }
        guard pending.generation == captureGeneration else { dictationCancellation = nil; return }
        guard panel.desktopInputReady, environmentAllows() else {
            dictationCancellation = nil
            voiceLog("sprite cancellation: focus lost; no further Escape sent; closure unconfirmed")
            panel.dismissDesktopCapture(); return
        }
        let elapsed = uptime() - pending.beganAt
        guard elapsed >= HeadsetVoiceTiming.cancellationProbeSeconds else { return }
        if !dictationVisible() {
            dictationCancellation = nil
            voiceLog("sprite cancellation: dictation window closed; dismissing receiver")
            panel.dismissDesktopCapture(); return
        }
        if !pending.retried, elapsed >= HeadsetVoiceTiming.cancellationRetrySeconds {
            pending.retried = true; dictationCancellation = pending
            requestDictationCancellation()
        }
        if elapsed >= HeadsetVoiceTiming.cancellationConfirmationSeconds {
            panel.desktopStatus("语音未关闭")
        }
    }

    /// 普通语音键在小精灵输入期间改走同源接收框，避免落入其他应用或重复启动快捷键。
    func continueVoice(key: HeadsetKey? = nil, toggle: Bool = false) -> HeadsetSpriteVoiceAction {
        guard inputOpen else { return .unavailable }
        if dictationCancellation != nil { return .waiting }
        if releasedAt != nil { return .waiting }
        if recording {
            guard voiceObserved || textObserved else { return .waiting }
            end(); return .ended
        }
        preparedInput = true
        begin(key: key, toggle: toggle)
        return recording ? .started : .waiting
    }

    /// 有线中键接管同一接收框时保留按住/松开语义，不把按下误解释为点击结束。
    func continueHeldVoice(key: HeadsetKey? = nil, toggle: Bool = false) -> HeadsetSpriteVoiceAction {
        guard inputOpen else { return .unavailable }
        guard dictationCancellation == nil, releasedAt == nil, !routingInput else { return .waiting }
        retireRecordingOwners()
        legacyCaptureGeneration = nil
        if recording { return .started }
        return continueVoice(key: key, toggle: toggle)
    }
    private func begin(key: HeadsetKey? = nil, toggle: Bool = false) {
        guard environmentAllows() else { return }
        guard !recording, dictationCancellation == nil else { return }
        retireRecordingOwners()
        releaseDiagnostics = nil
        let intent = preparedInput ? inputIntent : .automatic
        let reuseReceiver = preparedInput && inputOpen
        // 明确重开替换待转写；从恢复入口转为语音时保留已经打下的补充。
        if releasedAt != nil { cancel() }
        customVoiceKey = key; customVoiceToggle = toggle
        captureGeneration += 1
        let generation = captureGeneration
        let beganAt = uptime()
        if reuseReceiver {
            if !panel.desktopInputReady, !panel.resumeDesktopCapture() { return }
            panel.useVoicePresentation()
            panel.desktopStatus("准备中")
        }
        else if !panel.beginDesktopCapture(intent: intent, continuing: intent == .supplement) { return }
        inputIntent = intent; preparedInput = false
        recording = true; routingInput = false; showingTask = false; voiceObserved = false; textObserved = false; triggerAt = nil; triggerUptime = nil; previousText = ""
        voiceShortcutRequested = false
        voiceOriginalText = panel.desktopText
        let subject = String(Auth.token.prefix(8))
        // TaskStore can be writing a large snapshot. Resolve continuation alongside
        // startup, then require completion before submitting the final transcript.
        continuationPending = true
        let existingTaskId = taskId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var resolvedTaskId = intent == .newTask ? nil : existingTaskId
            if intent == .automatic {
                if let id = resolvedTaskId, TaskStore.task(id: id).map({ !TaskContinuation.isCandidate($0, subject: subject) }) ?? true { resolvedTaskId = nil }
            }
            if intent == .automatic, resolvedTaskId == nil {
                let latest = TaskStore.all().filter { $0.subject == subject }.max { $0.updatedAt < $1.updatedAt }
                if let latest, TaskContinuation.isCandidate(latest, subject: subject) { resolvedTaskId = latest.id }
            }
            let preparedTaskId = resolvedTaskId
            DispatchQueue.main.async {
                guard let self, self.captureGeneration == generation else { return }
                self.taskId = preparedTaskId
                self.panel.setDesktopInputContext(intent: intent, continuing: preparedTaskId != nil)
                self.continuationPending = false
                self.voiceLog(String(format: "sprite startup: continuation prepared after %.0f ms", (self.uptime() - beganAt) * 1000))
            }
        }
        startWhenFocused(generation: generation, beganAt: beganAt)
    }

    /// 用户点选恢复意图后进入同一接收框；不私自录音或执行，输入完成仍走提交门禁。
    private func prepareRecoveryInput(taskId: String?, intent: TaskRecovery.InputIntent) {
        // 清理上一轮默认拥有者，再建立新意图；否则下一次耳机点击会把准备好的补充取消。
        HeadsetClickControl.shared.cancelCurrent()
        cancel()
        inputContextTaskId = taskId
        self.taskId = intent == .newTask ? nil : taskId
        inputIntent = intent
        let previous = taskId.flatMap { TaskStore.task(id: $0) }
        let summary = previous?.messages.first(where: { $0.role == .user })?.text ?? previous?.text ?? ""
        let question = previous.flatMap { TaskRecovery.forTask($0)?.kind == .clarification ? $0.result ?? $0.error : nil } ?? ""
        guard panel.beginDesktopCapture(intent: intent, continuing: intent == .supplement,
                                        textEntry: true, summary: summary, question: question, canReturn: taskId != nil) else { return }
        preparedInput = true
        panel.desktopStatus(intent == .newTask ? "想做什么？" : "说说要补充的内容")
    }
    private func changeInputIntent(_ intent: TaskRecovery.InputIntent) {
        guard inputOpen, !recording, releasedAt == nil else { return }
        inputIntent = intent; taskId = intent == .newTask ? nil : inputContextTaskId
        panel.setDesktopInputContext(intent: intent, continuing: taskId != nil)
        panel.desktopStatus(intent == .newTask ? "想做什么？" : "说说要补充的内容")
    }
    private func requestTextSubmission() {
        guard inputOpen, !recording, !panel.desktopText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        releasedAt = Date(); changedAt = Date(); startReleaseDiagnostics()
    }
    private func retryTask(_ id: String) {
        guard !routingInput, !recording, !LockScreenInput.locked,
              let task = TaskStore.task(id: id) else { return }
        guard TaskRecovery.forTask(task) != nil, TaskRecovery.action(for: task).kind == .retry else {
            taskId = id; showingTask = true
            panel.beginDesktopRetry(); panel.desktopTask(task); return
        }
        if inputOpen, !panel.desktopText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputContextTaskId = id; changeInputIntent(.supplement); return
        }
        cancel()
        taskId = id; inputIntent = .supplement; routingInput = true
        panel.beginDesktopRetry()
        submitInput("继续处理刚才的请求", generation: captureGeneration)
    }
    private func startWhenFocused(generation: Int, beganAt: Double) {
        guard captureGeneration == generation, recording else { return }
        guard environmentAllows() else { prepareVoiceRetry("语音输入环境已变化"); return }
        let elapsed = uptime() - beganAt
        let budget = HeadsetVoiceTiming.focusPreparationSeconds
        if panel.desktopInputReady {
            // 原焦点保存、应用激活和系统 AX 读回都在同一准备期内；本地 key 不能代替真实归属。
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let readAt = self.uptime()
                let focusedPID = self.focusedPID()
                let readDuration = self.uptime() - readAt
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.captureGeneration == generation, self.recording else { return }
                    guard self.environmentAllows() else { self.prepareVoiceRetry("语音输入环境已变化"); return }
                    let elapsed = self.uptime() - beganAt
                    if focusedPID == ProcessInfo.processInfo.processIdentifier, self.panel.desktopInputReady,
                       elapsed <= budget {
                        self.voiceLog("sprite startup: receiver before shortcut; " + self.panel.desktopVoiceDiagnostics)
                        guard self.option(true) else { self.prepareVoiceRetry("语音快捷键未发出"); return }
                        self.voiceShortcutRequested = true
                        self.triggerAt = Date()
                        self.triggerUptime = self.uptime()
                        self.voiceLog(String(format: "sprite startup: Option sent after %.0f ms; system focus verified; focusReadMs=%.0f", elapsed * 1000, readDuration * 1000))
                    } else if elapsed < budget {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.startWhenFocused(generation: generation, beganAt: beganAt) }
                    } else {
                        self.voiceLog(String(format: "sprite startup: focus confirmation timeout; elapsedMs=%.0f focusReadMs=%.0f ownerPID=%@ expectedPID=%d editorReady=%@ key=%@ active=%@", elapsed * 1000, readDuration * 1000,
                            focusedPID.map(String.init) ?? "unknown", ProcessInfo.processInfo.processIdentifier,
                            String(self.panel.desktopInputReady), String(self.panel.isKeyWindow), String(NSApp.isActive)))
                        self.prepareVoiceRetry("未取得语音输入焦点")
                    }
                }
            }
        } else if elapsed < budget {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.startWhenFocused(generation: generation, beganAt: beganAt)
            }
        } else {
            voiceLog(String(format: "sprite startup: receiver focus timeout; elapsedMs=%.0f editorReady=%@ key=%@ active=%@; no Option sent", elapsed * 1000,
                String(panel.desktopInputReady), String(panel.isKeyWindow), String(NSApp.isActive)))
            prepareVoiceRetry("未能聚焦语音输入")
        }
    }
    private func end() {
        guard recording else { return }
        recording = false; option(false)
        retireRecordingOwners()
        releasedAt = Date(); changedAt = Date()
        startReleaseDiagnostics()
        voiceLog("sprite capture ended; editorChars=\(panel.desktopText.utf16.count) controlChars=\(panel.desktopInput.stringValue.utf16.count) marked=\(panel.desktopHasMarkedText)")
        NSLog("PocketDesk headset released; waiting for transcript")
    }
    private func prepareVoiceRetry(_ reason: String) {
        voiceLog("sprite startup: receiver at failure; " + panel.desktopVoiceDiagnostics)
        captureGeneration += 1
        recording = false; releasedAt = nil; triggerAt = nil; triggerUptime = nil
        continuationPending = false; releaseDiagnostics = nil
        option(false); preparedInput = true
        retireRecordingOwners()
        panel.desktopStatus("语音未启动")
        voiceLog("sprite startup: awaiting explicit retry; reason=\(reason)")
    }
    private func cancel(_ reason: String = "cancelled") {
        if recording || releasedAt != nil {
            voiceLog("sprite capture cancelled: \(reason); editorChars=\(panel.desktopText.utf16.count) controlChars=\(panel.desktopInput.stringValue.utf16.count)")
        }
        captureGeneration += 1
        dictationCancellation = nil
        recording = false; releasedAt = nil; triggerAt = nil; triggerUptime = nil; continuationPending = false
        releaseDiagnostics = nil
        routingInput = false; showingTask = false; option(false)
        voiceShortcutRequested = false
        retireRecordingOwners()
        preparedInput = false; inputIntent = .automatic
    }
    /// 同步退休两条入口的旧拥有者；不能等轮询，否则旧停顿/松开可能结束新录音。
    private func retireRecordingOwners() {
        guard connectHeadset else { return }
        HeadsetClickControl.shared.retireSpriteRecording()
        HeadsetMappingActions.shared.retireSpriteRecording()
    }
    @objc private func terminating() { cancel() }
    private func dictationVisible() -> Bool {
        dictationPanelVisible()
    }
    private func startReleaseDiagnostics() {
        releaseDiagnostics = ReleaseDiagnostics(now: ProcessInfo.processInfo.systemUptime)
    }
    private func recordReleaseTick() {
        guard var diagnostics = releaseDiagnostics else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let gap = max(0, now - diagnostics.lastTickAt)
        diagnostics.lastTickAt = now
        diagnostics.maxTickGap = max(diagnostics.maxTickGap, gap)
        if gap > 0.45 {
            diagnostics.slowTickGaps += gap
            voiceLog(String(format: "sprite finalization: tick gap %.0f ms; waitMs=%.0f reason=%@", gap * 1000,
                              (now - diagnostics.startedAt) * 1000, diagnostics.reason))
        }
        releaseDiagnostics = diagnostics
    }
    private func recordReleaseWait(_ reason: String, released: Date, chars: Int) {
        guard var diagnostics = releaseDiagnostics,
              diagnostics.changeReason(reason, now: ProcessInfo.processInfo.systemUptime) else { return }
        releaseDiagnostics = diagnostics
        voiceLog(String(format: "sprite finalization: gate=%@ releaseMs=%.0f stableMs=%.0f chars=%d marked=%@ editorReady=%@ key=%@ active=%@",
                          reason, Date().timeIntervalSince(released) * 1000, Date().timeIntervalSince(changedAt) * 1000,
                          chars, String(panel.desktopHasMarkedText), String(panel.desktopInputReady),
                          String(panel.isKeyWindow), String(NSApp.isActive)))
    }
    private func recordDictationProbe(_ elapsed: TimeInterval) {
        guard var diagnostics = releaseDiagnostics else { return }
        diagnostics.dictationProbeTotal += elapsed
        diagnostics.dictationProbeMax = max(diagnostics.dictationProbeMax, elapsed)
        if elapsed > 0.15 {
            voiceLog(String(format: "sprite finalization: dictation probe %.0f ms; waitMs=%.0f", elapsed * 1000,
                              (ProcessInfo.processInfo.systemUptime - diagnostics.startedAt) * 1000))
        }
        releaseDiagnostics = diagnostics
    }
    func tick() {
        if LockScreenInput.locked { cancel(); return }
        if dictationCancellation != nil { pollDictationCancellation(); return }
        if releasedAt != nil { recordReleaseTick() }
        panel.updateDesktopSubtitle()
        if recording, let triggerAt {
            let text = panel.desktopText
            if !voiceObserved && dictationVisible() {
                voiceObserved = true
                if !textObserved { panel.desktopStatus("正在听") }
                voiceLog(String(format: "sprite startup: dictation window observed %.0f ms after Option", Date().timeIntervalSince(triggerAt) * 1000))
            }
            if !textObserved && text != voiceOriginalText && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textObserved = true
                panel.desktopStatus("正在听")
                let elapsed = triggerUptime.map { (uptime() - $0) * 1000 } ?? 0
                voiceLog(String(format: "sprite transcription received %.0f ms after Option; chars=%d marked=%@", elapsed, text.utf16.count, String(panel.desktopHasMarkedText)))
            }
            if !voiceObserved && !textObserved, let postedAt = triggerUptime,
               uptime() - postedAt >= HeadsetVoiceTiming.startupObservationSeconds {
                prepareVoiceRetry("尚未检测到语音启动")
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
            guard !continuationPending else { recordReleaseWait("continuation", released: released, chars: text.utf16.count); return }
            guard !text.isEmpty else { recordReleaseWait("empty-text", released: released, chars: 0); return }
            guard Date().timeIntervalSince(released) >= HeadsetVoiceTiming.finalTextStabilitySeconds else {
                recordReleaseWait("release-stability", released: released, chars: text.utf16.count); return
            }
            guard Date().timeIntervalSince(changedAt) >= HeadsetVoiceTiming.finalTextStabilitySeconds else {
                recordReleaseWait("text-stability", released: released, chars: text.utf16.count); return
            }
            let probeAt = ProcessInfo.processInfo.systemUptime
            let visible = dictationVisible()
            recordDictationProbe(max(0, ProcessInfo.processInfo.systemUptime - probeAt))
            guard !visible else { recordReleaseWait("dictation-visible", released: released, chars: text.utf16.count); return }
            // ---------- 豆包收尾 ----------
            // 语音窗已关闭且文字稳定后，接受同一接收框的残留组合文字；不再等待输入法清除旧标记。
            let hadMarkedText = panel.desktopHasMarkedText
            guard let committed = panel.commitDesktopText()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                recordReleaseWait(panel.desktopInputReady ? "composition-uncommitted" : "editor-not-ready", released: released, chars: text.utf16.count); return
            }
            guard committed == text else {
                previousText = committed; changedAt = Date()
                recordReleaseWait("committed-text-changed", released: released, chars: committed.utf16.count); return
            }
            recordReleaseWait("ready", released: released, chars: committed.utf16.count)
            let timing = releaseDiagnostics?.summary(now: ProcessInfo.processInfo.systemUptime) ?? ""
            voiceLog(String(format: "sprite input ready %.0f ms after release; stableMs=%.0f chars=%d compositionCommitted=%@; %@",
                Date().timeIntervalSince(released) * 1000, Date().timeIntervalSince(changedAt) * 1000,
                committed.utf16.count, String(hadMarkedText), timing))
            releasedAt = nil
            releaseDiagnostics = nil
            routingInput = true; preparedInput = false
            let generation = captureGeneration
            panel.beginDesktopExecution()
            submitInput(committed, generation: generation)
        } else if !recording, !routingInput, showingTask, let id = taskId, panel.desktopMode, let task = TaskStore.task(id: id) {
            panel.desktopTask(task)
        }
    }
    private func submitInput(_ text: String, generation: Int) {
        TaskService.send(subject: String(Auth.token.prefix(8)), requestId: UUID().uuidString,
            text: text, context: nil, controlSession: Self.localControlSession, previousTaskId: taskId,
            inputIntent: inputIntent) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.captureGeneration == generation, self.panel.desktopMode else { return }
                self.routingInput = false
                switch result {
                case .success(let task):
                    self.taskId = task.id
                    self.showingTask = true
                    self.panel.desktopTask(task)
                    NSLog("PocketDesk headset submitted task %@", task.id)
                case .failure(let error):
                    self.panel.desktopStatus("这次没完成", result: error.localizedDescription,
                                             recovery: .init(kind: .executionFailure), taskId: self.taskId)
                }
            }
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if NSApp.currentEvent?.cgEvent?.getIntegerValueField(.eventSourceUserData) == HeadsetMarker { return true }
            _ = dismissInput(); return true
        }
        // Do not let a stray Enter submit before the held button is released.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            requestTextSubmission()
            return true
        }
        return false
    }
}
