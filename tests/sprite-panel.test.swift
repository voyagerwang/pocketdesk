/**
 * [INPUT]: AppKit、SpriteFeedbackPanel 与展示值类型；以测试锁屏状态替代系统锁屏执行器，并注入异步焦点读和内存应用激活记录。
 * [OUTPUT]: 验证取消安全归还应用、居中字幕与组合下划线同步及输入门禁；紧凑恢复卡依事实显示单主动作、重试封连点、未知结果只进输入；文字转语音收起前文说明并保留草稿，覆盖 Unicode、真实表情与长回答布局。
 * [POS]: 原生面板集成回归；只聚焦测试窗口并合成 AppKit 组合文本，应用归还只写内存记录，不激活真实外部应用、不注入按键、不启动录音、不请求模型。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import WebKit
// 独立编译此测试时不链接生产 LockScreenInput，避免操作真实锁屏。
// 文件发送接入后编译闭包扩大（ExecutionTrace/WSServer 也引用该类型），替身补齐成员保持只读隔离。
final class LockScreenInput {
    static var locked = false
    static var state = "unlocked"
    static let shared = LockScreenInput()
    func cancel() {}
    func prepare(session: String) -> [String: Any] { ["ok": false] }
    func prepare(session: String, authorized: @escaping () -> Bool, deadline: TimeInterval) -> [String: Any] { ["ok": false] }
    func submit(password: String, id: String, session: String, authorized: @escaping () -> Bool,
                completion: @escaping ([String: Any]) -> Void) { completion(["ok": false]) }
    func submit(password: String, id: String, session: String, authorized: @escaping () -> Bool,
                deadline: TimeInterval, targetConfirmed: Bool, completion: @escaping ([String: Any]) -> Void) { completion(["ok": false]) }
}
@main struct SpritePanelTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await runTests()
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func runTests() async {
        let savedFrame = UserDefaults.standard.object(forKey: SpriteFeedbackPanel.frameDefaultsKey)
        defer { UserDefaults.standard.set(savedFrame, forKey: SpriteFeedbackPanel.frameDefaultsKey) }
        let panel = SpriteFeedbackPanel(webRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Web"))
        panel.desktopFocusedPID = { $0(nil) }
        panel.desktopActivateApplication = { _ in assertionFailure("测试不得激活真实外部应用"); return false }
        defer { panel.orderOut(nil) }
        var model = SpriteFeedback.ViewModel()
        model.visible = true; model.presentationRevision = 1
        model.phase = .drafting; model.draft = "测试问题"; model.question = "测试问题"
        model.answer = String(repeating: "这是一段需要滚动查看的测试回答。", count: 100)
        model.statusLine = "测试反馈"
        panel.apply(model)
        panel.contentView?.layoutSubtreeIfNeeded()
        assert(panel.contentView?.layer?.backgroundColor?.alpha == 0, "容器透明")
        let transcript = panel.contentView!.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "测试问题" }!
        assert(panel.frame.width == 600 && transcript.frame.height < 30 && transcript.frame.width > 560,
               "电脑反馈框加宽且短句单行")
        assert(panel.isVisible && !panel.canBecomeKey && !panel.canBecomeMain)
        if let bitmap = panel.contentView!.bitmapImageRepForCachingDisplay(in: panel.contentView!.bounds) {
            panel.contentView!.cacheDisplay(in: panel.contentView!.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/pocketdesk-native-text.png"))
            }
        }
        let orb = panel.contentView!.subviews.compactMap { $0 as? SpriteOrbView }.first!
        func js(_ script: String) async -> Any? {
            do { return try await orb.evaluateJavaScript(script) }
            catch { assertionFailure("WebKit 脚本失败：\(error)"); return nil }
        }
        func expectString(_ script: String, _ expected: String, _ message: String) async {
            let deadline = Date().addingTimeInterval(1)
            var value = await js(script) as? String
            while value != expected && Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
                value = await js(script) as? String
            }
            assert(value == expected, message + ": " + String(describing: value))
        }
        // 真实 WKWebView 的本地页面与原版脚本必须完成装载；isLoading 在导航开始前后都可能为假，必须直接轮询脚本就绪。
        var loaded: Bool?
        let deadline = Date().addingTimeInterval(15)
        while loaded != true && Date() < deadline {
            loaded = await js("!!window.pocketdeskDesktopOrb && document.querySelectorAll('#orb svg').length === 1") as? Bool
            if loaded != true { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        assert(loaded == true)
        assert(panel.contentView!.subviews.compactMap { $0 as? NSButton }.allSatisfy(\.isHidden), "默认无常驻按钮")
        assert(transcript.alignment == .center && transcript.font!.pointSize == 15, "文字原生字号并居中")
        model.phase = .working; model.statusLine = "执行中"
        model.busy = true; model.emotion = "32"; panel.apply(model)
        assert(transcript.isHidden, "发送后原话退场")
        let title = panel.contentView!.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "执行中" }!
        assert(!title.isHidden && title.font!.pointSize == 15, "必须明确显示执行中")
        assert(panel.contentView!.subviews.compactMap { $0 as? NSScrollView }.allSatisfy { $0.isHidden }, "执行中不显示旧回答")
        func capture(_ name: String) {
            guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/pocketdesk-phase-" + name + ".png"))
            }
        }
        capture("working")
        await expectString("pocketdeskDesktopOrb.state().emotion", "32", "执行表情立即抢占唤醒")
        model.phase = .drafting; model.busy = false; model.emotion = "35"; model.draft = "正在输入的新句子"; panel.apply(model)
        await expectString("pocketdeskDesktopOrb.state().emotion", "35", "输入态用原版聆听")
        model.phase = .succeeded; model.statusLine = "已完成"; model.taskId = "panel-done"
        model.draft = ""; model.emotion = "33"; panel.apply(model)
        assert(transcript.isHidden && title.stringValue == "已完成", "完成标题与结果取代原话")
        // WebKit 短暂隐藏后允许进入完成稳态；精确庆祝时序由 orb-desktop.test.py 覆盖。
        let completionEmotion = await js("pocketdeskDesktopOrb.state().emotion") as? String
        assert(completionEmotion == "33" || completionEmotion == "19", "完成庆祝或完成稳态")
        let playing = await js("document.hidden || pocketdeskDesktopOrb.state().active") as? Bool
        assert(playing == true || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "可见原生窗口必须实际播放")
        capture("completed")
        let scroll = panel.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!
        assert(scroll.frame.height > 30, "回答区域不能坍缩")
        assert(scroll.hasVerticalScroller && scroll.autohidesScrollers, "长答案使用自动隐藏滚动条")
        assert(scroll.documentView!.frame.height > scroll.contentSize.height, "长答案可以滚动")
        model.answer = "今天（9月29日）有 3 个日程：\n\n- 11:00–12:00 直播早会（9楼会议室2）\n- 14:00–15:00【探月&体验】IM&直播需求节奏对齐（5层休息区）\n- 14:00–16:00【用户端】每周二需求预审\n\n后两个时间有重叠，注意安排。"
        panel.apply(model)
        assert(!scroll.hasVerticalScroller, "截图中的短日程完整展开，无滚动条")
        assert(scroll.documentView!.frame.height <= scroll.contentSize.height + 1, "短答案无隐藏正文")
        capture("short-calendar")
        let other = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }!
        panel.perform(NSSelectorFromString("appActivated:"), with: Notification(name: NSWorkspace.didActivateApplicationNotification, userInfo: [NSWorkspace.applicationUserInfoKey: other]) as NSNotification)
        assert(!panel.isVisible, "切应用后隐藏")
        model.presentationRevision += 1; panel.apply(model)
        assert(panel.isVisible, "重选恢复")
        panel.perform(NSSelectorFromString("screenLocked"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        model.presentationRevision += 1; panel.apply(model)
        assert(!panel.isVisible, "锁屏期间重选不显示")
        panel.perform(NSSelectorFromString("screenUnlocked"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        assert(panel.isVisible)
        model.phase = .idle; model.question = nil; model.answer = nil; model.statusLine = "你说，我在"; model.emotion = "02"
        panel.apply(model)
        assert(panel.contentView!.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.isHidden || $0.stringValue.isEmpty }, "默认态无常驻文字")
        assert(scroll.isHidden && panel.frame.height == 176, "空闲只保留球球")
        var imageFinished = false
        orb.takeSnapshot(with: nil) { image, error in
            assert(error == nil && image != nil)
            if let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/pocketdesk-native-orb.png"))
            }
            imageFinished = true
        }
        let imageDeadline = Date().addingTimeInterval(5)
        while !imageFinished && Date() < imageDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        assert(imageFinished)

        // MARK: 同源字幕与组合文本提交
        assert(panel.beginDesktopCapture(), "测试接收框能够开启")
        let focusDeadline = Date().addingTimeInterval(2)
        while !panel.desktopInputReady && Date() < focusDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        assert(panel.desktopInputReady, "仅测试接收框取得输入焦点")
        guard let editor = panel.desktopInput.currentEditor() as? NSTextView else {
            assertionFailure("测试接收框必须使用真实 AppKit field editor")
            return
        }
        let prefix = "已确认："
        let composition = "中文🙂e\u{301}组合文本"
        let completeText = prefix + composition
        editor.string = prefix
        editor.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
        editor.setMarkedText(composition,
                             selectedRange: NSRange(location: composition.utf16.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        assert(editor.hasMarkedText() && panel.desktopText == completeText,
               "合成组合文本包括已确认前文、中文、emoji 与组合字符")
        panel.updateDesktopSubtitle()
        guard let subtitle = panel.contentView!.subviews.compactMap({ $0 as? NSScrollView }).first(where: {
            ($0.documentView as? NSTextView)?.string == completeText
        }) else {
            assertionFailure("字幕必须读取当前 field editor 全文")
            return
        }
        let subtitleView = subtitle.documentView as! SpriteSubtitleView
        func underlineRanges() -> [NSRange] {
            var ranges: [NSRange] = []
            subtitleView.textStorage!.enumerateAttribute(.underlineStyle,
                in: NSRange(location: 0, length: subtitleView.string.utf16.count)) { value, range, _ in
                if (value as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue { ranges.append(range) }
            }
            return ranges
        }
        assert(panel.desktopInput.alphaValue == 0 && !panel.desktopInput.isHidden && panel.desktopInputReady,
               "隐藏输入层全部绘制，但真实编辑焦点与组合输入继续可用")
        assert(underlineRanges() == [editor.markedRange()], "蓝线仅标记实际组合范围，不覆盖已确认前文")
        // 同样正文在输入法内改变组合范围，字幕必须随真实范围刷新。
        editor.setMarkedText(completeText, selectedRange: NSRange(location: completeText.utf16.count, length: 0),
                             replacementRange: NSRange(location: 0, length: completeText.utf16.count))
        panel.updateDesktopSubtitle()
        assert(underlineRanges() == [NSRange(location: 0, length: completeText.utf16.count)]
               && panel.desktopText == completeText, "相同正文的组合范围变化也同步更新蓝线")
        func freezeExpectation(_ subtitle: NSScrollView) -> (String) -> Void {
            let textView = subtitle.documentView as! NSTextView
            let text = textView.string
            let font = textView.font
            let panelFrame = panel.frame
            let screenRect = panel.convertToScreen(subtitle.convert(subtitle.bounds, to: nil))
            let scrollOrigin = subtitle.contentView.bounds.origin
            return { status in
                assert(!title.isHidden && title.stringValue == status, "语音阶段标题直接切换：" + status)
                assert(!subtitle.isHidden && subtitle.documentView === textView && textView.string == text,
                       "活动阶段保留同一字幕控件与完整转写")
                assert(textView.font == font && textView.font?.pointSize == 16, "活动阶段保留字幕原字号")
                assert(panel.frame == panelFrame && panel.convertToScreen(subtitle.convert(subtitle.bounds, to: nil)) == screenRect,
                       "聆听到执行期间面板与字幕屏幕坐标固定")
                assert(subtitle.contentView.bounds.origin == scrollOrigin, "活动阶段字幕滚动位置固定")
                assert(scroll.isHidden, "活动阶段不渲染任务快照残留结果")
            }
        }
        panel.desktopStatus("正在听")
        assert(!title.isHidden && !subtitle.isHidden && title.stringValue == "正在听", "接收时只显示正在听")
        let expectShortSubtitle = freezeExpectation(subtitle)
        expectShortSubtitle("正在听")
        let listeningEmotion = await js("pocketdeskDesktopOrb.state().emotion") as? String
        assert(listeningEmotion == "02" || listeningEmotion == "10",
               "接收阶段显示真实待机或既有开心唤醒动效")
        try? await Task.sleep(nanoseconds: 200_000_000)
        capture("voice-listening")
        assert(panel.commitDesktopText() == completeText && !editor.hasMarkedText(),
               "提交同一 field editor 的组合文本，正文与 Unicode 完整保留")
        assert(underlineRanges().isEmpty && subtitleView.string == completeText,
               "确认后正文不变，组合下划线也立即清除")
        assert(editor.string == completeText && panel.desktopInput.stringValue == completeText,
               "接受 composition 后接收框与 field editor 全文一致")
        expectShortSubtitle("正在听")
        panel.beginDesktopExecution()
        expectShortSubtitle("执行中")
        assert(!panel.desktopInputReady && panel.commitDesktopText() == nil,
               "失去接收焦点后拒绝提交，不读取旧正文作为新输入")
        assert(panel.desktopInput.isHidden && !panel.isKeyWindow && !panel.canBecomeKey,
               "执行阶段释放编辑焦点且隐藏接收框")
        assert(NSApp.keyWindow !== panel && panel.isVisible,
               "释放的是系统管理的真实 key，字幕面板仍可见")
        var voiceTask = AgentTask(subject: "panel-test", requestId: "voice-short", text: completeText,
                                  result: "旧结果不应重新排版转写")
        panel.desktopTask(voiceTask)
        expectShortSubtitle("执行中")
        voiceTask.status = .running
        panel.desktopTask(voiceTask)
        panel.updateDesktopSubtitle()
        expectShortSubtitle("执行中")
        await expectString("pocketdeskDesktopOrb.state().emotion", "32", "释放焦点后执行球体恢复当前状态")
        let executingVisible = await js("!document.hidden && pocketdeskDesktopOrb.state().active") as? Bool
        assert(executingVisible == true || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               "释放焦点后可见的球体仍实际播放")
        try? await Task.sleep(nanoseconds: 200_000_000)
        capture("voice-executing")
        voiceTask.status = .verifying
        panel.desktopTask(voiceTask)
        expectShortSubtitle("结果待核对")
        voiceTask.status = .succeeded; voiceTask.result = "Unicode 组合任务已完成"
        panel.desktopTask(voiceTask)
        assert(subtitle.isHidden && !scroll.isHidden && title.stringValue == "已完成"
               && (scroll.documentView as? NSTextView)?.string == voiceTask.result,
               "终态才隐藏字幕并展示真实结果")
        assert(panel.desktopInput.currentEditor() == nil && panel.desktopText == completeText,
               "执行结束后 fallback 仍保存完整最终正文")

        // MARK: 连续补充
        // 完全走生产接收入口，不靠测试主动收起、等待或额外调用聚焦来修复窗口状态。
        func beginNextCapture(_ reason: String) async -> NSTextView {
            assert(panel.beginDesktopCapture(), reason)
            let deadline = Date().addingTimeInterval(1)
            while !panel.desktopInputReady && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            assert(panel.desktopInputReady && NSApp.keyWindow === panel,
                   reason + "：再次接收须在启动期限内取得系统和本地焦点")
            assert(panel.desktopText.isEmpty && !panel.desktopHasMarkedText,
                   reason + "：上一轮文字不能进入本次补充")
            return panel.desktopInput.currentEditor() as! NSTextView
        }
        for status in [TaskStatus.needsInput, .failed] {
            let nextEditor = await beginNextCapture("前轮结束后开始补充")
            let nextText = "补充应用名称：中文🙂e\u{301}"
            nextEditor.string = nextText
            panel.updateDesktopSubtitle()
            assert(panel.commitDesktopText() == nextText)
            panel.beginDesktopExecution()
            let nextTask = AgentTask(subject: "panel-test", requestId: "follow-up-" + status.rawValue,
                                     status: status, text: nextText, result: "请继续补充", error: "请重试")
            panel.desktopTask(nextTask)
            assert(panel.isVisible && !panel.isKeyWindow && NSApp.keyWindow !== panel,
                   "待补充和失败均保留回执并交出系统 key")
            assert((scroll.documentView as? NSTextView)?.string == "请继续补充",
                   "连续补充保留真实结果，操作提示独立呈现")
            assert(panel.contentView!.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.count >= 2,
                   "待补充和失败提供一个主动作与换件事出口")
        }

        // MARK: 恢复路径与归属
        let buttons = panel.contentView!.subviews.compactMap { $0 as? NSButton }
        let supplement = buttons.first { $0.accessibilityIdentifier() == "pocketdesk.sprite.supplement" }!
        let newTask = buttons.first { $0.accessibilityIdentifier() == "pocketdesk.sprite.new-task" }!
        var chosenTask: String?
        var chosenIntent: TaskRecovery.InputIntent?
        panel.onRecoveryInputRequested = { id, intent in chosenTask = id; chosenIntent = intent }
        var blocked = AgentTask(subject: "panel-test", requestId: "recovery", status: .failed,
                                text: "清理指定网站的重复标签页", error: "当前工具只能按完整网址清理各窗口里的重复页。")
        blocked.recovery = .init(kind: .capabilityLimit, nextStep: "可以清理全部重复页，或说明你希望保留哪些页面。")
        panel.desktopTask(blocked)
        assert(title.stringValue == "当前能力有限" && supplement.title == "调整要求" && !supplement.isHidden,
               "能力限制直显范围，并提供明确的调整入口")
        assert((scroll.documentView as? NSTextView)?.string.contains("可以清理全部重复页") == true,
               "真实可行的下一步完整呈现")
        assert(panel.contentView!.subviews.compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue == blocked.text
        }, "恢复卡用原要求定位上下文，不展示重复的通用长说明")
        assert(panel.frame.width == 440 && !newTask.isBordered, "恢复卡紧凑且换件事为低权重操作")
        await expectString("pocketdeskDesktopOrb.state().emotion", "11", "未完成用真实疑惑表情")
        try? await Task.sleep(nanoseconds: 200_000_000)
        capture("recovery-capability")
        supplement.performClick(nil)
        assert(chosenTask == blocked.id && chosenIntent == .supplement,
               "明确补充携带原任务身份")
        newTask.performClick(nil)
        assert(chosenTask == blocked.id && chosenIntent == .newTask, "换件事意图明确，原身份只用于可返回的输入上下文")

        blocked.status = .needsInput; blocked.error = nil; blocked.result = "你要操作的是 Chrome，还是 Safari？"
        blocked.recovery = .init(kind: .clarification, nextStep: "直接说应用名称就可以。")
        panel.desktopTask(blocked)
        assert(title.stringValue == "等你补充" && supplement.title == "补充信息",
               "表达不完整时提出一个具体问题")
        capture("recovery-clarification")
        blocked.status = .failed; blocked.result = nil; blocked.error = "本次模型连接中断，任务还没完成。"
        blocked.recovery = .init(kind: .executionFailure, nextStep: "可以补充你希望达到的结果，或连接恢复后说“继续”。")
        blocked.transcript = [["role": "user", "content": blocked.text]]
        panel.desktopTask(blocked)
        capture("recovery-execution")
        let originalGoal = blocked.text
        blocked.text = "帮我把今天下午还没有处理完的几个会议记录整理成一份清楚的行动清单，保留每位负责人的姓名和截止时间"
        panel.desktopTask(blocked)
        capture("recovery-long-goal")
        blocked.text = originalGoal
        panel.desktopTask(blocked)
        var retryCount = 0
        panel.onRecoveryRetryRequested = { id in assert(id == blocked.id); retryCount += 1 }
        assert(supplement.title == "再试一次")
        supplement.performClick(nil); supplement.performClick(nil)
        assert(retryCount == 1, "明确重试立即封住连点且不借用文本焦点")
        blocked.status = .submitted; blocked.recovery = .init(kind: .unconfirmed)
        blocked.error = nil; blocked.result = "操作已发出，还没有收到确认结果。"
        panel.desktopTask(blocked)
        capture("recovery-unconfirmed")
        supplement.performClick(nil)
        assert(retryCount == 1 && chosenIntent == .supplement && supplement.title == "核对结果",
               "结果未知仅进入核对输入，不提交一次重试")
        assert(panel.beginDesktopCapture(intent: .supplement, continuing: true, textEntry: true,
                                         summary: blocked.text, question: "你要操作的是 Chrome，还是 Safari？", canReturn: true))
        panel.desktopStatus("说说要补充的内容")
        let typingDeadline = Date().addingTimeInterval(2)
        while !panel.desktopInputReady && Date() < typingDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        let typedEditor = panel.desktopInput.currentEditor() as! NSTextView
        typedEditor.string = "可以先检查设备连接"
        typedEditor.setSelectedRange(NSRange(location: typedEditor.string.utf16.count, length: 0))
        assert(panel.desktopInput.isBezeled && panel.desktopInput.alphaValue == 1
               && typedEditor.textColor != .clear && typedEditor.insertionPointColor != .clear,
               "明确点击后的文字输入有真实边框、文字与光标")
        assert(panel.contentView!.subviews.compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue.contains("接着说 · ")
        }, "接收时清楚标识前文仍保留")
        assert(!scroll.isHidden && (scroll.documentView as? NSTextView)?.string.contains("Chrome") == true,
               "进入补充后原问题和候选仍可参照")
        capture("recovery-input")
        panel.onInputIntentChanged = { intent in
            panel.setDesktopInputContext(intent: intent, continuing: intent == .supplement)
            panel.desktopStatus(intent == .newTask ? "想做什么？" : "说说要补充的内容")
        }
        newTask.performClick(nil)
        assert(newTask.title == "返回原事" && panel.desktopText == "可以先检查设备连接", "换件事保留草稿并提供返回")
        assert(scroll.isHidden, "换件事收起原问题")
        capture("recovery-new-topic")
        newTask.performClick(nil)
        assert(newTask.title == "换件事" && panel.desktopText == "可以先检查设备连接", "返回原事保留同一份草稿")
        assert(!scroll.isHidden, "返回原事恢复问题")
        panel.useVoicePresentation()
        assert(panel.desktopText == "可以先检查设备连接" && !panel.desktopInput.isBezeled,
               "文字转语音仍用同一字段且不丢补充")
        assert(scroll.isHidden, "文字转语音收起前文说明，接收区仅保留状态与真实字幕")
        panel.endDesktopCapture()

        let pendingEditor = await beginNextCapture("失败后再次补充")
        pendingEditor.string = "尚在等待最终转写的前文"
        pendingEditor.setSelectedRange(NSRange(location: pendingEditor.string.utf16.count, length: 0))
        pendingEditor.setMarkedText("未确认的组合文字", selectedRange: NSRange(location: 0, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: 0))
        assert(panel.desktopHasMarkedText)
        _ = await beginNextCapture("未完成转写时明确开始新一轮")
        panel.endDesktopCapture()
        assert(NSApp.keyWindow !== panel && !panel.isKeyWindow && panel.isVisible,
               "结束接收正常交出 key，不主动收起面板")

        // MARK: 多行字幕与独立空标题
        for separator in ["\n", ""] {
            let longEditor = await beginNextCapture("多行字幕使用新的测试接收轮次")
            let longText = (1...7).map { "第\($0)段：保留连续口述的完整文字，中文🙂与组合字符e\u{301}。" }.joined(separator: separator)
            longEditor.setMarkedText(longText, selectedRange: NSRange(location: longText.utf16.count, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            panel.updateDesktopSubtitle()
            panel.desktopStatus("正在听")
            assert((subtitle.documentView as? NSTextView)?.string == longText && subtitle.contentView.bounds.origin.y > 0,
                   "超过三行时字幕保留全文并滚动到末尾")
            assert(underlineRanges() == [longEditor.markedRange()], "跨行组合文字的标记沿用完整UTF-16范围")
            capture("voice-marked-multiline")
            let expectLongSubtitle = freezeExpectation(subtitle)
            assert(panel.commitDesktopText() == longText, "多行全文从同源接收框提交")
            expectLongSubtitle("正在听")
            panel.beginDesktopExecution()
            expectLongSubtitle("执行中")
            var longTask = AgentTask(subject: "panel-test", requestId: "voice-long", status: .running, text: longText,
                                     result: "长转写不能被旧结果替换")
            panel.desktopTask(longTask)
            expectLongSubtitle("执行中")
            longTask.status = .needsInput; longTask.result = "需要补充哪个应用？"
            panel.desktopTask(longTask)
            assert(subtitle.isHidden && !scroll.isHidden && (scroll.documentView as? NSTextView)?.string == "需要补充哪个应用？",
                   "待补充才以真实问题替换长字幕")
            panel.endDesktopCapture()
        }

        assert(panel.beginDesktopCapture(), "独立验证通用空标题能力")
        let heightWithStatus = panel.frame.height
        panel.desktopStatus("")
        assert(title.isHidden && title.stringValue.isEmpty && panel.frame.height < heightWithStatus,
               "显式空标题仍可隐藏并移除布局高度")
        assert(!subtitle.isHidden, "通用空标题不删除字幕")
        panel.endDesktopCapture()

        // ---------- 明确取消只归还仍由接收窗口借用的应用焦点 ----------
        var focusReads: [(pid_t?) -> Void] = []
        var activated: [pid_t] = []
        var originalRunning = true
        let originalPID = other.processIdentifier
        panel.desktopFocusedPID = { focusReads.append($0) }
        panel.desktopApplication = { $0 == originalPID ? other : nil }
        panel.desktopApplicationIsRunning = { _ in originalRunning }
        panel.desktopActivateApplication = { activated.append($0.processIdentifier); return true }
        func deliverFocus(_ pid: pid_t?) {
            assert(!focusReads.isEmpty, "必须已经发起异步系统焦点读取")
            focusReads.removeFirst()(pid)
        }
        func openBorrowedCapture() async {
            assert(panel.beginDesktopCapture())
            assert(focusReads.count == 1 && activated.isEmpty,
                   "首次接收在激活之前读取真实焦点，尚未归还应用")
            deliverFocus(originalPID)
            let deadline = Date().addingTimeInterval(1)
            while !panel.desktopInputReady && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            assert(panel.desktopInputReady && NSApp.isActive)
        }
        func dismissBorrowedCapture() {
            panel.dismissDesktopCapture()
            assert(!panel.isVisible && !panel.desktopMode && NSApp.keyWindow !== panel,
                   "确认取消后先移除接收窗口，再异步核验应用焦点")
            assert(focusReads.count == 1)
        }
        for pid in [Optional(ProcessInfo.processInfo.processIdentifier), nil] {
            activated = []
            await openBorrowedCapture()
            assert(panel.resumeDesktopCapture() && focusReads.isEmpty,
                   "重试复用已捕获的原应用，不把本进程覆盖成目标")
            assert(panel.beginDesktopCapture() && focusReads.isEmpty,
                   "接收中重新开始保留原应用身份")
            dismissBorrowedCapture()
            assert(activated.isEmpty, "异步核验完成前不能归还")
            deliverFocus(pid)
            assert(activated == [originalPID], "本进程持有焦点或活跃但无焦点时归还原应用一次")
        }
        activated = []
        await openBorrowedCapture()
        dismissBorrowedCapture()
        deliverFocus(originalPID)
        assert(activated.isEmpty, "系统真实焦点已在外部应用时绝不抢回")

        await openBorrowedCapture()
        dismissBorrowedCapture()
        panel.perform(NSSelectorFromString("appActivated:"), with: Notification(name: NSWorkspace.didActivateApplicationNotification,
            userInfo: [NSWorkspace.applicationUserInfoKey: other]) as NSNotification)
        deliverFocus(ProcessInfo.processInfo.processIdentifier)
        assert(activated.isEmpty, "切应用通知使旧归还失效，即使迟到AX结果仍指向本进程")

        await openBorrowedCapture()
        let settingsWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 160, height: 80),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.makeKeyAndOrderFront(nil)
        assert(NSApp.keyWindow === settingsWindow)
        dismissBorrowedCapture()
        deliverFocus(ProcessInfo.processInfo.processIdentifier)
        assert(activated.isEmpty, "本进程其他key窗口表明用户已移交焦点，不归还")
        settingsWindow.orderOut(nil)

        assert(panel.beginDesktopCapture() && focusReads.count == 1)
        settingsWindow.makeKeyAndOrderFront(nil)
        deliverFocus(originalPID)
        assert(NSApp.keyWindow === settingsWindow && !panel.desktopInputReady && activated.isEmpty,
               "首次借焦点读取期间新打开同进程窗口，迟到结果不能抢回接收框")
        panel.dismissDesktopCapture()
        assert(focusReads.isEmpty, "已放弃借焦点的接收不保留原应用归还请求")

        assert(panel.beginDesktopCapture() && focusReads.count == 1)
        deliverFocus(ProcessInfo.processInfo.processIdentifier)
        let settingsCaptureDeadline = Date().addingTimeInterval(1)
        while !panel.desktopInputReady && Date() < settingsCaptureDeadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        assert(panel.desktopInputReady && NSApp.keyWindow === panel,
               "显式唤醒开始时已有的同进程窗口可以把焦点交给接收框")
        panel.dismissDesktopCapture()
        assert(focusReads.isEmpty && activated.isEmpty, "从本进程窗口唤醒不猜测外部归还目标")
        settingsWindow.orderOut(nil)

        await openBorrowedCapture()
        dismissBorrowedCapture()
        assert(panel.beginDesktopCapture() && focusReads.count == 2)
        deliverFocus(nil)
        assert(activated.isEmpty, "新一轮接收使旧取消的迟到归还失效")
        deliverFocus(originalPID)
        panel.endDesktopCapture()

        await openBorrowedCapture()
        dismissBorrowedCapture()
        originalRunning = false
        deliverFocus(nil)
        assert(activated.isEmpty, "原应用退出后不激活同号或无效目标")
        originalRunning = true

        await openBorrowedCapture()
        dismissBorrowedCapture()
        LockScreenInput.locked = true
        deliverFocus(nil)
        assert(activated.isEmpty, "锁屏阻断迟到的应用归还")
        LockScreenInput.locked = false

        assert(panel.beginDesktopCapture() && focusReads.count == 1)
        panel.dismissDesktopCapture()
        deliverFocus(originalPID)
        assert(!panel.isVisible && !panel.desktopMode && activated.isEmpty,
               "首次焦点读取尚未完成就取消，不再激活接收窗或外部应用")
        print("sprite panel: 可见性/锁屏隔离/布局/Unicode提交/字幕固定/连续补充/取消安全归还应用焦点全部通过")
    }
}
