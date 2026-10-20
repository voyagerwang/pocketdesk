/**
 * [INPUT]: 依赖耳机设置/录制模型与原生窗口、HeadsetAppearance 产品主题投影，以及 TargetStore 主题变更通知。
 * [OUTPUT]: 对外提供来源/规则/保存/取消保护断言与经典、米白、系统深色下的原生 PNG 预览。
 * [POS]: tests 的耳机展示集成验收，使用主线程事件循环验证已打开窗口实时换肤；不保存配置、不录音、不注入按键或执行动作。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import SwiftUI

@main struct HeadsetMagpieNativeTests {
    static let previewDirectory: URL = {
        if let path = ProcessInfo.processInfo.environment["PD_HEADSET_PREVIEW_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketdesk-headset-previews-\(UUID().uuidString)", isDirectory: true)
    }()
    static func snapshot(_ window: NSWindow, name: String) {
        guard let view = window.contentView else { fatalError("Missing content") }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No render") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let folder = previewDirectory
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
        // --- 画布像素核验：左侧中点避开标题、页脚和内容卡片 ---
        let expected = NSColor(HeadsetAppearance.shared.palette.canvas).usingColorSpace(.deviceRGB)!
        guard let rendered = rep.colorAt(x: 4, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
            fatalError("Missing canvas pixel")
        }
        assert(abs(rendered.redComponent - expected.redComponent) < 0.025, "Unexpected red canvas in \(name)")
        assert(abs(rendered.greenComponent - expected.greenComponent) < 0.025, "Unexpected green canvas in \(name)")
        assert(abs(rendered.blueComponent - expected.blueComponent) < 0.025, "Unexpected blue canvas in \(name)")
        assert(view.bounds.width >= 650 && view.bounds.height >= 500)
    }
    static func verifySourceSelectionAndRules() {
        let volume = HeadsetSignal(kind: .volume, device: "preview-audio", name: "  Earphone   USB  ", usage: 1, step: 0.0625)
        let button = HeadsetSignal(kind: .hid, device: "1:2:preview", name: "earphone usb", vendor: 1, product: 2, usage: 0)
        let sources = [volume, button]
        assert(HeadsetMappingModel.recordingSource(uid: volume.device, sources: sources) == button)
        assert(HeadsetMappingModel.recordingSource(uid: button.device, sources: sources) == button)
        var ambiguous = button; ambiguous.device = "1:2:another"
        assert(HeadsetMappingModel.recordingSource(uid: volume.device, sources: sources + [ambiguous]) == volume)
        var unrelated = button; unrelated.name = "Another headset"
        assert(HeadsetMappingModel.recordingSource(uid: volume.device, sources: [volume, unrelated]) == volume)
        var emptyVolume = volume; emptyVolume.name = " "
        var emptyButton = button; emptyButton.name = ""
        assert(HeadsetMappingModel.recordingSource(uid: volume.device, sources: [emptyVolume, emptyButton]) == emptyVolume)
        assert(HeadsetMappingModel.recordingSource(uid: "missing", sources: sources) == nil)

        let model = HeadsetMappingModel()
        model.load(uid: volume.device, ruleID: nil, sources: sources, rules: [])
        assert(model.selected == button && model.operation == nil)
        let clickRule = HeadsetRule(signal: volume, gesture: .click, action: .spriteWake)
        let doubleRule = HeadsetRule(signal: volume, gesture: .doubleClick, action: .spriteWake)
        model.load(uid: volume.device, ruleID: doubleRule.id, sources: sources, rules: [doubleRule])
        assert(model.selected == volume && model.operation?.signal == volume && model.operation?.gesture == .doubleClick)
        assert(model.editingID == doubleRule.id && model.phase == .editing)
        model.load(uid: volume.device, ruleID: nil, sources: sources, rules: [])
        model.edit(.init(signal: volume, gesture: .click))
        assert(model.selected == volume && model.operation?.signal == volume && model.phase == .editing)

        let device = HeadsetSettingsDevice(id: volume.device, name: volume.name, kind: .volume, connected: true)
        let rows = HeadsetSettingsModel.operationRows(rules: [clickRule, doubleRule], device: device, step: volume.step)
        assert(rows.count == 3)
        assert(rows.filter { $0.rule?.id == clickRule.id }.count == 1)
        let doubleRow = rows.first { $0.rule?.id == doubleRule.id }!
        assert(doubleRow.title == "音量增加 · 双击")
        assert(device.displayName.contains("音量信号"))
        assert(HeadsetSettingsDevice(id: button.device, name: button.name, kind: .hid, connected: true).displayName.contains("独立按键"))
        var disabledDouble = doubleRule; disabledDouble.enabled = false
        let preferences = HeadsetSettingsModel(); preferences.defaultEnabled = true
        assert(preferences.functionLabel(.init(id: "disabled-double", signal: volume, gesture: .doubleClick, rule: disabledDouble)) == "保留原有功能")
        assert(preferences.functionLabel(.init(id: "default-click", signal: volume, gesture: .click, rule: nil)) == "默认：普通语音")
        model.stop()
    }
    static func postTheme(_ name: String) {
        NotificationCenter.default.post(name: TargetStore.themeDidChange, object: nil, userInfo: ["theme": name])
    }
    static func verifyTheme(_ name: String, windows: [NSWindow]) {
        let appearance = HeadsetAppearance.shared
        let expected: HeadsetPalette = name == "muji" ? .muji : .classic
        assert(appearance.theme == name)
        assert(appearance.palette.canvas == expected.canvas)
        assert(appearance.palette.accent == expected.accent)
        assert(appearance.palette.foreground == expected.foreground)
        for window in windows { assert(window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua) }
    }
    static func runSteps(_ steps: [() -> Void], index: Int = 0) {
        guard index < steps.count else { return }
        // --- 让真实 AppKit/SwiftUI 事件循环完成渲染，主队列不阻塞 ---
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            steps[index]()
            runSteps(steps, index: index + 1)
        }
    }
    static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        verifySourceSelectionAndRules()
        let item = HeadsetController.shared.settingsItem()
        assert(item.title == "耳机设置…" && item.submenu == nil)
        assert(item.action == #selector(HeadsetSettings.show))
        assert(item.target === HeadsetSettings.shared)
        let previousAppAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        _ = HeadsetAppearance.shared
        postTheme("classic")
        let owner = HeadsetMappingWindow.shared
        owner.show()
        assert(!owner.model.canSave && owner.model.operation == nil)
        assert(!owner.model.recordingKey && !HeadsetMappingRuntime.shared.learning)
        let recorderWindow = owner.window!
        let settings = HeadsetSettings.shared
        settings.show()
        let settingsWindow = settings.window!
        let windows = [settingsWindow, recorderWindow]
        let preferences = settings.model
        let oldUID = preferences.selectedUID
        preferences.pauseEditing = true; preferences.pauseEditingUID = oldUID; preferences.pauseText = "7.5"
        preferences.reload(); assert(preferences.pauseText == "7.5")
        preferences.pauseEditing = false; preferences.pauseEditingUID = nil; preferences.reload()
        runSteps([
            {
                verifyTheme("classic", windows: windows)
                snapshot(settingsWindow, name: "classic-settings")
                snapshot(recorderWindow, name: "classic-record-ready")
                postTheme("muji")
            },
            {
                assert(settings.window === settingsWindow && owner.window === recorderWindow)
                verifyTheme("muji", windows: windows)
                assert(!owner.model.canSave && owner.model.operation == nil)
                snapshot(settingsWindow, name: "muji-settings")
                snapshot(recorderWindow, name: "muji-record-ready")
                postTheme("classic")
            },
            {
                assert(settings.window === settingsWindow && owner.window === recorderWindow)
                verifyTheme("classic", windows: windows)
                let signal = HeadsetSignal(kind: .hid, device: "preview", name: "耳机预览", vendor: 1, product: 2, usage: 0xCD)
                owner.model.devices = [signal]; owner.model.deviceID = HeadsetMappingModel.identity(signal)
                owner.model.operation = .init(signal: signal, gesture: .click); owner.model.phase = .recognized
                owner.model.message = "已识别：播放 / 暂停 · 单击。请选择动作。"
                assert(owner.model.canSave && owner.model.draft()?.gesture == .click)
            },
            {
                snapshot(recorderWindow, name: "classic-record-recognized")
                owner.model.action = .openApp; owner.model.appPath = nil
                assert(!owner.model.canSave && owner.model.draft() == nil)
                assert(owner.model.operation != nil && owner.model.error)
            },
            {
                snapshot(recorderWindow, name: "classic-record-error")
                NSApp.appearance = NSAppearance(named: .darkAqua)
            },
            {
                assert(settings.window === settingsWindow && owner.window === recorderWindow)
                verifyTheme("classic", windows: windows)
                snapshot(settingsWindow, name: "classic-settings-system-dark")
                snapshot(recorderWindow, name: "classic-record-system-dark")
                owner.window?.close()
                assert(!HeadsetMappingRuntime.shared.learning && owner.window == nil)
                settings.window?.close()
                assert(settings.window == nil)
                NSApp.appearance = previousAppAppearance
                print("PASS native classic/muji themes update open windows and ignore OS dark appearance; unambiguous source preference, existing rules, save gating, close cancellation and edit protection; no config save, recording, key injection or dispatch")
                NSApp.stop(nil)
                NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
            }
        ])
        NSApp.run()
    }
}
