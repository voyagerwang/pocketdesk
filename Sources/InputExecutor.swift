/**
 * [INPUT]: 依赖 AppKit 的 NSWorkspace/NSPasteboard 与 CoreGraphics 的 CGEvent/CGEventSource；消费 Models 的 SendCommand/ShortcutConfig/InputError/ShortcutError/ShortcutKeys、TargetStore 的目标解析。
 * [OUTPUT]: 对外提供 InputExecutor（图片预上传暂存、应用激活、图文发送的 activate → Unicode → 粘贴图片 → Return 注入序列、快捷键组合注入）；合成键盘事件统一经 postKey（真实 CGEventSource + characters 补齐 + down/up 间隔），解决 Zed 终端这类按 characters 取键的应用对合成 Return 的丢弃。
 * [POS]: Sources 的键盘输入执行层；Server 把 /api/activate、/api/send、/api/image、/api/shortcut-trigger 委托给它，与 PointerExecutor（指针）平行为一对执行兄弟。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import CoreGraphics
import Foundation

final class InputExecutor {
    static let frontmostPseudoId = "__frontmost__"
    // UU 远程特殊通道：UU 的键盘同步不吃合成 Unicode 事件（表现为只透传占位符），
    // 但剪贴板是应用层双向同步的——发往 UU 的内容改走「写剪贴板 + Cmd+V + Return」。
    static let uuRemoteId = "uu"
    private let queue = DispatchQueue(label: "dev.voicedeck.input")
    private let store: TargetStore
    // 手机预上传的待发图片；send(usePendingImage) 时取出消费。
    private var pendingImageData: Data?
    private let pendingLock = NSLock()

    init(store: TargetStore) { self.store = store }

    func stageImage(_ data: Data, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async {
            guard data.count <= 10 * 1024 * 1024 else {
                completion(.failure(.message("图片太大（>10MB）。"))); return
            }
            self.pendingLock.lock()
            self.pendingImageData = data
            self.pendingLock.unlock()
            completion(.success(()))
        }
    }

    private func takePendingImage() -> Data? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let data = pendingImageData
        pendingImageData = nil
        return data
    }

    func activate(_ targetId: String, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async { self.activateTarget(targetId, completion: completion) }
    }

    func send(_ command: SendCommand, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async {
            // 新流程：图片随 /api/image 预上传，发送时只带标记。
            let stagedImage = command.usePendingImage == true ? self.takePendingImage() : nil
            let inlineImage = stagedImage == nil ? command.image.flatMap { Data(base64Encoded: $0) } : nil
            let imageData = stagedImage ?? inlineImage
            if command.usePendingImage == true && imageData == nil {
                completion(.failure(.message("图片未找到或已过期，请重新选择。"))); return
            }
            let hasText = !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasText || imageData != nil else {
                completion(.failure(.message("先输入一点内容或选择一张图片。"))); return
            }
            guard command.text.utf16.count <= 8_000 else {
                completion(.failure(.message("单次文本最多 8,000 个 UTF-16 字符。"))); return
            }
            self.dispatchSend(command, imageData: imageData, completion: completion)
        }
    }

    // 统一执行路径：先输入文字，再粘贴可选图片，最后提交。
    private func dispatchSend(_ command: SendCommand, imageData: Data?, completion: @escaping (Result<Void, InputError>) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(.failure(.message("尚未授予“辅助功能”权限。请在控制台完成授权。"))); return
        }
        // UU 远程特殊通道：写剪贴板 + Cmd+V（UU 剪贴板同步跨机）+ Return；不走 Unicode 注入。
        if command.targetId == Self.uuRemoteId || isUUFrontmost() {
            queue.asyncAfter(deadline: .now() + .milliseconds(450)) {
                self.performUURemotePaste(text: command.text, imageData: imageData)
                completion(.success(()))
            }
            return
        }
        // 伪目标：不切换应用，直接注入当前前台（前台是非 Dock 应用时的发送路径）。
        if command.targetId == Self.frontmostPseudoId {
            queue.asyncAfter(deadline: .now() + .milliseconds(80)) {
                self.performPaste(imageData: imageData, text: command.text)
                completion(.success(()))
            }
            return
        }
        activateTarget(command.targetId) { result in
            guard case .success = result else { completion(result); return }
            // 给桌面应用取得前台焦点；后续步骤都在同一串行队列中执行。
            self.queue.asyncAfter(deadline: .now() + .milliseconds(450)) {
                self.performPaste(imageData: imageData, text: command.text)
                completion(.success(()))
            }
        }
    }

    // 前台应用是不是 UU 远程（发往伪目标时的兜底判定）。
    private func isUUFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.bundleIdentifier == "com.netease.uuremote"
    }

    // UU 通道注入序列：文字+图片都进剪贴板（图片优先，纯文字给纯文本），
    // Cmd+V 由 UU 的剪贴板同步带跨机器，粘进远程电脑的输入框后 Return 提交。
    private func performUURemotePaste(text: String, imageData: Data?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let imageData, let image = NSImage(data: imageData) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.setString(text, forType: .string)
        }
        usleep(120_000) // 剪贴板写入落定，给 UU 同步留个起跑信号
        postKey(9, flags: .maskCommand) // Cmd+V
        usleep(600_000) // 等远端粘贴落框
        postKey(36) // Return
    }

    // 先在仍持有焦点的编辑器中输入文字，避免图片挂载期间的焦点变化吞掉文字。
    // 等文字落入编辑器后再粘贴图片；等待缩略图挂载后统一按 Return。
    // 图片发送后留在剪贴板上（与手动复制粘贴语义一致，不额外清空）。
    private func performPaste(imageData: Data?, text: String) {
        if !text.isEmpty {
            postUnicode(text)
            usleep(200_000) // 让编辑器处理文字，再开始附件粘贴或提交
        }
        if let imageData, let image = NSImage(data: imageData) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            postKey(9, flags: .maskCommand) // Cmd+V
            usleep(1_000_000) // 等目标应用完成粘贴读取与缩略图挂载
        }
        postKey(36) // Return：图文一起发，或纯图直发
    }

    private func activateTarget(_ targetId: String, completion: @escaping (Result<Void, InputError>) -> Void) {
        guard let config = store.resolve(targetId) else {
            completion(.failure(.message("未知的目标应用。"))); return
        }
        guard let url = store.appURL(config) else {
            completion(.failure(.message("未找到 \(config.name)。请确认应用已安装或在控制台重新选择。"))); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            if let error {
                completion(.failure(.message("无法打开 \(config.name)：\(error.localizedDescription)"))); return
            }
            application?.unhide()
            application?.activate(options: [.activateAllWindows])
            completion(.success(()))
        }
    }

    private func postUnicode(_ text: String) {
        var units = Array(text.utf16)
        let length = units.count
        units.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress,
                  let down = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: 0, keyDown: false) else { return }
            // Unicode 输入不继承当前系统修饰键，防止被解释为快捷键。
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: length, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: length, unicodeString: base)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // 合成键盘事件的公共底座：真实事件源 + characters 补齐 + down/up 间隔。
    // 无源 CGEvent 的 characters 为空，Zed 终端这类按 characters 解释回车/退格的应用会整键丢弃
    //（方向键按键码识别不受影响，故此前"上下能动、回车无效"）；Hammerspoon 等注入工具同样带源。
    private static let eventSource = CGEventSource(stateID: .combinedSessionState)
    // 终端类应用按 characters 解释的特殊键；字母/数字/F 键按键码识别，无需补。
    private static let keyCharacters: [CGKeyCode: String] = [
        36: "\r", 51: "\u{7F}", 48: "\t", 53: "\u{1B}", 49: " ",
    ]

    @discardableResult
    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard let down = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: code, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = flags
            if let text = Self.keyCharacters[code] {
                var units = Array(text.utf16)
                let count = units.count
                units.withUnsafeMutableBufferPointer { buffer in
                    if let base = buffer.baseAddress {
                        event.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
                    }
                }
            }
        }
        down.post(tap: .cghidEventTap)
        usleep(25_000) // 贴合物理按键的 press-release 间隔，避免快速采样应用漏判
        up.post(tap: .cghidEventTap)
        return true
    }

    // 快捷键：组合键注入当前前台应用，不切换目标；与 send 共用串行队列。
    func triggerShortcut(_ shortcut: ShortcutConfig, completion: @escaping (Result<Void, ShortcutError>) -> Void) {
        queue.async {
            guard AXIsProcessTrusted() else {
                completion(.failure(.message("尚未授予“辅助功能”权限。请在控制台完成授权。"))); return
            }
            // 语义串经 ShortcutKeys.resolve 统一解析为 CGEvent 键码 + flags；失败给明确报错。
            guard let resolved = ShortcutKeys.resolve(shortcut.hotkey) else {
                completion(.failure(.message("快捷键无法识别：\(shortcut.hotkey)"))); return
            }
            if self.postKey(resolved.keycode, flags: resolved.flags) {
                completion(.success(()))
            } else {
                completion(.failure(.message("快捷键事件创建失败。")))
            }
        }
    }
}
