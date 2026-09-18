/**
 * [INPUT]: AppKit、SpriteFeedbackPanel 与展示值类型；以测试锁屏状态替代系统锁屏执行器。
 * [OUTPUT]: 验证输入→执行→完成的标题/正文切换和真实 WebKit 原版表情与无常驻文案、居中文字、待机/忙碌动效切换、非激活面板重选恢复、锁屏隔离、长回答布局和可滚动区域。
 * [POS]: 原生面板集成回归；只展示测试窗，不切换应用、不注入按键、不请求模型。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import WebKit
// 独立编译此测试时不链接生产 LockScreenInput，避免操作真实锁屏。
enum LockScreenInput { static var locked = false }
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
        assert(transcript.frame.height < 30 && transcript.frame.width > 300, "短句单行")
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
            let value = await js(script) as? String
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
        assert(panel.contentView!.subviews.allSatisfy { !($0 is NSButton) }, "不再有收起按钮")
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
        await expectString("pocketdeskDesktopOrb.state().emotion", NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "19" : "33", "实际原版完成动画")
        let playing = await js("pocketdeskDesktopOrb.state().active") as? Bool
        assert(playing == true || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "可见原生窗口必须实际播放")
        capture("completed")
        let scroll = panel.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!
        assert(scroll.frame.height > 30, "回答区域不能坍缩")
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
        print("sprite panel: 可见性/非激活/锁屏隔离/布局全部通过")
    }
}
