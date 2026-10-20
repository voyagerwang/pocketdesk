/**
 * [INPUT]: 依赖 SpriteFileDropView、PhoneFileStore 的批量拖入发送，以及 AppKit、SpriteSubtitleView 的组合字幕、SpriteOrbView 的原版动态组件、SpriteFeedback.ViewModel、AgentTask 与 TaskRecovery 的恢复事实；异步读取系统真实焦点归属，复用 HeadsetLog 记录应用归还请求，监听前台、锁屏和减少动态设置。
 * [OUTPUT]: 440pt 紧凑恢复卡以原目标、原因和一个主动作引导；点击后在同一原生字段可见编辑，切换话题保留草稿；语音接收仅呈现状态与真实字幕，不显示占位或前文说明；600pt 普通结果保留有界滚动；被动展示透明精灵面板、原版表情、
 *           文件拖入发送反馈与拖拽期间短暂显现；空闲无提示文字、无收起按钮；明确取消抑制同展示代际迟到状态，并仅在本进程仍持焦点且无其他 key 窗口时归还原应用；恢复动作只发明确意图，执行冻结字幕并交出焦点；接收诊断只读本进程AX身份、输入法来源和修饰键状态，不读取正文。
 * [POS]: 桌面展示层；球体单独在 WebKit 内矢量绘制，正文由原生字体按屏幕比例绘制；语音字幕逐行居中自然展开、满行换行，不随球体缩放或旋转。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

/// 即使系统设置为始终显示滚动条，也只画细圆角滑块，不出现槽线。
private final class SpriteResultScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: knob.midX - 1.5, y: knob.minY + 2,
                                        width: 3, height: max(0, knob.height - 4)),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class SpriteFeedbackPanel: NSPanel {
    private static let panelWidth: CGFloat = 600
    private static let horizontalInset: CGFloat = 16
    private static let textWidth = panelWidth - horizontalInset * 2
    private static let orbSize: CGFloat = 176
    private let container = SpriteFileDropView(frame: .zero)
    private let transcriptSurface = NSView()
    private(set) var desktopMode = false
    let desktopInput = NSTextField()
    private let desktopSubtitle = SpriteSubtitleView()
    private let subtitleScroll = NSScrollView()
    private var capturePrompt = "说出你想做的事…"
    var onDesktopInterrupted: ((String) -> Void)?
    var onRecoveryInputRequested: ((String?, TaskRecovery.InputIntent) -> Void)?
    var onRecoveryRetryRequested: ((String) -> Void)?
    var onInputIntentChanged: ((TaskRecovery.InputIntent) -> Void)?
    var onDesktopSubmitRequested: (() -> Void)?
    var desktopText: String {
        (desktopInput.currentEditor() as? NSTextView)?.string ?? desktopInput.stringValue
    }
    var desktopHasMarkedText: Bool {
        (desktopInput.currentEditor() as? NSTextView)?.hasMarkedText() == true
    }
    var desktopInputReady: Bool {
        guard desktopMode, !desktopInput.isHidden, isVisible, isKeyWindow, NSApp.isActive,
              let editor = desktopInput.currentEditor() else { return false }
        return firstResponder === editor
    }
    /// 只记录接收身份与输入法状态；本地 firstResponder 不能证明第三方已识别输入框。
    var desktopVoiceDiagnostics: String {
        let editor = desktopInput.currentEditor() as? NSTextView
        let context = editor?.inputContext
        let focused = NSApp.accessibilityFocusedUIElement as AnyObject?
        let receiver = NSAccessibility.unignoredAncestor(of: desktopInput) as AnyObject
        let role = (focused as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? "unknown"
        let source = context?.selectedKeyboardInputSource ?? "unknown"
        return "inputSource=\(source) contextCurrent=\(context != nil && context === NSTextInputContext.current) contextClient=\(editor != nil && (context?.client as AnyObject?) === editor) "
            + "axRole=\(role) axReceiver=\(focused != nil && (focused === editor || focused === desktopInput || focused === desktopInput.cell)) receiverAlpha=\(desktopInput.alphaValue) "
            + "axUnignoredReceiver=\(focused === receiver) "
            + "modifierFlags=\(CGEventSource.flagsState(.combinedSessionState).rawValue) hidFlags=\(CGEventSource.flagsState(.hidSystemState).rawValue)"
    }
    /// 仅在调用方确认豆包语音窗关闭、文字稳定后接受当前组合；不丢弃或替换识别内容。
    func commitDesktopText() -> String? {
        guard desktopInputReady, let editor = desktopInput.currentEditor() as? NSTextView else { return nil }
        if editor.hasMarkedText() { editor.unmarkText() }
        guard !editor.hasMarkedText() else { return nil }
        let text = editor.string
        desktopInput.stringValue = text
        updateDesktopSubtitle()
        return text
    }
    private let bubble = NSTextField(labelWithString: "")
    private let answer = NSTextView()
    private let answerScroll = NSScrollView()
    private let orbView: SpriteOrbView
    private let statusLine = NSTextField(labelWithString: "")
    private let connectionNotice = NSTextField(labelWithString: "")
    private let recoveryHint = NSTextField(labelWithString: "")
    private let supplementButton = NSButton(title: "接着说", target: nil, action: nil)
    private let editButton = NSButton(title: "补充说明", target: nil, action: nil)
    private let newTaskButton = NSButton(title: "换件事", target: nil, action: nil)
    private var recoveryTaskId: String?
    private var recoveryAction: TaskRecovery.Action?
    private var textEntryMode = false
    private var inputIntent: TaskRecovery.InputIntent = .automatic
    private var inputCanReturn = false
    private var inputSummary = ""
    private var inputQuestion = ""
    private var fileNotice = ""
    private var fileNoticeUntil = Date.distantPast
    private var preparingFiles = false
    /// 拖拽显现：访达是前台时面板按既有意图收起，用户拖文件时短暂放行，拖完恢复收起；
    /// 不改变"切应用隐藏"的本意，也不把球体永久置顶。
    private var dragRevealed = false
    private var dragMonitorActive = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lastViewModel: SpriteFeedback.ViewModel?
    private var hiddenByApplication = false
    private var screenIsLocked = LockScreenInput.locked
    private var presentationRevision = 0
    private var positioned = false
    static let frameDefaultsKey = "sprite.panel.frame.v3"
    // ---------- 接收窗口只借用应用焦点，取消后有条件归还 ----------
    // 两次系统 AX 读取均离开主线程，避免本进程的辅助功能响应等待自己的主线程。
    var desktopFocusedPID: (@escaping (pid_t?) -> Void) -> Void = { completion in
        DispatchQueue.global(qos: .userInitiated).async {
            let pid = InputFocus.focusedApplicationPID()
            DispatchQueue.main.async { completion(pid) }
        }
    }
    var desktopApplication: (pid_t) -> NSRunningApplication? = { pid in
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
    }
    var desktopApplicationIsRunning: (NSRunningApplication) -> Bool = { !$0.isTerminated }
    var desktopActivateApplication: (NSRunningApplication) -> Bool = { $0.activate(options: [.activateIgnoringOtherApps]) }
    private var desktopReturnApplication: NSRunningApplication?
    private var desktopReturnCaptured = false
    private var desktopCaptureFocusPending = false
    private var desktopOriginGeneration = 0
    private var desktopFocusGeneration = 0

    init(webRoot: URL) {
        orbView = SpriteOrbView(webRoot: webRoot)
        // Passive feedback is enforced by canBecomeKey/canBecomeMain and
        // orderFrontRegardless. Capture needs normal app/IME activation.
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.orbSize),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        appearance = NSAppearance(named: .aqua)
        setupViews()
        loadSavedFrame()
        positioned = UserDefaults.standard.object(forKey: Self.frameDefaultsKey) != nil
        observeEnvironment()
    }

    private func setupViews() {
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = container
        container.allowed = { [weak self] in self?.screenIsLocked == false && self?.preparingFiles == false }
        container.receive = { [weak self] paths in self?.receiveFiles(paths) }
        orbView.unregisterDraggedTypes()
        transcriptSurface.wantsLayer = true
        transcriptSurface.layer?.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 0.94).cgColor
        transcriptSurface.layer?.cornerRadius = 12
        bubble.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        bubble.textColor = .labelColor
        bubble.alignment = .center
        bubble.lineBreakMode = .byWordWrapping
        bubble.maximumNumberOfLines = 6
        bubble.preferredMaxLayoutWidth = Self.textWidth
        answer.font = NSFont.systemFont(ofSize: 15)
        answer.textColor = .labelColor
        answer.isEditable = false
        answer.isSelectable = false
        answer.drawsBackground = false
        answer.textContainerInset = NSSize(width: 0, height: 4)
        answer.isVerticallyResizable = true
        answer.isHorizontallyResizable = false
        answer.textContainer?.widthTracksTextView = true
        answerScroll.documentView = answer
        answerScroll.hasVerticalScroller = true
        answerScroll.verticalScroller = SpriteResultScroller()
        answerScroll.autohidesScrollers = true
        answerScroll.borderType = .noBorder
        answerScroll.drawsBackground = false
        answerScroll.scrollerStyle = .overlay
        answerScroll.verticalScroller?.controlSize = .small
        statusLine.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        statusLine.textColor = .labelColor
        statusLine.alignment = .center
        statusLine.lineBreakMode = .byWordWrapping
        statusLine.maximumNumberOfLines = 2
        connectionNotice.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        connectionNotice.textColor = .labelColor
        connectionNotice.alignment = .center
        recoveryHint.font = .systemFont(ofSize: 13)
        recoveryHint.textColor = .secondaryLabelColor
        recoveryHint.alignment = .left
        recoveryHint.lineBreakMode = .byTruncatingTail
        recoveryHint.maximumNumberOfLines = 1
        recoveryHint.isHidden = true
        for button in [supplementButton, editButton, newTaskButton] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 14)
            button.target = self
            button.isHidden = true
        }
        supplementButton.action = #selector(supplementRequested)
        supplementButton.setAccessibilityIdentifier("pocketdesk.sprite.supplement")
        supplementButton.bezelColor = .controlAccentColor
        supplementButton.contentTintColor = .white
        editButton.action = #selector(editRequested)
        editButton.setAccessibilityIdentifier("pocketdesk.sprite.edit")
        editButton.isBordered = false
        newTaskButton.action = #selector(newTaskRequested)
        newTaskButton.setAccessibilityIdentifier("pocketdesk.sprite.new-task")
        newTaskButton.isBordered = false
        newTaskButton.font = .systemFont(ofSize: 12)
        newTaskButton.contentTintColor = .secondaryLabelColor
        desktopInput.font = NSFont.systemFont(ofSize: 15)
        desktopInput.isBordered = false
        desktopInput.isBezeled = false
        desktopInput.drawsBackground = false
        desktopInput.focusRingType = .none
        desktopInput.textColor = .clear
        subtitleScroll.drawsBackground = false
        subtitleScroll.hasVerticalScroller = false
        subtitleScroll.documentView = desktopSubtitle
        subtitleScroll.isHidden = true
        desktopInput.placeholderString = ""
        desktopInput.setAccessibilityLabel("语音转写")
        desktopInput.setAccessibilityIdentifier("pocketdesk.sprite.transcript")
        desktopInput.isHidden = true
        for view in [transcriptSurface, bubble, answerScroll, orbView, statusLine, connectionNotice, desktopInput, subtitleScroll, recoveryHint, supplementButton, editButton, newTaskButton] { container.addSubview(view) }
    }

    func apply(_ model: SpriteFeedback.ViewModel) {
        if desktopMode {
            if model.presentationRevision == presentationRevision { return }
            onDesktopInterrupted?("phone presentation changed")
            endDesktopCapture()
        }
        if model.presentationRevision != presentationRevision {
            presentationRevision = model.presentationRevision
            hiddenByApplication = false
        }
        subtitleScroll.isHidden = true
        lastViewModel = model
        let revealAllowed = dragRevealed || (preparingFiles && fileNoticeUntil > Date())
        guard model.visible, !screenIsLocked, !hiddenByApplication || revealAllowed else { orderOutAndKeepIntent(); return }
        bubble.stringValue = model.phase == .drafting ? model.displayText : ""
        bubble.isHidden = bubble.stringValue.isEmpty
        let recovery = [.waiting, .failed, .unconfirmed].contains(model.phase) ? model.recovery : nil
        configureRecovery(recovery, taskId: model.taskId.isEmpty ? nil : model.taskId,
                          action: model.recoveryAction, summary: model.recoverySummary)
        let answerText = resultText(model.phase == .drafting ? "" : model.displayText, recovery: recovery)
        if answer.string != answerText { answer.string = answerText }
        answerScroll.isHidden = answerText.isEmpty
        // 表情传达情绪，标题交代执行事实；两者不能互相替代。
        statusLine.stringValue = Date() < fileNoticeUntil ? fileNotice : model.headline
        connectionNotice.stringValue = model.phoneConnected ? "" : "手机输入已断开"
        connectionNotice.isHidden = model.phoneConnected
        statusLine.isHidden = statusLine.stringValue.isEmpty
        layoutContent()
        if !isVisible { centerAndShow() }
        updateOrb(model)
    }

    func beginDesktopCapture(intent: TaskRecovery.InputIntent = .automatic, continuing: Bool = false,
                             textEntry: Bool = false, summary: String = "", question: String = "", canReturn: Bool = false) -> Bool {
        guard !LockScreenInput.locked else { return false }
        desktopFocusGeneration += 1
        // ---------- 新一轮接收 ----------
        // 先结束上一轮 field editor，组合文字与选择范围不能流入本次补充。
        makeFirstResponder(nil)
        desktopMode = true; hiddenByApplication = false
        textEntryMode = textEntry; inputSummary = summary; inputQuestion = question; inputCanReturn = canReturn
        desktopInput.stringValue = ""; desktopInput.isHidden = false
        bubble.isHidden = true; answerScroll.isHidden = true; connectionNotice.isHidden = true
        configureRecovery(nil, taskId: nil)
        setDesktopInputContext(intent: intent, continuing: continuing)
        updateInputAppearance()
        statusLine.stringValue = "准备中"; statusLine.isHidden = false
        desktopSubtitle.update(text: "")
        subtitleScroll.isHidden = textEntryMode
        layoutContent(); centerAndShow()
        prepareDesktopFocus()
        orbView.update(visible: true, revision: presentationRevision + 1, emotion: "02", reduced: reduceMotion, taskId: "")
        return true
    }
    /// 启动失败后只重新取得接收框焦点；原文、字幕与任务意图不重置。
    func resumeDesktopCapture() -> Bool {
        guard desktopMode, !desktopInput.isHidden, isVisible, !LockScreenInput.locked else { return false }
        let text = desktopText
        makeFirstResponder(nil)
        desktopInput.stringValue = text
        if !desktopCaptureFocusPending { focusDesktopInput() }
        return true
    }
    private func prepareDesktopFocus() {
        guard !desktopReturnCaptured else {
            if !desktopCaptureFocusPending { focusDesktopInput() }
            return
        }
        desktopReturnCaptured = true; desktopCaptureFocusPending = true
        let origin = desktopOriginGeneration
        let originalKeyWindow = NSApp.keyWindow
        desktopFocusedPID { [weak self, weak originalKeyWindow] pid in
            guard let self, self.desktopOriginGeneration == origin else { return }
            self.desktopCaptureFocusPending = false
            guard self.desktopMode, !self.desktopInput.isHidden, self.isVisible,
                  !self.screenIsLocked, !LockScreenInput.locked else { return }
            // 同进程换窗口不会触发外部应用通知，迟到读取不能抢走新打开的设置窗口。
            if let key = NSApp.keyWindow, key !== self, key !== originalKeyWindow {
                self.invalidateDesktopReturn(); return
            }
            if let pid, pid != ProcessInfo.processInfo.processIdentifier,
               let app = self.desktopApplication(pid), self.desktopApplicationIsRunning(app) {
                // 保存应用对象而非仅保存 PID，退出后不把同号的新进程当成原目标。
                self.desktopReturnApplication = app
            }
            self.focusDesktopInput()
        }
    }
    private func focusDesktopInput() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(desktopInput)
        updateInputAppearance()
    }
    private func updateInputAppearance() {
        desktopInput.isBezeled = textEntryMode
        desktopInput.bezelStyle = .roundedBezel
        desktopInput.drawsBackground = textEntryMode
        desktopInput.backgroundColor = .textBackgroundColor
        // 语音接收层仍持有真实输入焦点；整层透明，组合下划线由字幕按同一排版呈现。
        desktopInput.alphaValue = textEntryMode ? 1 : 0
        desktopInput.textColor = textEntryMode ? .labelColor : .clear
        desktopInput.placeholderString = textEntryMode ? capturePrompt : ""
        desktopInput.setAccessibilityLabel(textEntryMode ? "给小精灵的要求" : "语音转写")
        if let editor = desktopInput.currentEditor() as? NSTextView {
            editor.textColor = textEntryMode ? .labelColor : .clear
            editor.insertionPointColor = textEntryMode ? .labelColor : .clear
            editor.drawsBackground = false
            editor.selectedTextAttributes = [.foregroundColor: textEntryMode ? NSColor.selectedTextColor : .clear,
                                            .backgroundColor: textEntryMode ? NSColor.selectedTextBackgroundColor : .clear]
            editor.markedTextAttributes = [.foregroundColor: textEntryMode ? NSColor.labelColor : .clear]
        }
    }
    /// 文字转语音仍使用当前 field editor，内容、组合文字和任务归属都不重建。
    func useVoicePresentation() {
        guard desktopMode else { return }
        textEntryMode = false; subtitleScroll.isHidden = false
        supplementButton.isHidden = true; newTaskButton.isHidden = true
        recoveryHint.isHidden = true; answerScroll.isHidden = true
        updateInputAppearance(); updateDesktopSubtitle(); layoutContent()
    }
    /// 正文和组合范围共同驱动字幕；确认组合时即使正文不变，也要撤下对应下划线。
    func updateDesktopSubtitle() {
        guard desktopMode, !desktopInput.isHidden else { return }
        let editor = desktopInput.currentEditor() as? NSTextView
        desktopSubtitle.update(text: desktopText,
                               markedRange: editor?.hasMarkedText() == true ? editor?.markedRange() : nil)
    }
    /// 最终组合文字已接受后，只结束编辑；同一字幕保留原字号、滚动位置与高度。
    func beginDesktopExecution() {
        guard desktopMode else { return }
        if !desktopInput.isHidden {
            useVoicePresentation()
            updateDesktopSubtitle()
            desktopInput.stringValue = desktopText
            releaseDesktopFocus()
        }
        configureRecovery(nil, taskId: nil)
        inputQuestion = ""; answerScroll.isHidden = true
        desktopStatus("执行中")
        orbView.update(visible: isVisible && !screenIsLocked && !hiddenByApplication,
                       revision: presentationRevision + 1, emotion: "32", reduced: reduceMotion, taskId: "")
    }
    /// 明确重试只进入忙态，不借用键盘焦点、不启动语音。
    func beginDesktopRetry() {
        desktopMode = true; hiddenByApplication = false; textEntryMode = false
        releaseDesktopFocus()
        subtitleScroll.isHidden = true; bubble.isHidden = true; answerScroll.isHidden = true
        configureRecovery(nil, taskId: nil)
        desktopStatus("正在继续处理…")
        centerAndShow()
    }
    /// 本机语音的提交与执行合为一个可见阶段；仅需用户处理或已结束的任务替换字幕。
    func desktopTask(_ task: AgentTask) {
        guard desktopMode else { return }
        switch task.status {
        case .accepted, .running:
            beginDesktopExecution()
        case .verifying:
            desktopStatus(task.status.displayName)
            orbView.update(visible: isVisible && !screenIsLocked && !hiddenByApplication,
                           revision: presentationRevision + 1, emotion: "30", reduced: reduceMotion, taskId: task.id)
        default:
            let recovery = TaskRecovery.forTask(task)
            let result = task.result ?? task.error ?? task.text
            desktopStatus(recovery?.headline ?? task.status.displayName, result: result,
                          recovery: recovery, taskId: task.id, action: recovery == nil ? nil : TaskRecovery.action(for: task),
                          summary: task.messages.first(where: { $0.role == .user })?.text ?? task.text)
            let emotion = task.status == .succeeded ? task.handoffTargetId == nil ? "33" : "19"
                : recovery?.kind == .unconfirmed ? "02" : "11"
            orbView.update(visible: isVisible && !screenIsLocked && !hiddenByApplication,
                           revision: presentationRevision + 1, emotion: emotion, reduced: reduceMotion, taskId: task.id)
        }
    }
    func desktopStatus(_ status: String, result: String? = nil, recovery: TaskRecovery? = nil, taskId: String? = nil,
                       action: TaskRecovery.Action? = nil, summary: String = "") {
        guard desktopMode else { return }
        if result == nil, statusLine.stringValue == status, statusLine.isHidden == status.isEmpty { return }
        statusLine.stringValue = status; statusLine.isHidden = status.isEmpty
        if let result {
            inputQuestion = ""
            subtitleScroll.isHidden = true
            releaseDesktopFocus()
            textEntryMode = false
            configureRecovery(recovery, taskId: taskId, action: action, summary: summary)
            answer.string = resultText(result, recovery: recovery)
            answerScroll.isHidden = answer.string.isEmpty
        }
        layoutContent()
    }
    func endDesktopCapture() {
        invalidateDesktopReturn()
        desktopMode = false; textEntryMode = false; subtitleScroll.isHidden = true
        releaseDesktopFocus()
    }

    /// 明确取消后，旧手机快照或后台结果不能把同一轮输入重新弹回；新唤醒再放行。
    func dismissDesktopCapture() {
        let original = desktopReturnApplication
        endDesktopCapture()
        hiddenByApplication = true
        orderOutAndKeepIntent()
        guard let original else { return }
        let generation = desktopFocusGeneration
        desktopFocusedPID { [weak self] pid in
            guard let self, self.desktopFocusGeneration == generation,
                  !self.desktopMode, !self.isVisible, !self.screenIsLocked, !LockScreenInput.locked,
                  NSApp.isActive, NSApp.keyWindow == nil,
                  pid == nil || pid == ProcessInfo.processInfo.processIdentifier,
                  self.desktopApplicationIsRunning(original) else { return }
            let requested = self.desktopActivateApplication(original)
            HeadsetLog("sprite focus return: activation requested; pid=\(original.processIdentifier) accepted=\(requested)")
        }
    }
    private func invalidateDesktopReturn() {
        desktopFocusGeneration += 1; desktopOriginGeneration += 1
        desktopReturnApplication = nil; desktopReturnCaptured = false; desktopCaptureFocusPending = false
    }

    /// 输入意图保持独立；文字编辑可参照前文，语音只显示真实字幕。
    func setDesktopInputContext(intent: TaskRecovery.InputIntent, continuing: Bool) {
        inputIntent = intent
        capturePrompt = continuing ? "接着说，不用重复前文…" : "想做什么？"
        let summary = inputSummary.split(whereSeparator: \.isNewline).joined(separator: " ")
        recoveryHint.stringValue = continuing ? summary.isEmpty ? "接着说 · 前文已保留" : "接着说 · " + summary : ""
        recoveryHint.isHidden = !textEntryMode || recoveryHint.stringValue.isEmpty
        if textEntryMode {
            supplementButton.title = "发送"; supplementButton.isHidden = false; supplementButton.isEnabled = true
            supplementButton.setAccessibilityLabel("发送给小精灵")
            newTaskButton.title = intent == .newTask ? "返回原事" : "换件事"
            newTaskButton.isHidden = intent == .newTask && !inputCanReturn
            desktopInput.placeholderString = capturePrompt
            answer.string = continuing ? inputQuestion : ""
            answerScroll.isHidden = answer.string.isEmpty
        }
        layoutContent()
    }

    private func resultText(_ text: String, recovery: TaskRecovery?) -> String {
        guard let step = recovery?.nextStep, !step.isEmpty else { return text }
        return text + "\n\n" + step
    }

    private func configureRecovery(_ recovery: TaskRecovery?, taskId: String?, action: TaskRecovery.Action? = nil, summary: String = "") {
        recoveryTaskId = recovery == nil ? nil : taskId
        recoveryAction = action
        recoveryHint.stringValue = summary.split(whereSeparator: \.isNewline).joined(separator: " ")
        recoveryHint.isHidden = recovery == nil || summary.isEmpty
        supplementButton.isHidden = recovery == nil || taskId == nil
        newTaskButton.isHidden = recovery == nil
        editButton.isHidden = recovery == nil || action?.kind != .retry || taskId == nil
        supplementButton.title = action?.title ?? recovery?.inputLabel ?? "接着说"
        supplementButton.isEnabled = true
        newTaskButton.title = "换件事"
        supplementButton.setAccessibilityLabel(supplementButton.title + "，保留原任务")
    }

    @objc private func supplementRequested() {
        guard !screenIsLocked else { return }
        if textEntryMode { onDesktopSubmitRequested?(); return }
        guard supplementButton.isEnabled, let recoveryTaskId else { return }
        if recoveryAction?.kind == .retry {
            supplementButton.isEnabled = false
            onRecoveryRetryRequested?(recoveryTaskId)
        } else { onRecoveryInputRequested?(recoveryTaskId, .supplement) }
    }
    @objc private func editRequested() {
        guard !screenIsLocked, let recoveryTaskId else { return }
        onRecoveryInputRequested?(recoveryTaskId, .supplement)
    }
    @objc private func newTaskRequested() {
        guard !screenIsLocked else { return }
        if textEntryMode { onInputIntentChanged?(inputIntent == .newTask ? .supplement : .newTask) }
        else { onRecoveryInputRequested?(recoveryTaskId, .newTask) }
    }

    /// 经 AppKit 的窗口排序释放 key，保持面板与 NSApp.keyWindow 的焦点记录一致。
    private func releaseDesktopFocus() {
        makeFirstResponder(nil)
        desktopInput.isHidden = true
        guard isKeyWindow else { return }
        let keepVisible = isVisible && !screenIsLocked && !hiddenByApplication
        // resignKey 是系统通知回调，直接调用会留下悬挂的 keyWindow，阻断下一轮聚焦。
        orderOut(nil)
        if keepVisible { orderFrontRegardless() }
    }

    /// 拖入就是电脑端用户的发送意图；手机仍须点击接收，不要求手机当前选中任务。
    private func receiveFiles(_ paths: [String]) {
        guard !preparingFiles, !screenIsLocked else { return }
        preparingFiles = true
        showFileNotice("正在准备 \(paths.count) 个文件…", duration: 600)
        let batchId = UUID().uuidString
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let message: String
            do {
                let offer = try PhoneFileStore.shared.prepare(paths: paths, subject: PhoneFileStore.subject, taskId: batchId)
                message = "已准备好「\(offer.name)」，请在手机接收"
            } catch { message = error.localizedDescription }
            DispatchQueue.main.async {
                self?.preparingFiles = false
                self?.showFileNotice(message, duration: 15)
                // 拖放后面板可能本来就因切应用收起；结果要在这 15 秒里可见，随后按既有意图恢复收起。
                if self?.hiddenByApplication == true {
                    self?.dragRevealed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                        guard let self, self.dragRevealed else { return }
                        self.dragRevealed = false
                        if self.hiddenByApplication { self.orderOutAndKeepIntent() }
                    }
                }
            }
        }
    }

    private func showFileNotice(_ text: String, duration: TimeInterval) {
        fileNotice = text
        fileNoticeUntil = Date().addingTimeInterval(duration)
        statusLine.stringValue = text
        statusLine.isHidden = false
        layoutContent()
    }

    private func updateOrb(_ model: SpriteFeedback.ViewModel) {
        let revealed = dragRevealed || (preparingFiles && fileNoticeUntil > Date())
        orbView.update(visible: isVisible && model.visible && !screenIsLocked && (!hiddenByApplication || revealed),
                       revision: model.presentationRevision, emotion: model.emotion, reduced: reduceMotion, taskId: model.taskId)
    }

    private func layoutContent() {
        let availableFrame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let compact = recoveryTaskId != nil || textEntryMode || (desktopMode && !inputQuestion.isEmpty && !answerScroll.isHidden)
        let width = min(compact ? 440 : Self.panelWidth, availableFrame.width - 32)
        let textWidth = width - Self.horizontalInset * 2
        let horizontalInset = Self.horizontalInset
        let orbSize = Self.orbSize
        func textHeight(_ text: String, font: NSFont = .systemFont(ofSize: 15)) -> CGFloat {
            ceil((text as NSString).boundingRect(with: NSSize(width: textWidth - 10, height: 100_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]).height)
        }
        let questionHeight: CGFloat = textEntryMode && !desktopInput.isHidden ? 56 : !subtitleScroll.isHidden ? 68 : bubble.isHidden ? 0 : min(textHeight(bubble.stringValue) + 6, 132)
        let hintHeight: CGFloat = recoveryHint.isHidden ? 0 : 20
        let actionHeight: CGFloat = supplementButton.isHidden && newTaskButton.isHidden ? 0 : 36
        let recoveryHeight = hintHeight + actionHeight
        let recoveryOffset = actionHeight > 0 ? actionHeight + 12 : 0
        // 按实际 NSTextView 排版测高，避免估算行高与实际换行不一致造成假溢出。
        answer.setFrameSize(NSSize(width: textWidth, height: max(40, answer.frame.height)))
        answer.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        var documentHeight: CGFloat = 0
        if !answerScroll.isHidden, let layout = answer.layoutManager, let textContainer = answer.textContainer {
            layout.ensureLayout(for: textContainer)
            documentHeight = ceil(layout.usedRect(for: textContainer).maxY) + answer.textContainerInset.height * 2
        }
        let titleHeight: CGFloat = statusLine.isHidden ? 0 : min(textHeight(statusLine.stringValue) + 6, 48)
        let maxAnswerHeight = max(40, min(420, availableFrame.height - orbSize - titleHeight - questionHeight - recoveryOffset - hintHeight - 72))
        let answerHeight: CGFloat = answerScroll.isHidden ? 0 : min(max(documentHeight, 40), maxAnswerHeight)
        answerScroll.hasVerticalScroller = documentHeight > answerHeight
        let gap: CGFloat = titleHeight > 0 && answerHeight > 0 ? 8 : 0
        let hasText = questionHeight + answerHeight + titleHeight + recoveryHeight > 0
        let textBottom = orbSize
        let height = hasText ? textBottom + questionHeight + answerHeight + titleHeight + gap + recoveryOffset + hintHeight + 24 : textBottom
        // AppKit 改高度默认移动底边；显式保持原点，避免每个输入事件把球体挪走。
        let origin = NSPoint(x: frame.midX - width / 2, y: frame.minY)
        setContentSize(NSSize(width: width, height: height))
        setFrameOrigin(origin)
        orbView.frame = NSRect(x: (width - orbSize) / 2, y: 0, width: orbSize, height: orbSize)
        connectionNotice.frame = NSRect(x: horizontalInset, y: 0, width: textWidth, height: 20)
        statusLine.frame = NSRect(x: horizontalInset, y: height - 12 - titleHeight, width: textWidth, height: titleHeight)
        statusLine.alignment = compact ? .left : .center
        let buttonWidth: CGFloat = textEntryMode ? 88 : min(164, max(112, supplementButton.intrinsicContentSize.width + 12))
        supplementButton.frame = NSRect(x: textEntryMode ? width - horizontalInset - buttonWidth : horizontalInset, y: textBottom + 8, width: buttonWidth, height: actionHeight)
        editButton.frame = NSRect(x: horizontalInset + buttonWidth + 8, y: textBottom + 8, width: 100, height: actionHeight)
        newTaskButton.frame = NSRect(x: textEntryMode ? horizontalInset : width - horizontalInset - 76, y: textBottom + 8, width: 76, height: actionHeight)
        recoveryHint.frame = NSRect(x: horizontalInset, y: statusLine.frame.minY - hintHeight, width: textWidth, height: hintHeight)
        answerScroll.frame = NSRect(x: horizontalInset, y: textBottom + 12 + recoveryOffset, width: textWidth, height: answerHeight)
        let answerWidth = answerScroll.contentSize.width
        answer.setFrameSize(NSSize(width: answerWidth, height: max(documentHeight, answerHeight)))
        answer.textContainer?.containerSize = NSSize(width: answerWidth, height: .greatestFiniteMagnitude)
        if let layout = answer.layoutManager, let textContainer = answer.textContainer {
            layout.ensureLayout(for: textContainer)
            let laidOutHeight = ceil(layout.usedRect(for: textContainer).maxY) + answer.textContainerInset.height * 2
            answer.setFrameSize(NSSize(width: answerWidth, height: max(laidOutHeight, answerHeight)))
        }
        answer.alignment = !compact && documentHeight < 50 ? .center : .left
        bubble.frame = NSRect(x: horizontalInset, y: textBottom + 12 + recoveryOffset + answerHeight + gap, width: textWidth, height: questionHeight)
        desktopInput.frame = bubble.frame
        subtitleScroll.frame = bubble.frame
        if desktopMode, !desktopInput.isHidden, !answerScroll.isHidden {
            desktopInput.frame.origin.y = textBottom + 12 + recoveryOffset
            subtitleScroll.frame = desktopInput.frame
            answerScroll.frame.origin.y = desktopInput.frame.maxY + 8
        }
        desktopSubtitle.setFrameSize(NSSize(width: textWidth, height: max(68, desktopSubtitle.frame.height)))
        desktopSubtitle.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        if !subtitleScroll.isHidden {
            desktopSubtitle.layoutManager?.ensureLayout(for: desktopSubtitle.textContainer!)
            desktopSubtitle.scrollRangeToVisible(NSRange(location: desktopSubtitle.string.utf16.count, length: 0))
        }
        transcriptSurface.isHidden = !hasText
        // 单行回执背景随文字收紧；长结果仍沿用有界滚动区域。
        let titleOnly = questionHeight == 0 && answerHeight == 0 && recoveryHeight == 0 && titleHeight > 0
        let titleWidth = ceil((statusLine.stringValue as NSString).size(withAttributes:
            [.font: statusLine.font ?? NSFont.systemFont(ofSize: 15)]).width) + 32
        let surfaceWidth = titleOnly ? min(width - 8, max(120, titleWidth)) : width - 8
        transcriptSurface.frame = NSRect(x: (width - surfaceWidth) / 2, y: textBottom,
                                        width: surfaceWidth, height: max(0, height - textBottom))
        setFrame(clamped(frame), display: true)
    }

    private func centerAndShow() {
        if !positioned {
            if let visible = (NSScreen.screenContainingMouse() ?? NSScreen.main)?.visibleFrame {
                setFrameOrigin(NSPoint(x: floor(visible.midX - frame.width / 2), y: visible.minY + 44))
            }
            positioned = true
        }
        // 字体不参与淡入、位移或缩放，按当前屏幕原生分辨率直接呈现。
        alphaValue = 1
        orderFrontRegardless()
    }

    private func orderOutAndKeepIntent() {
        orbView.update(visible: false, revision: presentationRevision,
                       emotion: lastViewModel?.emotion ?? "02", reduced: reduceMotion, taskId: lastViewModel?.taskId ?? "")
        guard isVisible else { return }
        saveFrame()
        orderOut(nil)
    }

    // MARK: 环境观察

    private func observeEnvironment() {
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.addObserver(self, selector: #selector(appActivated),
                                                 name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.notificationCenter.addObserver(self, selector: #selector(reduceMotionChanged),
                                                 name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked),
                                                            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked),
                                                            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved),
                                               name: NSWindow.didMoveNotification, object: self)
        // 全局拖拽监听只读事件，不消费：用户在访达选中文件开始拖动时，把收起的球体短暂放行，
        // 让"访达多选 → 拖到球球"这条主路径真的可达；松开（或落点不在这里）即恢复收起。
        globalMouseUp = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.dragRevealed, self.dragMonitorActive else { return }
                self.dragMonitorActive = false
                guard !self.preparingFiles else { return }
                self.dragRevealed = false
                if self.hiddenByApplication { self.orderOutAndKeepIntent() }
            }
        }
        globalMouseDragged = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.dragMonitorActive else { return }
                guard !self.screenIsLocked, !self.preparingFiles,
                      let model = self.lastViewModel, model.visible else { return }
                if self.hiddenByApplication && !self.dragRevealed {
                    self.dragRevealed = true
                    self.showFileNotice("可把文件拖到这里发送到手机", duration: 60)
                    if let model = self.lastViewModel { self.apply(model) }
                }
            }
        }
        globalMouseDown = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.dragMonitorActive = true }
        }
    }

    private var globalMouseUp: Any?
    private var globalMouseDragged: Any?
    private var globalMouseDown: Any?

    /// 切到普通应用收起整个反馈窗；后台任务照常进行，迟到结果不弹回。
    /// 本进程（控制台）激活不算切换。
    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier && app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        invalidateDesktopReturn()
        onDesktopInterrupted?("application activated: " + (app.bundleIdentifier ?? "unknown"))
        hiddenByApplication = true
        orderOutAndKeepIntent()
    }

    @objc private func reduceMotionChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let model = lastViewModel, isVisible { updateOrb(model) }
    }

    /// 锁屏隐藏正文；解锁后在符合当前显示意图（未切走）时恢复。
    @objc private func screenLocked() {
        invalidateDesktopReturn()
        screenIsLocked = true
        orderOutAndKeepIntent()
    }

    @objc private func screenUnlocked() {
        screenIsLocked = false
        if let viewModel = lastViewModel, viewModel.visible { apply(viewModel) }
    }

    /// 屏幕移除/分辨率改变后夹回可用区域。
    @objc private func screensChanged() {
        guard isVisible else { return }
        setFrame(clamped(frame), display: true)
        saveFrame()
    }

    @objc private func windowMoved() {
        saveFrame()
    }

    // MARK: 位置记忆

    private func clamped(_ target: NSRect) -> NSRect {
        var rect = target
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let home = screens.first(where: { $0.intersects(rect) }) ?? NSScreen.main?.visibleFrame else { return rect }
        rect.origin.x = min(max(rect.origin.x, home.minX), max(home.maxX - rect.width, home.minX))
        rect.origin.y = min(max(rect.origin.y, home.minY), max(home.maxY - rect.height, home.minY))
        return rect
    }

    private func saveFrame() {
        guard isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameDefaultsKey)
    }

    private func loadSavedFrame() {
        guard let raw = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) else { return }
        let rect = NSRectFromString(raw)
        guard rect.width > 40, rect.height > 40 else { return }
        setFrame(clamped(rect), display: false)
    }

    override var canBecomeKey: Bool { desktopMode && !desktopInput.isHidden }
    override var canBecomeMain: Bool { false }
}

extension SpriteFeedbackPanel: SpriteFeedback.Panel {}

private extension NSScreen {
    static func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) }
    }
}
