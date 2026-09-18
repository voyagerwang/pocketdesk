/**
 * [INPUT]: 依赖 AppKit、SpriteOrbView 的原版动态组件与 SpriteFeedback.ViewModel；监听前台、锁屏和减少动态设置。
 * [OUTPUT]: 非激活透明精灵面板：按输入/提交/执行/终态切换的标题和正文、原版表情与有界结果滚动；空闲无提示文字、无收起按钮；切走隐藏、重选开心唤醒。
 * [POS]: 桌面展示层；球体单独在 WebKit 内矢量绘制，正文由原生字体按屏幕比例绘制，不随球体缩放或旋转。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

final class SpriteFeedbackPanel: NSPanel {
    private let container = NSView()
    private let transcriptSurface = NSView()
    private let bubble = NSTextField(labelWithString: "")
    private let answer = NSTextView()
    private let answerScroll = NSScrollView()
    private let orbView: SpriteOrbView
    private let statusLine = NSTextField(labelWithString: "")
    private let connectionNotice = NSTextField(labelWithString: "")
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lastViewModel: SpriteFeedback.ViewModel?
    private var hiddenByApplication = false
    private var screenIsLocked = LockScreenInput.locked
    private var presentationRevision = 0
    private var positioned = false
    static let frameDefaultsKey = "sprite.panel.frame.v3"

    init(webRoot: URL) {
        orbView = SpriteOrbView(webRoot: webRoot)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 176),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        transcriptSurface.wantsLayer = true
        transcriptSurface.layer?.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 0.94).cgColor
        transcriptSurface.layer?.cornerRadius = 12
        bubble.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        bubble.textColor = .labelColor
        bubble.alignment = .center
        bubble.lineBreakMode = .byWordWrapping
        bubble.maximumNumberOfLines = 6
        bubble.preferredMaxLayoutWidth = 328
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
        answerScroll.drawsBackground = false
        answerScroll.scrollerStyle = .overlay
        statusLine.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        statusLine.textColor = .labelColor
        statusLine.alignment = .center
        statusLine.lineBreakMode = .byWordWrapping
        statusLine.maximumNumberOfLines = 2
        connectionNotice.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        connectionNotice.textColor = .labelColor
        connectionNotice.alignment = .center
        for view in [transcriptSurface, bubble, answerScroll, orbView, statusLine, connectionNotice] { container.addSubview(view) }
    }

    func apply(_ model: SpriteFeedback.ViewModel) {
        if model.presentationRevision != presentationRevision {
            presentationRevision = model.presentationRevision
            hiddenByApplication = false
        }
        lastViewModel = model
        guard model.visible, !screenIsLocked, !hiddenByApplication else { orderOutAndKeepIntent(); return }
        bubble.stringValue = model.phase == .drafting ? model.displayText : ""
        bubble.isHidden = bubble.stringValue.isEmpty
        let answerText = model.phase == .drafting ? "" : model.displayText
        if answer.string != answerText { answer.string = answerText }
        answerScroll.isHidden = answerText.isEmpty
        // 表情传达情绪，标题交代执行事实；两者不能互相替代。
        statusLine.stringValue = model.headline
        connectionNotice.stringValue = model.phoneConnected ? "" : "手机输入已断开"
        connectionNotice.isHidden = model.phoneConnected
        statusLine.isHidden = statusLine.stringValue.isEmpty
        layoutContent()
        if !isVisible { centerAndShow() }
        updateOrb(model)
    }

    private func updateOrb(_ model: SpriteFeedback.ViewModel) {
        orbView.update(visible: isVisible && model.visible && !screenIsLocked && !hiddenByApplication,
                       revision: model.presentationRevision, emotion: model.emotion, reduced: reduceMotion, taskId: model.taskId)
    }

    private func layoutContent() {
        let width: CGFloat = 360, textWidth: CGFloat = 328
        func textHeight(_ text: String) -> CGFloat {
            ceil((text as NSString).boundingRect(with: NSSize(width: textWidth - 10, height: 100_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 15)]).height)
        }
        let questionHeight: CGFloat = bubble.isHidden ? 0 : min(textHeight(bubble.stringValue) + 6, 132)
        let documentHeight: CGFloat = answerScroll.isHidden ? 0 : textHeight(answer.string) + 16
        let answerHeight: CGFloat = answerScroll.isHidden ? 0 : min(max(documentHeight, 40), 180)
        let titleHeight: CGFloat = statusLine.isHidden ? 0 : min(textHeight(statusLine.stringValue) + 6, 48)
        let gap: CGFloat = titleHeight > 0 && answerHeight > 0 ? 8 : 0
        let hasText = questionHeight + answerHeight + titleHeight > 0
        let textBottom: CGFloat = 176
        let height = hasText ? textBottom + questionHeight + answerHeight + titleHeight + gap + 24 : textBottom
        // AppKit 改高度默认移动底边；显式保持原点，避免每个输入事件把球体挪走。
        let origin = frame.origin
        setContentSize(NSSize(width: width, height: height))
        setFrameOrigin(origin)
        orbView.frame = NSRect(x: 92, y: 0, width: 176, height: 176)
        connectionNotice.frame = NSRect(x: 16, y: 0, width: textWidth, height: 20)
        statusLine.frame = NSRect(x: 16, y: height - 12 - titleHeight, width: textWidth, height: titleHeight)
        answerScroll.frame = NSRect(x: 16, y: textBottom + 12, width: textWidth, height: answerHeight)
        answer.setFrameSize(NSSize(width: textWidth, height: max(documentHeight, answerHeight)))
        answer.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        answer.alignment = documentHeight < 50 ? .center : .left
        bubble.frame = NSRect(x: 16, y: textBottom + 12 + answerHeight + gap, width: textWidth, height: questionHeight)
        transcriptSurface.isHidden = !hasText
        transcriptSurface.frame = NSRect(x: 4, y: textBottom, width: width - 8, height: max(0, height - textBottom))
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
    }

    /// 切到普通应用收起整个反馈窗；后台任务照常进行，迟到结果不弹回。
    /// 本进程（控制台）激活不算切换。
    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier && app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension SpriteFeedbackPanel: SpriteFeedback.Panel {}

private extension NSScreen {
    static func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) }
    }
}
