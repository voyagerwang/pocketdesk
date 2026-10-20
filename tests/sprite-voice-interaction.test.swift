/**
 * [INPUT]: 真实 SpriteDesktopInput/原生接收框；注入内存按键接收器、豆包窗口、焦点 PID 与单调时钟；面板焦点归还不绑定真实外部应用。
 * [OUTPUT]: 验证有界焦点准备内迟到正确回执立即启动，超时/取消/撤权/外部焦点零键，以及启动去重/重试、释放 Option、Esc 取消和语音条关闭核验。
 * [POS]: tests 的桌面语音交互回归；不连接耳机、不注入真实按键、不录音、不提交任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

@main struct SpriteVoiceInteractionTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func run() async {
        let savedFrame = UserDefaults.standard.object(forKey: SpriteFeedbackPanel.frameDefaultsKey)
        defer { UserDefaults.standard.set(savedFrame, forKey: SpriteFeedbackPanel.frameDefaultsKey) }
        let panel = SpriteFeedbackPanel(webRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Web"))
        panel.desktopFocusedPID = { $0(nil) }
        panel.desktopActivateApplication = { _ in assertionFailure("测试不得激活真实外部应用"); return false }
        defer { panel.dismissDesktopCapture() }
        var now = 10.0
        var visible = false
        var focus: pid_t? = getpid()
        var environmentAllowed = true
        var keys: [Bool] = []
        var escapes = 0
        var logs: [String] = []
        let input = SpriteDesktopInput(panel: panel, connectHeadset: false,
            emitter: HeadsetKeyEmitter(post: {
                if $0.getIntegerValueField(.keyboardEventKeycode) == 58 { keys.append($0.flags.contains(.maskAlternate)) }
                if $0.getIntegerValueField(.keyboardEventKeycode) == 53 && $0.type == .keyDown { escapes += 1 }
            }),
            focusedPID: { focus }, dictationPanelVisible: { visible }, uptime: { now }, environmentAllows: { environmentAllowed },
            voiceLog: { logs.append($0) })
        func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }
        func finishDismissal() {
            visible = false; now += 0.2; input.tick()
            assert(!panel.isVisible && !panel.desktopMode, "确认豆包关闭后才收起接收框")
        }
        func open(_ text: String = "") async {
            assert(panel.beginDesktopCapture())
            let deadline = Date().addingTimeInterval(1)
            while !panel.desktopInputReady && Date() < deadline { await settle() }
            assert(panel.desktopInputReady, "测试使用真实 field editor 焦点")
            (panel.desktopInput.currentEditor() as! NSTextView).string = text
            panel.updateDesktopSubtitle()
        }

        // ---------- 已有文字不能证明本次豆包启动 ----------
        await open("保留的补充解释")
        let receiver = panel.desktopInput.currentEditor()
        assert(input.continueVoice() == .started)
        await settle()
        assert(keys == [true])
        assert(input.continueVoice() == .waiting && keys == [true], "启动中重复按键不发第二次快捷键")
        input.tick()
        assert(input.continueVoice() == .waiting, "原文字不冒充新增转写")
        now += HeadsetVoiceTiming.startupObservationSeconds
        input.tick()
        assert(keys == [true, false], "未观察到启动时释放所属快捷键")
        assert(panel.desktopInputReady && panel.desktopText == "保留的补充解释")
        assert(panel.desktopInput.currentEditor() === receiver, "未启动保留同一接收框")
        assert(input.continueVoice() == .started)
        await settle()
        assert(keys == [true, false, true] && panel.desktopText == "保留的补充解释")
        visible = true; input.tick()
        assert(input.continueVoice() == .ended, "观察到豆包后右侧结束录音")
        assert(keys == [true, false, true, false])
        assert(input.continueVoice() == .waiting, "等待完整转写期间不重复启动")
        assert(input.dismissInput() && panel.desktopInputReady, "左侧取消待提交时保留宿主焦点")
        await settle()
        assert(escapes == 1, "Option 已结束后仍须请求豆包取消")
        now += 0.2; input.tick()
        assert(panel.desktopInputReady && input.continueVoice() == .waiting, "豆包仍在时不提前收起或开始新语音")
        finishDismissal()
        assert(!input.dismissInput() && keys.count == 4, "取消幂等，不重复释放")
        assert(input.continueVoice() == .unavailable, "收起后回退普通输入")

        // ---------- 取消必须阻断迟到焦点回调 ----------
        visible = false
        await open()
        assert(input.continueVoice() == .started)
        assert(input.dismissInput())
        await settle()
        assert(keys.count == 4, "取消发生在准备期间，迟到回调不能按下 Option")
        input.tick()
        assert(!panel.isVisible, "取消后轮询不弹回面板")

        // ---------- 焦点失败可重试，原文与接收意图继续保留 ----------
        await open("焦点失败后仍保留")
        focus = nil
        assert(input.continueVoice() == .started)
        now += HeadsetVoiceTiming.focusPreparationSeconds + 0.1
        await settle()
        assert(keys.count == 4 && panel.desktopText == "焦点失败后仍保留")
        focus = getpid()
        assert(input.continueVoice() == .started)
        await settle()
        assert(keys.count == 5 && keys.last == true)
        assert(input.dismissInput() && keys.count == 6 && keys.last == false)
        finishDismissal()

        // ---------- 系统焦点正确但回执晚于旧1秒期限，仍应立即启动 ----------
        await open("准备期间保留的文字")
        let beforeLateFocus = keys.count
        assert(input.continueVoice() == .started)
        now += 1.2
        await settle()
        assert(keys.count == beforeLateFocus + 1 && keys.last == true,
               "正确焦点回执1.2秒到达仍在共享准备期内，不能误报未唤醒")
        assert(panel.desktopText == "准备期间保留的文字")
        assert(input.continueVoice() == .waiting && keys.count == beforeLateFocus + 1,
               "焦点确认后已经启动，不等待满准备期或重复发送Option")
        assert(input.dismissInput()); finishDismissal()

        // ---------- 扩大准备期不能放行已取消、撤权或真实外部焦点 ----------
        await open()
        let beforeCancelledFocus = keys.count
        assert(input.continueVoice() == .started)
        now += 1.2
        assert(input.dismissInput())
        await settle()
        assert(keys.count == beforeCancelledFocus && !panel.isVisible,
               "取消后即使正确焦点回执迟到也不能发送Option")

        await open()
        let beforeDeniedEnvironment = keys.count
        assert(input.continueVoice() == .started)
        environmentAllowed = false
        now += 1.2
        await settle()
        assert(keys.count == beforeDeniedEnvironment, "准备中撤权不能借延长期限发送Option")
        environmentAllowed = true
        assert(input.continueVoice() == .started,
               "环境失效必须退休准备拥有者，权限恢复后明确重试能重新开始")
        await settle()
        assert(keys.count == beforeDeniedEnvironment + 1 && keys.last == true)
        assert(input.dismissInput()); finishDismissal()

        await open("外部焦点不应接收的文字")
        focus = 999
        let beforeForeignFocus = keys.count
        assert(input.continueVoice() == .started)
        now += 1.2
        await settle()
        assert(panel.desktopInputReady && keys.count == beforeForeignFocus,
               "本地编辑器就绪不能覆盖系统明确的外部焦点")
        now += HeadsetVoiceTiming.focusPreparationSeconds
        await settle()
        assert(keys.count == beforeForeignFocus && panel.desktopText == "外部焦点不应接收的文字",
               "持续外部焦点到超时仍零键，保留原文字供重试")
        focus = getpid()
        assert(input.dismissInput()); finishDismissal()

        // ---------- 本轮文字变化也是可观察启动证据 ----------
        await open()
        assert(input.continueVoice() == .started)
        await settle()
        (panel.desktopInput.currentEditor() as! NSTextView).string = "新增语音文字"
        input.tick()
        assert(input.continueVoice() == .ended)
        assert(input.dismissInput())
        finishDismissal()

        // ---------- 云端尾字尚未返回，结束仍等待完整转写而不创建空任务 ----------
        await open()
        assert(input.continueVoice() == .started)
        await settle()
        visible = true; input.tick()
        assert(input.continueVoice() == .ended && panel.isVisible && panel.desktopMode)
        assert(input.continueVoice() == .waiting, "语音尚无文字仍等待迟到转写")
        input.tick()
        assert(input.dismissInput(), "空白待转写仍可明确取消")
        finishDismissal()

        // ---------- 开关式快捷键未观测到启动，超时不能盲发第二次点按 ----------
        visible = false
        await open()
        let beforeToggle = keys.count
        assert(input.continueVoice(key: HeadsetKey.parse("LeftOption"), toggle: true) == .started)
        await settle()
        assert(keys.count == beforeToggle + 2)
        now += HeadsetVoiceTiming.startupObservationSeconds
        input.tick()
        assert(keys.count == beforeToggle + 2, "未知录音状态不能用第二次 toggle 假装关闭")
        assert(input.dismissInput() && keys.count == beforeToggle + 2)
        finishDismissal()

        // ---------- 残留语音条必须确认关闭，不能把发送 Esc 当作成功 ----------
        await open()
        assert(input.continueVoice() == .started)
        await settle()
        visible = true; input.tick()
        let beforeCancel = escapes
        assert(input.dismissInput() && keys.last == false)
        await settle()
        assert(escapes == beforeCancel + 1)
        assert(panel.desktopInputReady, "发出取消仍保留同一 field editor")
        assert(input.dismissInput() && escapes == beforeCancel + 1, "重复回调不重复取消")
        now += 0.31; input.tick()
        await settle()
        assert(escapes == beforeCancel + 2, "语音条仍可见时仅补一次取消")
        now += 1; input.tick(); input.tick()
        assert(escapes == beforeCancel + 2 && panel.desktopInputReady, "关闭未确认时不假称完成、不无限发键")
        assert(input.continueVoice() == .waiting)
        assert(input.dismissInput())
        await settle()
        assert(escapes == beforeCancel + 3, "超时后再次左耳允许明确重试取消")
        finishDismissal()

        // ---------- 清理失焦后不得把 Esc 发给其他应用 ----------
        await open()
        assert(input.continueVoice() == .started)
        await settle()
        visible = true; input.tick()
        assert(input.dismissInput())
        await settle()
        let beforeFocusLoss = escapes
        panel.makeFirstResponder(nil)
        now += 1; input.tick()
        assert(!panel.isVisible && escapes == beforeFocusLoss)
        visible = false
        await open()
        assert(input.continueVoice() == .started)
        await settle()
        visible = true; input.tick()
        focus = 999
        assert(panel.desktopInputReady, "本地 key 仍在，但系统键盘落点已改变")
        let beforeSystemFocusLoss = escapes
        assert(input.dismissInput())
        await settle()
        assert(escapes == beforeSystemFocusLoss && !panel.isVisible, "真实系统焦点不符时不能注入 Esc")
        focus = getpid()
        visible = false
        await open()
        assert(input.continueVoice() == .started)
        await settle()
        now += 0.4; input.tick()
        assert(escapes == beforeSystemFocusLoss, "旧取消不会迟到影响新录音")
        assert(input.dismissInput()); finishDismissal()
        // ---------- 有线中键接续保留按住说，按下不会变成提前结束 ----------
        await open()
        let beforeHeld = keys.count
        assert(input.continueHeldVoice() == .started)
        await settle()
        assert(keys.count == beforeHeld + 1 && keys.last == true)
        visible = true; input.tick()
        assert(input.continueHeldVoice() == .started && keys.count == beforeHeld + 1,
               "按住接续正在录音的接收框不重复快捷键或结束录音")
        assert(input.continueVoice() == .ended, "按住入口的松开由同一结束流程收尾")
        assert(input.continueHeldVoice() == .waiting, "尾字等待不被按住入口重复启动")
        assert(input.dismissInput()); finishDismissal()
        assert(logs.contains { $0.contains("dictation window closed") })
        // ---------- 默认有线唤醒也先取消同一输入，旧松开不得结束下一轮 ----------
        let beforeLegacy = keys.count
        input.beginLegacyHeadsetCapture()
        await settle()
        assert(keys.count == beforeLegacy + 1 && keys.last == true)
        visible = true; input.tick()
        assert(input.dismissLegacyHeadsetInput(), "已有小精灵输入时有线再次按下立即取消")
        assert(keys.count == beforeLegacy + 2 && keys.last == false)
        await settle()
        finishDismissal()
        input.beginLegacyHeadsetCapture()
        await settle()
        let newLegacyKeys = keys.count
        assert(keys.last == true)
        visible = true; input.tick()
        assert(input.dismissLegacyHeadsetInput())
        await settle()
        finishDismissal()
        await open()
        assert(input.continueVoice() == .started)
        await settle()
        let afterRetry = keys.count
        input.endLegacyHeadsetCapture()
        assert(keys.count == afterRetry && keys.last == true && afterRetry > newLegacyKeys,
               "取消后的旧有线松开不结束新入口的录音")
        assert(input.dismissInput()); finishDismissal()
        print("PASS sprite voice interaction: late valid focus within shared preparation budget, zero keys after timeout/cancel/environment loss/foreign focus, Option release, Escape and verified dictation closure; no physical input or tasks")
    }
}
