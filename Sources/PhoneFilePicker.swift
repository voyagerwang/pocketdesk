/**
 * [INPUT]: AppKit 原生文件选择器、PhoneFileStore 快照和 LockScreenInput 锁屏状态。
 * [OUTPUT]: 网页回调与菜单共用选择器和快照准备； Dock 右键与应用菜单的“发送文件到手机…”明确入口；用户多选后后台准备，回执只表示等待手机接收。
 * [POS]: 电脑本机发送入口，不依赖手机任务或隐藏的小精灵，不读取未选择的文件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

final class PhoneFilePicker: NSObject {
    static let shared = PhoneFilePicker()
    private var preparing = false
    func menu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "发送文件到手机…", action: #selector(chooseFiles), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }
    func installMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出 PocketDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu; bar.addItem(appItem)
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        fileItem.submenu = menu(); bar.addItem(fileItem)
        NSApp.mainMenu = bar
    }
    @objc func chooseFiles() {
        presentPicker { result in
            if result["cancelled"] as? Bool == true { return }
            self.show("发送文件到手机", result["error"] as? String ?? result["message"] as? String ?? "文件已准备好。")
        }
    }
    // 网页和菜单共用系统选择器；网页由回调原地呈现结果，不再弹第二个原生提醒。
    func presentPicker(completion: @escaping ([String: Any]) -> Void) {
        guard !LockScreenInput.locked else { completion(["error": "请先解锁这台电脑。"]); return }
        guard !preparing else { completion(["error": "文件正在准备，请稍候。"]); return }
        preparing = true
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSOpenPanel()
        picker.title = "发送文件到手机"
        picker.message = "可多选，最多20个文件、合计512 MB。手机确认接收后下载。"
        picker.prompt = "发送到手机"
        picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
        picker.begin { result in
            guard result == .OK, !LockScreenInput.locked else {
                self.preparing = false; completion(["cancelled": true]); return
            }
            let paths = picker.urls.map(\.path)
            DispatchQueue.global(qos: .utility).async {
                let response: [String: Any]
                do {
                    let offer = try PhoneFileStore.shared.prepare(paths: paths, subject: PhoneFileStore.subject, taskId: UUID().uuidString,
                        authorized: { !LockScreenInput.locked })
                    response = ["ok": true, "file": offer.json, "message": "已准备好「\(offer.name)」，等待手机接收。"]
                } catch { response = ["error": error.localizedDescription] }
                DispatchQueue.main.async { self.preparing = false; completion(response) }
            }
        }
    }
    private func show(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "知道了"); alert.runModal()
    }
}
