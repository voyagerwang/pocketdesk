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
        assert(view.bounds.width >= 650 && view.bounds.height >= 500)
    }
    static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let item = HeadsetController.shared.settingsItem()
        assert(item.title == "耳机设置…" && item.submenu == nil)
        assert(item.action == #selector(HeadsetSettings.show))
        assert(item.target === HeadsetSettings.shared)
        NSApp.appearance = NSAppearance(named: .aqua)
        let owner = HeadsetMappingWindow.shared
        owner.show()
        assert(!owner.model.canSave && owner.model.operation == nil)
        assert(!owner.model.recordingKey && !HeadsetMappingRuntime.shared.learning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            snapshot(owner.window!, name: "record-ready")
            let signal = HeadsetSignal(kind: .hid, device: "preview", name: "耳机预览", vendor: 1, product: 2, usage: 0xCD)
            owner.model.devices = [signal]; owner.model.deviceID = HeadsetMappingModel.identity(signal)
            owner.model.operation = .init(signal: signal, gesture: .click); owner.model.phase = .recognized
            owner.model.message = "已识别：播放 / 暂停 · 单击。请选择动作。"
            assert(owner.model.canSave && owner.model.draft()?.gesture == .click)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                snapshot(owner.window!, name: "record-recognized")
                owner.model.action = .openApp; owner.model.appPath = nil
                assert(!owner.model.canSave && owner.model.draft() == nil)
                assert(owner.model.operation != nil && owner.model.error)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    snapshot(owner.window!, name: "record-error")
                    owner.window?.close()
                    assert(!HeadsetMappingRuntime.shared.learning && owner.window == nil)
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    owner.show()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        snapshot(owner.window!, name: "record-dark")
                        owner.window?.close()
                        NSApp.appearance = NSAppearance(named: .aqua)
                        HeadsetSettings.shared.show()
                        let preferences = HeadsetSettings.shared.model
                        let oldUID = preferences.selectedUID
                        preferences.pauseEditing = true; preferences.pauseEditingUID = oldUID; preferences.pauseText = "7.5"
                        preferences.reload(); assert(preferences.pauseText == "7.5")
                        preferences.pauseEditing = false; preferences.pauseEditingUID = nil; preferences.reload()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            snapshot(HeadsetSettings.shared.window!, name: "settings")
                            HeadsetSettings.shared.window?.close()
                            print("PASS native ready/recognized/error/dark/settings renders; save gating, preserved draft, close cancellation and edit protection; no config save, recording, key injection or dispatch")
                            NSApp.stop(nil)
                            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
                        }
                    }
                }
            }
        }
        NSApp.run()
    }
}
