/**
 * [INPUT]: 依赖 SpriteFileDropView、PhoneFileStore 的批量拖入发送，以及 AppKit、SpriteOrbView 的原版动态组件与 SpriteFeedback.ViewModel；监听前台、锁屏和减少动态设置。
 * [OUTPUT]: 600pt 宽松回执、短答案完整展开、长答案按屏幕限高并自动隐藏原生浮动滚动条；单行回执背景随文字收紧；被动展示透明精灵面板、原版表情、
 *           文件拖入发送反馈与拖拽期间短暂显现；空闲无提示文字、无收起按钮；切走隐藏、重选开心唤醒；明确语音唤醒才激活输入，字幕与提交共用当前 field editor，语音相同状态提示不重复布局。
 * [POS]: 桌面展示层；球体单独在 WebKit 内矢量绘制，正文由原生字体按屏幕比例绘制，不随球体缩放或旋转。
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
    private let desktopSubtitle = NSTextView()
    private let subtitleScroll = NSScrollView()
    private var subtitleText = ""
    var onDesktopInterrupted: ((String) -> Void)?
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
    private let bubble = NSTextField(labelWithString: "")
    private let answer = NSTextView()
    private let answerScroll = NSScrollView()
    private let orbView: SpriteOrbView
    private let statusLine = NSTextField(labelWithString: "")
    private let connectionNotice = NSTextField(labelWithString: "")
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
        desktopInput.font = NSFont.systemFont(ofSize: 15)
        desktopInput.isBordered = false
        desktopInput.isBezeled = false
        desktopInput.drawsBackground = false
        desktopInput.focusRingType = .none
        desktopInput.textColor = .clear
        desktopSubtitle.isEditable = false
        desktopSubtitle.isSelectable = false
        desktopSubtitle.drawsBackground = false
        desktopSubtitle.font = .systemFont(ofSize: 16, weight: .medium)
        desktopSubtitle.textColor = .labelColor
        desktopSubtitle.textContainerInset = NSSize(width: 0, height: 2)
        desktopSubtitle.textContainer?.widthTracksTextView = true
        desktopSubtitle.isVerticallyResizable = true
        desktopSubtitle.autoresizingMask = [.width]
        subtitleScroll.drawsBackground = false
        subtitleScroll.hasVerticalScroller = false
        subtitleScroll.documentView = desktopSubtitle
        subtitleScroll.isHidden = true
        desktopInput.placeholderString = ""
        desktopInput.setAccessibilityLabel("语音转写")
        desktopInput.setAccessibilityIdentifier("pocketdesk.sprite.transcript")
        desktopInput.isHidden = true
        for view in [transcriptSurface, bubble, answerScroll, orbView, statusLine, connectionNotice, desktopInput, subtitleScroll] { container.addSubview(view) }
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
        let answerText = model.phase == .drafting ? "" : model.displayText
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

    func beginDesktopCapture() -> Bool {
        guard !LockScreenInput.locked else { return false }
        desktopMode = true; hiddenByApplication = false
        desktopInput.stringValue = ""; desktopInput.isHidden = false
        bubble.isHidden = true; answerScroll.isHidden = true; connectionNotice.isHidden = true
        statusLine.stringValue = "正在启动语音…"; statusLine.isHidden = false
        subtitleText = ""; desktopSubtitle.string = "说出你想做的事…"
        desktopSubtitle.textColor = .secondaryLabelColor
        subtitleScroll.isHidden = false
        layoutContent(); centerAndShow()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(desktopInput)
        if let editor = desktopInput.currentEditor() as? NSTextView {
            editor.textColor = .clear
            editor.insertionPointColor = .clear
            editor.drawsBackground = false
            editor.selectedTextAttributes = [.foregroundColor: NSColor.clear, .backgroundColor: NSColor.clear]
            editor.markedTextAttributes = [.foregroundColor: NSColor.clear, .backgroundColor: NSColor.clear]
        }
        orbView.update(visible: true, revision: presentationRevision + 1, emotion: "02", reduced: reduceMotion, taskId: "")
        return true
    }
    /// Render the IME's current composition as subtitles; the focused receiver remains unchanged.
    func updateDesktopSubtitle() {
        guard desktopMode, !desktopInput.isHidden else { return }
        let text = desktopText
        guard text != subtitleText else { return }
        subtitleText = text
        desktopSubtitle.string = text.isEmpty ? "说出你想做的事…" : text
        desktopSubtitle.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
        desktopSubtitle.scrollRangeToVisible(NSRange(location: desktopSubtitle.string.utf16.count, length: 0))
    }
    func desktopStatus(_ status: String, result: String? = nil) {
        guard desktopMode else { return }
        if result == nil, statusLine.stringValue == status, !statusLine.isHidden { return }
        statusLine.stringValue = status; statusLine.isHidden = false
        if let result {
            desktopInput.isHidden = true
            subtitleScroll.isHidden = true
            makeFirstResponder(nil)
            resignKey()
            answer.string = result; answerScroll.isHidden = result.isEmpty
        }
        layoutContent()
    }
    func endDesktopCapture() {
        makeFirstResponder(nil)
        resignKey()
        desktopMode = false; desktopInput.isHidden = true; subtitleScroll.isHidden = true
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
        let width = min(Self.panelWidth, availableFrame.width - 32)
        let textWidth = width - Self.horizontalInset * 2
        let horizontalInset = Self.horizontalInset
        let orbSize = Self.orbSize
        func textHeight(_ text: String) -> CGFloat {
            ceil((text as NSString).boundingRect(with: NSSize(width: textWidth - 10, height: 100_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 15)]).height)
        }
        let questionHeight: CGFloat = !desktopInput.isHidden ? 68 : bubble.isHidden ? 0 : min(textHeight(bubble.stringValue) + 6, 132)
        // 按实际 NSTextView 排版测高，避免估算行高与实际换行不一致造成假溢出。
        answer.setFrameSize(NSSize(width: textWidth, height: max(40, answer.frame.height)))
        answer.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        var documentHeight: CGFloat = 0
        if !answerScroll.isHidden, let layout = answer.layoutManager, let textContainer = answer.textContainer {
            layout.ensureLayout(for: textContainer)
            documentHeight = ceil(layout.usedRect(for: textContainer).maxY) + answer.textContainerInset.height * 2
        }
        let titleHeight: CGFloat = statusLine.isHidden ? 0 : min(textHeight(statusLine.stringValue) + 6, 48)
        let maxAnswerHeight = max(40, min(420, availableFrame.height - orbSize - titleHeight - questionHeight - 72))
        let answerHeight: CGFloat = answerScroll.isHidden ? 0 : min(max(documentHeight, 40), maxAnswerHeight)
        answerScroll.hasVerticalScroller = documentHeight > answerHeight
        let gap: CGFloat = titleHeight > 0 && answerHeight > 0 ? 8 : 0
        let hasText = questionHeight + answerHeight + titleHeight > 0
        let textBottom = orbSize
        let height = hasText ? textBottom + questionHeight + answerHeight + titleHeight + gap + 24 : textBottom
        // AppKit 改高度默认移动底边；显式保持原点，避免每个输入事件把球体挪走。
        let origin = NSPoint(x: frame.midX - width / 2, y: frame.minY)
        setContentSize(NSSize(width: width, height: height))
        setFrameOrigin(origin)
        orbView.frame = NSRect(x: (width - orbSize) / 2, y: 0, width: orbSize, height: orbSize)
        connectionNotice.frame = NSRect(x: horizontalInset, y: 0, width: textWidth, height: 20)
        statusLine.frame = NSRect(x: horizontalInset, y: height - 12 - titleHeight, width: textWidth, height: titleHeight)
        answerScroll.frame = NSRect(x: horizontalInset, y: textBottom + 12, width: textWidth, height: answerHeight)
        let answerWidth = answerScroll.contentSize.width
        answer.setFrameSize(NSSize(width: answerWidth, height: max(documentHeight, answerHeight)))
        answer.textContainer?.containerSize = NSSize(width: answerWidth, height: .greatestFiniteMagnitude)
        if let layout = answer.layoutManager, let textContainer = answer.textContainer {
            layout.ensureLayout(for: textContainer)
            let laidOutHeight = ceil(layout.usedRect(for: textContainer).maxY) + answer.textContainerInset.height * 2
            answer.setFrameSize(NSSize(width: answerWidth, height: max(laidOutHeight, answerHeight)))
        }
        answer.alignment = documentHeight < 50 ? .center : .left
        bubble.frame = NSRect(x: horizontalInset, y: textBottom + 12 + answerHeight + gap, width: textWidth, height: questionHeight)
        desktopInput.frame = bubble.frame
        subtitleScroll.frame = bubble.frame
        desktopSubtitle.setFrameSize(NSSize(width: textWidth, height: max(68, desktopSubtitle.frame.height)))
        desktopSubtitle.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        if !subtitleScroll.isHidden {
            desktopSubtitle.layoutManager?.ensureLayout(for: desktopSubtitle.textContainer!)
            desktopSubtitle.scrollRangeToVisible(NSRange(location: desktopSubtitle.string.utf16.count, length: 0))
        }
        transcriptSurface.isHidden = !hasText
        // 单行回执背景随文字收紧；长结果仍沿用有界滚动区域。
        let titleOnly = questionHeight == 0 && answerHeight == 0 && titleHeight > 0
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
